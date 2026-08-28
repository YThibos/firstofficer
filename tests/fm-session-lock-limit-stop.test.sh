#!/usr/bin/env bash
# tests/fm-session-lock-limit-stop.test.sh - session-lock ownership boundaries:
# which process a session resolves to, and when a live holder may be taken over.
#
# Both halves are safety-critical in the same direction. Resolving a session to
# a process shared by every session in the machine makes a lock permanent and
# makes two sessions indistinguishable; taking a lock from a session that is
# still working destroys that session's authority mid-flight. So the shared
# service must never be selected, and only a positively identified usage-limit
# stop may be taken over.
#
# Process shapes come from a fixture `ps` table rather than real Claude
# processes, because the shapes under test (a background session under the
# shared daemon, a session stopped on a limit) cannot be produced on demand.
# Liveness still uses real background processes, so kill -0 means what it says.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-session-lock-lib.sh"
LOCK="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-session-lock-limit-stop)
BASE_PATH=$PATH
# The limit-stop classifier is a node program; every fixture keeps the real
# PATH behind fakebin, so a host without node would fail confusingly instead.
command -v node >/dev/null 2>&1 || fail "node is required to run this suite"

# fm_test_tmproot registers its dir from inside a command substitution, so the
# registration is lost with that subshell and the dir is removed as the subshell
# exits. Recreate it here and remove it in this suite's own trap, so the root
# exists for the whole run and nothing of it is left behind afterwards.
mkdir -p "$TMP_ROOT"

# Every starter below also runs inside a command substitution, so a variable it
# appends to dies with that subshell too. The holder pids are therefore recorded
# in a file, which is the only channel that reaches this shell.
HOLDER_PIDS="$TMP_ROOT/holder-pids"
: > "$HOLDER_PIDS"
release_holders() {
  local pid
  [ -f "$HOLDER_PIDS" ] || return 0
  while read -r pid; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done < "$HOLDER_PIDS"
  : > "$HOLDER_PIDS"
}
trap 'release_holders; rm -rf "$TMP_ROOT"; fm_test_cleanup' EXIT

# start_holder: a real live process to stand in for a lock holder, so liveness
# tests exercise kill -0 rather than a stub. Echoes its pid.
start_holder() {
  # Detached from this function's stdout, or a command substitution around the
  # call would block until the holder itself exits.
  sleep 300 >/dev/null 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" >> "$HOLDER_PIDS"
  printf '%s\n' "$pid"
}

# start_argv_holder <dir> <arg>...: a real live process whose OWN argv is the
# given elements, so a fixture holder's session id is resolved from real
# discrete argv rather than from anything this suite could hand the code under
# test. That distinction is the point of several cases below: the fixture `ps`
# table supplies the process NAME and command line identity is classified from,
# while the session id can only come from the live process itself. Echoes its
# pid.
start_argv_holder() {
  local dir=$1 prog="$1/argv-holder" pid
  shift
  if [ ! -x "$prog" ]; then
    cat > "$prog" <<'SH'
#!/usr/bin/env bash
# Keeps its own argv and stays killable: sleeping in the background and waiting
# means a TERM is handled at once and takes the sleep with it, where sleeping in
# the foreground would leave it behind.
set -u
sleep 300 &
child=$!
trap 'kill "$child" 2>/dev/null; exit 0' TERM INT
wait "$child" 2>/dev/null
SH
    chmod +x "$prog"
  fi
  "$prog" "$@" >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >> "$HOLDER_PIDS"
  printf '%s\n' "$pid"
}

# proc_supported: the takeover reads a holder's discrete argv from
# /proc/<pid>/cmdline and verifies a per-pid record against /proc/<pid>/stat,
# neither of which exists off Linux. There it refuses by design, so the cases
# that assert a takeover HAPPENS, or that a record restricted one, have nothing
# to assert and say so instead of failing.
proc_supported() { [ -r "/proc/$$/cmdline" ] && [ -r "/proc/$$/stat" ]; }

# make_case <name>: a case directory with a home, a fakebin, and an empty
# process table. Echoes "<dir>|<home>|<fakebin>|<table>".
make_case() {
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/fakebin" "$dir/claude-config"
  : > "$dir/ps-table"
  make_fake_ps "$dir/fakebin"
  printf '%s|%s|%s|%s\n' "$dir" "$dir/home" "$dir/fakebin" "$dir/ps-table"
}

# make_fake_ps <fakebin>: serve `ps -o comm=|args=|ppid=|etime= -p <pid>` from
# the tab separated table in FM_TEST_PS_TABLE (pid, ppid, comm, args, age).
# The age is the process's age in seconds, which is how a fixture places a
# holder's start time relative to its transcript's last record; the fake renders
# it in the POSIX [[dd-]hh:]mm:ss form real ps prints, so the parser under test
# is exercised rather than bypassed, and passes a non-numeric age through
# verbatim so a fixture can still present an unreadable one. A pid with no row
# answers as a plain foreground claude, which is what the transient process
# running the command under test looks like from inside these fixtures. Its
# parent is FM_TEST_PS_DEFAULT_PPID, so a fixture can put a live process there
# and give the command under test a session pid that outlives the command -
# exactly as a real session's harness pid does, and as any later read of the
# lock it writes depends on.
make_fake_ps() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=""
pid=""
prev=""
for arg in "$@"; do
  case "$arg" in
    comm=) field=comm ;;
    args=) field=args ;;
    ppid=) field=ppid ;;
    etime=) field=etime ;;
  esac
  [ "$prev" = "-p" ] && pid=$arg
  prev=$arg
done
[ -n "$field" ] && [ -n "$pid" ] || exit 1
# Render an age in seconds the way ps prints "etime": [[dd-]hh:]mm:ss.
as_etime() {
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' "$1"; return 0 ;;
  esac
  local total=$1 days hours mins secs
  days=$(( total / 86400 ))
  hours=$(( total % 86400 / 3600 ))
  mins=$(( total % 3600 / 60 ))
  secs=$(( total % 60 ))
  if [ "$days" -gt 0 ]; then
    printf '%d-%02d:%02d:%02d\n' "$days" "$hours" "$mins" "$secs"
  elif [ "$hours" -gt 0 ]; then
    printf '%02d:%02d:%02d\n' "$hours" "$mins" "$secs"
  else
    printf '%02d:%02d\n' "$mins" "$secs"
  fi
}
row=$(awk -F'\t' -v p="$pid" '$1 == p { print; exit }' "$FM_TEST_PS_TABLE" 2>/dev/null)
if [ -z "$row" ]; then
  case "$field" in
    comm|args) printf 'claude\n' ;;
    ppid) printf '%s\n' "${FM_TEST_PS_DEFAULT_PPID:-1}" ;;
    etime) as_etime 0 ;;
  esac
  exit 0
fi
IFS=$'\t' read -r _ row_ppid row_comm row_args row_age <<EOF
$row
EOF
case "$field" in
  comm) printf '%s\n' "$row_comm" ;;
  args) printf '%s\n' "$row_args" ;;
  ppid) printf '%s\n' "$row_ppid" ;;
  etime) as_etime "${row_age:-0}" ;;
esac
SH
  chmod +x "$fakebin/ps"
}

# add_process <table> <pid> <ppid> <comm> <args> [age-seconds]
add_process() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "${6:-0}" >> "$1"
}

# The two Claude process shapes this suite depends on, observed verbatim on a
# real machine: a background session's own host (its release version is the
# process name and its session id is in its argv) and the shared supervisor
# every background session in the machine descends from.
#
# The host shape is stated once, as discrete argv, because the suite needs it
# both ways: session_host_argv sets SESSION_HOST_ARGV for the live process a
# fixture starts, and session_host_args renders those same elements the way ps
# flattens them for the fixture table. Deriving one from the other is what keeps
# a fixture's process table and its own live process from ever describing
# different command lines.
SESSION_HOST_ARGV=()
session_host_argv() {  # <version> <session-id>
  SESSION_HOST_ARGV=(
    claude bg-pty-host --bg-pty-host "/tmp/cc-daemon/pty/$2.sock" 238 54
    -- "/opt/claude/versions/$1" --session-id "$2" --agent claude
  )
}

session_host_args() {  # <version> <session-id>
  session_host_argv "$1" "$2"
  printf '%s' "${SESSION_HOST_ARGV[*]}"
}

daemon_args() {
  printf '/usr/local/bin/claude daemon run --json-path /home/u/.claude/daemon.json --origin transient'
}

# walk_from <dir> <table> <fakebin> <parent-pid>: run the ancestry walk from a
# real process spliced into the fixture table under <parent-pid>.
walk_from() {
  local dir=$1 table=$2 fakebin=$3 parent=$4 driver="$1/walk.sh"
  cat > "$driver" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\t%s\tzsh\t-zsh\n' "$$" "$FM_TEST_PS_PARENT" >> "$FM_TEST_PS_TABLE"
# shellcheck source=/dev/null
. "$FM_TEST_LIB"
fm_harness_ancestry_pid
SH
  chmod +x "$driver"
  env PATH="$fakebin:$BASE_PATH" FM_TEST_PS_TABLE="$table" FM_TEST_LIB="$LIB" \
    FM_TEST_PS_PARENT="$parent" "$driver"
}

# transcript_path <home> <session-id>: where Claude Code keeps that session's
# transcript for a session working in <home>, under the fixture config root.
transcript_path() {
  printf '%s/projects/%s/%s.jsonl' \
    "$CLAUDE_CONFIG_DIR" "$(printf '%s' "$1" | tr '/.' '--')" "$2"
}

# write_transcript <path> <tail-kind> [last-record-timestamp]
# The last record's instant matters as much as its shape: the takeover requires
# the holder to have been running already when that record was written. It
# defaults to now, so a fixture holder given an age is a session that hit the
# limit while running, and a fixture passing an older instant is the resumed
# session that must NOT be taken over.
write_transcript() {
  local path=$1 kind=$2 at=${3:-$(date -u +%Y-%m-%dT%H:%M:%S.000Z)}
  mkdir -p "$(dirname "$path")"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"},"timestamp":"2026-08-20T07:39:46.497Z"}'
    case "$kind" in
      limit-stop)
        printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 12:40pm (Europe/Brussels) · progress saved"}]},"timestamp":"'"$at"'"}'
        ;;
      working)
        printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Captain, the fix is in."}]},"timestamp":"'"$at"'"}'
        ;;
      other-error)
        printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error: 529 Overloaded. This is a server-side issue, usually temporary."}]},"timestamp":"'"$at"'"}'
        ;;
      quoted-limit-stop)
        # A live session whose last turn merely QUOTED a limit message, which is
        # what a session working on this mechanism produces. Text matching would
        # steal its lock; a real parse of the record type must not.
        printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"You'"'"'ve hit your session limit · resets 12:40pm (Europe/Brussels) · progress saved"}]},"timestamp":"'"$at"'"}'
        ;;
      limit-stop-no-timestamp)
        printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 12:40pm (Europe/Brussels) · progress saved"}]}}'
        ;;
      truncated)
        printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assis'
        ;;
    esac
    # Claude appends metadata records after a session ends; they are not
    # conversational and must not hide the record the decision depends on.
    printf '%s\n' '{"type":"system","subtype":"turn_duration"}'
    printf '%s\n' '{"type":"ai-title","title":"a session"}'
    printf '%s\n' '{"type":"agent-name","name":"claude"}'
  } > "$path"
}

# claim <home> <fakebin> <table> [session-pid]: run a lock claim as a fresh
# session whose own harness pid is <session-pid>, defaulting to init so the
# claim resolves to the transient process itself.
claim() {
  env PATH="$2:$BASE_PATH" FM_TEST_PS_TABLE="$3" FM_HOME="$1" \
    FM_TEST_PS_DEFAULT_PPID="${4:-1}" \
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" "$LOCK"
}

lock_status() {  # <home> <fakebin> <table> [session-pid]
  env PATH="$2:$BASE_PATH" FM_TEST_PS_TABLE="$3" FM_HOME="$1" \
    FM_TEST_PS_DEFAULT_PPID="${4:-1}" \
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" "$LOCK" status
}

# add_session <table>: a live process standing in for the harness pid of the
# fresh session running the command under test. Echoes its pid.
add_session() {
  local pid
  pid=$(start_holder)
  add_process "$1" "$pid" 1 claude 'claude --dangerously-skip-permissions'
  printf '%s\n' "$pid"
}

# --- the shared-service boundary -------------------------------------------

test_walk_stops_below_the_shared_daemon() {
  local rec dir home fakebin table host daemon resolved
  rec=$(make_case walk-daemon)
  IFS='|' read -r dir home fakebin table <<EOF
$rec
EOF
  daemon=4001
  host=4002
  add_process "$table" "$daemon" 1 claude "$(daemon_args)"
  add_process "$table" "$host" "$daemon" 2.1.237 "$(session_host_args 2.1.237 aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee)"
  resolved=$(walk_from "$dir" "$table" "$fakebin" "$host")
  [ "$resolved" = "$host" ] \
    || fail "background session resolved to '$resolved', not its own host $host"
  pass "the ancestry walk stops at a background session's own host, not the shared daemon"
}

test_two_background_sessions_resolve_apart() {
  local rec dir home fakebin table daemon host_a host_b a b
  rec=$(make_case walk-two-sessions)
  IFS='|' read -r dir home fakebin table <<EOF
$rec
EOF
  daemon=4101
  host_a=4102
  host_b=4103
  add_process "$table" "$daemon" 1 claude "$(daemon_args)"
  add_process "$table" "$host_a" "$daemon" 2.1.237 "$(session_host_args 2.1.237 aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa)"
  add_process "$table" "$host_b" "$daemon" 2.1.237 "$(session_host_args 2.1.237 bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb)"
  a=$(walk_from "$dir" "$table" "$fakebin" "$host_a")
  b=$(walk_from "$dir" "$table" "$fakebin" "$host_b")
  [ "$a" = "$host_a" ] && [ "$b" = "$host_b" ] \
    || fail "concurrent background sessions resolved to '$a' and '$b', not $host_a and $host_b"
  [ "$a" != "$b" ] || fail "two concurrent background sessions resolved to the same pid $a"
  pass "two concurrent background sessions resolve to their own hosts, never a shared pid"
}

test_nested_claude_run_still_resolves_outermost() {
  local rec dir home fakebin table outer inner resolved
  rec=$(make_case walk-nested)
  IFS='|' read -r dir home fakebin table <<EOF
$rec
EOF
  outer=4201
  inner=4202
  add_process "$table" "$outer" 1 2.1.237 "claude bg-pty-host --bg-pty-host /tmp/cc-daemon/spare/x.pty.sock 200 50 -- /opt/claude/versions/2.1.237 --bg-spare /tmp/cc-daemon/spare/x.claim.sock"
  add_process "$table" "$inner" "$outer" 2.1.237 "claude bg-spare --bg-spare /tmp/cc-daemon/spare/x.claim.sock"
  resolved=$(walk_from "$dir" "$table" "$fakebin" "$inner")
  [ "$resolved" = "$outer" ] \
    || fail "nested claude run resolved to '$resolved', not its outermost pid $outer"
  pass "a genuine nested claude run still resolves to the outermost pid of that run"
}

test_daemon_holder_is_not_a_live_session() {
  local rec dir home fakebin table daemon session out
  rec=$(make_case liveness-daemon)
  IFS='|' read -r dir home fakebin table <<EOF
$rec
EOF
  daemon=$(start_holder)
  session=$(start_holder)
  add_process "$table" "$daemon" 1 claude "$(daemon_args)"
  add_process "$table" "$session" "$daemon" 2.1.237 "$(session_host_args 2.1.237 cccccccc-3333-3333-3333-cccccccccccc)"

  printf '%s\n' "$daemon" > "$home/state/.lock"
  out=$(lock_status "$home" "$fakebin" "$table")
  assert_contains "$out" "lock: stale" "a lock recording the live shared daemon was reported as a live session"

  printf '%s\n' "$session" > "$home/state/.lock"
  out=$(lock_status "$home" "$fakebin" "$table")
  assert_contains "$out" "lock: held by live harness pid $session" "a live session's own host was not reported as a live holder"
  pass "the shared daemon is never a live session holder, while a session host still is"
}

# --- taking over a session stopped by a usage limit -------------------------

# limit_stop_case <name> <tail-kind> [holder-age] [record-timestamp]: a home
# whose lock is held by a live Claude session with a transcript of the given
# shape. The holder defaults to an hour old against a record written now, which
# is a session that hit the limit while running; a caller overrides both to
# build the resumed session, whose process is younger than its own last record.
# Echoes "<home>|<fakebin>|<table>|<holder-pid>|<transcript>".
limit_stop_case() {
  local name=$1 kind=$2 age=${3:-3600} at=${4:-} rec dir home fakebin table
  local holder session_id transcript
  rec=$(make_case "$name")
  IFS='|' read -r dir home fakebin table <<EOF
$rec
EOF
  session_id=dddddddd-4444-4444-4444-dddddddddddd
  # A real process carrying the observed argv, because the session id is read
  # from the live process and not from the fixture table. Its own argv[0] is the
  # helper rather than "claude", which changes nothing: only the --session-id
  # element and the one after it are ever read.
  session_host_argv 2.1.235 "$session_id"
  holder=$(start_argv_holder "$dir" "${SESSION_HOST_ARGV[@]}")
  add_process "$table" "$holder" 1 2.1.235 "${SESSION_HOST_ARGV[*]}" "$age"
  printf '%s\n' "$holder" > "$home/state/.lock"
  transcript=$(transcript_path "$home" "$session_id")
  [ "$kind" = none ] || write_transcript "$transcript" "$kind" ${at:+"$at"}
  printf '%s|%s|%s|%s|%s\n' "$home" "$fakebin" "$table" "$holder" "$transcript"
}

# seconds_ago <n>: an ISO 8601 instant <n> seconds in the past, for a fixture
# that needs a record demonstrably older than its holder process.
seconds_ago() {
  date -u -d "@$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%S.000Z
}

test_limit_stopped_holder_is_taken_over() {
  local rec home fakebin table holder transcript out status=0 recorded session
  if ! proc_supported; then
    pass "the takeover needs a holder's discrete argv and is not evaluated on this host"
    return 0
  fi
  rec=$(limit_stop_case takeover limit-stop)
  IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
  session=$(add_session "$table")
  out=$(claim "$home" "$fakebin" "$table" "$session") || status=$?
  expect_code 0 "$status" "a limit-stopped holder must not refuse the claim"
  assert_contains "$out" "lock takeover:" "the takeover was not announced"
  assert_contains "$out" "stopped by a usage limit" "the takeover did not say why it was allowed"
  assert_contains "$out" "lock acquired:" "the claim did not report acquiring the lock"
  recorded=$(cat "$home/state/.lock")
  [ "$recorded" = "$session" ] \
    || fail "the lock records '$recorded', not the session that took it over ($session)"
  assert_present "$home/state/.lock.takeover" "the takeover was not recorded durably"

  out=$(lock_status "$home" "$fakebin" "$table" "$session")
  assert_contains "$out" "took over from a session stopped by a usage limit" \
    "a later read did not report that this session took over"
  pass "a live holder stopped by a usage limit is taken over, announced, and recorded"
}

test_working_holder_still_refuses() {
  local rec home fakebin table holder transcript out status=0
  rec=$(limit_stop_case working working)
  IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
  out=$(claim "$home" "$fakebin" "$table" 2>&1) || status=$?
  expect_code 1 "$status" "a working holder must still refuse the claim"
  assert_contains "$out" "another live firstmate session holds the lock" "the refusal lost its own explanation"
  assert_not_contains "$out" "takeover" "a working session was reported as taken over"
  [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "a working holder's lock was overwritten"
  pass "a holder that is still working keeps its lock and the new session stays read-only"
}

test_quoted_limit_message_does_not_steal_a_lock() {
  local rec home fakebin table holder transcript status=0
  rec=$(limit_stop_case quoted quoted-limit-stop)
  IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
  claim "$home" "$fakebin" "$table" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a session that merely quoted a limit message was taken over"
  [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "a working holder's lock was overwritten"
  pass "a live session that only quoted a limit message keeps its lock"
}

test_ambiguous_transcripts_refuse() {
  local kind rec home fakebin table holder transcript status
  for kind in none truncated other-error; do
    status=0
    rec=$(limit_stop_case "ambiguous-$kind" "$kind")
    IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
    claim "$home" "$fakebin" "$table" >/dev/null 2>&1 || status=$?
    expect_code 1 "$status" "a '$kind' transcript must keep refusing the claim"
    [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "a '$kind' transcript let the lock be taken"
  done
  pass "a missing, unparseable, or non-limit transcript keeps refusing the claim"
}

test_unresolvable_holders_refuse() {
  local rec dir home fakebin table holder status name
  local -a argv
  for name in no-session-id non-claude; do
    status=0
    rec=$(make_case "unresolvable-$name")
    IFS='|' read -r dir home fakebin table <<EOF
$rec
EOF
    # The non-Claude holder deliberately carries a real --session-id pair, so
    # its refusal can only come from the harness test and not from an absence.
    case "$name" in
      no-session-id) argv=(claude --dangerously-skip-permissions) ;;
      non-claude) argv=(codex --session-id dddddddd-4444-4444-4444-dddddddddddd) ;;
    esac
    holder=$(start_argv_holder "$dir" "${argv[@]}")
    add_process "$table" "$holder" 1 "${argv[0]}" "${argv[*]}"
    printf '%s\n' "$holder" > "$home/state/.lock"
    # A transcript that WOULD authorise a takeover, so the refusal can only come
    # from failing to tie this holder to it.
    write_transcript "$(transcript_path "$home" dddddddd-4444-4444-4444-dddddddddddd)" limit-stop
    claim "$home" "$fakebin" "$table" >/dev/null 2>&1 || status=$?
    expect_code 1 "$status" "a '$name' holder must keep refusing the claim"
    [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "a '$name' holder lost its lock"
  done
  pass "a holder with no resolvable session id, and one that is not Claude, both keep refusing"
}

test_session_id_inside_one_argument_is_not_read() {
  local rec dir home fakebin table holder status=0 planted
  local -a argv
  rec=$(make_case argv-one-argument)
  IFS='|' read -r dir home fakebin table <<EOF
$rec
EOF
  planted=dddddddd-4444-4444-4444-dddddddddddd
  # A live session whose own prompt carries the words a flattened command line
  # cannot tell apart from a real flag pair - which is exactly what a session
  # working on this mechanism looks like. Its discrete argv holds no
  # --session-id element at all, so nothing ties it to the transcript below.
  argv=(claude -p "explain how --session-id $planted resolves a transcript")
  holder=$(start_argv_holder "$dir" "${argv[@]}")
  add_process "$table" "$holder" 1 claude "${argv[*]}"
  printf '%s\n' "$holder" > "$home/state/.lock"
  # A transcript that WOULD authorise a takeover under the planted id, so the
  # refusal can only come from declining to read that id out of one argument.
  write_transcript "$(transcript_path "$home" "$planted")" limit-stop
  claim "$home" "$fakebin" "$table" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a session id quoted inside one argument was read as the holder's own"
  [ "$(cat "$home/state/.lock")" = "$holder" ] \
    || fail "a working session lost its lock to a session id it had merely quoted"
  pass "a --session-id pair inside a single argument is never read as the holder's own session"
}

test_resumed_session_keeps_its_lock() {
  local rec home fakebin table holder transcript status=0
  # The reported defect: resuming a limit-stopped session reuses its session id
  # and its transcript, so the tail still ends on the limit error while the
  # session is live and working. Its process is younger than that record.
  rec=$(limit_stop_case resumed limit-stop 60 "$(seconds_ago 7200)")
  IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
  claim "$home" "$fakebin" "$table" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a resumed limit-stopped session was taken over while live"
  [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "a resumed session lost its lock"
  pass "a resumed limit-stopped session keeps its lock, because its process is younger than its last record"
}

test_missing_record_instant_refuses() {
  local rec home fakebin table holder transcript status=0
  rec=$(limit_stop_case no-instant limit-stop-no-timestamp)
  IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
  claim "$home" "$fakebin" "$table" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a limit-stop record with no instant must keep refusing the claim"
  [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "a timestamp-less record let the lock be taken"
  pass "a limit-stop record carrying no instant refuses, rather than skipping the start-time test"
}

test_unreadable_start_time_refuses() {
  local rec home fakebin table holder transcript status=0
  # A holder whose age cannot be read at all: the start-time test has no value
  # to compare, so the claim must refuse rather than fall back to the tail alone.
  rec=$(limit_stop_case no-start limit-stop unreadable)
  IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
  claim "$home" "$fakebin" "$table" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "an unreadable holder start time must keep refusing the claim"
  [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "an unreadable start time let the lock be taken"
  pass "a holder whose start time cannot be read refuses, never falling back to the transcript alone"
}

test_takeover_is_not_attributed_to_other_readers() {
  local rec home fakebin table holder transcript out taker other
  if ! proc_supported; then
    pass "takeover attribution needs a holder's discrete argv and is not evaluated on this host"
    return 0
  fi
  rec=$(limit_stop_case attribution limit-stop)
  IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
  taker=$(add_session "$table")
  claim "$home" "$fakebin" "$table" "$taker" >/dev/null 2>&1 \
    || fail "the takeover that this case depends on did not happen"
  out=$(lock_status "$home" "$fakebin" "$table" "$taker")
  assert_contains "$out" "took over from" "the session that took over was not told so"

  # A third session reads the same lock. It took nothing, so it must not be told
  # that it did - the marker names the session that took over, not the reader.
  other=$(add_session "$table")
  out=$(lock_status "$home" "$fakebin" "$table" "$other")
  assert_not_contains "$out" "took over" "a session that took nothing was told it took over"
  assert_contains "$out" "held by live harness pid $taker" "the reading session lost sight of the real holder"
  pass "only the session that took the lock over is told it did"
}

# --- the per-pid session record cross-check ---------------------------------
#
# Claude Code keeps one record per live session process at
# <config-root>/sessions/<pid>.json naming that session's CURRENT session id, so
# a holder that replaced its conversation in place can be told apart from one
# still working on the session its argv names. The record is only trusted when
# its procStart matches the live process, which needs /proc and therefore only
# exists on Linux; elsewhere every record is unverifiable and the cross-check
# adds nothing, which is exactly what these cases assert for an absent one.

# proc_start_ticks <pid>: field 22 of /proc/<pid>/stat, the value Claude Code
# records as procStart.
proc_start_ticks() {
  awk '{ sub(/^[^)]*\) /, ""); print $20 }' "/proc/$1/stat"
}

# write_session_record <pid> <session-id> [proc-start]: a real per-pid session
# record, defaulting to the live process's true start value.
write_session_record() {
  local pid=$1 id=$2 start=${3:-}
  [ -n "$start" ] || start=$(proc_start_ticks "$pid")
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
  printf '{"pid":%s,"sessionId":"%s","cwd":"/tmp","procStart":"%s","kind":"interactive"}\n' \
    "$pid" "$id" "$start" > "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
}

test_replaced_session_keeps_its_lock() {
  local rec home fakebin table holder transcript status=0
  if ! proc_supported; then
    pass "the replaced-session cross-check needs /proc and is not evaluated on this host"
    return 0
  fi
  # The reported defect: the holder hit the limit under the session its argv
  # names, then replaced its conversation in place and is working again under a
  # new one. Its argv, and so the transcript this resolves, cannot know that.
  rec=$(limit_stop_case replaced limit-stop)
  IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
  write_session_record "$holder" eeeeeeee-5555-5555-5555-eeeeeeeeeeee
  claim "$home" "$fakebin" "$table" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a holder working under a replaced session was taken over"
  [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "a working holder lost its lock"
  pass "a holder whose current session differs from the one its argv names keeps its lock"
}

test_absent_session_record_still_takes_over() {
  local rec home fakebin table holder transcript session status=0
  if ! proc_supported; then
    pass "the absent-record case needs a holder's discrete argv and is not evaluated on this host"
    return 0
  fi
  rec=$(limit_stop_case no-record limit-stop)
  IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
  [ -e "$CLAUDE_CONFIG_DIR/sessions/$holder.json" ] \
    && fail "this case depends on the holder having no per-pid record"
  session=$(add_session "$table")
  claim "$home" "$fakebin" "$table" "$session" >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "a holder with no per-pid record was refused, so the cross-check did more than restrict"
  [ "$(cat "$home/state/.lock")" = "$session" ] || fail "the takeover did not record the taking session"
  pass "a holder with no per-pid record is taken over exactly as before"
}

test_stale_session_record_is_ignored() {
  local rec home fakebin table holder transcript session status=0
  if ! proc_supported; then
    pass "the stale-record case needs /proc and is not evaluated on this host"
    return 0
  fi
  rec=$(limit_stop_case stale-record limit-stop)
  IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
  # A record left behind by a process that once had this pid: it names another
  # session, but its procStart belongs to that dead process, so it is not this
  # holder's record and must not restrict anything.
  write_session_record "$holder" eeeeeeee-6666-6666-6666-eeeeeeeeeeee 1
  session=$(add_session "$table")
  claim "$home" "$fakebin" "$table" "$session" >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "a record from a reused pid was trusted and blocked the takeover"
  [ "$(cat "$home/state/.lock")" = "$session" ] || fail "the takeover did not record the taking session"
  pass "a per-pid record whose procStart does not match the live process is ignored"
}

test_status_names_the_takeover_command() {
  local rec home fakebin table holder transcript out
  if ! proc_supported; then
    pass "reporting a limit-stopped holder needs its discrete argv and is not evaluated on this host"
    return 0
  fi
  rec=$(limit_stop_case status-report limit-stop)
  IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
  out=$(lock_status "$home" "$fakebin" "$table")
  assert_contains "$out" "held by a session stopped by a usage limit" "status did not report the limit-stopped holder"
  assert_contains "$out" "bin/fm-lock.sh" "status did not name the command that takes the lock over"
  [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "reading the status took the lock"
  pass "status reports a limit-stopped holder and names the takeover command without claiming it"
}

CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-config"
export CLAUDE_CONFIG_DIR
mkdir -p "$CLAUDE_CONFIG_DIR"
test_walk_stops_below_the_shared_daemon
test_two_background_sessions_resolve_apart
test_nested_claude_run_still_resolves_outermost
test_daemon_holder_is_not_a_live_session
test_limit_stopped_holder_is_taken_over
test_working_holder_still_refuses
test_quoted_limit_message_does_not_steal_a_lock
test_ambiguous_transcripts_refuse
test_unresolvable_holders_refuse
test_session_id_inside_one_argument_is_not_read
test_resumed_session_keeps_its_lock
test_missing_record_instant_refuses
test_unreadable_start_time_refuses
test_replaced_session_keeps_its_lock
test_absent_session_record_still_takes_over
test_stale_session_record_is_ignored
test_takeover_is_not_attributed_to_other_readers
test_status_names_the_takeover_command

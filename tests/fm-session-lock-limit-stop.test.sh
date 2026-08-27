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

HOLDERS=()
release_holders() {
  local pid
  for pid in "${HOLDERS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  HOLDERS=()
}
trap 'release_holders; fm_test_cleanup' EXIT

# start_holder: a real live process to stand in for a lock holder, so liveness
# tests exercise kill -0 rather than a stub. Echoes its pid.
start_holder() {
  # Detached from this function's stdout, or a command substitution around the
  # call would block until the holder itself exits.
  sleep 300 >/dev/null 2>&1 &
  local pid=$!
  HOLDERS+=("$pid")
  printf '%s\n' "$pid"
}

# make_case <name>: a case directory with a home, a fakebin, and an empty
# process table. Echoes "<dir>|<home>|<fakebin>|<table>".
make_case() {
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/fakebin" "$dir/claude-config"
  : > "$dir/ps-table"
  make_fake_ps "$dir/fakebin"
  printf '%s|%s|%s|%s\n' "$dir" "$dir/home" "$dir/fakebin" "$dir/ps-table"
}

# make_fake_ps <fakebin>: serve `ps -o comm=|args=|ppid= -p <pid>` from the tab
# separated table in FM_TEST_PS_TABLE (pid, ppid, comm, args). A pid with no row
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
  esac
  [ "$prev" = "-p" ] && pid=$arg
  prev=$arg
done
[ -n "$field" ] && [ -n "$pid" ] || exit 1
row=$(awk -F'\t' -v p="$pid" '$1 == p { print; exit }' "$FM_TEST_PS_TABLE" 2>/dev/null)
if [ -z "$row" ]; then
  case "$field" in
    comm|args) printf 'claude\n' ;;
    ppid) printf '%s\n' "${FM_TEST_PS_DEFAULT_PPID:-1}" ;;
  esac
  exit 0
fi
IFS=$'\t' read -r _ row_ppid row_comm row_args <<EOF
$row
EOF
case "$field" in
  comm) printf '%s\n' "$row_comm" ;;
  args) printf '%s\n' "$row_args" ;;
  ppid) printf '%s\n' "$row_ppid" ;;
esac
SH
  chmod +x "$fakebin/ps"
}

# add_process <table> <pid> <ppid> <comm> <args>
add_process() {
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$1"
}

# The two Claude process shapes this suite depends on, observed verbatim on a
# real machine: a background session's own host (its release version is the
# process name and its session id is in its argv) and the shared supervisor
# every background session in the machine descends from.
session_host_args() {  # <version> <session-id>
  printf 'claude bg-pty-host --bg-pty-host /tmp/cc-daemon/pty/%s.sock 238 54 -- /opt/claude/versions/%s --session-id %s --agent claude' \
    "$2" "$1" "$2"
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

write_transcript() {  # <path> <tail-kind>
  local path=$1 kind=$2
  mkdir -p "$(dirname "$path")"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"},"timestamp":"2026-08-20T07:39:46.497Z"}'
    case "$kind" in
      limit-stop)
        printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 12:40pm (Europe/Brussels) · progress saved"}]},"timestamp":"2026-08-20T07:39:47.128Z"}'
        ;;
      working)
        printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Captain, the fix is in."}]},"timestamp":"2026-08-20T07:39:47.128Z"}'
        ;;
      other-error)
        printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"API Error: 529 Overloaded. This is a server-side issue, usually temporary."}]},"timestamp":"2026-08-20T07:39:47.128Z"}'
        ;;
      quoted-limit-stop)
        # A live session whose last turn merely QUOTED a limit message, which is
        # what a session working on this mechanism produces. Text matching would
        # steal its lock; a real parse of the record type must not.
        printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"You'"'"'ve hit your session limit · resets 12:40pm (Europe/Brussels) · progress saved"}]},"timestamp":"2026-08-20T07:39:47.128Z"}'
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

# limit_stop_case <name> <tail-kind>: a home whose lock is held by a live
# Claude session with a transcript of the given shape.
# Echoes "<home>|<fakebin>|<table>|<holder-pid>|<transcript>".
limit_stop_case() {
  local name=$1 kind=$2 rec dir home fakebin table holder session_id transcript
  rec=$(make_case "$name")
  IFS='|' read -r dir home fakebin table <<EOF
$rec
EOF
  session_id=dddddddd-4444-4444-4444-dddddddddddd
  holder=$(start_holder)
  add_process "$table" "$holder" 1 2.1.235 "$(session_host_args 2.1.235 "$session_id")"
  printf '%s\n' "$holder" > "$home/state/.lock"
  transcript=$(transcript_path "$home" "$session_id")
  [ "$kind" = none ] || write_transcript "$transcript" "$kind"
  printf '%s|%s|%s|%s|%s\n' "$home" "$fakebin" "$table" "$holder" "$transcript"
}

test_limit_stopped_holder_is_taken_over() {
  local rec home fakebin table holder transcript out status=0 recorded session
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
  local rec dir home fakebin table holder status name args
  for name in no-session-id non-claude; do
    status=0
    rec=$(make_case "unresolvable-$name")
    IFS='|' read -r dir home fakebin table <<EOF
$rec
EOF
    holder=$(start_holder)
    case "$name" in
      no-session-id) args='claude --dangerously-skip-permissions' ;;
      non-claude) args='codex --session-id dddddddd-4444-4444-4444-dddddddddddd' ;;
    esac
    add_process "$table" "$holder" 1 "${args%% *}" "$args"
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

test_status_names_the_takeover_command() {
  local rec home fakebin table holder transcript out
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
test_status_names_the_takeover_command

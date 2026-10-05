#!/usr/bin/env bash
# tests/fm-session-lock-limit-stop.test.sh - when a live session-lock holder
# may be taken over because its session stopped on a usage limit.
#
# Taking a lock from a session that is still working destroys that session's
# authority mid-flight, so only a positively identified usage-limit stop may be
# taken over. The holder's session id comes from the state/.lock-session sidecar
# the holder itself recorded beside the lock, never from its argv.
#
# Process shapes come from a fixture `ps` table rather than real Claude
# processes, because a session stopped on a limit cannot be produced on demand.
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
# given elements, for the one case that proves argv is never a session-id
# source. Echoes its pid.
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
# A host's real pid 1 is init, never harness-shaped. The session-lock walk
# examines pid 1 because a harness can be pid 1 of its own PID namespace, so
# the catch-all below must not answer for it.
if [ -z "$row" ] && [ "$pid" = 1 ]; then
  case "$field" in
    comm) printf 'systemd\n' ;;
    args) printf '/sbin/init\n' ;;
    ppid) printf '0\n' ;;
    etime) as_etime 0 ;;
  esac
  exit 0
fi
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
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    PATH="$2:$BASE_PATH" FM_TEST_PS_TABLE="$3" FM_HOME="$1" \
    FM_TEST_PS_DEFAULT_PPID="${4:-1}" \
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" "$LOCK"
}

lock_status() {  # <home> <fakebin> <table> [session-pid]
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    PATH="$2:$BASE_PATH" FM_TEST_PS_TABLE="$3" FM_HOME="$1" \
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

# --- taking over a session stopped by a usage limit -------------------------

# limit_stop_case <name> <tail-kind> [holder-age] [record-timestamp] [comm] [args]:
# a home whose lock is held by a live Claude session, with that session's id
# recorded beside the lock and a transcript of the given shape. The holder
# defaults to an hour old against a record written now, which is a session that
# hit the limit while running; a caller overrides both to build the resumed
# session, whose process is younger than its own last record. The holder's
# process shape defaults to a plain claude, and a caller passes another to cover
# the version-named executable Claude Code's native installer runs.
# Echoes "<home>|<fakebin>|<table>|<holder-pid>|<transcript>".
LIMIT_SESSION_ID=dddddddd-4444-4444-4444-dddddddddddd
limit_stop_case() {
  local name=$1 kind=$2 age=${3:-3600} at=${4:-} comm=${5:-claude}
  local args=${6:-claude --dangerously-skip-permissions} rec dir home fakebin table
  local holder transcript
  rec=$(make_case "$name")
  IFS='|' read -r dir home fakebin table <<EOF
$rec
EOF
  holder=$(start_holder)
  add_process "$table" "$holder" 1 "$comm" "$args" "$age"
  printf '%s\n' "$holder" > "$home/state/.lock"
  printf '%s\n' "$LIMIT_SESSION_ID" > "$home/state/.lock-session"
  transcript=$(transcript_path "$home" "$LIMIT_SESSION_ID")
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
  for name in no-sidecar malformed-sidecar non-claude; do
    status=0
    rec=$(make_case "unresolvable-$name")
    IFS='|' read -r dir home fakebin table <<EOF
$rec
EOF
    holder=$(start_holder)
    case "$name" in
      non-claude) add_process "$table" "$holder" 1 codex 'codex' 3600 ;;
      *) add_process "$table" "$holder" 1 claude 'claude --dangerously-skip-permissions' 3600 ;;
    esac
    printf '%s\n' "$holder" > "$home/state/.lock"
    # The non-Claude holder deliberately carries a real recorded id, so its
    # refusal can only come from the harness test and not from an absence; the
    # malformed one would name a path outside the transcript directory.
    case "$name" in
      no-sidecar) : ;;
      malformed-sidecar) printf '%s\n' "../$LIMIT_SESSION_ID" > "$home/state/.lock-session" ;;
      non-claude) printf '%s\n' "$LIMIT_SESSION_ID" > "$home/state/.lock-session" ;;
    esac
    # A transcript that WOULD authorise a takeover, so the refusal can only come
    # from failing to tie this holder to it.
    write_transcript "$(transcript_path "$home" "$LIMIT_SESSION_ID")" limit-stop
    claim "$home" "$fakebin" "$table" >/dev/null 2>&1 || status=$?
    expect_code 1 "$status" "a '$name' holder must keep refusing the claim"
    [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "a '$name' holder lost its lock"
  done
  pass "a holder with no recorded session id, a malformed one, or one that is not Claude keeps refusing"
}

test_session_id_in_argv_is_not_read() {
  local rec dir home fakebin table holder status=0 planted
  local -a argv
  rec=$(make_case argv-not-a-source)
  IFS='|' read -r dir home fakebin table <<EOF
$rec
EOF
  planted=$LIMIT_SESSION_ID
  # A live session whose argv carries a real --session-id pair, with nothing
  # recorded beside the lock. Only the sidecar the holder wrote ties it to a
  # transcript, so argv must never stand in for it.
  argv=(claude --session-id "$planted")
  holder=$(start_argv_holder "$dir" "${argv[@]}")
  add_process "$table" "$holder" 1 claude "${argv[*]}" 3600
  printf '%s\n' "$holder" > "$home/state/.lock"
  write_transcript "$(transcript_path "$home" "$planted")" limit-stop
  claim "$home" "$fakebin" "$table" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a session id read from the holder's argv authorised a takeover"
  [ "$(cat "$home/state/.lock")" = "$holder" ] \
    || fail "a holder lost its lock on a session id it never recorded beside the lock"
  pass "a --session-id in the holder's argv is never read as the recorded session"
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

# --- the sidecar names the conversation the holder is on now ------------------
#
# A live session that replaces its conversation in place (/clear) re-keys its
# session id, and bin/fm-lock.sh refreshes the sidecar to the new id when that
# same process confirms its lock. The old conversation's transcript can still
# end on the limit error, so the takeover must follow the recorded id rather
# than any transcript that merely belongs to the holder's past.
test_rekeyed_session_keeps_its_lock() {
  local rec home fakebin table holder transcript status=0
  rec=$(limit_stop_case rekeyed limit-stop)
  IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
  printf '%s\n' eeeeeeee-5555-5555-5555-eeeeeeeeeeee > "$home/state/.lock-session"
  write_transcript "$(transcript_path "$home" eeeeeeee-5555-5555-5555-eeeeeeeeeeee)" working
  claim "$home" "$fakebin" "$table" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a holder working under a re-keyed session was taken over"
  [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "a working holder lost its lock"
  pass "a holder whose recorded session is still working keeps its lock, whatever an older transcript says"
}

# --- the version-named executable ---------------------------------------------
#
# Claude Code's native installer runs a per-session executable named after its
# release version, so neither its process name nor its basename says claude.
# Upstream's harness identity recognises it by the whole `claude` path
# component in argv[0], and the takeover has to reach the same holder.
VERSIONED_ARGS='/opt/claude/versions/2.1.235 --agent claude'

test_limit_stopped_versioned_holder_is_taken_over() {
  local rec home fakebin table holder transcript session out status=0
  rec=$(limit_stop_case versioned-takeover limit-stop 3600 '' 2.1.235 "$VERSIONED_ARGS")
  IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
  out=$(lock_status "$home" "$fakebin" "$table")
  assert_contains "$out" "held by a session stopped by a usage limit" \
    "a limit-stopped version-named holder was reported as another live session holding the lock"

  session=$(add_session "$table")
  out=$(claim "$home" "$fakebin" "$table" "$session") || status=$?
  expect_code 0 "$status" "a limit-stopped version-named holder must not refuse the claim"
  assert_contains "$out" "stopped by a usage limit" "the takeover did not say why it was allowed"
  [ "$(cat "$home/state/.lock")" = "$session" ] \
    || fail "the lock was not handed to the session that took it over"
  pass "a limit-stopped version-named holder is identified and taken over"
}

test_working_versioned_holder_still_refuses() {
  local rec home fakebin table holder transcript status=0 out
  rec=$(limit_stop_case versioned-working working 3600 '' 2.1.235 "$VERSIONED_ARGS")
  IFS='|' read -r home fakebin table holder transcript <<EOF
$rec
EOF
  out=$(claim "$home" "$fakebin" "$table" 2>&1) || status=$?
  expect_code 1 "$status" "a working version-named holder must still refuse the claim"
  assert_contains "$out" "another live firstmate session holds the lock" "the refusal lost its own explanation"
  [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "a working version-named holder lost its lock"
  pass "a version-named holder that is still working keeps its lock"
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
test_limit_stopped_holder_is_taken_over
test_working_holder_still_refuses
test_quoted_limit_message_does_not_steal_a_lock
test_ambiguous_transcripts_refuse
test_unresolvable_holders_refuse
test_session_id_in_argv_is_not_read
test_resumed_session_keeps_its_lock
test_missing_record_instant_refuses
test_unreadable_start_time_refuses
test_rekeyed_session_keeps_its_lock
test_limit_stopped_versioned_holder_is_taken_over
test_working_versioned_holder_still_refuses
test_takeover_is_not_attributed_to_other_readers
test_status_names_the_takeover_command

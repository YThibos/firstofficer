#!/usr/bin/env bash
# Behavior tests for the fork's standby rule in bin/fm-session-lock-lib.sh.
#
# Claude Code's background daemon keeps pre-warmed spare session hosts
# (`claude bg-spare`), and a spare runs SessionStart while it is being
# pre-warmed, long before anyone uses it. Unchecked, it claims the home's lock
# and sits on it as a live harness, so the captain's real session starts
# read-only. These pin that an unclaimed standby never wins or holds the lock,
# and that the same process is an ordinary session once claimed. Upstream's
# tests/fm-session-lock-ancestry.test.sh owns harness identity itself.
# shellcheck disable=SC2016,SC2089,SC2090 # CLAIM_PROBE is a shell snippet handed verbatim to a child shell, so its single quotes and unexpanded variables are deliberate
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-identity)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

# A "release binary" whose file name is a bare version, exactly like a real
# Claude Code install under versions/<v>. Its process name is that version, and
# a fixture invokes it as claude, the argv[0] a real standby carries.
VERSIONED="$FAKEBIN/2.1.235"
ln -s /bin/bash "$VERSIONED"

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# A child that holds its own process name for the length of the check. It blocks
# in a shell builtin reading a fifo nobody ever writes, so the fixture shell
# stays alive AS ITSELF: no "sleep" is exec-optimised over the process shape
# under test, and no separate long-lived child survives the kill still holding
# the test's inherited stdout, which would stall the serial runner's tee.
HOLD_FIFO="$TMP_ROOT/hold.fifo"
mkfifo "$HOLD_FIFO"
HOLD="read -r _ < '$HOLD_FIFO'"

# start_child <argv0> <binary> [extra arg]: run <binary> under the given argv[0]
# in the background and set CHILD_PID to it once it is up. It sets a variable
# rather than echoing, because a command substitution would hold the child's
# stdout and disturb the very process shape under test. It waits for the exec to
# actually land: until then the child is still the intermediate "bash", which no
# rule matches, so a negative assertion could pass for the wrong reason.
CHILD_PID=''
start_child() {
  local argv0=$1 binary=$2 extra=${3:-} want comm tries=0
  want=$(basename -- "$binary")
  bash -c 'exec -a "$1" "$2" -c "$3" "$4"' _ "$argv0" "$binary" "$HOLD" "$extra" &
  CHILD_PID=$!
  while [ "$tries" -lt 100 ]; do
    comm=$(ps -o comm= -p "$CHILD_PID" 2>/dev/null || true)
    comm="${comm#"${comm%%[![:space:]]*}"}"
    comm="${comm%"${comm##*[![:space:]]}"}"
    [ "$(basename -- "$comm")" = "$want" ] && return 0
    tries=$((tries + 1))
    sleep 0.02
  done
  stop_child "$CHILD_PID"
  fail "fixture child never became '$want' (argv[0] '$argv0'); last process name: '${comm:-none}'"
}

# stop_child <pid>: kill a fixture child and reap it without leaking job noise.
stop_child() {
  kill "$1" 2>/dev/null
  wait "$1" 2>/dev/null || true
}

# shellcheck source=bin/fm-session-lock-lib.sh
. "$LIB"

# A per-pid record is only trusted against /proc, so the standby rule exists
# only on Linux and there is nothing to assert elsewhere.
if [ ! -r /proc/$$/stat ]; then
  pass "skip: /proc unavailable, Claude standby records cannot be verified here"
else
  CFG="$TMP_ROOT/claude-config"
  mkdir -p "$CFG/sessions"
  export CFG LIB
  export CLAUDE_CONFIG_DIR="$CFG"

  # --- an unclaimed Claude Code standby never wins or holds the lock ---------
  #
  # The background daemon keeps pre-warmed spare session hosts ready
  # (`claude bg-spare`), and a spare runs SessionStart while it is being
  # pre-warmed, long before anyone uses it. It claimed the home's lock that way
  # and then sat on it as a live verified session host, so the captain's real
  # session started read-only. Claude Code marks an unclaimed spare
  # "spare": true in its per-pid record and drops the flag once a client claims
  # it; that flag, not the unchanging bg-spare argv, decides. These pin that a
  # standby holder is reclaimable, that a real session takes over from one
  # through fm-lock.sh, that a standby cannot claim the lock itself, and that
  # the same process claims normally once its record no longer says spare.
  LOCK_HOME="$TMP_ROOT/standby-home"
  mkdir -p "$LOCK_HOME/state"
  SPARE_UUID=0c003a9b-98bb-4b07-88b4-18bfd530c9db
  export SPARE_UUID LOCK_HOME

  # write_record <pid> <spare-json-or-empty>
  write_record() {
    printf '{"pid":%s,"sessionId":"%s","procStart":"%s"%s}\n' \
      "$1" "$SPARE_UUID" "$(fm_proc_stat_field "$1" 19)" "$2" > "$CFG/sessions/$1.json"
  }

  start_child claude "$VERSIONED"
  standby_pid=$CHILD_PID
  write_record "$standby_pid" ',"kind":"bg","spare":true'
  if fm_harness_pid_alive "$standby_pid"; then
    stop_child "$standby_pid"
    fail "an unclaimed standby was read as a live harness, so a lock it holds pins the home read-only"
  fi
  write_record "$standby_pid" ',"kind":"bg"'
  if ! fm_harness_pid_alive "$standby_pid"; then
    stop_child "$standby_pid"
    fail "a claimed standby, whose record no longer says spare, was not read as a live session"
  fi
  pass "an unclaimed standby is not a live lock holder, and the same host counts once claimed"

  # A real session takes the lock over from a standby that holds it.
  write_record "$standby_pid" ',"kind":"bg","spare":true'
  printf '%s\n' "$standby_pid" > "$LOCK_HOME/state/.lock"
  CLAIM_PROBE='
. "$LIB"
st=$(fm_proc_stat_field $$ 19) || exit 1
printf "{\"pid\":%s,\"sessionId\":\"%s\",\"procStart\":\"%s\"%s}\n" \
  "$$" "$CLAIMANT_UUID" "$st" "$OWN_FLAGS" > "$CFG/sessions/$$.json"
FM_HOME="$LOCK_HOME" "$ROOT/bin/fm-lock.sh" >/dev/null 2>"$LOCK_HOME/claim.err"; rc=$?
printf "%s %s %s\n" "$$" "$rc" "$(cat "$LOCK_HOME/state/.lock" 2>/dev/null || echo none)"
'
  CLAIMANT_UUID=9b1f7c52-3a44-4c8e-9d61-2f0e5b7a8c13
  export CLAIM_PROBE ROOT CLAIMANT_UUID
  out=$(OWN_FLAGS=',"kind":"interactive"' env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID bash -c 'exec -a claude "$0" -c "$CLAIM_PROBE"' "$VERSIONED" 2>/dev/null) || true
  read -r real_pid rc holder_after <<< "$out"
  if [ "$rc" != 0 ] || [ "$holder_after" != "$real_pid" ]; then
    stop_child "$standby_pid"
    fail "a real session did not take the lock over from an unclaimed standby (rc=$rc, holder=$holder_after, session=$real_pid)"
  fi
  pass "a real session takes the fleet lock over from an unclaimed standby"

  # A standby cannot claim the lock, not even a free one.
  rm -f "$LOCK_HOME/state/.lock"
  out=$(OWN_FLAGS=',"kind":"bg","spare":true' env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID bash -c 'exec -a claude "$0" -c "$CLAIM_PROBE"' "$VERSIONED" 2>/dev/null) || true
  read -r _ rc _ <<< "$out"
  err=$(cat "$LOCK_HOME/claim.err" 2>/dev/null)
  if [ "$rc" = 0 ] || [ -e "$LOCK_HOME/state/.lock" ]; then
    stop_child "$standby_pid"
    fail "an unclaimed standby claimed the fleet lock (rc=$rc)"
  fi
  case "$err" in
    *"unclaimed Claude Code standby"*) : ;;
    *) stop_child "$standby_pid"; fail "the standby refusal did not say why: $err" ;;
  esac
  # Once claimed, the same process is a live session in use and keeps the lock
  # against another session exactly like any other live holder.
  printf '%s\n' "$standby_pid" > "$LOCK_HOME/state/.lock"
  write_record "$standby_pid" ',"kind":"bg"'
  out=$(OWN_FLAGS=',"kind":"interactive"' env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID bash -c 'exec -a claude "$0" -c "$CLAIM_PROBE"' "$VERSIONED" 2>/dev/null) || true
  read -r _ rc holder_after <<< "$out"
  if [ "$rc" = 0 ] || [ "$holder_after" != "$standby_pid" ]; then
    stop_child "$standby_pid"
    fail "a session took the lock from a claimed standby that is a live session in use (rc=$rc, holder=$holder_after)"
  fi
  stop_child "$standby_pid"
  pass "an unclaimed standby cannot claim the lock, and a claimed one keeps it like any live session"

  unset CLAUDE_CONFIG_DIR
fi

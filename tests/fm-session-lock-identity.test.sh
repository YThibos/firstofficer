#!/usr/bin/env bash
# Behavior tests for the harness identity contract in bin/fm-session-lock-lib.sh.
#
# The lib decides which process owns a home's session lock. It matched only the
# process NAME, which breaks on a versioned launcher: Claude Code execs its own
# release binary, so the process name is the version string ("2.1.235") and no
# harness name appears there at all. Such a session could never acquire the lock
# and was stuck read-only forever.
#
# The fix falls back to argv[0]'s basename, which still names the harness. These
# tests pin both halves of that: the versioned launcher IS recognised when it was
# invoked as a harness, and is NOT recognised when the only mention of one is a
# later argument or a directory component of argv[0]'s own path, so neither an
# unrelated versioned binary nor the leaf session process can claim a home. They
# also pin the two narrower rules the fallback sits behind, so widening one
# cannot silently replace them.
# shellcheck disable=SC2016,SC2089,SC2090 # PROBE is a shell snippet handed verbatim to a child shell, so its single quotes and unexpanded $LIB are deliberate
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-identity)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

# A "release binary" whose file name is a bare version, exactly like a real
# Claude Code install under versions/<v>. Its process name is that version.
VERSIONED="$FAKEBIN/2.1.235"
ln -s /bin/bash "$VERSIONED"

# A harness-named binary and a bare interpreter, for the two narrower rules.
NAMED="$FAKEBIN/codex"
ln -s /bin/bash "$NAMED"
NODE="$FAKEBIN/node"
ln -s /bin/bash "$NODE"

# The real Claude Code leaf shape: the release binary lives under a directory
# named after the harness, so a harness name appears in argv[0]'s PATH while its
# basename is still a bare version. Rule 3 must not reach it.
LEAF_DIR="$TMP_ROOT/claude/versions"
mkdir -p "$LEAF_DIR"
LEAF="$LEAF_DIR/2.1.235"
ln -s /bin/bash "$LEAF"

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Probe run inside the child: report its own pid and what the lib resolves for
# this ancestry. Both are needed, because the walk must land on the child ITSELF.
# Asserting only that some pid came back would pass on the broken lib whenever
# the suite runs inside a real Claude session, where the walk skips the
# unrecognised child and correctly finds the genuine harness further up.
PROBE='. "$LIB"; printf "%s %s\n" "$$" "$(fm_harness_ancestry_pid || echo NONE)"'
export PROBE LIB

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

# --- versioned launcher invoked as a harness is recognised ------------------
# argv[0] is "claude" while the process name is "2.1.235" - the real shape of a
# Claude Code session host process.
out=$(LIB="$LIB" bash -c 'exec -a claude "$0" -c "$PROBE"' "$VERSIONED" 2>&1) || true
child_pid=${out%% *}
walked_pid=${out##* }
case "$out" in
  *[!0-9\ ]*|'' ) fail "expected two bare pids from the probe, got: $out" ;;
esac
if [ "$walked_pid" != "$child_pid" ] || [ -z "$child_pid" ]; then
  fail "ancestry walk should resolve the versioned claude launcher to its own pid $child_pid, got: $out"
fi
pass "ancestry walk resolved the versioned claude launcher to its own pid $child_pid"

# --- liveness agrees with the walk -----------------------------------------
# shellcheck source=bin/fm-session-lock-lib.sh
. "$LIB"

# Liveness must accept the same versioned-launcher shape the walk resolves,
# otherwise the holder it just recorded reads back as stale to every guard.
start_child claude "$VERSIONED"
live_harness=$CHILD_PID
if fm_harness_pid_alive "$live_harness"; then
  pass "a live versioned launcher invoked as claude is a live harness"
else
  stop_child "$live_harness"
  fail "a live versioned claude launcher was reported as not a harness"
fi
stop_child "$live_harness"

# The same binary NOT invoked as a harness must stay unrecognised, even when a
# later argument mentions one: argv[0] is the version path, so nothing that
# names the process names a harness and it cannot claim a home.
start_child "$VERSIONED" "$VERSIONED" /opt/claude/bin/claude
live_other=$CHILD_PID
if fm_harness_pid_alive "$live_other"; then
  stop_child "$live_other"
  fail "a versioned binary with no harness name in argv[0] was treated as a harness"
fi
pass "a versioned binary with no harness name in argv[0] is not a harness"
stop_child "$live_other"

# Nor when a DIRECTORY component of argv[0] names a harness. This is the leaf
# session process itself, whose argv[0] is the versioned binary's own full path
# under .../claude/versions/. Matching it would hand a home to any binary merely
# living under a "claude" directory, so only argv[0]'s basename is ever matched.
start_child "$LEAF" "$LEAF"
live_leaf=$CHILD_PID
if fm_harness_pid_alive "$live_leaf"; then
  stop_child "$live_leaf"
  fail "a versioned binary under a claude-named directory was treated as a harness"
fi
pass "a harness name in a directory component of argv[0] is not a harness"
stop_child "$live_leaf"

# --- the two narrower rules still stand ------------------------------------
# A process whose own name is a harness name needs no fallback at all.
start_child codex "$NAMED"
live_named=$CHILD_PID
if fm_harness_pid_alive "$live_named"; then
  pass "a process named after a harness is a live harness"
else
  stop_child "$live_named"
  fail "a codex-named process was reported as not a harness"
fi
stop_child "$live_named"

# A bare interpreter is still matched on the harness name in its script path,
# which argv[0] alone ("node") would never see.
start_child node "$NODE" /opt/opencode/cli.js
live_node=$CHILD_PID
if fm_harness_pid_alive "$live_node"; then
  pass "a bare node interpreter running a harness script is a live harness"
else
  stop_child "$live_node"
  fail "node running an opencode script was reported as not a harness"
fi
stop_child "$live_node"

# A dead pid is never a live harness, whatever its name was.
dead=$(bash -c 'echo $$')
while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
if fm_harness_pid_alive "$dead"; then
  fail "a dead pid was reported as a live harness"
fi
pass "a dead pid is not a live harness"

# pid 1 is alive but is not a harness under any matching rule.
if fm_harness_pid_alive 1; then
  fail "pid 1 was reported as a live harness"
fi
pass "an unrelated live process is not a live harness"

# --- a Claude session host outranks every naming rule -----------------------
#
# Claude Code re-hosts a session it moves into a background job. The session's
# own process tree changes under it while the `claude` client that launched it
# stays alive in the terminal, so the ancestry walk answers with one pid before
# the move and another after, and the pid it recorded first keeps reading back
# as a live harness in a tree the session no longer belongs to. Every later
# ownership check then concludes some OTHER session holds the home, and the
# Stop-owned auto-arm stays inert for the rest of that session.
#
# The session host is the fixed point: one process for one session, the process
# both a tool call and a Stop hook descend from. These pin that it wins over the
# claude-named ancestor above it, that it counts as a live harness despite being
# named after its release version, and that only a pid-reuse-verified record can
# claim it.
if [ ! -r /proc/$$/stat ]; then
  pass "skip: /proc unavailable, Claude session-host records cannot be verified here"
else
  CFG="$TMP_ROOT/claude-config"
  mkdir -p "$CFG/sessions"

  # The inner process writes its own record, because its pid is not knowable
  # until it runs. procStart comes from the lib's own reader, so the record is
  # verified against exactly the field the lib checks.
  INNER='
. "$LIB"
st=$(fm_proc_stat_field $$ 19) || exit 1
printf "{\"pid\":%s,\"sessionId\":\"%s\",\"procStart\":\"%s\"}\n" \
  "$$" "$SESSION_UUID" "${PROC_START_OVERRIDE:-$st}" > "$CFG/sessions/$$.json"
printf "%s %s %s\n" "$PPID" "$$" "$(fm_harness_ancestry_pid || echo NONE)"
'
  # A subshell forks before it execs, so the leaf is a real child of the
  # claude-named process rather than replacing it.
  OUTER='( exec -a "$LEAF" "$LEAF" -c "$INNER" )'
  SESSION_UUID=45d20461-bd73-4201-9442-480730901f20
  export CFG INNER LEAF LIB SESSION_UUID
  export CLAUDE_CONFIG_DIR="$CFG"

  out=$(bash -c 'exec -a claude "$0" -c "$1"' "$VERSIONED" "$OUTER" 2>&1) || true
  read -r outer_pid inner_pid walked _ <<< "$out"
  case "$outer_pid$inner_pid$walked" in
    ''|*[!0-9]*) fail "expected three bare pids from the nested probe, got: $out" ;;
  esac
  if [ "$walked" = "$outer_pid" ]; then
    fail "ancestry walk climbed past the session host $inner_pid to the claude-named client $outer_pid; a background-job session would lose its own lock"
  fi
  if [ "$walked" != "$inner_pid" ]; then
    fail "ancestry walk should resolve the verified session host $inner_pid, got: $walked"
  fi
  pass "ancestry walk resolves the verified Claude session host, not the claude-named client above it"

  # The walk just recorded that pid, so liveness must agree - a session host is
  # named after its release version and matches no naming rule on its own.
  start_child "$LEAF" "$LEAF"
  host_pid=$CHILD_PID
  host_start=$(fm_proc_stat_field "$host_pid" 19)
  printf '{"pid":%s,"sessionId":"%s","procStart":"%s"}\n' \
    "$host_pid" "$SESSION_UUID" "$host_start" > "$CFG/sessions/$host_pid.json"
  if fm_harness_pid_alive "$host_pid"; then
    pass "a live verified Claude session host is a live harness"
  else
    stop_child "$host_pid"
    fail "a live verified session host was reported as not a harness, so the lock it holds reads back as stale"
  fi

  # A record is only evidence while it still belongs to the live process: a
  # recycled pid inheriting a leftover record must claim nothing.
  printf '{"pid":%s,"sessionId":"%s","procStart":"%s"}\n' \
    "$host_pid" "$SESSION_UUID" "$((host_start + 1))" > "$CFG/sessions/$host_pid.json"
  if fm_harness_pid_alive "$host_pid"; then
    stop_child "$host_pid"
    fail "a session record whose procStart does not match the live process was treated as evidence"
  fi
  pass "a leftover session record from a recycled pid is not evidence of a harness"
  stop_child "$host_pid"

  # The same must hold for the walk: with the record unverifiable, resolution
  # falls back to the naming rules exactly as it did before.
  PROC_START_OVERRIDE=0
  export PROC_START_OVERRIDE
  out=$(bash -c 'exec -a claude "$0" -c "$1"' "$VERSIONED" "$OUTER" 2>&1) || true
  read -r outer_pid _ walked _ <<< "$out"
  if [ "$walked" != "$outer_pid" ]; then
    fail "with no verifiable session record the walk should fall back to the claude-named ancestor $outer_pid, got: $walked"
  fi
  pass "an unverifiable session record leaves the naming rules deciding, unchanged"
  unset PROC_START_OVERRIDE

  # --- a superseded host of THIS session does not hold the home -------------
  #
  # The claim can land on either side of the re-host. Claimed AFTER it, the lock
  # already records the pty host and the walk above is the whole fix. Claimed
  # BEFORE it - firstmate bootstraps from a session-start hook, and the captain
  # only backgrounds the session afterwards - the lock records the CLIENT, which
  # stays alive, stays claude-named, and keeps its own record, so liveness would
  # answer "another live session holds this home" for the rest of the session and
  # the Stop-owned auto-arm would stay inert exactly as before.
  #
  # The two records naming ONE session id is the positive proof that separates
  # that case from a genuine second session, so these pin the liveness test on
  # the identity alone: same id is reclaimable, and a different, unverifiable, or
  # absent record all keep the lock exactly as they do today.
  REHOST_PROBE='
. "$LIB"
st=$(fm_proc_stat_field $$ 19) || exit 1
printf "{\"pid\":%s,\"sessionId\":\"%s\",\"procStart\":\"%s\"}\n" \
  "$$" "$OWN_UUID" "$st" > "$CFG/sessions/$$.json"
[ "$HOLDER_PID" = SELF ] && HOLDER_PID=$$
if fm_harness_pid_alive "$HOLDER_PID"; then echo ALIVE; else echo RECLAIMABLE; fi
'
  export REHOST_PROBE

  # rehost_verdict <holder pid or SELF> <this session host's id>: run the probe
  # as a process that IS a verified session host and echo how it reads <holder>.
  rehost_verdict() {
    OWN_UUID=$2 HOLDER_PID=$1 bash -c "$REHOST_PROBE" 2>&1
  }

  # The client the captain launched: still alive, still claude-named, and its
  # record still verifies - every reason liveness had to call it live.
  start_child claude "$VERSIONED"
  client_pid=$CHILD_PID
  client_start=$(fm_proc_stat_field "$client_pid" 19)
  write_client_record() {
    printf '{"pid":%s,"sessionId":"%s","procStart":"%s"}\n' \
      "$client_pid" "$1" "$2" > "$CFG/sessions/$client_pid.json"
  }
  OTHER_UUID=7c1f0f4a-2b6d-4f3e-8a11-0c9d5e2b7431

  write_client_record "$SESSION_UUID" "$client_start"
  verdict=$(rehost_verdict "$client_pid" "$SESSION_UUID")
  if [ "$verdict" != RECLAIMABLE ]; then
    stop_child "$client_pid"
    fail "a live claude-named client whose record names this session's own id should be a superseded host, got: $verdict"
  fi
  pass "a lock claimed before the re-host reads as reclaimable, not as another live session"

  verdict=$(rehost_verdict "$client_pid" "$OTHER_UUID")
  if [ "$verdict" != ALIVE ]; then
    stop_child "$client_pid"
    fail "a holder whose record names a DIFFERENT session id must keep its lock, got: $verdict"
  fi
  pass "another live session's host keeps its lock"

  write_client_record "$SESSION_UUID" "$((client_start + 1))"
  verdict=$(rehost_verdict "$client_pid" "$SESSION_UUID")
  if [ "$verdict" != ALIVE ]; then
    stop_child "$client_pid"
    fail "an unverifiable holder record must add no evidence, so the holder keeps its lock, got: $verdict"
  fi
  pass "a holder record whose procStart does not match the live process reclaims nothing"

  rm -f "$CFG/sessions/$client_pid.json"
  verdict=$(rehost_verdict "$client_pid" "$SESSION_UUID")
  if [ "$verdict" != ALIVE ]; then
    stop_child "$client_pid"
    fail "a holder with no record at all must keep its lock, got: $verdict"
  fi
  pass "a holder with no session record keeps its lock"
  stop_child "$client_pid"

  # The current host is not superseded by anything, so a session must never read
  # its own live lock as reclaimable.
  verdict=$(rehost_verdict SELF "$SESSION_UUID")
  if [ "$verdict" != ALIVE ]; then
    fail "this session's own current host must still read as a live harness, got: $verdict"
  fi
  pass "this session's own current host is not treated as superseded"

  # --- the shared-service boundary outranks the host short-circuit ----------
  #
  # A process shared by every session in the machine must never be selected by
  # either caller, whatever else is true of it: it never exits, so a lock
  # recording it pins the home read-only forever, and every concurrent
  # background session resolves to that one pid. The verified-host short-circuit
  # is the only thing that could reach past that boundary, so these give a
  # shared-service argv a verifiable per-pid record of its own - the one shape
  # where the boundary and the short-circuit disagree - and require the boundary
  # to win in the walk and in the liveness test alike. The ordinary host, whose
  # argv is not a shared service, still wins over the naming rules exactly as
  # the cases above pin.
  DAEMON_HOLD="$TMP_ROOT/daemon-hold.fifo"
  mkfifo "$DAEMON_HOLD"
  # The supervisor's argv is `claude daemon run ...`, and only a real one will
  # do: the boundary matches argv[1] exactly, so the fixture's own script has to
  # BE argv[1]. A shell script named "daemon", run from its own directory under
  # argv[0] "claude", is the one shape that gives a live process that command
  # line while still being this suite's code.
  DAEMON_DIR="$TMP_ROOT/shared-service"
  mkdir -p "$DAEMON_DIR"
  cat > "$DAEMON_DIR/daemon" <<'SH'
set -u
# shellcheck source=/dev/null
. "$LIB"
st=$(fm_proc_stat_field $$ 19) || exit 1
printf '{"pid":%s,"sessionId":"%s","procStart":"%s"}\n' \
  "$$" "$SESSION_UUID" "$st" > "$CFG/sessions/$$.json"
if [ "${DAEMON_MODE:-hold}" = walk ]; then
  # A plain, unrecognised child, so the walk has to climb into the shared
  # service to reach it at all.
  ( exec bash -c 'printf "%s %s\n" "$PPID" "$(. "$LIB"; fm_harness_ancestry_pid || echo NONE)"' )
else
  read -r _ < "$DAEMON_HOLD"
fi
SH
  export DAEMON_HOLD DAEMON_DIR
  DAEMON_RUN='cd "$DAEMON_DIR" && exec -a claude bash daemon run'

  out=$(DAEMON_MODE=walk bash -c "$DAEMON_RUN" 2>&1) || true
  read -r daemon_pid walked _ <<< "$out"
  case "$daemon_pid" in
    ''|*[!0-9]*) fail "expected the shared-service pid and a walk result, got: $out" ;;
  esac
  if [ "$walked" = "$daemon_pid" ]; then
    fail "the ancestry walk selected the shared service $daemon_pid because it carried a verified session record; every background session in the home would resolve to that one pid"
  fi
  pass "a shared service carrying a verified session record is still not selected by the ancestry walk"

  DAEMON_MODE=hold bash -c "$DAEMON_RUN" &
  daemon_pid=$!
  tries=0
  while [ "$tries" -lt 100 ] && [ ! -f "$CFG/sessions/$daemon_pid.json" ]; do
    tries=$((tries + 1))
    sleep 0.02
  done
  if [ ! -f "$CFG/sessions/$daemon_pid.json" ]; then
    stop_child "$daemon_pid"
    fail "fixture shared service never wrote its own session record"
  fi
  if fm_harness_pid_alive "$daemon_pid"; then
    stop_child "$daemon_pid"
    fail "a shared service carrying a verified session record was read as a live harness; a lock recording it would pin the home read-only for as long as it runs"
  fi
  pass "a shared service carrying a verified session record is not a live harness"
  stop_child "$daemon_pid"

  unset CLAUDE_CONFIG_DIR
fi

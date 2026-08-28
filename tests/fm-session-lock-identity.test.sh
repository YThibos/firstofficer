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
  unset PROC_START_OVERRIDE CLAUDE_CONFIG_DIR
fi

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
# invoked as a harness, and is NOT recognised when nothing but a later argument
# mentions one, so an unrelated versioned binary cannot claim a home. They also
# pin the two narrower rules the fallback sits behind, so widening one cannot
# silently replace them.
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

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Probe run inside the child: report its own pid and what the lib resolves for
# this ancestry. Both are needed, because the walk must land on the child ITSELF.
# Asserting only that some pid came back would pass on the broken lib whenever
# the suite runs inside a real Claude session, where the walk skips the
# unrecognised child and correctly finds the genuine harness further up.
PROBE='. "$LIB"; printf "%s %s\n" "$$" "$(fm_harness_ancestry_pid || echo NONE)"'
export PROBE LIB

# A child that holds its own process name for the length of the check. Plain
# "sleep 30" would exec-optimise into the sleep binary, replacing exactly the
# process shape under test; the trailing ":" keeps the shell alive as itself.
HOLD='sleep 30; :'

# start_child <argv0> <binary> [extra arg]: run <binary> under the given argv[0]
# in the background and set CHILD_PID to it once it is up. It sets a variable
# rather than echoing, because a command substitution would hold the child's
# stdout and disturb the very process shape under test.
CHILD_PID=''
start_child() {
  local argv0=$1 binary=$2 extra=${3:-}
  bash -c 'exec -a "$1" "$2" -c "$3" "$4"' _ "$argv0" "$binary" "$HOLD" "$extra" &
  CHILD_PID=$!
  sleep 0.2
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

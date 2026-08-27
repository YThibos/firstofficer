#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
#
# A live holder normally refuses the claim, with ONE exception: a holder whose
# session is positively identified as stopped on a usage limit is taken over,
# because that process stays alive indefinitely and would otherwise pin the
# home read-only forever. The takeover is always announced on stdout and
# recorded in state/.lock.takeover so a later read still knows it happened.
# bin/fm-session-lock-lib.sh owns the identity and limit-stop decisions and
# docs/session-lock.md owns the contract.
#
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
TAKEOVER="$STATE/.lock.takeover"
TOOK_OVER=""
PREVIOUS=""
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# Render the shared lock report's tokens as the lines this command has always
# printed, so the decision stays in the lib and only its wording lives here.
print_status() {
  local line verb rest
  while IFS= read -r line; do
    verb=${line%% *}
    rest=${line#* }
    case "$verb" in
      free) echo "lock: free" ;;
      unreadable|malformed) echo "lock: unreadable" ;;
      owned|held) echo "lock: held by live harness pid $rest" ;;
      limit-stopped)
        echo "lock: held by a session stopped by a usage limit (pid $rest)"
        echo "lock: run bin/fm-lock.sh to take it over"
        ;;
      stale) echo "lock: stale (pid $rest dead or not a harness)" ;;
      took-over-from)
        echo "lock: this session took over from a session stopped by a usage limit (previous pid ${rest%% *})"
        ;;
    esac
  done
}

if [ "${1:-}" = "status" ]; then
  fm_session_lock_report "$STATE" "$FM_HOME" | print_status
  exit 0
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$CLAIM_LOCK"
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
    if fm_session_limit_stopped "$old" "$FM_HOME"; then
      TOOK_OVER=$old
    else
      echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
      exit 1
    fi
  fi
  PREVIOUS=$old
fi
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
# The marker names the pid that took over, so a later read only reports it while
# that same session still holds the lock; a plain claim by anyone else drops it.
if [ -n "$TOOK_OVER" ]; then
  printf '%s %s %s\n' "$me" "$TOOK_OVER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$TAKEOVER" 2>/dev/null || true
elif [ "$PREVIOUS" != "$me" ]; then
  rm -f "$TAKEOVER" 2>/dev/null || true
fi
release_claim_lock
if [ -n "$TOOK_OVER" ]; then
  echo "lock takeover: previous holder pid $TOOK_OVER was a session stopped by a usage limit"
fi
echo "lock acquired: harness pid $me"

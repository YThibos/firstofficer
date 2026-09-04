#!/usr/bin/env bash
# Resume one worker that its own usage limit parked, once that limit has reset.
#
# Usage: fm-limit-resume.sh <id>
#        fm-limit-resume.sh --help
#
# The whole contract is the exit status; stdout carries one short line of
# evidence for the caller's log.
#   0  resumed, and the resume was VERIFIED to have landed
#   2  usage error, or this task's endpoint could not be resolved
#   3  the pane is not showing a parked usage-limit footer
#   4  the limit has not reset yet
#   5  the resume attempt budget for this park is spent
#   6  the message was sent but the pane did not come out of the parked state
# Exits 3 and 4 are refusals taken BEFORE anything is sent, and they spend no
# part of the attempt budget, so an early or mistaken call leaves the worker
# exactly as it found it.
#
# The resume is a real message, never a bare keystroke. That is not a style
# choice: a bare Enter into such a pane was verified on 2026-08-20 not to resume
# the worker, while a message did, so a keystroke-only resume would report
# success and change nothing. FM_LIMIT_RESUME_MESSAGE overrides the text; it must
# stay a single line, which is what an endpoint accepts.
#
# Landing is verified rather than assumed. A successful send only proves the
# endpoint accepted the text, so the pane is re-read afterwards
# (FM_LIMIT_RESUME_VERIFY_TRIES reads, FM_LIMIT_RESUME_VERIFY_SLEEP apart) and
# the resume counts as landed only once the pane shows the worker is out of the
# park: either the parked footer is gone, or the worker is demonstrably working
# again. The second reading matters because a resumed worker's banner takes a
# moment to scroll out of the footer band, and treating that moment as a failed
# resume would spend the attempt budget on resumes that in fact worked.
#
# Whether the pane is parked, and whether its limit has reset, are both read
# through bin/fm-limit-park-lib.sh, the single owner of that decision, so this
# command and the watcher that schedules it cannot disagree.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

ID=${1:-}
[ -n "$ID" ] || { usage; exit 2; }

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# The busy-footer signatures, for the "working again" half of the landing test.
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-limit-park-lib.sh
. "$SCRIPT_DIR/fm-limit-park-lib.sh"

FM_SEND_BIN=${FM_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}
FM_LIMIT_RESUME_MAX_ATTEMPTS=${FM_LIMIT_RESUME_MAX_ATTEMPTS:-3}
FM_LIMIT_RESUME_VERIFY_TRIES=${FM_LIMIT_RESUME_VERIFY_TRIES:-5}
FM_LIMIT_RESUME_VERIFY_SLEEP=${FM_LIMIT_RESUME_VERIFY_SLEEP:-1}
# Mirrors the prompt Claude Code sends itself when it continues automatically:
# it names the reset and tells the worker to carry on rather than start over.
FM_LIMIT_RESUME_MESSAGE=${FM_LIMIT_RESUME_MESSAGE:-'Your usage limit has reset. Continue the task you were working on when the limit was reached; do not repeat work that is already complete.'}

META="$STATE/$ID.meta"
[ -f "$META" ] || { printf 'no local record for %s\n' "$ID"; exit 2; }
TARGET=$(fm_backend_target_of_meta "$META")
[ -n "$TARGET" ] || { printf 'no endpoint recorded for %s\n' "$ID"; exit 2; }
BACKEND=$(fm_backend_of_meta "$META")
HARNESS=$(fm_meta_get "$META" harness)
LABEL="fm-$ID"

capture_pane() {
  fm_backend_capture "$BACKEND" "$TARGET" 40 "$LABEL" 2>/dev/null
}

capture_footer() {
  capture_pane | fm_limit_park_match "$HARNESS"
}

# 0 once the pane says this worker is out of the park. Asked only after a send,
# so it never decides whether to send. Busy is read the way the watcher reads
# it: the backend's own semantic state when it has one, else the recorded
# harness's verified busy footer over the same footer band.
resume_landed() {
  local pane busy
  pane=$(capture_pane) || return 1
  busy=$(fm_backend_busy_state "$BACKEND" "$TARGET" 2>/dev/null)
  case "$busy" in
    busy) return 0 ;;
    idle) : ;;
    *) printf '%s' "$pane" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match "$HARNESS" && return 0 ;;
  esac
  ! printf '%s' "$pane" | fm_limit_park_match "$HARNESS" >/dev/null
}

FOOTER=$(capture_footer) || { printf '%s is not parked on a usage limit\n' "$ID"; exit 3; }

NOW=$(date +%s)
ANCHOR=$(fm_limit_park_anchor "$STATE" "$ID" "$NOW")
case "$ANCHOR" in ''|*[!0-9]*) ANCHOR=$NOW ;; esac
if ! fm_limit_park_due "$ANCHOR" "$NOW" "$FOOTER"; then
  printf '%s is parked until its limit resets; nothing sent\n' "$ID"
  exit 4
fi

ATTEMPTS=$(fm_limit_park_attempts "$STATE" "$ID")
if [ "$ATTEMPTS" -ge "$FM_LIMIT_RESUME_MAX_ATTEMPTS" ]; then
  printf '%s has spent its %s resume attempts\n' "$ID" "$FM_LIMIT_RESUME_MAX_ATTEMPTS"
  exit 5
fi
fm_limit_park_set "$STATE" "$ID" attempts "$((ATTEMPTS + 1))"
fm_limit_park_set "$STATE" "$ID" last-attempt "$NOW"

# One line of real text through the ordinary steer path, which owns marker
# handling, submit confirmation, and the swallowed-Enter retry. The --key path
# is deliberately never used here.
if ! FM_HOME="$FM_HOME" "$FM_SEND_BIN" "$ID" "$FM_LIMIT_RESUME_MESSAGE" >/dev/null 2>&1; then
  printf 'resume message to %s was not accepted (attempt %s)\n' "$ID" "$((ATTEMPTS + 1))"
  exit 6
fi

i=0
while [ "$i" -lt "$FM_LIMIT_RESUME_VERIFY_TRIES" ]; do
  if resume_landed; then
    fm_limit_park_clear "$STATE" "$ID"
    printf 'resumed %s after its usage limit reset (attempt %s)\n' "$ID" "$((ATTEMPTS + 1))"
    exit 0
  fi
  i=$((i + 1))
  [ "$i" -lt "$FM_LIMIT_RESUME_VERIFY_TRIES" ] && sleep "$FM_LIMIT_RESUME_VERIFY_SLEEP"
done
printf 'resume message to %s was sent but the pane is still parked (attempt %s)\n' "$ID" "$((ATTEMPTS + 1))"
exit 6

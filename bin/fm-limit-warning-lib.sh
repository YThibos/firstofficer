#!/usr/bin/env bash
# fm-limit-warning-lib.sh - read a harness's usage-limit warning out of a
# captured terminal pane and decide, once per limit episode, whether the session
# should be forced to stow its durable knowledge before the budget is spent.
#
# Why this is a sibling library rather than more code inside
# bin/fm-turnend-guard.sh: everything here is pure pane-text classification plus
# one episode ledger, with no dependency on a Stop payload, a supervision
# predicate, or a blocking mechanism. Keeping it separate lets it be tested
# directly against captured pane text, and lets a future crewmate-side reader of
# the same warnings reuse the classifier without inheriting the primary turn-end
# guard's blocking semantics. The turn-end guard remains the single hook that
# acts on the verdict; this file never blocks, exits, or writes outside the
# episode marker.
#
# Two distinct Claude Code states matter, and only the first is actionable:
#   approaching - the usage window is nearly spent but the session can still run
#                 one short step. This is the ONLY trigger for a forced stow.
#   exhausted   - the session is already stopped until its reset. Detected only
#                 to SUPPRESS a stow that could no longer run.
#
# Everything fails open. A pane that cannot be captured, a terminal that is not
# tmux, an unsupported harness, an unreadable or unwritable episode marker, or
# any other uncertainty returns "not due" so the caller leaves the turn alone.
# A bug here must never be able to wedge the primary session.
#
# No side effects on source. set -u and set -e safe.

# Observed live in Claude Code on 2026-08-25, and read verbatim out of the
# shipped Claude Code 2.1.270 binary on 2026-09-14 as "Approaching your 5-hour
# usage limit <em dash> Claude will wrap up the current step.". The anchor is
# deliberately loose about the separator glyph and the window descriptor, and
# deliberately strict about the surrounding words, so a rewording of the
# punctuation does not break detection while ordinary prose cannot trip it.
FM_LIMIT_APPROACHING_RE_DEFAULT='Approaching your [^[:cntrl:]]{0,40}(usage|session) limit'

# The exhausted state is not matched here: bin/fm-limit-park-lib.sh already owns
# Claude's stopped-on-a-usage-limit footer signature, and reading it from there
# keeps one definition of "the session has stopped".
_FM_LIMIT_WARNING_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || _FM_LIMIT_WARNING_DIR=

# Fallback window length for a descriptor this library does not recognise.
# Claude's shortest published window is the 5-hour one, so assuming it is the
# conservative choice: it expires the episode sooner and therefore risks one
# extra stow rather than a missed one.
FM_LIMIT_WINDOW_DEFAULT_SECONDS=18000

# Set by fm_limit_stow_due for the caller's message; consumed by the sourcing
# script, not by this library.
# shellcheck disable=SC2034
FM_LIMIT_WINDOW_DESC=

# Return 0 only for a harness whose limit wording has actually been observed.
fm_limit_warning_harness_supported() {  # <harness>
  case "${1:-}" in
    claude) return 0 ;;
    # Every other harness prints its own wording for a spent budget, and none of
    # it has been captured. Guessing would either force a pointless stow or miss
    # the real warning, so unverified harnesses stay a silent no-op until their
    # exact strings are observed and pinned by a test.
    *) return 1 ;;
  esac
}

# Capture the VISIBLE pane of the calling process's own tmux pane.
# Scrollback is deliberately excluded: a warning from a previous usage window
# that is still in history must not read as a live one.
fm_limit_pane_capture() {
  [ -n "${TMUX:-}" ] || return 1
  [ -n "${TMUX_PANE:-}" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux capture-pane -p -t "$TMUX_PANE" 2>/dev/null || return 1
}

# Classify captured Claude pane text on stdin.
# Exhausted wins over approaching when both are visible, because a session that
# has already stopped cannot run the stow either way. When the stopped-footer
# owner cannot be loaded the pane reads as unknown, which is never approaching,
# so an incomplete install leaves the turn alone.
fm_limit_warning_classify() {  # pane text on stdin -> approaching|exhausted|none|unknown
  local pane
  pane=$(cat 2>/dev/null || true)
  if ! command -v fm_limit_park_match >/dev/null 2>&1; then
    # shellcheck source=bin/fm-limit-park-lib.sh
    { [ -n "$_FM_LIMIT_WARNING_DIR" ] && . "$_FM_LIMIT_WARNING_DIR/fm-limit-park-lib.sh"; } 2>/dev/null || true
  fi
  if ! command -v fm_limit_park_match >/dev/null 2>&1; then
    printf 'unknown'
    return 0
  fi
  if printf '%s\n' "$pane" | fm_limit_park_match claude >/dev/null 2>&1; then
    printf 'exhausted'
    return 0
  fi
  if printf '%s\n' "$pane" | grep -qE "${FM_LIMIT_APPROACHING_RE:-$FM_LIMIT_APPROACHING_RE_DEFAULT}"; then
    printf 'approaching'
    return 0
  fi
  printf 'none'
}

# Print the window descriptor the approaching warning names, for example
# "5-hour" or "weekly". Prints "unknown" when the warning names none.
fm_limit_warning_window() {  # pane text on stdin -> descriptor
  local match desc
  match=$(grep -oE "${FM_LIMIT_APPROACHING_RE:-$FM_LIMIT_APPROACHING_RE_DEFAULT}" 2>/dev/null | head -n 1) || true
  if [ -z "$match" ]; then
    printf 'unknown'
    return 1
  fi
  desc=${match#Approaching your }
  desc=${desc% usage limit}
  desc=${desc% session limit}
  desc="${desc#"${desc%%[![:space:]]*}"}"
  desc="${desc%"${desc##*[![:space:]]}"}"
  case "$desc" in
    ''|*[!A-Za-z0-9.-]*) printf 'unknown'; return 1 ;;
  esac
  printf '%s' "$desc"
}

# Map a window descriptor to its length in seconds, used as the episode's
# expiry so a later window in the same session re-arms the stow.
fm_limit_window_seconds() {  # <descriptor>
  local desc=${1:-unknown} n
  case "$desc" in
    weekly|week) printf '604800' ;;
    daily|day) printf '86400' ;;
    *-hour|*-hours)
      n=${desc%%-*}
      case "$n" in
        ''|*[!0-9]*|0) printf '%s' "$FM_LIMIT_WINDOW_DEFAULT_SECONDS" ;;
        *) printf '%s' "$((n * 3600))" ;;
      esac
      ;;
    *) printf '%s' "$FM_LIMIT_WINDOW_DEFAULT_SECONDS" ;;
  esac
}

# Claim this limit episode. Exit 0 = this call owns the episode (the marker was
# just written). Exit 1 = the same episode is already claimed and still inside
# its window, or the ledger could not be read or written.
#
# The shape follows bin/fm-guard.sh's stale-banner episode marker: one bounded,
# overwritten, home-scoped file holding the current episode key. The difference
# is the key itself. fm-guard.sh keys on the watcher beacon's mtime, a value that
# changes on its own when the episode ends; the approaching warning carries no
# reset time and no other value that moves when the window rolls over, so the key
# here is the harness session plus the window descriptor, and the recorded claim
# time plus the window's own length supplies the expiry that the beacon mtime
# supplies over there. That gives exactly one stow per session per usage window,
# and re-arms a session long enough to outlive its own window.
#
# No lock: unlike fm-guard.sh, which any concurrent supervision command may call,
# this ledger is only ever touched by one primary session's turn-end hook, and a
# session runs one turn end at a time.
fm_limit_episode_claim() {  # <state-dir> <key> <ttl-seconds>
  local state=${1:-} key=${2:-} ttl=${3:-0} marker seen_key seen_at now age
  [ -n "$key" ] || return 1
  [ -d "$state" ] || return 1
  case "$ttl" in ''|*[!0-9]*) return 1 ;; esac
  marker="$state/.turnend-limit-stow-episode"
  now=$(date +%s 2>/dev/null) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  seen_key=$(sed -n '1s/^key=//p' "$marker" 2>/dev/null || true)
  seen_at=$(sed -n '2s/^at=//p' "$marker" 2>/dev/null || true)
  case "$seen_at" in ''|*[!0-9]*) seen_at=0 ;; esac
  age=$((now - seen_at))
  if [ "$seen_key" = "$key" ] && [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then
    return 1
  fi
  # Bounded write: two lines, overwritten, never appended. A failed write must
  # not leave the caller blocking on every later turn, so it reads as not due.
  printf 'key=%s\nat=%s\n' "$key" "$now" > "$marker" 2>/dev/null || return 1
  return 0
}

# The single entry point: return 0 when the caller should force one brief stow
# now, having claimed the episode, and set FM_LIMIT_WINDOW_DESC for its message.
# Every other outcome returns 1 and leaves no trace.
fm_limit_stow_due() {  # <harness> <state-dir> [session-id]
  local harness=${1:-} state=${2:-} session=${3:-unknown} pane verdict desc ttl
  FM_LIMIT_WINDOW_DESC=
  fm_limit_warning_harness_supported "$harness" || return 1
  pane=$(fm_limit_pane_capture) || return 1
  verdict=$(printf '%s\n' "$pane" | fm_limit_warning_classify)
  [ "$verdict" = approaching ] || return 1
  desc=$(printf '%s\n' "$pane" | fm_limit_warning_window) || desc=unknown
  ttl=$(fm_limit_window_seconds "$desc")
  fm_limit_episode_claim "$state" "$harness:$desc:$session" "$ttl" || return 1
  # shellcheck disable=SC2034
  FM_LIMIT_WINDOW_DESC=$desc
  return 0
}

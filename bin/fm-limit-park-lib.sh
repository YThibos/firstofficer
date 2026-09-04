#!/usr/bin/env bash
# Shared reader for a worker parked by its own usage limit: the pane signature,
# the reset time, and the durable per-task record the watcher and
# bin/fm-limit-resume.sh both key their decisions off.
#
# Why this exists: a worker whose harness stopped on a usage limit leaves a
# stable, idle pane with no busy signature and no running pipeline - byte for
# byte the shape of a worker that stopped or wedged. The supervision path
# therefore either surfaced it over and over or absorbed it as noise, and only a
# manual steer ever restarted it. Two workers lost over three hours each that way
# on 2026-09-03. The pane itself carries the missing evidence: the harness prints
# both that it is waiting on a usage limit and, usually, when that limit resets.
# This library is the one place that reads it, so the watcher's triage and the
# resume command cannot drift on what "parked" or "due" means.
#
# The signature is matched only in the FOOTER band (the last
# FM_LIMIT_PARK_TAIL_LINES non-blank lines), for the same reason
# fm_busy_lines_match reads only the footer: a transcript quoting a past limit
# banner - a session doing this very kind of work does exactly that - must never
# be read as the current state of the pane.
#
# Signatures are registered per harness and there is no shared default: an
# unregistered harness never classifies as parked, so its supervision behaviour
# is exactly what it was before this library existed. Only Claude Code's
# signatures are verified today; see docs/verification/supervision.md.
#
# Scope: the 5-hour session usage limit, which resets on its own and which a
# fresh prompt resumes. A monthly spend limit, a weekly limit, or an exhausted
# credit balance is deliberately NOT matched - no prompt clears those, so they
# keep surfacing on the ordinary stale path where a human sees them.

# Footer band, in non-blank lines, mirroring the busy-footer window the watcher
# already reads.
FM_LIMIT_PARK_TAIL_LINES=${FM_LIMIT_PARK_TAIL_LINES:-12}

# How long a parked worker may be waited out before a resume is attempted no
# matter what the pane claims. It bounds every unparseable and every
# self-updating countdown form at once, and sits above the 5-hour session window
# it exists to cover. Reaching it is not a resume on its own: the resume command
# re-reads the pane and still refuses while the pane names a future reset.
FM_LIMIT_PARK_MAX_WAIT=${FM_LIMIT_PARK_MAX_WAIT:-21600}

# Verified verbatim in the shipped Claude Code binary (2.1.259, read 2026-09-03).
# Each alternative is one of the footers it renders while a session usage limit
# holds the turn, from the moment the limit lands through the reset and the
# states where it says it will not continue on its own.
FM_LIMIT_PARK_CLAUDE_RE_DEFAULT='Usage limit reached|Usage limit (has reset|available again)|Your usage limit has reset|Automatic continue (was turned off|stopped|did not run)|You'\''ve hit your session limit'

# Print the registered parked-footer regex for <harness>, or nothing.
# FM_LIMIT_PARK_REGEX overrides every harness, mirroring FM_BUSY_REGEX.
fm_limit_park_regex() {  # [harness]
  local harness=${1:-}
  if [ -n "${FM_LIMIT_PARK_REGEX:-}" ]; then
    printf '%s' "$FM_LIMIT_PARK_REGEX"
    return 0
  fi
  case "$harness" in
    claude) printf '%s' "$FM_LIMIT_PARK_CLAUDE_RE_DEFAULT" ;;
    *) : ;;
  esac
}

# Print the footer band of a pane capture read on stdin: the last
# FM_LIMIT_PARK_TAIL_LINES non-blank lines.
fm_limit_park_footer() {
  grep -v '^[[:space:]]*$' | tail -"$FM_LIMIT_PARK_TAIL_LINES"
}

# Print the parked footer line of a pane capture read on stdin, and exit 0, when
# <harness>'s registered signature matches inside the footer band. Print nothing
# and exit 1 otherwise, including for every harness with no registered
# signature.
fm_limit_park_match() {  # [harness]; pane capture on stdin
  local harness=${1:-} regex line
  regex=$(fm_limit_park_regex "$harness")
  [ -n "$regex" ] || return 1
  line=$(fm_limit_park_footer | grep -iE "$regex" | tail -1)
  [ -n "$line" ] || return 1
  printf '%s' "$line"
}

# Run date in <tz>, or in the machine's own zone when the footer named none.
# An empty TZ in the environment means UTC, not local, so the zone is applied
# only when there really is one.
_fm_limit_park_date() {  # <tz> <date-argument>...
  local tz=$1
  shift
  if [ -n "$tz" ]; then TZ="$tz" date "$@"; else date "$@"; fi
}

# Convert a wall-clock <hour>:<minute> in <tz> (empty for the machine's own
# zone) to the epoch second on the anchor's day that shows that time, rolled a
# day forward only when that keeps it inside the bounded maximum wait.
# Prints nothing when the platform's date cannot express the conversion, which
# leaves the caller with an unknown reset rather than a wrong one.
_fm_limit_park_wallclock_epoch() {  # <anchor> <hour> <minute> <tz>
  local anchor=$1 hour=$2 minute=$3 tz=$4 day epoch stamp
  day=$(_fm_limit_park_date "$tz" -d "@$anchor" +%Y-%m-%d 2>/dev/null) \
    || day=$(_fm_limit_park_date "$tz" -r "$anchor" +%Y-%m-%d 2>/dev/null) \
    || return 0
  stamp=$(printf '%s %02d:%02d' "$day" "$hour" "$minute")
  epoch=$(_fm_limit_park_date "$tz" -d "$stamp" +%s 2>/dev/null) \
    || epoch=$(_fm_limit_park_date "$tz" -j -f '%Y-%m-%d %H:%M' "$stamp" +%s 2>/dev/null) \
    || return 0
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  # The anchor is the moment the WATCHER FIRST SAW the footer, not the moment
  # the banner appeared - a parked footer can sit unnoticed for hours - so a
  # named time that already passed on the anchor's day is usually a reset that
  # has genuinely elapsed, not one a day out. Roll it forward only when the
  # rolled reading still lands inside the bounded maximum wait, which is what
  # keeps a midnight crossing working ("resets 00:30" first seen at 23:50 is 40
  # minutes ahead). Otherwise take the reading as it stands, so the reset reads
  # as already past and the worker is due now: rolling the motivating
  # 2026-09-03 case (a banner naming 11:10 whose footer was first seen at 12:44)
  # a full day forward would leave it waiting on the 6h backstop, which is the
  # failure this work exists to remove.
  if [ "$epoch" -lt "$anchor" ] \
    && [ "$((epoch + 86400))" -le "$((anchor + FM_LIMIT_PARK_MAX_WAIT))" ]; then
    epoch=$((epoch + 86400))
  fi
  printf '%s' "$epoch"
}

# Normalise a 12-hour clock reading to 24-hour hours.
_fm_limit_park_hour24() {  # <hour> <am-or-pm-or-empty>
  local hour=$1 meridiem=$2
  hour=$((10#$hour))
  case "$meridiem" in
    [aA][mM]) [ "$hour" = 12 ] && hour=0 ;;
    [pP][mM]) [ "$hour" != 12 ] && hour=$((hour + 12)) ;;
  esac
  printf '%s' "$hour"
}

# Print the epoch second at which <footer>'s named usage limit resets, or
# nothing when the footer names no time this reader understands.
#
# Absolute forms ("resets 12:40pm (Europe/Brussels)", "continuing automatically
# at 12:40pm") are resolved against <anchor>, the moment the parked footer was
# first seen, so re-reading an unchanged pane keeps answering the same instant.
# Relative forms ("resets in 2h 30m") are resolved against <now> instead,
# because that is what a counting-down footer means on the poll that reads it.
# A footer that says the limit has already reset answers <now>.
fm_limit_park_reset_epoch() {  # <anchor> <now> <footer>
  local anchor=$1 now=$2 footer=$3 hours minutes hour minute meridiem tz rest
  case "$footer" in
    *[Hh]as\ reset*|*available\ again*) printf '%s' "$now"; return 0 ;;
  esac

  rest=$(printf '%s' "$footer" | sed -n 's/.*[Rr]esets in \([0-9]\{1,\}h\)\{0,1\} *\([0-9]\{1,\}m\)\{0,1\}.*/\1 \2/p')
  if [ -n "${rest// /}" ]; then
    hours=${rest%% *}; hours=${hours%h}
    minutes=${rest##* }; minutes=${minutes%m}
    case "$hours" in ''|*[!0-9]*) hours=0 ;; esac
    case "$minutes" in ''|*[!0-9]*) minutes=0 ;; esac
    printf '%s' $(( now + 10#$hours * 3600 + 10#$minutes * 60 ))
    return 0
  fi

  # "continuing automatically at 12:40pm", "resets 12:40pm (Europe/Brussels)",
  # "resets 23:10". The minutes and the meridiem are each optional.
  rest=$(printf '%s' "$footer" \
    | sed -nE 's/.*([Rr]esets|continuing automatically at)[[:space:]]+([0-9]{1,2})(:([0-9]{2}))?[[:space:]]*([aApP][mM])?.*/\2 \4 \5/p')
  [ -n "${rest// /}" ] || return 0
  hour=${rest%% *}
  minute=$(printf '%s' "$rest" | cut -d' ' -f2)
  meridiem=$(printf '%s' "$rest" | cut -d' ' -f3)
  case "$hour" in ''|*[!0-9]*) return 0 ;; esac
  case "$minute" in ''|*[!0-9]*) minute=0 ;; esac
  hour=$(_fm_limit_park_hour24 "$hour" "$meridiem")
  [ "$hour" -le 23 ] || return 0
  [ "$minute" -le 59 ] || return 0
  tz=$(printf '%s' "$footer" | sed -n 's/.*(\([A-Za-z_]\{1,\}\/[A-Za-z_+-]\{1,\}\)).*/\1/p')
  _fm_limit_park_wallclock_epoch "$anchor" "$hour" "$minute" "$tz"
}

# 0 when a worker parked since <anchor>, whose pane now shows <footer>, may be
# resumed at <now>. Due means the footer's own reset time has passed, or the
# bounded maximum wait since the first sighting has elapsed - the backstop that
# keeps an unparseable or self-updating footer from parking a worker forever.
fm_limit_park_due() {  # <anchor> <now> <footer>
  local anchor=$1 now=$2 footer=$3 reset
  [ "$now" -ge $((anchor + FM_LIMIT_PARK_MAX_WAIT)) ] && return 0
  reset=$(fm_limit_park_reset_epoch "$anchor" "$now" "$footer")
  [ -n "$reset" ] || return 1
  [ "$now" -ge "$reset" ]
}

# --- the durable per-task record -------------------------------------------
#
# state/<id>.limit-park holds only what cannot be re-derived from the pane:
# when the parked footer was first seen (the anchor every absolute reset time is
# resolved against) and how many resume attempts have been spent. It is removed
# the moment the pane stops showing a parked footer, so a worker that resumed -
# on its own or through a resume - starts from a clean record next time.

fm_limit_park_record() {  # <state> <id>
  printf '%s/%s.limit-park' "$1" "$2"
}

fm_limit_park_get() {  # <state> <id> <key>
  local f
  f=$(fm_limit_park_record "$1" "$2")
  [ -f "$f" ] || return 0
  grep "^$3=" "$f" 2>/dev/null | tail -1 | cut -d= -f2-
}

fm_limit_park_set() {  # <state> <id> <key> <value>
  local f tmp
  f=$(fm_limit_park_record "$1" "$2")
  tmp="$f.tmp.$$"
  { [ -f "$f" ] && grep -v "^$3=" "$f" 2>/dev/null; printf '%s=%s\n' "$3" "$4"; } > "$tmp" || return 1
  mv -f "$tmp" "$f"
}

fm_limit_park_clear() {  # <state> <id>
  rm -f "$(fm_limit_park_record "$1" "$2")"
}

# Print the epoch second at which this task's parked footer was first seen,
# recording <now> as that moment the first time it is asked.
fm_limit_park_anchor() {  # <state> <id> <now>
  local anchor
  anchor=$(fm_limit_park_get "$1" "$2" first-seen)
  case "$anchor" in
    ''|*[!0-9]*)
      anchor=$3
      fm_limit_park_set "$1" "$2" first-seen "$anchor" || return 1
      ;;
  esac
  printf '%s' "$anchor"
}

fm_limit_park_attempts() {  # <state> <id>
  local n
  n=$(fm_limit_park_get "$1" "$2" attempts)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

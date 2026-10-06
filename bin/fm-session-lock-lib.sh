#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process run inside that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock and its
# state/.lock-session sidecar; bin/fm-claude-stop-autoarm.sh uses it to prove a
# Stop hook fires inside the lock-owning primary session before it may arm or
# rewake. Two signals decide ownership, either one sufficient: the recorded pid
# is a member of this process's contiguous harness ancestry, or the trusted
# Claude session id below matches the id recorded beside a live lock. Neither
# signal ever fails open: no id, no sidecar, an untrusted id, or a different
# recorded id leaves the ancestry verdict exactly as it was.
# It also owns two fork-only rules that sit on top of that decision: an unclaimed
# Claude Code standby is never a live lock holder, and the ONE limit-stop test
# that lets a fresh session take the lock from a holder that is still running
# but stopped on a usage limit; see docs/session-lock.md for both contracts and
# their safety rationale.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
_FM_SESSION_LOCK_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_SESSION_LOCK_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_SESSION_LOCK_LIB_DIR=.
# shellcheck source=bin/fm-cursor-lib.sh
. "${_FM_SESSION_LOCK_LIB_DIR:-/}/fm-cursor-lib.sh"
unset _FM_SESSION_LOCK_LIB_DIR

# Directory this lib was sourced from, so the node helper below is found from
# the same code root as the rest of bin/ no matter which home is being served.
FM_SESSION_LOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Print field $2 of /proc/$1/stat, counted from 0 at the state field that
# follows the process name, or fail when it cannot be read. The name is skipped
# through its closing parenthesis, because a process may have spaces or
# parentheses in it. /proc is Linux-only, so every caller of this treats a
# failure as "cannot be verified here" rather than as evidence of anything.
fm_proc_stat_field() {
  local pid=$1 index=$2 line rest
  local -a fields
  { read -r line < "/proc/$pid/stat"; } 2>/dev/null || return 1
  rest=${line#*') '}
  [ "$rest" != "$line" ] || return 1
  # shellcheck disable=SC2206
  fields=($rest)
  [ -n "${fields[$index]:-}" ] || return 1
  printf '%s' "${fields[$index]}"
}

# Print the path of the per-pid record Claude Code currently keeps for pid $1,
# or fail when there is no record that can be TRUSTED for that pid. Claude Code
# keeps one such record per session process at <config-root>/sessions/<pid>.json.
#
# A pid is reused, so the record is only trusted when its procStart matches the
# live process's own start value in /proc/<pid>/stat; anything else is a leftover
# from a pid that has since been recycled. /proc exists only on Linux, so on any
# other host that verification cannot be performed at all and every record is
# therefore unverifiable, which every caller treats exactly like an absent one.
fm_claude_trusted_record() {
  local pid=$1 record started recorded
  started=$(fm_proc_stat_field "$pid" 19) || return 1
  record="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$pid.json"
  [ -f "$record" ] && [ -r "$record" ] || return 1
  recorded=$(sed -n \
    's/.*"procStart"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\).*/\1/p' \
    "$record" 2>/dev/null | head -n 1)
  [ -n "$recorded" ] && [ "$recorded" = "$started" ] || return 1
  printf '%s' "$record"
}

# True when pid $1 is an UNCLAIMED Claude Code standby: a pre-warmed spare
# session host (`claude bg-spare`) the background daemon keeps ready for the
# next session to claim, whose trusted per-pid record still carries
# "spare": true.
#
# A standby runs the project's SessionStart hooks while it is being pre-warmed,
# long before anyone uses it, so without this it claims the home's session lock
# and then sits on it indefinitely: it never takes a turn, never exits, and
# reads as a live harness, so the captain's real session starts read-only.
# Claude Code drops the flag from the record the moment a client claims the
# standby, so a claimed one is an ordinary session and nothing here applies to
# it. Its argv cannot tell the two apart, because a claimed standby keeps its
# `bg-spare` command line for the rest of the session; the record is the only
# signal, and an untrusted or absent record answers no.
fm_claude_session_is_spare() {
  local record
  record=$(fm_claude_trusted_record "$1" 2>/dev/null) || return 1
  grep -q '"spare"[[:space:]]*:[[:space:]]*true' "$record" 2>/dev/null
}

# Known harness command names; extend when a new adapter is verified. omp is
# anchored exactly like pi: its process name is the bare word `omp` (verified,
# omp 18.1.11), and a substring match would claim ompd or comp.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the outermost pid of this session's contiguous harness run for callers
# that need that ancestry identity. This is not necessarily the pid written to
# the session lock: fm_session_lock_anchor_pid owns that choice and uses a
# trusted Claude session's model-loop pid instead. Every non-Claude harness
# reports a single pid, so this remains its innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  _fm_harness_outermost_pid "$pids"
}

# Print the last (outermost) pid of ancestry list $1, or return 1 when empty.
_fm_harness_outermost_pid() {  # <ancestry-pids>
  local pid outermost=''
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$1
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
# An unclaimed standby never counts, because it is not a session anyone is
# using (fm_claude_session_is_spare), so a lock one holds reads as stale.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  fm_claude_session_is_spare "$pid" && return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# --- trusted same-session identity -------------------------------------------
# Claude Code hands every hook and tool shell CLAUDE_CODE_SESSION_ID (the
# session's conversation id) and CLAUDE_PID (the pid of the process running the
# model loop). A background session runs that model loop in a transient helper
# bridged to its front-end by a shared daemon, and when that bridge is recycled
# the contiguous claude-named ancestry from a hook to the recorded lock owner
# breaks while the owner pid stays alive, so ancestry alone reads the session's
# own lock as another live session's. The id is the one identity that survives
# the recycling, so it is accepted as a second ownership signal - but only from
# an environment proven to belong to the current Claude run.
#
# Trust gate: CLAUDE_PID must be a Claude-shaped member of this process's
# contiguous harness ancestry. An id merely retained in a helper environment
# fails that membership and is ignored: a hand-started Pi or codex primary under
# a Claude pane still carries the pane's CLAUDE_CODE_SESSION_ID and CLAUDE_PID,
# and must never own a lock with them. Ids are read from the environment only,
# never from ps argv, where prompts and briefs are visible.
#
# A --fork-session successor mints a new id, so it stays a foreign live owner
# until the pre-fork process exits; that is the safe direction and a documented
# non-goal. Two genuinely different live sessions sharing one id is not a
# supported state (Claude refuses to resume a running session under its id).

# Print the Claude session id this process may own with, or return 1. $1 is the
# ancestry list an earlier walk already produced, so a caller that walked once
# need not walk again.
fm_session_lock_trusted_session_id() {  # [<ancestry-pids>]
  local id=${CLAUDE_CODE_SESSION_ID:-} claude_pid=${CLAUDE_PID:-} pids=${1:-} pid comm args
  [ -n "$id" ] || return 1
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$claude_pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$pids" ]; then
    pids=$(fm_harness_ancestry_pids) || return 1
  fi
  while IFS= read -r pid; do
    [ "$pid" = "$claude_pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    fm_harness_process_matches "$comm" "$args" || return 1
    [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
    printf '%s\n' "$id"
    return 0
  done <<EOF
$pids
EOF
  return 1
}

# Print the session id recorded beside the lock in state dir $1, or return 1.
# bin/fm-lock.sh is the only writer of state/.lock-session; a missing,
# symlinked, unreadable, or empty sidecar, or one whose first line contains a
# newline or carriage return, is simply no recorded id.
fm_session_lock_recorded_session_id() {  # <state>
  local state=$1 recorded
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
  recorded=$(head -n 1 "$state/.lock-session" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  case "$recorded" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$recorded"
}

# True when the lock in state dir $1 was recorded by this same Claude session:
# the trusted id equals the id recorded beside the lock. No trusted id, no
# sidecar, or a different recorded id is false.
fm_session_lock_same_session() {  # <state> [<ancestry-pids>]
  local state=$1 trusted recorded
  trusted=$(fm_session_lock_trusted_session_id "${2:-}") || return 1
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  [ "$recorded" = "$trusted" ]
}

# Print the pid bin/fm-lock.sh records on lock line 1 for this session. For a
# Claude session with a trusted id that is CLAUDE_PID, the model-loop process:
# never the shared transient daemon and never a front-end that outlives the
# session, so "recorded pid dead" keeps meaning "session gone" instead of
# wedging a home behind a live daemon whose session died. A replaced background
# helper leaves a dead pid that its own session's next hook reclaims, because
# the sidecar still names that session. Every other session records the
# outermost pid of its contiguous run, exactly as before.
fm_session_lock_anchor_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  if fm_session_lock_trusted_session_id "$pids" >/dev/null; then
    printf '%s\n' "$CLAUDE_PID"
    return 0
  fi
  _fm_harness_outermost_pid "$pids"
}

# True when state dir $1 holds a session lock that this process's session owns:
# the recorded pid is ANY harness ancestor of the current process, or the lock
# was recorded by this same trusted Claude session and its recorded pid is still
# a live harness. Membership is the honest ancestry test, because the lock owner
# sits at an unknown depth in a contiguous Claude run - it is the outermost pid
# when the hook fires inside the session's own nested worker chain, and an inner
# pid when a harness-named daemon parents the session. The same-session path
# requires the recorded pid alive so that a dead one is reclaimed through
# bin/fm-lock.sh's ordinary stale-owner path, which refreshes line 1, rather than
# silently owned with a dead anchor. A missing lock, a malformed lock, a lock
# held by a harness outside this ancestry under another (or no) session id, or
# an ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  fm_session_lock_same_session "$state" "$pids" || return 1
  fm_harness_pid_alive "$lock_pid"
}

# True when state dir $1 records a live verified harness outside this process's
# contiguous harness ancestry that was not recorded by this same trusted Claude
# session. Sets FM_SESSION_LOCK_FOREIGN_OWNER_PID for a diagnostic caller.
# Malformed, missing, dead, and ancestry-uncertain locks are not foreign-owner
# evidence.
# shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
FM_SESSION_LOCK_FOREIGN_OWNER_PID=
fm_session_lock_foreign_owner_live() {
  local state=$1 lock_pid pids pid
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$lock_pid" || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 1
  done <<EOF
$pids
EOF
  fm_session_lock_same_session "$state" "$pids" && return 1
  # shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
  return 0
}

# Read-only classification of state/.lock for machine-readable callers.
# Never acquires the lock. A held lock is not proof the holder is consuming
# wakes; that question belongs to the inbox readiness projection.
#
# Sets:
#   FM_LOCK_INSPECT_STATE         free|held|stale|unreadable|unknown
#   FM_LOCK_INSPECT_PID           recorded pid, or empty
#   FM_LOCK_INSPECT_LIVE_HARNESS  true|false|unknown
#
# held: the recorded pid is a live verified harness.
# stale: the recorded pid is gone.
# unknown: the file or pid cannot be classified without guessing, including a
# live process that is not a verified harness. Existence of a lock file, a
# session record, or a pane is never treated as liveness.
# shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
FM_LOCK_INSPECT_STATE=unknown
FM_LOCK_INSPECT_PID=
FM_LOCK_INSPECT_LIVE_HARNESS=unknown
fm_session_lock_inspect() {  # <state>
  local state=$1 lock pid
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=unknown
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=unknown
  lock="$state/.lock"
  if [ ! -e "$lock" ]; then
    FM_LOCK_INSPECT_STATE=free
    FM_LOCK_INSPECT_LIVE_HARNESS=false
    return 0
  fi
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  fi
  pid=$(cat "$lock" 2>/dev/null) || {
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  }
  pid=${pid%%$'\n'*}
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=$pid
  case "$pid" in
    ''|*[!0-9]*)
      FM_LOCK_INSPECT_STATE=unknown
      return 0
      ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    if fm_harness_pid_alive "$pid"; then
      FM_LOCK_INSPECT_STATE=held
      FM_LOCK_INSPECT_LIVE_HARNESS=true
    else
      FM_LOCK_INSPECT_STATE=unknown
      FM_LOCK_INSPECT_LIVE_HARNESS=false
    fi
    return 0
  fi
  if ps -o comm= -p "$pid" >/dev/null 2>&1; then
    FM_LOCK_INSPECT_STATE=unknown
    return 0
  fi
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=stale
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=false
}

# --- limit-stop takeover -------------------------------------------------
#
# A Claude session that stops on a usage limit leaves its host process running
# for as long as the terminal or the daemon keeps it, so fm_harness_pid_alive
# keeps answering "live" indefinitely and every later session in the home is
# refused the lock and forced read-only. The helpers below give fm-lock.sh one
# positive, evidence-backed test for that specific state.
#
# The bar is deliberately asymmetric: taking the lock from a session that is
# genuinely working is far worse than refusing one that is finished, so ONLY a
# positively identified limit stop returns true and every other outcome -
# unknown harness, no recorded session id, missing, unreadable, or unparseable
# transcript, or any other last record - returns false and keeps refusing.

# Print the directory Claude Code keeps transcripts in for working directory $1.
# It names that directory after the absolute path with every "/" and every "."
# replaced by "-", under the config root CLAUDE_CONFIG_DIR selects.
#
# That mapping is deliberately narrow. All 72 real project directories on the
# machine this was established on were checked against the working directory
# each transcript records internally, and 72 of 72 matched this rule exactly;
# the only special characters appearing in any recorded path were "-", "." and
# "/". Widening it to every non-alphanumeric character was rejected because a
# path holding an underscore resolves correctly today and an all-punctuation
# rule would break it. A path some other character is mangled differently in
# simply yields no transcript, which refuses, so this costs a missed takeover
# and never a wrong one.
fm_claude_transcript_dir() {
  local cwd=$1
  printf '%s/projects/%s' \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
    "$(printf '%s' "$cwd" | tr '/.' '--')"
}

# Print the epoch second process $1 started at, or fail when it cannot be read.
# Derived from the elapsed time ps reports for that pid, which is the process's
# own age rather than anything about a file, so it stays clear of the transcript
# mtime this decision must never depend on. A pid that is gone, or an elapsed
# time that does not parse, fails rather than guessing.
#
# It reads the POSIX "etime" field in its [[dd-]hh:]mm:ss form rather than the
# plain seconds of "etimes", because the latter is a procps extension that BSD
# ps rejects outright and macOS is a supported host.
fm_process_start_epoch() {
  local pid=$1 elapsed days=0 hours=0 mins secs rest part
  elapsed=$(ps -o etime= -p "$pid" 2>/dev/null) || return 1
  elapsed=${elapsed//[[:space:]]/}
  case "$elapsed" in *-*) days=${elapsed%%-*}; elapsed=${elapsed#*-} ;; esac
  case "$elapsed" in
    *:*:*) hours=${elapsed%%:*}; rest=${elapsed#*:} ;;
    *:*) rest=$elapsed ;;
    *) return 1 ;;
  esac
  mins=${rest%%:*}
  secs=${rest#*:}
  for part in "$days" "$hours" "$mins" "$secs"; do
    case "$part" in ''|*[!0-9]*) return 1 ;; esac
  done
  printf '%s' "$(( $(date -u +%s) \
    - (10#$days * 86400 + 10#$hours * 3600 + 10#$mins * 60 + 10#$secs) ))"
}

# True when lock-holder pid $1, holding the lock in state dir $3 for home $2, is
# stopped on a usage limit.
#
# The holder's session id is the one recorded beside the lock in
# state/.lock-session, which the holder itself wrote under the trusted-id gate
# above and which bin/fm-lock.sh refreshes when that same process re-keys its
# conversation (/clear), so it names the conversation the holder is on now.
# A lock with no sidecar, or one that does not hold a session id, has nothing
# tying the holder to a transcript and is never taken over.
#
# Everything else comes from the holder's transcript and its own process age;
# nothing is inferred from elapsed time or file timestamps, because Claude
# rewrites trailing transcript metadata long after a session stops and an mtime
# therefore says nothing about whether it is idle.
fm_session_limit_stopped() {  # <pid> <home> <state>
  local pid=$1 home=$2 state=$3 comm args session_id transcript classifier started
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$home" ] && [ -n "$state" ] || return 1
  classifier="$FM_SESSION_LOCK_LIB_DIR/fm-transcript-limit-stop.mjs"
  [ -f "$classifier" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  [ "$(head -n 1 "$state/.lock" 2>/dev/null || true)" = "$pid" ] || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  # Claude is the only harness with a verified limit-stop transcript shape.
  fm_harness_process_matches "$comm" "$args" || return 1
  [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
  session_id=$(fm_session_lock_recorded_session_id "$state") || return 1
  # The id becomes a path component below, so only an exact session id passes.
  printf '%s' "$session_id" \
    | grep -qE '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' || return 1
  transcript="$(fm_claude_transcript_dir "$home")/$session_id.jsonl"
  [ -f "$transcript" ] && [ -r "$transcript" ] || return 1
  # Resuming a limit-stopped session reuses its session id and its transcript,
  # so the tail alone would still read as stopped while the resumed session is
  # live and holding the lock. The holder must have been running already when
  # that last record was written; a start time that cannot be read refuses.
  started=$(fm_process_start_epoch "$pid") || return 1
  node "$classifier" "$transcript" "$started" >/dev/null 2>&1
}

# Print one stable token describing the session lock in state dir $1 for home
# $2, so fm-lock.sh and the bearings projection render the same decision in
# their own words instead of each deciding it again:
#   free                       no lock file
#   unreadable                 a lock that is not a readable regular file
#   malformed <content>        a lock that does not hold a pid
#   owned <pid>                held by the session this call runs in
#   limit-stopped <pid>        held by a live session stopped on a usage limit
#   held <pid>                 held by another live session
#   stale <pid>                held by a pid that is dead, not a harness, or an
#                              unclaimed standby
# A takeover recorded for THIS session adds a second line after "owned",
# "took-over-from <pid> <iso8601>"; no other reader is told it took anything.
fm_session_lock_report() {
  local state=$1 home=$2 lock="$1/.lock" holder marker
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    echo free
    return 0
  fi
  if [ ! -f "$lock" ] || [ -L "$lock" ] || ! holder=$(cat "$lock" 2>/dev/null); then
    echo unreadable
    return 0
  fi
  case "$holder" in
    ''|*[!0-9]*) echo "malformed $holder"; return 0 ;;
  esac
  if ! fm_harness_pid_alive "$holder"; then
    echo "stale $holder"
    return 0
  fi
  if ! fm_session_lock_owned_by_self "$state"; then
    if fm_session_limit_stopped "$holder" "$home" "$state"; then
      echo "limit-stopped $holder"
    else
      echo "held $holder"
    fi
    return 0
  fi
  echo "owned $holder"
  # Only the session that performed the takeover is told it did. The marker
  # names that session, so a reader that merely sees its lock - and never took
  # anything - is not handed a claim about itself that is not true.
  marker=$(cat "$state/.lock.takeover" 2>/dev/null) || return 0
  if [ "${marker%% *}" = "$holder" ]; then
    printf 'took-over-from %s\n' "${marker#* }"
  fi
  return 0
}

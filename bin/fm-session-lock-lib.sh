#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# It also owns the ONE limit-stop test that lets a fresh session take the lock
# from a holder that is still running but stopped on a usage limit; see
# docs/session-lock.md for the ownership contract and its safety rationale.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# Directory this lib was sourced from, so the node helper below is found from
# the same code root as the rest of bin/ no matter which home is being served.
FM_SESSION_LOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Assign the basename of argv[0] in command line $1 to the variable named $2,
# and fail when there is no argv[0]. It assigns rather than echoes so the
# identity path below stays free of subshells, and it reads argv[0] ONLY,
# never the rest of the command line, so a process that merely mentions a
# harness in an argument is never mistaken for one.
fm_argv0_basename() {
  local argv0=$1
  argv0=${argv0#"${argv0%%[![:space:]]*}"}
  argv0=${argv0%%[[:space:]]*}
  [ -n "$argv0" ] || return 1
  printf -v "$2" '%s' "${argv0##*/}"
}

# True when process name $1 / command line $2 belong to Claude Code, by the
# same two names fm_harness_identity would match it on and no others. Both the
# shared-service test below and the limit-stop test further down need this one
# question answered the same way, so it lives here rather than in either.
fm_harness_is_claude() {
  local comm=$1 args=$2 argv0base
  case "${comm##*/}" in *claude*) return 0 ;; esac
  fm_argv0_basename "$args" argv0base || return 1
  case "$argv0base" in *claude*) return 0 ;; esac
  return 1
}

# True when process name $1 / command line $2 belong to a harness process that
# SERVES MANY SESSIONS AT ONCE rather than being one session's own host.
#
# Claude Code's background sessions run under `claude daemon run`, a supervisor
# that outlives every session it starts and is shared by all of them. It is
# claude-named, so without this test the ancestry walk below happily extends
# past a background session's own host and returns the daemon, with two
# consequences that both break ownership outright: the daemon never exits, so a
# lock recording it looks live forever and every later session is refused; and
# every concurrent background session in the home resolves to that same pid, so
# no two of them can tell each other apart.
#
# The rule matches the subcommand in argv[1], never a substring of the whole
# command line, so a session that merely mentions the word elsewhere is not
# mistaken for a shared service.
fm_harness_shared_service() {
  local comm=$1 args=$2 rest argv1
  fm_harness_is_claude "$comm" "$args" || return 1
  rest=${args#"${args%%[![:space:]]*}"}
  argv1=${rest#* }
  [ "$argv1" != "$rest" ] || return 1
  [ "${argv1%%[[:space:]]*}" = daemon ]
}

# Decide whether one process is a verified harness, from its name ($1, ps comm)
# and its command line ($2, ps args). Echoes the string that identified it, so
# a caller can tell WHICH harness matched, and returns non-zero when none did.
# Both the ancestry walk and the liveness check below go through here: if they
# matched by different rules, the walk could record a lock holder that liveness
# then reads back as stale, and every guard would see the home as unowned.
#
# Three rules, narrowest first:
#  1. the process name itself names a harness;
#  2. a bare interpreter (node, python) running a script whose path names one;
#  3. a versioned launcher, matched on argv[0]'s basename alone. Claude Code
#     execs its own release binary, so the process name is the version string
#     ("2.1.235") and names no harness, while argv[0] is still "claude". This
#     rule reads argv[0] and never the rest of the command line, so a process
#     that merely mentions a harness in an argument - a shell running a
#     "claude ..." command, an editor holding an adapter path - is not mistaken
#     for one by accident. argv[0] is freely settable by any process of the same
#     user, so this is a guard against misidentification, not against a
#     deliberate forge - as rule 1 already was, since naming or symlinking an
#     executable "claude" has always been enough for it.
#     The leaf session process, whose argv[0] is the versioned binary's own
#     path, is deliberately left unmatched here: its basename is the version
#     string too, and reaching it would mean matching a directory component of
#     that path, which would hand a home to any binary merely living under a
#     "claude" directory. The walk below still resolves such a session, through
#     the argv[0]-named launcher above it.
#
# A process shared across sessions is rejected before any of the three rules,
# so no caller can select one: the walk stops one hop below it and keeps this
# session's own host, and a lock already recording one reads back as stale and
# reclaimable instead of pinning the home read-only for as long as that
# service runs.
fm_harness_identity() {
  local comm=$1 args=$2 candidate
  fm_harness_shared_service "$comm" "$args" && return 1
  candidate=${comm##*/}
  if [[ $candidate =~ $FM_HARNESS_RE ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      if [[ $args =~ $FM_HARNESS_RE ]]; then
        printf '%s' "$args"
        return 0
      fi
      ;;
  esac
  fm_argv0_basename "$args" candidate || return 1
  if [[ $candidate =~ $FM_HARNESS_RE ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print a harness pid.
# For every harness except Claude, the first match wins (innermost pid), which
# is where e.g. Pi's shared signed-wrapper ancestry actually holds the session:
# a "pi-signed" launcher can be the direct parent of the inner "pi" engine
# pid that owns the lock, and the wrapper pid above it is not that owner.
# Claude Code's bg-spare hook worker chain is the opposite shape: it nests
# several claude-named processes directly parent-child with no non-harness
# process between them, and the lock is held by the outermost pid of that
# run. So once a claude-named match is found, this keeps walking past it
# looking for a still-more-ancestral claude-named match, and stops the
# instant a non-match follows - never walking past that gap to an unrelated
# claude-named process further up the real process tree (e.g. the live
# session that launched a test as its own subprocess). A process shared across
# sessions is not an identity at all, so it counts as exactly such a non-match
# and the extension stops one hop below it, keeping this session's own host.
# The harness pid lives as long as the session, unlike the transient subshell
# pid of any one tool call.
fm_harness_ancestry_pid() {
  local pid=$$ comm args ident best='' extending=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if ident=$(fm_harness_identity "$comm" "$args"); then
      best="$pid"
      case "$ident" in
        *claude*) extending=1 ;;
        *) break ;;
      esac
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ -n "$best" ] && { echo "$best"; return 0; }
  return 1
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_identity "$comm" "$args" >/dev/null
}

# True when state dir $1 holds a session lock whose pid is the harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. A missing lock, a lock held by another live harness, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid my_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ]
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
# unknown harness, unresolvable session id, missing, unreadable, or unparseable
# transcript, or any other last record - returns false and keeps refusing.

# Print the session id carried in command line $1, or fail when there is none.
# Only a session hosted with an explicit --session-id can be traced back to its
# transcript; a session whose id never reaches its own argv (a plain foreground
# `claude`) is unresolvable and therefore never taken over.
fm_claude_session_id() {
  local args=$1 rest id
  case "$args" in *' --session-id '*) ;; *) return 1 ;; esac
  rest=${args#*' --session-id '}
  id=${rest%% *}
  printf '%s' "$id" \
    | grep -qE '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' || return 1
  printf '%s' "$id"
}

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
# ps rejects outright and macOS is a supported host: on Darwin every takeover
# would otherwise refuse and the feature would be a silent no-op there.
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

# True when pid $1 is pid $2 or one of its descendants, walking up to 16 hops of
# real parent links. Bounded in both directions: the hop count caps the walk,
# and reaching pid 1 or an unreadable process ends it, so a process outside the
# holder's own tree is never reported as being in it.
fm_pid_in_tree() {
  local pid=$1 root=$2
  case "$pid$root" in ''|*[!0-9]*) return 1 ;; esac
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    [ "$pid" = "$root" ] && return 0
    [ "$pid" -gt 1 ] || return 1
    pid=$(fm_proc_stat_field "$pid" 1) || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  done
  return 1
}

# Print the session id Claude Code currently records for pid $1, or fail when
# there is no record that can be TRUSTED for that pid. Claude Code keeps one
# such record per session process at <config-root>/sessions/<pid>.json, holding
# that session's current sessionId and the procStart of the process it belongs
# to.
#
# A pid is reused, so the record is only trusted when its procStart matches the
# live process's own start value in /proc/<pid>/stat; anything else is a leftover
# from a pid that has since been recycled. /proc exists only on Linux, so on any
# other host that verification cannot be performed at all and every record is
# therefore unverifiable, which the single caller below treats exactly like an
# absent one - leaving existing behaviour untouched there.
fm_claude_recorded_session_id() {
  local pid=$1 record started recorded id
  started=$(fm_proc_stat_field "$pid" 19) || return 1
  record="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$pid.json"
  [ -f "$record" ] && [ -r "$record" ] || return 1
  recorded=$(sed -n \
    's/.*"procStart"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\).*/\1/p' \
    "$record" 2>/dev/null | head -n 1)
  [ -n "$recorded" ] && [ "$recorded" = "$started" ] || return 1
  id=$(sed -n \
    's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F-]\{36\}\)".*/\1/p' \
    "$record" 2>/dev/null | head -n 1)
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

# True when the session lock holder $1 is demonstrably NOT working on session id
# $2 any more, because a trusted per-pid record inside its own process tree names
# a different session.
#
# A holder's argv is fixed at exec, so a live session that replaces its
# conversation in place (/clear, /new, /fork) keeps pointing at the transcript of
# the session it replaced - whose tail is still the limit record that same
# process wrote before the replacement. Without this the holder would be taken
# over while actively working.
#
# This is a purely restrictive cross-check and never an alternative way to
# resolve the session id: resolution still comes from argv alone. A missing,
# unreadable, unparseable, or unverifiable record adds no restriction at all, so
# every existing condition still decides the outcome on its own.
#
# The lock deliberately records the OUTERMOST pid of a run while these records
# are keyed on an inner pid, so the search covers the holder and its own
# descendants. It walks the recorded pids rather than the process table, and
# confines itself to the holder's tree, so a record belonging to an unrelated
# process is never consulted. A record that names the expected session wins over
# one that does not, because corroboration may only ever permit.
fm_claude_session_replaced() {
  local holder=$1 expected=$2 dir record pid id replaced=1
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
  [ -d "$dir" ] || return 1
  for record in "$dir"/*.json; do
    [ -f "$record" ] || continue
    pid=${record##*/}
    pid=${pid%.json}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    fm_pid_in_tree "$pid" "$holder" || continue
    id=$(fm_claude_recorded_session_id "$pid") || continue
    [ "$id" = "$expected" ] && return 1
    replaced=0
  done
  return "$replaced"
}

# True when the session behind lock-holder pid $1, running in home $2, is
# stopped on a usage limit. Everything it needs comes from the holder's own
# argv and its transcript; nothing is inferred from elapsed time or file
# timestamps, because Claude rewrites trailing transcript metadata long after a
# session stops and an mtime therefore says nothing about whether it is idle.
fm_session_limit_stopped() {
  local pid=$1 home=$2 args comm session_id transcript classifier started
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$home" ] || return 1
  classifier="$FM_SESSION_LOCK_LIB_DIR/fm-transcript-limit-stop.mjs"
  [ -f "$classifier" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  # Claude is the only harness with a verified limit-stop transcript shape.
  fm_harness_is_claude "$comm" "$args" || return 1
  session_id=$(fm_claude_session_id "$args") || return 1
  # A holder that has since replaced its conversation in place is still working,
  # under a session id its argv cannot know about. This only ever refuses; where
  # no trusted record exists it adds nothing and the conditions below decide.
  fm_claude_session_replaced "$pid" "$session_id" && return 1
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
#   stale <pid>                held by a pid that is dead or not a harness
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
    if fm_session_limit_stopped "$holder" "$home"; then
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

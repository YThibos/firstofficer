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

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

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
# keeps one such record per session process at <config-root>/sessions/<pid>.json,
# holding that session's current sessionId and the procStart of the process it
# belongs to.
#
# A pid is reused, so the record is only trusted when its procStart matches the
# live process's own start value in /proc/<pid>/stat; anything else is a leftover
# from a pid that has since been recycled. /proc exists only on Linux, so on any
# other host that verification cannot be performed at all and every record is
# therefore unverifiable, which every caller treats exactly like an absent one -
# leaving existing behaviour untouched there.
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

# Print the session id in pid $1's trusted per-pid record, or fail when there is
# no trusted record or it names no session.
fm_claude_recorded_session_id() {
  local record id
  record=$(fm_claude_trusted_record "$1") || return 1
  id=$(sed -n \
    's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F-]\{36\}\)".*/\1/p' \
    "$record" 2>/dev/null | head -n 1)
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

# True when pid $1 is a process Claude Code itself records as hosting a live
# session: the SESSION HOST, the process a session's own tool calls and hooks
# both run as children of.
#
# This is the only identity in a Claude session that is fixed for the whole of
# it. The name-and-argv rules below resolve a process by how it was LAUNCHED,
# and Claude Code re-hosts a session it moves into a background job: the
# launching `claude` client stays alive in the terminal while the session itself
# is handed to a daemon-spawned pty host that is then reparented to init. The
# ancestry walk therefore answers with a different pid before and after that
# move, and the pid it answered with first - a client in an unrelated process
# tree - stays alive for the rest of the session, so it reads back as a live
# harness holding the home and every later check concludes some OTHER session
# owns it. The session host has neither problem: it is one process for one
# session, it is what both a tool call and a Stop hook descend from, and it is
# gone the moment the session is.
#
# Verification is Claude Code's own per-pid record, pid-reuse checked, so this
# only ever answers yes for a process Claude currently calls a session. Where it
# cannot be verified at all - any non-Linux host, an older Claude Code, a
# session with no record yet - it answers no and the rules below decide exactly
# as they did before.
fm_claude_session_host() {
  fm_claude_recorded_session_id "$1" >/dev/null 2>&1
}

# True when pid $1 is an UNCLAIMED Claude Code standby: a pre-warmed spare
# session host (`claude bg-spare`) the background daemon keeps ready for the
# next session to claim, whose trusted per-pid record still carries
# "spare": true.
#
# A standby runs the project's SessionStart hooks while it is being pre-warmed,
# long before anyone uses it, so without this it claims the home's session lock
# and then sits on it indefinitely: it never takes a turn, never exits, and
# reads as a live verified session host, so the captain's real session starts
# read-only. Claude Code drops the flag from the record the moment a client
# claims the standby, so a claimed one is an ordinary session host and nothing
# here applies to it. Its argv cannot tell the two apart, because a claimed
# standby keeps its `bg-spare` command line for the rest of the session; the
# record is the only signal, and an untrusted or absent record answers no.
fm_claude_session_is_spare() {
  local record
  record=$(fm_claude_trusted_record "$1" 2>/dev/null) || return 1
  grep -q '"spare"[[:space:]]*:[[:space:]]*true' "$record" 2>/dev/null
}

# Print the pid of the CURRENT process's own verified Claude session host, by
# walking real parent links (up to 16 hops) until one of them is a host. It
# answers the same question fm_harness_ancestry_pid short-circuits on, and only
# that question: where no record can be verified anywhere in the ancestry it
# fails, and every caller then leaves the existing rules deciding.
fm_claude_own_session_host_pid() {
  local pid=$$
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    if fm_claude_session_host "$pid"; then
      printf '%s' "$pid"
      return 0
    fi
    [ "$pid" -gt 1 ] || return 1
    pid=$(fm_proc_stat_field "$pid" 1) || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  done
  return 1
}

# True when lock holder $1 is a SUPERSEDED host of the session this call runs
# in, because its own trusted per-pid record names the very same session id as
# this session's current host.
#
# That identity is positive proof rather than an inference. Claude Code keeps
# one record per host process and re-hosts a session it moves into a background
# job, so two live pids naming one session id are the client the captain
# launched and the pty host the session was handed to, in that order. A lock
# claimed BEFORE that move records the client, which stays alive and
# claude-named for the rest of the session, and without this the home would read
# as held by another live session forever and the Stop-owned auto-arm could
# never claim it.
#
# Only that positive match ever refuses. A holder whose record names a DIFFERENT
# session id is another live session and keeps its lock; a holder with no record,
# an unverifiable one, or one whose procStart does not match the live process
# adds no evidence at all and is decided exactly as before; and where this
# session's own host cannot be resolved - any host without /proc, an older Claude
# Code, a session that has not written its record yet - nothing here applies.
# The holder that IS this session's current host is not superseded by anything
# and is deliberately excluded, so a session never reads its own live lock as
# reclaimable.
fm_claude_superseded_own_host() {
  local holder=$1 holder_id own_pid own_id
  case "$holder" in ''|*[!0-9]*) return 1 ;; esac
  holder_id=$(fm_claude_recorded_session_id "$holder") || return 1
  own_pid=$(fm_claude_own_session_host_pid) || return 1
  [ "$own_pid" != "$holder" ] || return 1
  own_id=$(fm_claude_recorded_session_id "$own_pid") || return 1
  [ "$holder_id" = "$own_id" ]
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
  # A process that serves many sessions at once is never one session's
  # identity, whichever rule below would otherwise match it.
  fm_harness_shared_service "$comm" "$args" && return 1
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
#
# A verified Claude session host short-circuits every naming rule and ends the
# run on sight, because it answers the question the walk is only approximating:
# which process IS this session. Stopping there also keeps the Claude extension
# from climbing out of the session into the client that launched it, whose pid
# the session loses the moment Claude re-hosts it as a background job (see
# fm_claude_session_host). The shared-service rejection is the one test that
# still precedes it, so a process serving many sessions is never selected.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if ! fm_harness_shared_service "$comm" "$args" && fm_claude_session_host "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
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

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
# A verified Claude session host counts, because the walk above records one and
# a holder it just recorded must not read back as stale to every guard: a
# session host is named after its release version, so no naming rule matches it.
# A superseded host of THIS session never counts, whatever its name: the home it
# holds is this session's own across a re-host, so it is reclaimable rather than
# held by someone else. An unclaimed standby never counts either, because it is
# not a session anyone is using (fm_claude_session_is_spare).
# A process shared across sessions is rejected before the host check as well as
# before the naming rules, so a lock recording one stays reclaimable by every
# route.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  fm_claude_superseded_own_host "$pid" && return 1
  fm_claude_session_is_spare "$pid" && return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_shared_service "$comm" "$args" && return 1
  fm_claude_session_host "$pid" && return 0
  fm_harness_process_matches "$comm" "$args"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
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
  return 1
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

# Print the session id carried in the argv of process $1, or fail when there is
# none that can be read UNAMBIGUOUSLY. Only a session hosted with an explicit
# --session-id can be traced back to its transcript; a session whose id never
# reaches its own argv (a plain foreground `claude`) is unresolvable and
# therefore never taken over.
#
# It reads the discrete argv elements from /proc/<pid>/cmdline, where they are
# NUL separated, and never the single space-joined string ps prints. Flattened,
# there is no way to tell a real "--session-id <uuid>" pair from that same text
# sitting INSIDE one argument - a prompt, a file path, a command a wrapper was
# handed - so a live session merely carrying those words in an argument would
# resolve to a transcript that is not its own and could then be taken over on a
# stranger's evidence. As discrete elements the pair is unambiguous: the flag is
# an element of its own and the id is the element that follows it.
#
# /proc is Linux-only and there is deliberately no fallback to the flattened
# string, because such a fallback would reinstate exactly the ambiguity this
# closes. Where discrete argv cannot be read, macOS included, this refuses and
# the takeover is simply unavailable on that host. That is the intended trade,
# and the same one the whole test makes: a missed takeover, never a wrong one.
fm_claude_session_id() {
  local pid=$1 arg id='' next=0
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "/proc/$pid/cmdline" ] || return 1
  while IFS= read -r -d '' arg; do
    if [ "$next" -eq 1 ]; then
      id=$arg
      break
    fi
    if [ "$arg" = --session-id ]; then
      next=1
    fi
  done < "/proc/$pid/cmdline"
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
# Inside this function the record is purely restrictive and may only ever
# refuse. Resolution itself is argv first and the per-pid record only as a
# fallback (fm_session_limit_stopped), but that order is decided before this
# call and nothing here ever widens it. A missing, unreadable, unparseable, or
# unverifiable record adds no restriction at all, so every existing condition
# still decides the outcome on its own.
#
# The lock records the verified Claude session host whenever there is one, and
# Claude keys sessions/<pid>.json on exactly that one-process-per-session host,
# so fm_pid_in_tree matches the holder's own record immediately and the
# cross-check still covers the record that matters. Only where no host can be
# verified does the lock fall back to recording the outermost pid of a run
# while these records are keyed on an inner pid, and there the search covers
# the holder and its own descendants. It walks the recorded pids rather than
# the process table, and
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
  # Claude is the only harness with a verified limit-stop transcript shape. A
  # verified session host is one by the same evidence fm_harness_pid_alive
  # accepts it on, and is the shape the lock now records; without it the
  # takeover this whole path exists for is unreachable for every holder whose
  # name is its release version.
  fm_harness_is_claude "$comm" "$args" || fm_claude_session_host "$pid" || return 1
  # Argv first, unchanged. A verified host that carries no --session-id falls
  # back to the per-pid record Claude Code keeps for it, which is a stronger
  # link than argv rather than a looser one: it is that process's own current
  # session, pid-reuse checked against /proc. A record that cannot be trusted
  # yields nothing and the refusal stands.
  #
  # This deliberately widens the takeover contract, and the captain approved
  # it: a plain foreground claude with no --session-id was previously never
  # taken over, and on Linux it now can be, because it is a verified session
  # host whose id comes from its own record. What keeps that safe is unchanged
  # - the transcript classification below still has to positively identify a
  # usage-limit stop, the record is trusted only when its procStart matches the
  # live process, and the holder must have been running when that last record
  # was written. Non-Linux hosts are unaffected: no record is verifiable there,
  # so such a holder is refused exactly as before.
  session_id=$(fm_claude_session_id "$pid") \
    || session_id=$(fm_claude_recorded_session_id "$pid") \
    || return 1
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

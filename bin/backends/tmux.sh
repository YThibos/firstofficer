#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter.
#
# Reference backend (AGENTS.md section 8; data/fm-backend-design-d7). P1 moves
# the tmux command sequences that fm-send.sh, fm-peek.sh, fm-watch.sh,
# fm-spawn.sh, and fm-teardown.sh already ran inline into named functions
# here, running the EXACT same commands in the EXACT same order, so the
# default (tmux, `backend=` absent) path stays byte-identical. Sourced only
# through bin/fm-backend.sh's fm_backend_source, never directly.
#
# Worktree acquisition (running `treehouse get` inside the pane, and polling
# its cwd) is unchanged by this extraction: P1 scopes only the session
# provider, not the worktree provider, so fm-spawn.sh still drives that part
# inline with these same send/current-path primitives.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/fm-tmux-lib.sh, shared with the away-mode daemon
# (bin/fm-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-agent-process-lib.sh"

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# fm_backend_tmux_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's and fm-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
fm_backend_tmux_capture() {  # <target> <lines>
  tmux capture-pane -p -t "$1" -S -"$2"
}

# fm_backend_tmux_visible_capture: the visible viewport only. `-S -0` starts at
# the first line of the pane rather than in its history, so nothing scrolled out
# of view can appear in the result - the guarantee a trust-dialog predicate
# needs, which the scrollback-bounded capture above cannot give.
fm_backend_tmux_visible_capture() {  # <target>
  tmux capture-pane -p -t "$1" -S -0
}

# fm_backend_tmux_send_key: one named key. Mirrors fm-send.sh's --key path:
# `tmux display-message -p -t "$T" '#{pane_id}' >/dev/null`, then
# `tmux send-keys -t "$T" "$2"`.
fm_backend_tmux_send_key() {  # <target> <key>
  tmux display-message -p -t "$1" '#{pane_id}' >/dev/null
  tmux send-keys -t "$1" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Re-exports fm_tmux_submit_core (bin/fm-tmux-lib.sh) verbatim; see
# that file for the composer-verification contract and echoed verdicts.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
    printf 'firstmate'
  fi
}

# fm_backend_tmux_create_task: create the task's window in <proj-abs>,
# refusing an existing <window-name> in <session>. Mirrors fm-spawn.sh's
# duplicate-check-then-new-window sequence, including the exact error text
# (session:window, matching how fm-spawn.sh composed its own $T). Prints the
# created window's stable window id on stdout for the caller to target.
#
# Robustness (fm-spawn tmux window handling under a non-default captain config):
#   - Capture a STABLE window id with -P -F '#{window_id}', and let tmux append
#     at the next free index by targeting the session with a trailing colon
#     ("$ses:"), so a non-default base-index (e.g. base-index 1) cannot collide.
#   - PIN the window name by disabling automatic-rename and allow-rename on the
#     new window: the captain's tmux may rename the window away from fm-<id> once
#     treehouse cd's into the worktree, which would break name-based targeting.
# The returned window id lets callers target the window even if its name is ever
# lost, so worktree discovery cannot fall back to the active client's window.
fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 wid
  if tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs") || return 1
  tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# fm_backend_tmux_current_path: the live pane's current working directory, or
# empty on any tmux error. Mirrors fm-spawn.sh's worktree-discovery poll:
# `tmux display-message -p -t "$T" '#{pane_current_path}'`.
fm_backend_tmux_current_path() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (`treehouse get`, the GOTMPDIR export) that already ran this exact sequence
# inline in fm-spawn.sh. Mirrors `tmux send-keys -t "$T" "<text>" Enter`.
fm_backend_tmux_send_text_line() {  # <target> <text>
  tmux send-keys -t "$1" "$2" Enter
}

# fm_backend_tmux_send_literal: send TEXT as literal bytes with no
# submission - the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter for the harness to settle).
# Mirrors `tmux send-keys -t "$T" -l "<text>"`.
fm_backend_tmux_send_literal() {  # <target> <text>
  tmux send-keys -t "$1" -l "$2"
}

# fm_backend_tmux_window_inventory: <session-target>'s window names, one per
# line on stdout, together with a verdict on the READ ITSELF, which is what
# every caller that must not guess depends on:
#   0 - the inventory was read; its lines are that session's windows.
#   2 - tmux answered definitively that the session, or its whole server, is
#       absent, so no window of that session exists.
#   1 - the read could not be made at all, and proves nothing either way. A
#       transient tmux problem, or a tmux that is not even on PATH, must never
#       be read as an absent endpoint: that mistake launches a duplicate agent
#       for fm_backend_tmux_agent_state and reports a live window as closed for
#       fm_backend_tmux_kill.
# The target is passed through exactly as the caller means it, so a caller that
# requires the exact recorded session asks for `=session` and still gets the
# same classification.
fm_backend_tmux_window_inventory() {  # <session-target>
  local windows
  if windows=$(LC_ALL=C tmux list-windows -t "$1" -F '#{window_name}' 2>&1); then
    printf '%s\n' "$windows"
    return 0
  fi
  case "$windows" in
    *"can't find session:"*|*"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
      return 2
      ;;
  esac
  return 1
}

# fm_backend_tmux_kill: remove one explicitly named task window.
# Empty, omitted, and malformed targets return nonzero before invoking tmux so
# tmux can never interpret an empty target as the caller's current window.
#
# A close that did not succeed is resolved, never assumed: `kill-window` fails
# for the ordinary already-exited window exactly as it does for a window that
# is still there, so its status alone cannot tell a benign cleanup from a
# stranded endpoint. The re-read below settles which one happened, under the
# window's EXACT recorded identity (`=session` plus a whole-line name match -
# never a prefix, which would read a neighbor as this window's survivor).
# Only a read that actually happened can settle it, so the same classification
# fm_backend_tmux_agent_state uses applies here: a window still present is the
# kill failing to do its job, a definitively absent session or server is the
# silent success, and an inventory that could not be read refuses rather than
# calling a window it never saw closed. An already-gone window, and a whole
# server that is already gone, stay silent successes. Verified against real
# tmux 3.7c: killing a live window, re-killing the same gone window, and
# killing into a dead session all return 0 here
# (docs/verification/runtime-backends.md "Endpoint close").
fm_backend_tmux_kill() {  # <target>
  local target=${1:-} session window windows inventory_status
  case "$target" in
    *:*)
      session=${target%%:*}
      window=${target#*:}
      ;;
    *) return 1 ;;
  esac
  case "$session:$window" in
    :*|*:|*:*:*) return 1 ;;
  esac
  tmux kill-window -t "=$session:=$window" 2>/dev/null && return 0
  windows=$(fm_backend_tmux_window_inventory "=$session")
  inventory_status=$?
  if [ "$inventory_status" -eq 2 ]; then
    return 0
  fi
  if [ "$inventory_status" -ne 0 ]; then
    echo "error: tmux window $session:$window could not be read after its close, so whether it survived is unknown" >&2
    return 1
  fi
  printf '%s\n' "$windows" | grep -qxF -- "$window" || return 0
  echo "error: tmux window $session:$window is still present after its close" >&2
  return 1
}

# fm_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pty's
# foreground process group (verified empirically with real tmux 3.6a: a
# harness invoked interactively stays the reported command even while it
# shells out to subcommands that do not take over the pty - e.g. `bash -c
# "sleep 30"` alone reports "sleep" because bash execs directly into it, but
# a persisting parent script running `sleep` as a child reports the PARENT's
# own name throughout; the value reverts to the shell's own name only once
# the foreground command actually exits). Empty on any tmux error.
fm_backend_tmux_current_command() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# The process-name classifier every liveness signal below feeds
# (fm_agent_process_classify_name) is owned by bin/fm-agent-process-lib.sh,
# shared with the Herdr adapter so both backends mean the same thing by
# `agent`, `shell`, and `other`.

# fm_backend_tmux_foreground_comms: the kernel-side names of every process in
# <target>'s pane tty foreground process group, one full value per line.
# Empty on any failure.
#
# This is the foreground-process-group half of the liveness probe, and it exists
# because `#{pane_current_command}` and `ps -o comm=` expose different name
# fields whose roles vary by platform. On macOS the tmux field can carry a
# harness-rewritten title (Claude Code 2.1.220 reports `2.1.220`) while `comm`
# retains executable identity; the portable Linux regression observes the
# reverse for its version-named executable. Reading both `comm` and argv[0]
# preserves an identifying install path without making either platform's field
# assignment load-bearing.
#
# Scoping to the foreground process group rather than to the pane's descendants
# is what keeps the probe honest in the other direction: a harness-named process
# left running in the background of an otherwise idle pane is deliberately NOT
# reported, so a genuinely agent-free pane still classifies `dead`. It also
# reports every member of a multi-process launcher (the Pi Launcher path runs a
# `pi-signed` wrapper and a `pi` engine in one group), so no launcher needs its
# own special case here.
#
# Like fm_backend_tmux_current_command this is a RAW pane read: tmux answers an
# absent target from the client's active window rather than failing, so callers
# must confirm exact window membership first, exactly as the classifier below
# does, or they will describe some other pane entirely.
fm_backend_tmux_foreground_comms() {  # <target>
  local target=$1 tty pid pgid tpgid comm
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$comm"
      done
}

# The foreground group's full command lines. Needed because a node-bundle
# harness carries its identity in argv[1] rather than in its command name or
# argv[0]; bin/fm-gemini-lib.sh owns what counts as evidence inside one.
fm_backend_tmux_foreground_args() {  # <target>
  local target=$1 tty pid pgid tpgid comm args
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        [ -n "$args" ] && printf '%s\n' "$args"
      done
}

fm_backend_tmux_foreground_pids() {  # <target>
  local target=$1 tty pid pgid tpgid comm
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$pid"
      done
}

fm_backend_tmux_foreground_argv0s() {  # <target>
  local target=$1 tty pid pgid tpgid comm args argv0
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        args=${args#"${args%%[![:space:]]*}"}
        argv0=${args%%[[:space:]]*}
        [ -n "$argv0" ] && printf '%s\n' "$argv0"
      done
}

# fm_backend_tmux_agent_state: recovery-grade harness-agent state for one
# recorded target. See bin/fm-backend.sh's fm_backend_agent_state for the
# shared state vocabulary and docs/tmux-backend.md "Agent liveness probe" for
# the empirical basis. Tmux silently falls back to the active window when a
# named target is absent, so the exact recorded window must appear in a
# successful session inventory before its foreground command can be trusted.
# An omitted window or a definitive missing-session/server response is
# `missing`; any other inventory or pane read failure is `unreadable`, so a
# transient tmux problem never licenses a duplicate.
# fm_backend_tmux_window_inventory above owns that read classification, shared
# with fm_backend_tmux_kill so both mean the same thing by an absent session.
#
# The verdict combines two independent name sources rather than trusting either
# alone. Either source naming a verified harness is enough for `alive`, because
# a false `dead` is the one outcome that can launch a duplicate agent onto a
# live worktree, while the foreground process group - when it is readable - is
# authoritative for the negative verdicts, since it is the only source that can
# distinguish a truly idle pane from a rewritten process title.
fm_backend_tmux_agent_state() {  # <target>
  local target=$1 comm session window windows inventory_status
  local foreground argv0s name pid fg_seen=0 fg_shell=0 fg_other=0
  case "$target" in
    *:*:*|'':*|*:'') printf 'unreadable'; return 0 ;;
    *:*) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  windows=$(fm_backend_tmux_window_inventory "$session")
  inventory_status=$?
  if [ "$inventory_status" -ne 0 ]; then
    if [ "$inventory_status" -eq 2 ]; then
      printf 'missing'
    else
      printf 'unreadable'
    fi
    return 0
  fi
  if ! printf '%s\n' "$windows" | grep -Fqx "$window"; then
    printf 'missing'
    return 0
  fi

  foreground=$(fm_backend_tmux_foreground_comms "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fg_seen=1
    case "$(fm_agent_process_classify_name "$name")" in
      agent) printf 'alive'; return 0 ;;
      shell) fg_shell=1 ;;
      *) fg_other=1 ;;
    esac
  done <<EOF
$foreground
EOF

  argv0s=$(fm_backend_tmux_foreground_argv0s "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$(fm_agent_process_classify_name '' "$name")" = agent ]; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$argv0s
EOF

  # Preserve argv boundaries where the platform exposes them. This is needed
  # when the Gemini script path contains whitespace, which flattened ps output
  # cannot represent unambiguously.
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if fm_gemini_pid_is_gemini "$pid"; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$(fm_backend_tmux_foreground_pids "$target")
EOF

  # Fall back to flattened arguments on platforms without /proc. Positive
  # evidence only - a bare interpreter still reaches the negative verdicts.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if fm_gemini_args_are_gemini "$name"; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$(fm_backend_tmux_foreground_args "$target")
EOF

  comm=$(fm_backend_tmux_current_command "$target") || {
    printf 'unreadable'
    return 0
  }
  if [ "$(fm_agent_process_classify_name "$comm")" = agent ]; then
    printf 'alive'
    return 0
  fi

  # A readable foreground process group settles the negative verdicts: only a
  # group that is nothing but shells is confidently agent-free.
  if [ "$fg_seen" -eq 1 ]; then
    if [ "$fg_other" -eq 0 ] && [ "$fg_shell" -eq 1 ]; then
      printf 'dead'
    else
      printf 'ambiguous'
    fi
    return 0
  fi

  case "$comm" in
    '') printf 'unreadable'; return 0 ;;
  esac
  case "$(fm_agent_process_classify_name "$comm")" in
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_tmux_agent_alive() {  # <target>
  case "$(fm_backend_tmux_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

# --- endpoint absence proof --------------------------------------------------
#
# fm_backend_agent_state's tmux `missing` describes only the server THIS
# process addresses, so on its own it cannot tell a destroyed window from one on
# a server this seat cannot see. The functions below are the tmux half of the
# control plane's absence proof (bin/fm-control-lib.sh's
# fm_control_endpoint_absence_verdict owns the argument and the verdicts); each
# prints "<verdict>\t<reason>" with verdict gone or unproven.

# fm_backend_tmux_server_identity: the identity of the tmux server at <socket>
# (or the ambient one when <socket> is empty) as
# "<socket_path>\t<server-pid>\t<server-start-time>". Returns nonzero, printing
# nothing, when no server answers. A socket path alone is not an identity: a
# restarted server reuses it, so the pid and start time pin the exact server a
# window was created on.
fm_backend_tmux_server_identity() {  # [<socket>] [<session>]
  local socket=${1-} session=${2-} out pid start path
  local -a sock=() tgt=()
  [ -z "$socket" ] || sock=(-S "$socket")
  [ -z "$session" ] || tgt=(-t "=$session:")
  # tmux escapes control characters in display-message output, so the fields
  # are space-separated with the socket path, the only one that may hold a
  # space, last.
  out=$(LC_ALL=C tmux "${sock[@]}" display-message -p "${tgt[@]}" '#{pid} #{start_time} #{socket_path}' 2>/dev/null) || return 1
  pid=${out%% *}
  out=${out#* }
  start=${out%% *}
  path=${out#* }
  case "$pid:$start" in
    *[!0-9:]*|:*|*:) return 1 ;;
  esac
  [ -n "$path" ] && [ "$path" != "$start" ] || return 1
  printf '%s\t%s\t%s\n' "$path" "$pid" "$start"
}

# Whether <pid> is a running tmux process. Any process that cannot be shown NOT
# to be tmux counts as one, so an unreadable process table never proves a
# server dead.
fm_backend_tmux_pid_is_tmux() {  # <pid>
  local comm
  case "${1-}" in ''|*[!0-9]*) return 0 ;; esac
  kill -0 "$1" 2>/dev/null || [ -e "/proc/$1" ] || return 1
  comm=$(ps -p "$1" -o comm= 2>/dev/null) || return 0
  case "$comm" in
    *tmux*) return 0 ;;
  esac
  return 1
}

# fm_backend_tmux_recorded_absence: the proof for a record that carries its
# endpoint's server identity (tmux_socket, tmux_server_pid,
# tmux_server_start, written at spawn). The recorded server is asked directly
# through its own socket, so the answer is about the task's endpoint and not
# about whichever server this process happens to address:
#   - the recorded server answers with the recorded identity: the window's
#     name absent from every session on it is `gone`; a window still there is
#     `unproven`, because this seat's own read could not see it.
#   - a server with the recorded pid but another start time answers on that
#     socket: that pid now belongs to a later server, as after a reboot, so the
#     recorded server is `gone`.
#   - another server answers on that socket, or none does: the recorded server
#     is gone unless its recorded pid is still a running tmux process (a server
#     whose socket file was removed keeps running), which is `unproven`.
fm_backend_tmux_recorded_absence() {  # <target> <socket> <pid> <start>
  local target=$1 socket=$2 pid=$3 start=$4 window identity windows
  window=${target#*:}
  if identity=$(fm_backend_tmux_server_identity "$socket"); then
    identity=${identity#*$'\t'}
    if [ "$identity" = "$pid"$'\t'"$start" ]; then
      # Every session, not only the recorded one: a window moved or a session
      # renamed on that server is still the task's live window.
      windows=$(LC_ALL=C tmux -S "$socket" list-windows -a -F '#{window_name}' 2>/dev/null) || {
        printf 'unproven\tthe recorded tmux server at %s answered but its windows could not be read' "$socket"
        return 0
      }
      if printf '%s\n' "$windows" | grep -Fqx -- "$window"; then
        printf 'unproven\twindow %s still exists on the recorded tmux server at %s, which this process does not address' "$window" "$socket"
        return 0
      fi
      printf 'gone\t'
      return 0
    fi
    if [ "${identity%%$'\t'*}" = "$pid" ]; then
      printf 'gone\t'
      return 0
    fi
  fi
  if fm_backend_tmux_pid_is_tmux "$pid"; then
    printf 'unproven\tthe recorded tmux server (pid %s) no longer answers on %s but may still be running' "$pid" "$socket"
    return 0
  fi
  printf 'gone\t'
}

# fm_backend_tmux_worktree_holders: pids of live processes, other than this
# process and its ancestors, whose working directory is <worktree> or below it.
# Returns nonzero when the process table's working directories cannot be read
# at all, so an unreadable table never reads as "nobody".
fm_backend_tmux_worktree_holders() {  # <worktree>
  local wt pid cwd self=${BASHPID:-$$} p
  local -a mine=()
  wt=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  p=$self
  while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ]; do
    mine+=("$p")
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ') || break
  done
  if [ -d /proc/self ] && [ -r /proc/self/cwd ]; then
    for cwd in /proc/[0-9]*/cwd; do
      pid=${cwd#/proc/}
      pid=${pid%/cwd}
      cwd=$(readlink "$cwd" 2>/dev/null) || continue
      case "$cwd" in
        "$wt"|"$wt"/*) ;;
        *) continue ;;
      esac
      case " ${mine[*]} " in *" $pid "*) continue ;; esac
      printf '%s\n' "$pid"
    done
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  lsof -a -d cwd -u "$(id -u)" -Fpn 2>/dev/null | awk -v wt="$wt" '
    /^p/ { pid = substr($0, 2) }
    /^n/ { n = substr($0, 2); if (n == wt || index(n, wt "/") == 1) print pid }
  ' | while IFS= read -r pid; do
    case " ${mine[*]} " in *" $pid "*) continue ;; esac
    printf '%s\n' "$pid"
  done
}

# fm_backend_tmux_legacy_absence: the proof for a record written before spawn
# recorded its server identity. It cannot ask the endpoint's own server, so it
# proves the two things a surviving agent would need instead:
#   - no tmux server other than the one this process addresses (told apart by
#     its pid and start time, not its socket path) answers on any socket in
#     this user's tmux socket directory (${TMUX_TMPDIR:-/tmp}/tmux-UID), so the
#     window was not merely on a sibling server; and
#   - no live process has the recorded worktree as its working directory, so
#     no shell or agent of the task survives anywhere, even on a server started
#     on a socket outside that directory.
fm_backend_tmux_legacy_absence() {  # <target> <worktree>
  local wt=${2-} dir ambient f identity holders
  [ -n "$wt" ] && [ -d "$wt" ] || {
    printf 'unproven\tthe record carries no tmux server identity and no readable worktree to check for surviving processes'
    return 0
  }
  dir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
  ambient=$(fm_backend_tmux_server_identity) && ambient=${ambient#*$'\t'} || ambient=
  for f in "$dir"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if tmux -S "$f" list-sessions >/dev/null 2>&1; then
      if [ -n "$ambient" ] && identity=$(fm_backend_tmux_server_identity "$f") \
        && [ "${identity#*$'\t'}" = "$ambient" ]; then
        continue
      fi
      printf 'unproven\tthe record carries no tmux server identity, and another tmux server answers on %s, so the window may still be alive there' "$f"
      return 0
    fi
  done
  holders=$(fm_backend_tmux_worktree_holders "$wt") || {
    printf 'unproven\tthe record carries no tmux server identity, and which processes hold its worktree cannot be read here'
    return 0
  }
  if [ -n "$holders" ]; then
    printf 'unproven\tthe record carries no tmux server identity, and live process(es) %s still have its worktree %s as their working directory' "$(printf '%s' "$holders" | tr '\n' ' ' | sed 's/ $//')" "$wt"
    return 0
  fi
  printf 'gone\t'
}

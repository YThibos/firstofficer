#!/bin/bash
# Live drive: real tmux server (-L fmlive-bgjob), real bin/fm-watch.sh and
# bin/fm-supervise-daemon.sh housekeeping, and a real agent process whose
# executable is named "claude" that detaches a real background shell job.
set -u
ROOT=$1
. "$ROOT/tests/wake-helpers.sh"; . "$ROOT/bin/fm-classify-lib.sh"
eval "$(sed -n '/^ack_stopped_cycle()/,/^}/p;/^seen_sig()/,/^}/p;/^size_of()/p;/^record_pi_busy()/,/^}/p' "$ROOT/tests/fm-watch-triage.test.sh")"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
S=$(mktemp -d /tmp/fmlive.XXXX); export FM_HOME=$S/home; STATE=$FM_HOME/state
mkdir -p "$STATE" "$S/bin" "$S/wt/src" "$S/otherdir"
printf '#!/bin/sh\nexec /usr/bin/tmux -L fmlive-bgjob "$@"\n' > "$S/bin/tmux"; chmod +x "$S/bin/tmux"
ln -s /bin/bash "$S/bin/claude"      # the agent process: comm and argv0 are "claude"
cat > "$S/agent.sh" <<'SH'
cd "$1"
case "$3" in
  shell) perl -e 'use POSIX (); POSIX::setsid(); exec "bash", "-c", "sleep 900; true"' </dev/null >/dev/null 2>&1 & ;;
  nonshell) perl -e 'use POSIX (); POSIX::setsid(); exec "sleep", "900"' </dev/null >/dev/null 2>&1 & ;;
esac
echo $! > "$2"
printf '%s' "$4"; read -r _
SH
export PATH="$S/bin:$PATH"
log(){ echo "== $*"; }
agent(){ tmux new-window -d -t live -n "$1" "claude '$S/agent.sh' '$2' '$S/$1.pid' $3 '$4'"; sleep 1; cat "$S/$1.pid"; }
tmux new-session -d -s live -n boot 'sleep 3600'
W=live:fm-suite; KEY=live_fm-suite
JOB=$(agent fm-suite "$S/wt/src" shell '> ')
printf 'window=%s\nkind=ship\nharness=claude\nworktree=%s\n' "$W" "$S/wt" > "$STATE/suite.meta"
printf 'working: running the full suite\n' > "$STATE/suite.status"
printf '%s' "$(seen_sig "$STATE/suite.status")" > "$STATE/.seen-suite_status"
log "pane_current_command: $(tmux display -p -t $W '#{pane_current_command}')"
ps -o pid,ppid,pgid,tty,etime,comm,args -p "$(ps -o ppid= -p $JOB | tr -d ' ')","$JOB"
log "S4a own detached shell in worktree subdir: '$(crew_background_job_of suite "$STATE")' (want $JOB)"
printf 'window=live:fm-other\nkind=ship\nworktree=%s\n' "$S/otherdir" > "$STATE/other.meta"
log "S4b same job asked for a task whose worktree is another dir: '$(crew_background_job_of other "$STATE")' (want empty)"
H=$(agent fm-helper "$S/otherdir" nonshell '> ')
log "S4c detached non-shell helper ($H) under claude in that other task's worktree: '$(crew_background_job_of other "$STATE")' (want empty)"
tmux kill-window -t live:fm-helper; kill "$H" 2>/dev/null
( cd "$S/otherdir" && exec perl -e 'use POSIX (); POSIX::setsid(); exec "bash", "-c", "sleep 900"' ) </dev/null >/dev/null 2>&1 & NP=$!; sleep 0.5
log "S4d detached shell ($NP) in other task dir with non-harness parent: '$(crew_background_job_of other "$STATE")' (want empty)"; kill $NP
export FM_STATE_OVERRIDE=$STATE FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
runwatch(){ # <secs>; a restart after a killed watcher first delivers its recovery wake, acked and rerun
  local n; for n in 1 2 3; do runwatch1 "$1"; grep -qx 'check: rearm-resurface' "$S/out" 2>/dev/null || return 0; echo "   (acked startup recovery wake, rerunning)"; : > "$S/out"; done
}
runwatch1(){ # <secs>
  : > "$S/out"; "$ROOT/bin/fm-watch.sh" > "$S/out" 2>"$S/err" & local p=$! i=0
  while kill -0 $p 2>/dev/null && [ $i -lt $1 ]; do sleep 1; i=$((i+1)); done
  if kill -0 $p 2>/dev/null; then kill $p; wait $p 2>/dev/null; echo "   watcher alive after ${1}s: no wake"; else [ "$(cat $S/out)" = "check: rearm-resurface" ] || { echo "   watcher exited with wake:"; sed 's/^/   out: /' "$S/out"; }; ack_stopped_cycle "$STATE" >/dev/null 2>&1; fi
}
log "warm-up (startup recovery wake, first pane hash)"; runwatch 8; runwatch 8
log "S1 first stale sighting"; runwatch 10
log "   stale-since=$(cat $STATE/.stale-since-$KEY 2>/dev/null || echo none)"
B=$(( $(date +%s) - 500 )); echo $B > $STATE/.stale-since-$KEY; echo 2 > $STATE/.wedge-escalations-$KEY
log "S1 at threshold (idle 500s, 2 prior escalations)"; runwatch 10
log "   stale-since before=$B after=$(cat $STATE/.stale-since-$KEY); escalation row: $(cat $STATE/.wedge-escalations-$KEY 2>/dev/null || echo cleared)"
grep 'background job' $STATE/.watch-triage.log | sed 's/^/   triage: /'
log "S2 job $JOB ends, worker stays idle"; kill "$JOB"; sleep 1
echo $(( $(date +%s) - 500 )) > $STATE/.stale-since-$KEY; runwatch 20
log "S3 busy pane past turn bound with a live job"
tmux kill-window -t $W; JOB=$(agent fm-suite "$S/wt" shell 'Working...')
printf 'window=%s\nkind=ship\nharness=pi\nworktree=%s\n' "$W" "$S/wt" > "$STATE/suite.meta"
record_pi_busy "$STATE" suite >/dev/null; touch -t 200001010000 "$STATE/suite.meta"
log "   classifier sees job: '$(crew_background_job_of suite "$STATE")'"
runwatch 5; echo $(( $(date +%s) - 500 )) > $STATE/.stale-since-$KEY
FM_BUSY_TURN_MAX_SECS=1 runwatch 20
kill $JOB
log "S5 away-mode daemon housekeeping"
tmux kill-window -t $W; JOB=$(agent fm-suite "$S/wt" shell '> ')
printf 'window=%s\nkind=ship\nharness=claude\nworktree=%s\n' "$W" "$S/wt" > "$STATE/suite.meta"
( . "$ROOT/bin/fm-supervise-daemon.sh"
  M=$(( $(date +%s) - 500 )); echo $M > $STATE/.subsuper-stale-suite; rm -f $STATE/.subsuper-escalations
  housekeeping "$STATE" >/dev/null 2>&1
  echo "   with job: marker before=$M after=$(cat $STATE/.subsuper-stale-suite); escalations: $(cat $STATE/.subsuper-escalations 2>/dev/null || echo none)"
  kill "$JOB"; sleep 1; echo $(( $(date +%s) - 500 )) > $STATE/.subsuper-stale-suite
  housekeeping "$STATE" >/dev/null 2>&1
  echo "   job ended: escalations: $(cat $STATE/.subsuper-escalations 2>/dev/null || echo none)" )
tmux kill-server; rm -rf "$S"

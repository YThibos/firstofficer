#!/usr/bin/env bash
# Live driver: real fm-captain-hold.sh + tasks-axi + fm-captain-report.sh against a disposable lab FM_HOME.
set -u
WT=/home/thibyann001/.no-mistakes/worktrees/04c39aeaee8f/01M4X1Z6WV8PYR2861D4NHRTY7
EV=/home/thibyann001/.no-mistakes/evidence/01M4X1Z6WV8PYR2861D4NHRTY7
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
cp "$WT/.tasks.toml" "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE
export FM_HOME="$LAB"
NOW=2026-10-14T09:00:00Z
T() { (cd "$LAB" && tasks-axi "$@" >/dev/null); }
H() { FM_CAPTAIN_HOLD_NOW="${HNOW:-$NOW}" "$WT/bin/fm-captain-hold.sh" "$@"; }
R() { FM_SNAPSHOT_NOW="${SNOW:-$NOW}" "$WT/bin/fm-captain-report.sh" "$@"; }
card() { # path title projects context recommend
  jq -n --arg t "$2" --argjson p "$3" --arg c "$4" '{title:$t,projects:$p,
   options:[{key:"A",text:"Restart now, one at a time, watching the first for ten minutes before the next"},
            {key:"B",text:"Wait until tomorrow morning so the captain can watch"},
            {key:"C",text:"Drop the work and file a fresh task"}],
   recommend:{key:"A",why:"it keeps the work moving and nothing is lost"}} + (if $c=="" then {} else {context:$c} end)' > "$1"; }
holdc() { card "$LAB/$1.json" "$2" "$3" "${4:-}"; H hold "$1" --title "Call $1" --reason "captain call pending" --repo sample --decision-card "$LAB/$1.json" "${@:5}"; }
sec() { printf '\n===== %s =====\n' "$*"; }
{
sec "S1: hold four carded calls across projects (real fm-captain-hold.sh)"
holdc restart-call "Restart the stopped workers" '["JustMasterData"]' "Both stopped mid-task; nothing is lost."
holdc merge-call "Merge the green pull request" '["firstofficer"]'
holdc shared-call "Share one sign-in setup across both apps" '["JustMasterData","JustAuth"]'
holdc book-call "Book the research minutes" '["JustMasterData"]'
T add backfill "SHIP JustMasterData: finish the backfill" --repo JustMasterData --start
T add relaunch-fix "Relaunch fix" --repo firstofficer --start
T add q1 "Queued idea one" --repo firstofficer
cat > "$LAB/turn.json" <<'J'
{"done": [{"projects": [], "text": "Took over monitoring for this session"},
          {"projects": ["firstofficer"], "text": "Report-format investigation finished, see https://github.com/YThibos/firstofficer/pull/31"}],
 "next": [{"projects": ["JustMasterData"], "text": "Start the recovery workers one at a time"}],
 "tasks": {"backfill": {"text": "Finish the decision-log backfill", "state": "running"},
           "relaunch-fix": {"text": "Fix the relaunch of a stopped worker", "state": "running"}}}
J
sec "S1 report at default width (no --width, outside tmux)"
R --turn "$LAB/turn.json" > "$EV/report-busy-120.txt"; echo "exit=$?"
cat "$EV/report-busy-120.txt"
echo "max line width (chars): $(awk '{ if (length($0)>m) m=length($0) } END{print m}' "$EV/report-busy-120.txt")"

sec "S2: answer D1 (restart-call) -> leaves the box; others keep numbers"
echo "Captain said: A" > "$LAB/ans.txt"
H answer restart-call --decision-file "$LAB/ans.txt"
R --turn "$LAB/turn.json" | sed -n '1,/^DONE THIS TURN/p' | grep -E 'NEEDS|D[0-9]+ ' 
sec "S2b: new hold after answering -> gets next number, not D1 reused"
holdc new-call "A brand new call" '["JustAuth"]'
sec "S2c: lose the counter file (new session / lost state) -> still no reuse"
cat "$LAB/data/decision-seq"; rm -f "$LAB/data/decision-seq"
holdc newer-call "Another new call after the counter was lost" '["JustAuth"]'
R | grep -E 'NEEDS|  D[0-9]+ '

sec "S3: aged call (snapshot 40 days later) stays in NEEDS YOUR DECISION"
SNOW=2026-11-23T09:00:00Z R | grep -E 'NEEDS|  D[0-9]+ |PARKED'

sec "S4: dated and blocked carded holds render in PARKED with D number and reason"
holdc dated-call "A deferred call" '["JustAuth"]' "" --until 2026-10-30
T add prereq "Prerequisite work" --repo JustAuth
holdc blocked-call "A blocked call" '["JustAuth"]'
T block blocked-call --by prereq
R > "$EV/report-parked.txt"; sed -n '/^PARKED/,$p' "$EV/report-parked.txt"
echo "--- is any dated/blocked call in the decision box?"; sed -n '1,/^DONE/p' "$EV/report-parked.txt" | grep -E 'deferred|blocked' || echo "no (correct)"

sec "S5: release then non-captain hold -> retired number never shown in PARKED"
H answer merge-call --decision-file "$LAB/ans.txt" --release
T hold merge-call --reason "waiting on infra"
R | sed -n '/^PARKED/,$p'

sec "S6: adversarial turn file input"
echo '{"done":[{"projects":[],"text":"Shipped 🚀"}]}' > "$LAB/bad1.json"; R --turn "$LAB/bad1.json"; echo "exit=$?"
echo '{"done":[],"decisions":[]}' > "$LAB/bad2.json"; R --turn "$LAB/bad2.json"; echo "exit=$?"
echo '{"tasks":{"shared-call":{"text":"Reworded by firstmate"}}}' > "$LAB/t3.json"
echo "--- turn rewording a decision's task cannot remove it:"; R --turn "$LAB/t3.json" | grep -E 'NEEDS|  D[0-9]+ '
R --width 40; echo "exit=$?"

sec "S7: BACKLOG appears only when nothing open and nothing ongoing"
echo "with open+ongoing: $(R | grep -c '^BACKLOG' ) BACKLOG headings"
for id in shared-call book-call new-call newer-call; do H answer $id --decision-file "$LAB/ans.txt" >/dev/null; done
for id in backfill relaunch-fix; do T done $id; done
R > "$EV/report-quiet.txt"; cat "$EV/report-quiet.txt"
} 2>&1
echo "LAB=$LAB"

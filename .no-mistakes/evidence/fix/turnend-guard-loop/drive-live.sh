#!/usr/bin/env bash
# Live driver: real bin/ scripts in a scratch FM_HOME, real stand-in processes as lock holders.
set -u
SRC=$1; BASE=$2
S=$(mktemp -d /tmp/fm-live.XXXXXX); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$S"' EXIT
export CLAUDE_CONFIG_DIR="$S/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
FB="$S/fb"; mkdir -p "$FB"; ln -s /bin/bash "$FB/2.1.235"
mkhome() { # dir rev
  mkdir -p "$1"; git -C "$SRC" archive "$2" bin docs AGENTS.md | tar -x -C "$1"
  git init -q "$1"; git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  mkdir -p "$1/state"; for i in 1 2 3 4 5; do : > "$1/state/task$i.meta"; done; }
record() { printf '{"pid":%s,"sessionId":"0c003a9b-98bb-4b07-88b4-18bfd530c9db","procStart":"%s"%s}\n' "$1" "$(awk '{print $22}' /proc/$1/stat)" "$2" > "$CLAUDE_CONFIG_DIR/sessions/$1.json"; }
holder() { bash -c 'exec -a "claude bg-spare --bg-spare /tmp/x/claim.sock" "$0" -c "sleep 900; true"' "$FB/2.1.235" & HP=$!; sleep 0.3; }
stop() { # home mode session
  local m=; [ "$2" = claude ] && m=--claude
  printf '{"stop_hook_active":true,"session_id":"%s"}' "$3" | env -u TMUX -u TMUX_PANE CLAUDECODE=1 FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 FM_HOME="$1" bash "$1/bin/fm-turnend-guard.sh" $m 2>&1; }
summ() { printf '%s' "$1" | head -c 110 | tr '\n' ' '; }

echo "=== S1: read-only session, fleet lock held by another LIVE real session (record without spare) ==="
for rev in "$BASE" HEAD; do
  H="$S/h1-$rev"; mkhome "$H" "$rev"; holder; record $HP ',"kind":"interactive"'; echo $HP > "$H/state/.lock"
  echo "-- bin/ at ${rev:0:7}; lock holder pid $HP; fm-lock.sh status: $(FM_HOME=$H bash $H/bin/fm-lock.sh status 2>&1 | head -1)"
  for mode in claude default; do for i in 1 2 3 4 5 6 7 8 9 10; do
    out=$(stop "$H" $mode s1-$mode); rc=$?; echo "   $mode stop $i: exit=$rc $(summ "$out")"; done; done
  kill $HP; done

echo; echo "=== S2: frozen/reset epoch vs hard cap (lock free, unhealthy, --claude) ==="
H="$S/h2"; mkhome "$H" HEAD
for i in 1 2 3 4 5 6 7 8; do
  rm -f "$H/state/.turnend-claude-blocks"
  [ $((i%2)) = 0 ] && o=failed || o=clean
  printf 'epoch=%s owner_pid=999 outcome=%s updated_at=1\n' $((100+i)) $o > "$H/state/.claude-autoarm-epoch"; touch -t 202001010000 "$H/state/.claude-autoarm-epoch"
  out=$(stop "$H" claude s2); echo "   stop $i (epoch reset, budget ledger wiped): exit=$? $(summ "$out")"; done
echo "   hard-cap file: $(tr '\n' ' ' < $H/state/.turnend-claude-hard-cap)"
rm -f $H/state/*.meta; out=$(stop "$H" claude s2); echo "   supervision idle -> exit=$? cap file present: $([ -e $H/state/.turnend-claude-hard-cap ] && echo yes || echo no)"

echo; echo "=== S3: unclaimed bg-spare standby as lock holder ==="
H="$S/h3"; mkhome "$H" HEAD; holder; record $HP ',"kind":"bg","spare":true'; echo $HP > "$H/state/.lock"
echo "   fm-lock.sh status: $(FM_HOME=$H bash $H/bin/fm-lock.sh status 2>&1 | head -1)"
out=$(stop "$H" claude s3); echo "   Stop in a session not holding lock: exit=$? (guard still applies; lock is reclaimable) $(summ "$out")"
echo "   standby tries to claim a free lock:"; rm -f $H/state/.lock
out=$(bash -c 'exec -a "claude bg-spare" "$0" -c "$1"' "$FB/2.1.235" 'awk "{print \$22}" /proc/$$/stat >/dev/null; printf "{\"pid\":%s,\"sessionId\":\"0c003a9b-98bb-4b07-88b4-18bfd530c9db\",\"procStart\":\"%s\",\"spare\":true}\n" $$ $(awk "{print \$22}" /proc/$$/stat) > $CLAUDE_CONFIG_DIR/sessions/$$.json; FM_HOME='"$H"' bash '"$H"'/bin/fm-lock.sh; echo rc=$?' 2>&1); echo "   $out | lock file: $(cat $H/state/.lock 2>/dev/null || echo absent)"
echo $HP > "$H/state/.lock"

echo; echo "=== S4 (reboot approximation): primary claude-ancestry session starts while bg-spare holds lock ==="
out=$(bash -c 'exec -a "claude" "$0" -c "$1"' "$FB/2.1.235" 'printf "{\"pid\":%s,\"sessionId\":\"9b1f7c52-3a44-4c8e-9d61-2f0e5b7a8c13\",\"procStart\":\"%s\",\"kind\":\"interactive\"}\n" $$ $(awk "{print \$22}" /proc/$$/stat) > $CLAUDE_CONFIG_DIR/sessions/$$.json; FM_HOME='"$H"' bash '"$H"'/bin/fm-lock.sh; echo "rc=$? me=$$"' 2>&1)
echo "   session start fm-lock.sh: $(echo $out | tr '\n' ' ') | lock now: $(cat $H/state/.lock) (standby was $HP)"
kill $HP

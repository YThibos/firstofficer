#!/usr/bin/env bash
# Live driver: real bin/ scripts, scratch FM_HOME and CLAUDE_CONFIG_DIR, real stand-in processes.
set -u
ROOT=$1; T=$(mktemp -d /tmp/fm-live.XXXXXX); export CLAUDE_CONFIG_DIR=$T/cfg; mkdir -p $CLAUDE_CONFIG_DIR/sessions
LIB=$ROOT/bin/fm-session-lock-lib.sh
echo "scratch=$T (live home untouched)"
newhome(){ local h=$T/$1; mkdir -p $h/state $h/config; git init -q $h; git -C $h -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; : > $h/AGENTS.md; cp -R $ROOT/bin $ROOT/docs $h/; for i in 1 2 3 4 5; do : > $h/state/task$i.meta; done; echo $h; }
# holder <spare-json> : live claude-named process with a trusted per-pid record
holder(){ bash -c '. "$1"; st=$(fm_proc_stat_field $$ 19); printf "{\"pid\":%s,\"sessionId\":\"0c003a9b-98bb-4b07-88b4-18bfd530c9db\",\"procStart\":\"%s\",\"kind\":\"bg\"%s}\n" $$ "$st" "$3" > "$2/sessions/$$.json"; exec -a claude sleep 300' _ "$LIB" "$CLAUDE_CONFIG_DIR" "$1" >/dev/null 2>&1 & local p=$!; while [ ! -f $CLAUDE_CONFIG_DIR/sessions/$p.json ]; do sleep 0.02; done; echo $p; }
stop(){ printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":%s}' "$1" "${2:-false}"; }
g(){ local h=$1 sid=$2; shift 2; stop $sid | (cd $h && CLAUDECODE=1 FM_HOME=$h FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 "$h/bin/fm-turnend-guard.sh" "$@") >$T/out 2>&1; local rc=$?; echo "rc=$rc $(head -c 160 $T/out | tr '\n' ' ')"; }

echo "=== S1: lock held by another live session -> never blocked"
H=$(newhome s1); P=$(holder ''); echo $P > $H/state/.lock
FM_HOME=$H $ROOT/bin/fm-lock.sh status
for m in --claude ''; do for i in $(seq 1 10); do echo "mode=${m:-default} stop#$i $(g $H ro-sess $m)"; done; done
kill $P

echo "=== S2: hard cap vs frozen/reset epoch (reclaimable lock -> guarded)"
H=$(newhome s2); echo 999999 > $H/state/.lock; printf 'epoch=7 outcome=failed x\n' > $H/state/.claude-autoarm-epoch
for i in 1 2 3 4 5 6; do [ $i -eq 4 ] && { rm -f $H/state/.turnend-claude-blocks; echo "(reset epoch budget file)"; }; echo "stop#$i $(g $H capsess --claude)"; echo "  cap: $(tr "\n" " " < $H/state/.turnend-claude-hard-cap 2>/dev/null)"; done
echo "-- supervision healthy (no in-flight tasks):"; rm -f $H/state/task*.meta; echo "stop $(g $H capsess --claude)"; echo "  cap file exists? $([ -e $H/state/.turnend-claude-hard-cap ] && echo yes || echo no)"
for i in 1 2; do : > $H/state/task$i.meta; done; echo "after re-break: stop $(g $H capsess --claude)"

echo "=== S3: unclaimed spare holds lock; real session claims via fm-lock.sh; guard at Stop"
H=$(newhome s3); S=$(holder ',"spare":true'); echo $S > $H/state/.lock
FM_HOME=$H $ROOT/bin/fm-lock.sh status
echo "guard stop (spare holder must not make it stand down): $(g $H s3 --claude)"
echo "-- spare tries to claim a free lock:"; rm $H/state/.lock
bash -c '. "$1"; st=$(fm_proc_stat_field $$ 19); printf "{\"pid\":%s,\"sessionId\":\"1c003a9b-98bb-4b07-88b4-18bfd530c9db\",\"procStart\":\"%s\",\"spare\":true}\n" $$ "$st" > "$2/sessions/$$.json"; FM_HOME=$3 exec -a claude bash -c "\"$4/bin/fm-lock.sh\"; echo rc=\$?; cat $3/state/.lock 2>/dev/null || echo no-lock-file"' _ "$LIB" "$CLAUDE_CONFIG_DIR" $H $ROOT
echo $S > $H/state/.lock
echo "-- real session claims:"
bash -c '. "$1"; st=$(fm_proc_stat_field $$ 19); printf "{\"pid\":%s,\"sessionId\":\"9b1f7c52-3a44-4c8e-9d61-2f0e5b7a8c13\",\"procStart\":\"%s\",\"kind\":\"interactive\"}\n" $$ "$st" > "$2/sessions/$$.json"; echo "real pid=$$"; FM_HOME=$3 exec -a claude bash -c "\"$4/bin/fm-lock.sh\"; echo rc=\$?; echo holder=\$(cat $3/state/.lock); \"$4/bin/fm-lock.sh\" status"' _ "$LIB" "$CLAUDE_CONFIG_DIR" $H $ROOT
kill $S

echo "=== S4 (approximation, no reboot): running bg-spare-shaped holder, primary session start claims"
H=$(newhome s4); S=$(bash -c '. "$1"; st=$(fm_proc_stat_field $$ 19); printf "{\"pid\":%s,\"sessionId\":\"2c003a9b-98bb-4b07-88b4-18bfd530c9db\",\"procStart\":\"%s\",\"kind\":\"bg\",\"spare\":true}\n" $$ "$st" > "$2/sessions/$$.json"; exec -a "claude bg-spare --bg-spare /tmp/claim.sock" sleep 300' _ "$LIB" "$CLAUDE_CONFIG_DIR" >/dev/null 2>&1 & p=$!; while [ ! -f $CLAUDE_CONFIG_DIR/sessions/$p.json ]; do sleep 0.02; done; echo $p)
ps -o pid,args -p $S; echo $S > $H/state/.lock; FM_HOME=$H $ROOT/bin/fm-lock.sh status
bash -c '. "$1"; st=$(fm_proc_stat_field $$ 19); printf "{\"pid\":%s,\"sessionId\":\"3b1f7c52-3a44-4c8e-9d61-2f0e5b7a8c13\",\"procStart\":\"%s\",\"kind\":\"interactive\"}\n" $$ "$st" > "$2/sessions/$$.json"; echo "primary pid=$$"; FM_HOME=$3 exec -a claude bash -c "\"$4/bin/fm-lock.sh\"; echo claim-rc=\$?; echo holder=\$(cat $3/state/.lock); for i in 1 2 3 4 5 6; do printf %s \"{\\\"session_id\\\":\\\"primary\\\",\\\"hook_event_name\\\":\\\"Stop\\\"}\" | CLAUDECODE=1 FM_HOME=$3 FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \"$3/bin/fm-turnend-guard.sh\" --claude >/dev/null 2>&1; echo stop#\$i rc=\$?; done"' _ "$LIB" "$CLAUDE_CONFIG_DIR" $H $ROOT
kill $S; rm -rf $T

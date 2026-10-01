#!/usr/bin/env bash
# Live, read-only poll of real forge URLs in a disposable firstofficer home.
# Usage: live-poll.sh <code-root> <label>
set -u
CODE=$1; LABEL=$2
home=$(mktemp -d /tmp/fm-live-XXXXXX)
mkdir -p "$home/data" "$home/state" "$home/config" "$home/fakebin" "$home/root/bin"
printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
chmod +x "$home/fakebin/"* "$home/root/bin/fm-guard.sh"
G=https://git.intra.just.fgov.be/celbig/justmasterdata/-/merge_requests
{
  printf '# Backlog\n\n## Queued\n'
  printf -- '- [ ] openmr - Filed %s/77 (repo: sample) (kind: ship)\n' "$G"
  printf -- '- [ ] mergedmr - Filed %s/76 (repo: sample) (kind: ship)\n' "$G"
  printf -- '- [ ] missingmr - Filed %s/999999 (repo: sample) (kind: ship)\n' "$G"
  printf -- '- [ ] ghmissing - Filed https://github.com/YThibos/firstofficer/pull/999999 (repo: sample) (kind: ship)\n'
} > "$home/data/backlog.md"
run() {
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_CONTRIBUTIONS_BUDGET=25 "$@"
}
echo "### $LABEL ($CODE)"
for i in 1 2 3; do
  echo "--- poll $i stdout:"
  run "$CODE/bin/fm-contributions.sh" poll; echo "(rc=$?)"
done
echo "--- durable records after 3 polls:"
for t in openmr mergedmr missingmr ghmissing; do
  f=$home/data/$t/contributions.json
  [ -f "$f" ] && jq -c '.records[] | {url,checked_at,error,state:.observation.state,head:.observation.head,checks:[.observation.checks[]?|{name,conclusion}],review_decision:.observation.review_decision,pending:(.pending|length)}' "$f" || echo "$t: no record"
done
echo "--- bearings contribution coverage:"
run env FM_BEARINGS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CODE/bin/fm-bearings-snapshot.sh" --json | jq '.contributions | del(.valid_until)'
echo "--- per-URL actor (snapshot --all):"
run "$CODE/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" 2>/dev/null \
  && FM_CONTRIBUTIONS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)" run "$CODE/bin/fm-contributions.sh" snapshot "$home/input.json" --all | jq -c '.rows[] | {url,actor,reason}'
rm -rf "$home"

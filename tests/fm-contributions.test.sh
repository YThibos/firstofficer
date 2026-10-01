#!/usr/bin/env bash
# Published-contribution behavior through Bearings and the authenticated checks.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-contributions)
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  chmod +x "$home/fakebin/"*
  printf '%s\n' "$home"
}

bearings() {
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" \
    FM_BEARINGS_NOW="$NOW" "$ROOT/bin/fm-bearings-snapshot.sh" --json
}

record() { # home id number forge-state mergeability [hold]
  local home=$1 id=$2 number=$3 state=$4 mergeable=$5 hold=${6:-}
  mkdir -p "$home/data/$id"
  printf -- '- [ ] %s - Contribution %s https://github.com/o/r/pull/%s (repo: sample) (kind: ship) %s\n' \
    "$id" "$id" "$number" "$hold" >> "$home/data/backlog.md"
  jq -n --arg task "$id" --arg url "https://github.com/o/r/pull/$number" \
    --arg head "$HEAD_A" --arg at "$NOW" --arg state "$state" --arg mergeable "$mergeable" '
    {schema:"fm-contributions.v1",task:$task,records:[{
      url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
      observation:{head:$head,state:$state,draft:false,mergeable:$mergeable,
        review_decision:"APPROVED",can_merge:false,
        checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],
        reviews:[],events:[]}}]}' > "$home/data/$id/contributions.json"
}

mutate_record() {
  jq "$3" "$1/data/$2/contributions.json" > "$1/update.json" || fail 'fixture mutation failed'
  mv "$1/update.json" "$1/data/$2/contributions.json"
}

test_actor_coverage() {
  local home out
  home=$(new_home actors)
  record "$home" own 1 open mergeable '(hold: choose scope) (hold-kind: captain)'
  record "$home" repair 2 open conflicting
  record "$home" external 3 open mergeable
  record "$home" landed 4 merged mergeable
  out=$(bearings "$home") || fail 'Bearings could not read contribution fixture'
  printf '%s' "$out" | jq -e '
    .contributions.known == 4 and .contributions.checked == 4
    and .contributions.counts == {captain:1,fleet:1,maintainer:1,nobody:1}
    and (.contributions.captain | length) == 1
    and .contributions.captain[0].url == "https://github.com/o/r/pull/1"
    and .contributions.complete == true and .contributions.proven_clear == false' >/dev/null \
    || fail "published deliveries must report actors and measured coverage: $out"
  pass 'only required-captain contributions are rows; other actors are counted'
}

test_stale_verdict() {
  local home out
  home=$(new_home stale)
  record "$home" changed 5 open mergeable
  mutate_record "$home" changed ".records[0].verdict = {head:\"$HEAD_B\",actor:\"captain\",source:\"https://github.com/o/r/pull/5#issuecomment-8\",summary:\"choose contract\"}"
  out=$(bearings "$home") || fail 'Bearings could not read stale verdict fixture'
  printf '%s' "$out" | jq -e '
    .contributions.stale_verdicts == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 1' >/dev/null \
    || fail "a verdict on a replaced head must be STALE, not current captain work: $out"
  pass 'replaced-head verdict is stale and cannot create a captain requirement'
}

test_unchecked_is_not_silence() {
  local home out
  home=$(new_home unchecked)
  printf -- '- [ ] unseen - Unchecked https://github.com/o/r/pull/6 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  out=$(bearings "$home") || fail 'Bearings could not read unchecked fixture'
  printf '%s' "$out" | jq -e '
    .contributions.known == 1 and .contributions.checked == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail "no observation must not become a proven empty actionable set: $out"
  pass 'unchecked ownership is disclosed and cannot prove silence'
}

test_newest_check_has_no_verdict() {
  local home out
  home=$(new_home no-verdict)
  record "$home" missing 7 open mergeable
  mutate_record "$home" missing '.records[0].observation.checks += [{name:"test",id:2,status:"completed",conclusion:null,started_at:"2026-09-16T08:00:01Z"}]'
  out=$(bearings "$home") || fail 'Bearings could not read missing verdict fixture'
  printf '%s' "$out" | jq -e '
    .contributions.missing_verdicts == 1 and .contributions.counts.fleet == 1
    and .contributions.counts.maintainer == 0' >/dev/null \
    || fail "newest distinct check must not inherit an earlier success: $out"
  pass 'newest check with no verdict is distinct from passing and pending'
}


forge_home() {
  local home=$1
  mkdir -p "$home/forge" "$home/root/bin" "$home/wt"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  chmod +x "$home/root/bin/fm-guard.sh"
  printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"
  chmod 600 "$home/state/delivery.meta"
  record "$home" delivery 8 open mergeable
  printf '%s\n' "$HEAD_A" > "$home/forge/head"
  printf '[]\n' > "$home/forge/comments.json"
  printf '[]\n' > "$home/forge/reviews.json"
  printf '[]\n' > "$home/forge/inline.json"
  printf '[]\n' > "$home/forge/labels.json"
  printf '[]\n' > "$home/forge/events.json"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  'pr view '*headRefOid,reviewDecision*)
    jq -n --arg head "$(cat "$FORGE/head")" '{headRefOid:$head,reviewDecision:"APPROVED"}' ;;
  'pr view '*headRefOid*) cat "$FORGE/head" ;;
  'pr view '*state*) printf 'OPEN\n' ;;
  'api repos/o/r/pulls/8')
    jq -n --arg head "$(cat "$FORGE/head")" '{state:"open",user:{login:"author"},head:{sha:$head},draft:false,mergeable:true,merged_at:null}' ;;
  'api repos/o/r/issues/9')
    jq -n --slurpfile labels "$FORGE/labels.json" '{state:"open",user:{login:"author"},labels:$labels[0]}' ;;
  'api repos/o/r/issues/'*'/events?'*) jq -s . "$FORGE/events.json" ;;
  'api repos/o/r/issues/'*'/comments?'*) jq -s . "$FORGE/comments.json" ;;
  'api repos/o/r/pulls/8/reviews?'*) jq -s . "$FORGE/reviews.json" ;;
  'api repos/o/r/pulls/8/comments?'*) jq -s . "$FORGE/inline.json" ;;
  'api repos/o/r/commits/'*'/check-runs?'*)
    printf '[{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}]\n' ;;
  'api repos/o/r/commits/'*'/statuses?'*) printf '[[]]\n' ;;
  'api repos/o/r') printf '{"permissions":{"push":false}}\n' ;;
  *) printf 'unexpected gh fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/gh"
}

with_home() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" HEAD_A="$HEAD_A" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW="$NOW" "$@"
}

registered_checks() {
  local home=$1 check
  for check in "$home/state/"*.check.sh; do
    [ -f "$check" ] || continue
    with_home "$home" bash "$check" || fail 'registered check failed'
  done
}

test_incoming_signal() { # comment|review|inline
  local type=$1 home out count fixture wake_count
  case "$type" in comment) fixture=comments ;; review) fixture=reviews ;; *) fixture=inline ;; esac
  home=$(new_home "incoming-$type")
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  registered_checks "$home" >/dev/null
  jq -n --arg head "$HEAD_A" --arg type "$type" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}
    + (if $type == "comment" then {} else {commit_id:$head,state:"CHANGES_REQUESTED"} end)]' \
    > "$home/forge/$fixture.json"
  registered_checks "$home" >/dev/null
  jq -e '.records[0].pending | length == 1' "$home/data/delivery/contributions.json" >/dev/null \
    || fail "new maintainer $type must survive as a pending outward signal"
  [ -s "$home/state/.wake-queue" ] || fail "new maintainer $type must enqueue an ordinary durable wake"
  count=$(wc -l < "$home/state/.wake-queue")
  wake_count=$(awk 'END { print NR }' "$home/state/.wake-queue")
  [ "$wake_count" = 1 ] || fail "new maintainer $type must enqueue exactly one ordinary durable wake"
  registered_checks "$home" >/dev/null
  [ "$(wc -l < "$home/state/.wake-queue")" = "$count" ] || fail 're-poll duplicated an already enqueued event'
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = "$wake_count" ] || fail 're-poll duplicated an already enqueued event'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending)
  printf '%s' "$out" | jq -e 'length == 1 and .[0].author == "maintainer"' >/dev/null \
    || fail 'supervisor cannot retrieve captured signal'
  pass "new maintainer $type wakes once and stays pending until acknowledged"
}

test_ready_issue_wake() {
  local home count
  home=$(new_home ready)
  forge_home "$home"
  printf -- '- [ ] filed - Measured defect https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery'
  registered_checks "$home" >/dev/null
  printf '[{"name":"ready-for-pr"}]\n' > "$home/forge/labels.json"
  registered_checks "$home" >/dev/null
  if [ ! -f "$home/data/filed/contributions.json" ] \
    || ! jq -e 'any(.records[].pending[]; .type == "ready-for-pr")' "$home/data/filed/contributions.json" >/dev/null; then
    fail 'ready-for-pr on an explicitly filed issue must become a planning wake'
  fi
  [ -s "$home/state/.wake-queue" ] || fail 'ready-for-pr signal never reached the durable wake path'
  count=$(awk 'END { print NR }' "$home/state/.wake-queue")
  [ "$count" = 1 ] || fail 'ready-for-pr signal must enqueue exactly one durable wake'
  registered_checks "$home" >/dev/null
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = "$count" ] || fail 're-poll duplicated an already enqueued ready-for-pr wake'
  pass 'ready-for-pr on a filed issue becomes a planning wake'
}

test_fresh_issue_requires_maintainer() {
  local home
  home=$(new_home fresh-issue)
  forge_home "$home"
  printf -- '- [ ] filed - Measured defect https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'could not observe filed issue'
  bearings "$home" | jq -e '.contributions.known == 2 and .contributions.checked == 2
    and .contributions.counts.maintainer == 2 and .contributions.counts.fleet == 0
    and .contributions.complete == true and .contributions.proven_clear == true' >/dev/null \
    || fail 'a fresh open issue did not remain measured maintainer triage'
  pass 'a fresh open issue remains measured maintainer triage'
}

test_comment_wake() { test_incoming_signal comment; }
test_review_wake() { test_incoming_signal review; }
test_inline_wake() { test_incoming_signal inline; }

test_missing_lane_remains_missing() {
  local home
  home=$(new_home absent-lane)
  forge_home "$home"
  mutate_record "$home" delivery '.records[0].observation.checks += [{name:"required-extra",id:2,status:"completed",conclusion:"success",started_at:"2026-09-16T07:59:00Z"}]'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'first poll failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'second poll failed'
  bearings "$home" | jq -e '.contributions.missing_verdicts == 1 and .contributions.counts.fleet == 1' >/dev/null \
    || fail 'repeated polling erased the absent lane from measured readiness'
  pass 'an absent check lane remains missing across repeated observations'
}

test_partial_freshness_keeps_measured_rows() {
  local home
  home=$(new_home mixed-age)
  record "$home" current 10 open mergeable '(hold: choose scope) (hold-kind: captain)'
  record "$home" expired 11 open mergeable
  mutate_record "$home" expired '.records[0].checked_at="2026-09-15T08:00:00Z"'
  bearings "$home" | jq -e '.contributions.known == 2 and .contributions.checked == 1
    and .contributions.counts.captain == 1 and (.contributions.captain | length) == 1
    and .contributions.proven_clear == false' >/dev/null \
    || fail 'one expired observation erased the independently measured captain row'
  pass 'mixed freshness retains measured captain work and discloses the gap'
}

test_malformed_record_cannot_prove_silence() {
  local home
  home=$(new_home malformed)
  record "$home" invalid 12 open mergeable
  mutate_record "$home" invalid '.records[0].observation.state="not-a-forge-state"'
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'malformed durable evidence was counted as checked'
  pass 'malformed durable evidence cannot prove silence'
}

test_issue_timeline_and_exact_ack() {
  local home token
  home=$(new_home issue-timeline)
  forge_home "$home"
  printf -- '- [ ] filed - Filed https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'initial poll failed'
  printf '[{"event":"labeled","id":88,"label":{"name":"ready-for-pr"}}]\n' > "$home/forge/events.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'timeline poll failed'
  token=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -er '.[] | select(.type=="ready-for-pr") | .token') \
    || fail 'add/remove between polls lost ready-for-pr transition'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack filed https://github.com/o/r/issues/9 "$token" || fail 'exact ack failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'post-ack poll failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null || fail 'acknowledged timeline event replayed'
  pass 'a transient ready-for-pr label wakes and its exact acknowledgement survives replay'
}

test_verdict_retains_judged_head() {
  local home
  home=$(new_home verdict-roundtrip)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery before judging its head'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_A" \
    https://github.com/o/r/pull/8#issuecomment-99 maintainer 'awaiting maintainer' || fail 'could not record judged head'
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  registered_checks "$home" >/dev/null
  printf 'pr=https://github.com/o/r/pull/8\npr_head=%s\n' "$HEAD_B" >> "$home/state/delivery.meta"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  bearings "$home" | jq -e '.contributions.stale_verdicts == 1 and .contributions.checked == 0' >/dev/null \
    || fail 'changed published head reused a current verdict'
  jq -e --arg head "$HEAD_A" '.records[0].verdict.head==$head' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'projection rewrote the judged head'
  pass 'recorded judgment keeps its exact head and is stale immediately on a published replacement'
}

test_observed_replacement_refreshes_verdict() {
  local home
  home=$(new_home observed-replacement)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery before replacement'
  registered_checks "$home" >/dev/null
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  registered_checks "$home" >/dev/null
  with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_B" \
    https://github.com/o/r/pull/8#issuecomment-100 maintainer 'awaiting maintainer' \
    || fail 'could not record verdict on the observed replacement'
  bearings "$home" | jq -e '.contributions.checked == 1 and .contributions.stale_verdicts == 0
    and .contributions.counts.maintainer == 1 and .contributions.counts.fleet == 0' >/dev/null \
    || fail 'a current forge observation did not refresh a verdict on its observed head'
  pass 'a current forge observation refreshes a verdict after a replacement'
}

test_unobserved_head_leaves_verdict_unknown() {
  local home out
  home=$(new_home unobserved-head)
  record "$home" delivery 17 open mergeable
  mutate_record "$home" delivery ".records[0].error=\"forge unavailable\" | .records[0].verdict={head:\"$HEAD_B\",actor:\"maintainer\",source:\"https://github.com/o/r/pull/17#issuecomment-101\",summary:\"awaiting maintainer\"}"
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" \
    || fail 'could not collect contribution input without a forge read'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) \
    || fail 'could not project unavailable forge observation'
  printf '%s' "$out" | jq -e '.stale_verdicts == 0 and .checked == 0
    and .rows[0].verdict.freshness == "unverified"' >/dev/null \
    || fail 'an unavailable current head became a fresh or stale verdict'
  pass 'an unavailable current head leaves verdict freshness unknown'
}

test_away_yolo_is_fleet_work() {
  local home out
  home=$(new_home away-yolo)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register away delivery'
  printf 'yolo=on\n' >> "$home/state/delivery.meta"
  with_home "$home" "$ROOT/bin/fm-afk-contract.sh" propose --grant delivery >/dev/null \
    || fail 'could not propose away posture'
  with_home "$home" "$ROOT/bin/fm-afk-contract.sh" confirm >/dev/null \
    || fail 'could not confirm away posture'
  mutate_record "$home" delivery '.records[0].observation.can_merge=true'
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" \
    || fail 'could not collect contribution input for away posture'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) \
    || fail 'could not project away delivery'
  printf '%s' "$out" | jq -e '.checked == 1 and .counts.captain == 0 and .counts.fleet == 1' >/dev/null \
    || fail 'away yolo delivery requiring a merge remained captain work'
  pass 'away yolo delivery is fleet work without granting merge authority'
}

test_away_yolo_cross_home_is_fleet_work() {
  local home child
  home=$(new_home away-yolo-parent)
  child=$(new_home away-yolo-child)
  mkdir -p "$child/bin"
  printf '# Fixture\n' > "$child/AGENTS.md"
  printf 'child\n' > "$child/.fm-secondmate-home"
  forge_home "$child"
  with_home "$child" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register child away delivery'
  printf 'yolo=on\n' >> "$child/state/delivery.meta"
  with_home "$child" "$ROOT/bin/fm-afk-contract.sh" propose --grant delivery >/dev/null \
    || fail 'could not propose child away posture'
  with_home "$child" "$ROOT/bin/fm-afk-contract.sh" confirm >/dev/null \
    || fail 'could not confirm child away posture'
  mutate_record "$child" delivery '.records[0].observation.can_merge=true'
  FM_SNAPSHOT_NOW="$NOW" with_home "$child" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$child/state/home-summary.json" \
    || fail 'could not collect child contribution summary'
  printf -- '- child - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-16)\n' "$child" > "$home/data/secondmates.md"
  bearings "$home" | jq -e '.contributions.checked == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 1' >/dev/null \
    || fail 'cross-home away yolo delivery requiring a merge remained captain work'
  pass 'cross-home away yolo delivery is fleet work'
}

test_retired_and_unsupported_coverage() {
  local home
  home=$(new_home retained)
  record "$home" retained 14 open mergeable
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 1
    and .contributions.proven_clear == true and .contributions.counts.maintainer == 1' >/dev/null \
    || fail 'endpoint retirement lost published ownership or proved nothing'
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 2 and .contributions.checked == 1
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'unsupported forge silently disappeared from coverage'
  pass 'retired ownership persists and unsupported forge remains visibly unmeasured'
}

test_unsupported_forge_is_not_fleet_work() {
  local home
  home=$(new_home unsupported-forge)
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.unmeasured == 1 and .contributions.counts.fleet == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'an unsupported forge was classified as fleet work instead of unmeasured coverage'
  pass 'unsupported forge coverage is disclosed without inventing fleet work'
}

test_held_unsupported_forge_is_not_captain_work() {
  local home
  home=$(new_home held-unsupported-forge)
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship) (hold: choose scope) (hold-kind: captain)\n' >> "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.unmeasured == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 0 and (.contributions.captain | length) == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'a held unsupported forge was classified as captain or fleet work'
  pass 'held unsupported forge coverage remains unmeasured'
}

test_shared_contribution_signal_wakes_once() {
  local home token pending wakes
  home=$(new_home shared-contribution-signal)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register shared contribution owner'
  printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  registered_checks "$home" >/dev/null
  jq -n --arg head "$HEAD_A" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  registered_checks "$home" >/dev/null
  wakes=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$wakes" = 1 ] || fail "one shared contribution signal created $wakes durable wakes"
  pending=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending) || fail 'shared contribution pending view failed'
  printf '%s' "$pending" | jq -e 'length == 2 and ([.[].task] | sort) == ["delivery","duplicate"]' >/dev/null \
    || fail 'shared contribution owners did not retain their separate acknowledgements'
  token=$(printf '%s' "$pending" | jq -er '.[0].token') || fail 'shared contribution signal had no acknowledgement token'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 "$token" >/dev/null \
    || fail 'could not acknowledge the first shared contribution owner'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack duplicate https://github.com/o/r/pull/8 "$token" >/dev/null \
    || fail 'could not acknowledge the second shared contribution owner'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null \
    || fail 'shared contribution acknowledgements did not remain independent'
  pass 'shared contribution signal wakes once while retaining both acknowledgements'
}

test_watcher_keeps_diagnostics_separate_from_contribution_wakes() {
  local home out rc wakes diagnostic
  home=$(new_home watcher-diagnostics)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery for diagnostic watcher wake'
  registered_checks "$home" >/dev/null
  mkdir -p "$home/data/unreadable"
  printf 'incomplete JSON\n' > "$home/data/unreadable/contributions.json"
  jq -n --arg head "$HEAD_A" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  out="$home/watcher-diagnostics.out"
  rc=0
  with_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 15 > "$out" 2> "$home/watcher-diagnostics.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "watcher did not surface contribution diagnostics: $(cat "$home/watcher-diagnostics.err")"
  diagnostic=$(awk -F '\t' -v key="$home/state/contributions.check.sh" '$3 == "check" && $4 == key { print $5 }' "$home/state/.wake-queue")
  [ "$diagnostic" = "check: $home/state/contributions.check.sh: contributions: 1 unreadable durable record(s)" ] \
    || fail "watcher wrapped a durable contribution wake into diagnostics: $diagnostic"
  wakes=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$wakes" = 2 ] || fail "signal plus observer failure created $wakes durable wakes"
  pass 'watcher keeps observer diagnostics separate from contribution wakes'
}

test_expired_child_unsupported_forge_stays_unmeasured() {
  local home child
  home=$(new_home expired-unsupported-parent)
  child=$(new_home expired-unsupported-child)
  mkdir -p "$child/bin"
  printf '# Fixture\n' > "$child/AGENTS.md"
  printf 'child\n' > "$child/.fm-secondmate-home"
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$child/data/backlog.md"
  FM_SNAPSHOT_NOW="$NOW" with_home "$child" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$child/state/home-summary.json" \
    || fail 'could not collect child unsupported-forge coverage'
  jq '.contributions.valid_until=0' "$child/state/home-summary.json" > "$child/update.json"
  mv "$child/update.json" "$child/state/home-summary.json"
  printf -- '- child - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-16)\n' "$child" > "$home/data/secondmates.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.unmeasured == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 0 and .contributions.complete == false
    and .contributions.proven_clear == false' >/dev/null \
    || fail 'expired child unsupported-forge coverage became fleet work'
  pass 'expired child unsupported-forge coverage remains unmeasured'
}

test_watcher_surfaces_new_contribution_once() {
  local home out rc rows
  home=$(new_home watcher-contribution)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery for watcher wake'
  registered_checks "$home" >/dev/null
  jq -n --arg head "$HEAD_A" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  out="$home/watcher.out"
  rc=0
  with_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 5 > "$out" 2> "$home/watcher.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "watcher did not surface the new contribution signal: $(cat "$home/watcher.err")"
  grep -E '^check: contributions delivery [0-9a-f]{64}$' "$out" >/dev/null \
    || fail "watcher did not surface the durable contribution wake: $(cat "$out")"
  rows=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$rows" = 1 ] || fail "one contribution signal created $rows durable check wakes"
  rc=0
  with_home "$home" env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$home/watcher-repeat.out" 2> "$home/watcher-repeat.err" || rc=$?
  [ "$rc" -eq 124 ] || fail "an already durable contribution signal re-rang the watcher: $(cat "$home/watcher-repeat.out")"
  rows=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$rows" = 1 ] || fail "repeat contribution observation created $rows durable check wakes"
  pass 'watcher surfaces one newly durable contribution signal without re-ringing it'
}

test_home_summary_coverage() {
  local home child
  home=$(new_home parent)
  child=$(new_home child)
  mkdir -p "$child/bin"
  printf '# Fixture\n' > "$child/AGENTS.md"
  printf 'child\n' > "$child/.fm-secondmate-home"
  record "$child" child-work 15 open mergeable
  FM_SNAPSHOT_NOW="$NOW" with_home "$child" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$child/state/home-summary.json" \
    || fail 'child summary failed'
  printf -- '- child - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-16)\n' "$child" > "$home/data/secondmates.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 1
    and .contributions.proven_clear == true' >/dev/null || fail 'measured child coverage did not reach parent'
  jq '.contributions.valid_until=0' "$child/state/home-summary.json" > "$child/update.json"
  mv "$child/update.json" "$child/state/home-summary.json"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.proven_clear == false' >/dev/null || fail 'expired child evidence proved parent silence'
  pass 'parent consumes measured child coverage and refuses expired child silence'
}

test_unreadable_pending_is_not_empty() {
  local home
  home=$(new_home unreadable-pending)
  record "$home" invalid 16 open mergeable
  printf 'incomplete JSON\n' > "$home/data/invalid/contributions.json"
  if with_home "$home" "$ROOT/bin/fm-contributions.sh" pending > "$home/pending.json" 2> "$home/pending.err"; then
    fail 'an unreadable signal record was presented as an empty inbox'
  fi
  pass 'unreadable pending signals refuse an empty-inbox claim'
}

wrap_forge() { # home: log gh calls and apply per-call faults from $FORGE/fault
  local home=$1
  mv "$home/fakebin/gh" "$home/fakebin/gh-fixture"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FORGE/calls"
fault=$(cat "$FORGE/fault" 2>/dev/null || true)
case "$fault:$*" in
  exhaust:'api repos/o/r/issues/8/comments?'*)
    printf '%s\n' "$(( $(cat "$FORGE/clock") + 100 ))" > "$FORGE/clock" ;;
  fail-late:'api repos/o/r/pulls/8/reviews?'*)
    printf '%s\n' "$(( $(cat "$FORGE/clock") + 100 ))" > "$FORGE/clock"
    printf 'HTTP 502\n' >&2; exit 1 ;;
  fail:'api repos/o/r/pulls/8/reviews?'*) printf 'HTTP 502\n' >&2; exit 1 ;;
  hang:'api repos/o/r/pulls/8') sleep 4 ;;
  head:'pr view '*) printf '{"headRefOid":"%s","reviewDecision":"APPROVED"}\n' "$(printf 'b%.0s' $(seq 40))"; exit 0 ;;
esac
exec "$(dirname "$0")/gh-fixture" "$@"
SH
  # A controllable clock lets the budget expire between two forge calls.
  cat > "$home/fakebin/date" <<'SH'
#!/bin/sh
if [ "$*" = +%s ] && [ -f "$FORGE/clock" ]; then cat "$FORGE/clock"; else exec /bin/date "$@"; fi
SH
  chmod +x "$home/fakebin/gh" "$home/fakebin/date"
}

test_budget_exhaustion_keeps_prior_record() { # exhaust|hang
  local mode=$1 home out
  home=$(new_home "budget-$mode")
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  cp "$home/data/delivery/contributions.json" "$home/prior.json"
  if [ "$mode" = exhaust ]; then /bin/date +%s > "$home/forge/clock"; fi
  printf '%s\n' "$mode" > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_BUDGET=1 "$ROOT/bin/fm-contributions.sh" poll) \
    || fail "poll failed when its budget ran out ($mode)"
  [ -z "$out" ] || fail "budget exhaustion ($mode) printed a wake line: $out"
  grep -F 'api repos/o/r/pulls/8' "$home/forge/calls" >/dev/null \
    || fail "budget exhaustion ($mode) never started the observation"
  cmp -s "$home/prior.json" "$home/data/delivery/contributions.json" \
    || fail "budget exhaustion ($mode) rewrote the prior record: $(cat "$home/data/delivery/contributions.json")"
  [ ! -s "$home/state/.wake-queue" ] || fail "budget exhaustion ($mode) enqueued a wake"
  pass "budget exhausted mid-observation ($mode) keeps the prior record and stays silent"
}

test_budget_refusal_between_calls() { test_budget_exhaustion_keeps_prior_record exhaust; }
test_budget_bounded_call_timeout() { test_budget_exhaustion_keeps_prior_record hang; }

test_genuine_failure_near_deadline_is_unavailable() {
  local home out
  home=$(new_home genuine-failure)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  /bin/date +%s > "$home/forge/clock"
  printf 'fail-late\n' > "$home/forge/fault"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'poll failed on a genuine forge failure'
  [ "$out" = 'contributions: observation unavailable for https://github.com/o/r/pull/8' ] \
    || fail "a genuine forge failure past the deadline was swallowed: $out"
  jq -e --arg now "$NOW" '.records[0].checked_at == $now
    and .records[0].error == "forge observation unavailable or changed during read"' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'a genuine forge failure left no error evidence'
  printf 'fail\n' > "$home/forge/fault"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'repeat poll failed on a genuine forge failure'
  [ "$out" = 'contributions: observation unavailable for https://github.com/o/r/pull/8' ] \
    || fail "an unchanged GitHub forge failure was not reported on every poll: $out"
  pass 'a genuine forge failure inside the budget records the error and wakes on every poll'
}

test_shared_url_observed_once() {
  local mode home out calls expected
  for mode in ok fail head; do
    home=$(new_home "shared-once-$mode")
    forge_home "$home"
    wrap_forge "$home"
    printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
    printf '%s\n' "$mode" > "$home/forge/fault"
    out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail "shared-owner poll failed ($mode)"
    calls=$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")
    [ "$calls" = 1 ] || fail "a URL owned by two tasks was observed $calls times in one poll ($mode)"
    if [ "$mode" = ok ]; then
      expected=null
      [ -z "$out" ] || fail "a healthy shared observation printed: $out"
    else
      expected='"forge observation unavailable or changed during read"'
      [ "$out" = 'contributions: observation unavailable for https://github.com/o/r/pull/8' ] \
        || fail "a shared unavailable observation did not wake exactly once ($mode): $out"
    fi
    for task in delivery duplicate; do
      jq -e --arg now "$NOW" --argjson error "$expected" '.records[0].checked_at == $now and .records[0].error == $error' \
        "$home/data/$task/contributions.json" >/dev/null || fail "owner $task did not receive the shared result ($mode)"
    done
  done
  pass 'a URL owned by two tasks is observed once and every owner receives the result'
}

GITLAB_URL=https://git.example.test/group/sub/project/-/merge_requests/7

gitlab_home() { # home: a linked GitLab merge request read through a stubbed glab
  local home=$1
  mkdir -p "$home/forge"
  printf -- '- [ ] landing - Filed %s (repo: sample) (kind: ship)\n' "$GITLAB_URL" >> "$home/data/backlog.md"
  printf 'opened\n' > "$home/forge/state"
  printf '%s\n' "$HEAD_A" > "$home/forge/head"
  printf '[]\n' > "$home/forge/notes.json"
  printf 'mergeable\n' > "$home/forge/detailed"
  cat > "$home/fakebin/glab" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FORGE/glab-calls"
[ ! -f "$FORGE/glab-down" ] || { printf 'glab: 502 Bad Gateway (HTTP 502)\n' >&2; exit 1; }
[ "$1 $2 $3 $4 $5" = 'api --hostname git.example.test --method GET' ] \
  || { printf 'unexpected glab fixture call: %s\n' "$*" >&2; exit 1; }
shift 5
mr='projects/group%2Fsub%2Fproject/merge_requests/7'
case "$*" in
  "$mr")
    jq -n --arg head "$(cat "$FORGE/head")" --arg state "$(cat "$FORGE/state")" --arg detailed "$(cat "$FORGE/detailed")" '{state:$state,sha:$head,draft:false,
      merge_status:"can_be_merged",detailed_merge_status:$detailed,has_conflicts:false,author:{id:1,username:"author"},user:{can_merge:false},
      head_pipeline:{id:5,sha:$head,status:"success",started_at:"2026-09-16T07:00:00Z"}}' ;;
  "$mr/notes?per_page=100 --paginate") cat "$FORGE/notes.json" ;;
  'projects/group%2Fsub%2Fproject/members/all/2')
    [ ! -f "$FORGE/member-forbidden" ] || { printf '{"message":"403 Forbidden"}'; exit 1; }
    printf '{"id":2,"access_level":40}\n' ;;
  'projects/group%2Fsub%2Fproject/members/all/3') printf '{"message":"404 Not found"}'; exit 1 ;;
  'projects/group%2Fsub%2Fproject/members/all/4') printf '{"message":"403 Forbidden"}'; exit 1 ;;
  'projects/group%2Fsub%2Fproject/members/all/'[5-9]) printf '{"id":%s,"access_level":30}\n' "${1##*/}" ;;
  *) printf 'unexpected glab fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/glab"
}

test_gitlab_merge_request_is_observed() {
  local home out
  home=$(new_home gitlab-observed)
  gitlab_home "$home"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'could not poll a GitLab merge request'
  [ -z "$out" ] || fail "a readable GitLab merge request printed: $out"
  jq -e --arg head "$HEAD_A" '.records[0] | .error == null and .kind == "pr" and .observation.head == $head
    and .observation.state == "open" and .observation.mergeable == "mergeable" and .observation.reviews == []
    and .observation.review_decision == ""
    and .observation.checks == [{name:"pipeline",id:5,started_at:"2026-09-16T07:00:00Z",status:"completed",conclusion:"success"}]' \
    "$home/data/landing/contributions.json" >/dev/null \
    || fail "GitLab observation was not normalized: $(cat "$home/data/landing/contributions.json")"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 1 and .contributions.unmeasured == 0
    and .contributions.counts.maintainer == 1 and .contributions.complete == true' >/dev/null \
    || fail 'a freshly observed GitLab merge request was not measured coverage'
  jq -n '[{id:20,system:true,body:"added 1 commit",author:{id:2,username:"maintainer"},updated_at:"2026-09-16T08:01:00Z"},
    {id:21,system:false,body:"drive-by",author:{id:3,username:"stranger"},updated_at:"2026-09-16T08:01:00Z"},
    {id:22,system:false,body:"own reply",author:{id:1,username:"author"},updated_at:"2026-09-16T08:01:00Z"},
    {id:23,system:false,type:"DiffNote",body:"Please clarify; $(touch /tmp/never)",author:{id:2,username:"maintainer"},
     updated_at:"2026-09-16T08:01:00Z",position:{head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]' > "$home/forge/notes.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'could not poll GitLab notes'
  [ "$(grep -c '/members/all/' "$home/forge/glab-calls")" = 2 ] || fail 'each new commenter must be looked up once'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'could not re-poll GitLab notes'
  [ "$(grep -c '/members/all/' "$home/forge/glab-calls")" = 2 ] || fail 'an already-seen GitLab note was looked up again'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e --arg url "$GITLAB_URL" 'length == 1
    and .[0].author == "maintainer" and .[0].type == "review-comment" and .[0].source == ($url + "#note_23")
    and .[0].body == "Please clarify; $(touch /tmp/never)"' >/dev/null \
    || fail 'only the project member note must become a pending signal, as inert data'
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = 1 ] || fail 'one GitLab maintainer note must wake exactly once'
  ! grep -Ev '^api --hostname git\.example\.test --method GET ' "$home/forge/glab-calls" >/dev/null \
    || fail 'GitLab observation issued something other than a GET read'
  pass 'a GitLab merge request is observed through glab and a member note wakes once'
}

test_gitlab_terminal_merge_request_needs_nobody() {
  local home state
  for state in merged closed; do
    home=$(new_home "gitlab-$state")
    gitlab_home "$home"
    printf '%s\n' "$state" > "$home/forge/state"
    [ -z "$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll)" ] || fail "a $state GitLab merge request printed a wake line"
    bearings "$home" | jq -e '.contributions.checked == 1 and .contributions.counts.nobody == 1
      and .contributions.unmeasured == 0 and .contributions.proven_clear == true' >/dev/null \
      || fail "a $state GitLab merge request still needed an actor"
  done
  pass 'a merged or closed GitLab merge request needs nobody, like a GitHub pull request'
}

test_gitlab_forbidden_member_lookup_is_not_unavailable() {
  local home out
  home=$(new_home gitlab-forbidden-member)
  gitlab_home "$home"
  jq -n '[{id:30,system:false,body:"opinion",author:{id:4,username:"hidden"},updated_at:"2026-09-16T08:01:00Z"}]' \
    > "$home/forge/notes.json"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'poll failed on a forbidden member lookup'
  [ -z "$out" ] || fail "a forbidden member lookup made the merge request unavailable: $out"
  jq -e '.records[0].error == null and .records[0].pending == [] and .records[0].seen == []
    and .records[0].observation.events == []' \
    "$home/data/landing/contributions.json" >/dev/null \
    || fail "a forbidden member lookup failed the observation or counted a maintainer: $(cat "$home/data/landing/contributions.json")"
  bearings "$home" | jq -e '.contributions.checked == 1 and .contributions.unmeasured == 0' >/dev/null \
    || fail 'a forbidden member lookup left the merge request unmeasured'
  pass 'a forbidden GitLab member lookup leaves the role unknown and the observation readable'
}

test_gitlab_failed_member_lookup_keeps_acknowledgement() {
  local home
  home=$(new_home gitlab-ack-gap)
  gitlab_home "$home"
  jq -n '[{id:23,system:false,body:"Please clarify",author:{id:2,username:"maintainer"},updated_at:"2026-09-16T08:01:00Z"}]' \
    > "$home/forge/notes.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'could not poll a GitLab maintainer note'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack landing "$GITLAB_URL" 'note:23:2026-09-16T08:01:00Z' \
    || fail 'could not acknowledge the GitLab maintainer note'
  : > "$home/forge/member-forbidden"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'poll failed on a forbidden member lookup'
  rm "$home/forge/member-forbidden"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'poll failed after the member lookup recovered'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null \
    || fail 'an acknowledged GitLab note came back after a transient member lookup failure'
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = 1 ] || fail 'an acknowledged GitLab note woke again'
  pass 'a transient GitLab member lookup failure never re-raises an acknowledged note'
}

test_gitlab_resolved_note_keeps_acknowledgement() {
  local home
  home=$(new_home gitlab-resolved-note)
  gitlab_home "$home"
  jq -n '[{id:23,system:false,type:"DiffNote",body:"Please clarify",author:{id:2,username:"maintainer"},
    updated_at:"2026-09-16T08:01:00Z",position:{head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]' > "$home/forge/notes.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'could not poll a GitLab maintainer note'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack landing "$GITLAB_URL" 'note:23:2026-09-16T08:01:00Z' \
    || fail 'could not acknowledge the GitLab maintainer note'
  jq '.[0] += {resolved:true,resolved_at:"2026-09-16T09:00:00.120Z",updated_at:"2026-09-16T09:00:00.124Z"}' \
    "$home/forge/notes.json" > "$home/forge/notes.next" && mv "$home/forge/notes.next" "$home/forge/notes.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'could not poll a resolved GitLab note'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null \
    || fail 'resolving a thread re-raised an acknowledged GitLab note'
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = 1 ] || fail 'resolving a thread woke the supervisor again'
  [ "$(grep -c '/members/all/' "$home/forge/glab-calls")" = 1 ] || fail 'a resolve-only change looked the author up again'
  jq '.[0] += {body:"Please clarify, edited",updated_at:"2026-09-16T10:00:00Z"}' \
    "$home/forge/notes.json" > "$home/forge/notes.next" && mv "$home/forge/notes.next" "$home/forge/notes.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'could not poll an edited GitLab note'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 1
    and .[0].token == "note:23:2026-09-16T10:00:00Z" and .[0].body == "Please clarify, edited"' >/dev/null \
    || fail 'a genuine edit of a resolved GitLab note was not re-raised'
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = 2 ] || fail 'a genuine GitLab note edit did not wake once'
  pass 'resolving a GitLab thread keeps the acknowledgement while a real edit re-raises'
}

test_gitlab_member_lookups_are_capped_per_poll() {
  local home
  home=$(new_home gitlab-lookup-cap)
  gitlab_home "$home"
  jq -n '[range(5;10) | {id:(100 + .),system:false,body:"note",author:{id:.,username:("member" + tostring)},
    updated_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/notes.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'could not poll five new GitLab commenters'
  [ "$(grep -c '/members/all/' "$home/forge/glab-calls")" = 3 ] || fail 'one observation looked up more than three authors'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 3' >/dev/null \
    || fail 'the first three looked-up maintainers did not become pending'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'could not re-poll GitLab commenters'
  [ "$(grep -c '/members/all/' "$home/forge/glab-calls")" = 5 ] || fail 'the remaining commenters were not looked up next'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'could not poll settled GitLab commenters'
  [ "$(grep -c '/members/all/' "$home/forge/glab-calls")" = 5 ] || fail 'a steady-state poll still looked up members'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'map(.author) | sort == ["member5","member6","member7","member8","member9"]' \
    >/dev/null || fail 'commenters over the cap were not reconsidered on a later poll'
  pass 'GitLab member lookups are capped per poll and progress across polls'
}

test_gitlab_approval_states_map_to_review_decision() {
  local home detailed decision
  for detailed in not_approved:REVIEW_REQUIRED requested_changes:CHANGES_REQUESTED; do
    decision=${detailed#*:}; detailed=${detailed%%:*}
    home=$(new_home "gitlab-$detailed")
    gitlab_home "$home"
    printf '%s\n' "$detailed" > "$home/forge/detailed"
    with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail "could not poll a $detailed GitLab merge request"
    jq -e --arg decision "$decision" '.records[0].observation.review_decision == $decision' \
      "$home/data/landing/contributions.json" >/dev/null || fail "$detailed was not mapped to $decision"
  done
  bearings "$home" | jq -e '.contributions.counts.fleet == 1' >/dev/null \
    || fail 'a GitLab merge request with requested changes was not fleet work'
  pass 'GitLab approval states map onto the review decision'
}

test_unavailable_gitlab_notifies_once_and_stays_disclosed() {
  local home out
  home=$(new_home gitlab-unavailable)
  gitlab_home "$home"
  : > "$home/forge/glab-down"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'poll failed on an unreadable GitLab merge request'
  [ "$out" = "contributions: observation unavailable for $GITLAB_URL" ] \
    || fail "a newly unreadable GitLab merge request was not reported: $out"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'repeat poll failed on an unreadable GitLab merge request'
  [ -z "$out" ] || fail "an unchanged unreadable GitLab merge request was reported again: $out"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0 and .contributions.unmeasured == 1
    and .contributions.counts.fleet == 0 and .contributions.complete == false
    and .contributions.proven_clear == false' >/dev/null \
    || fail 'an unreadable GitLab merge request was not disclosed as unmeasured coverage'
  rm "$home/forge/glab-down"
  [ -z "$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll)" ] || fail 'a recovered GitLab read printed a wake line'
  jq -e '.records[0].error == null' "$home/data/landing/contributions.json" >/dev/null || fail 'recovery did not clear the error'
  : > "$home/forge/glab-down"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll)
  [ "$out" = "contributions: observation unavailable for $GITLAB_URL" ] \
    || fail "an unreadable GitLab merge request after recovery was not reported again: $out"
  bearings "$home" | jq -e '.contributions.checked == 0 and .contributions.unmeasured == 1' >/dev/null \
    || fail 'a failed re-read kept an earlier observation as measured coverage'
  pass 'an unreadable GitLab merge request is reported once per condition and stays unmeasured'
}

failures=0
for test_name in test_actor_coverage test_stale_verdict test_unchecked_is_not_silence test_newest_check_has_no_verdict test_comment_wake test_review_wake test_inline_wake test_ready_issue_wake test_fresh_issue_requires_maintainer test_missing_lane_remains_missing test_partial_freshness_keeps_measured_rows test_malformed_record_cannot_prove_silence test_issue_timeline_and_exact_ack test_verdict_retains_judged_head test_observed_replacement_refreshes_verdict test_unobserved_head_leaves_verdict_unknown test_away_yolo_is_fleet_work test_away_yolo_cross_home_is_fleet_work test_retired_and_unsupported_coverage test_unsupported_forge_is_not_fleet_work test_held_unsupported_forge_is_not_captain_work test_shared_contribution_signal_wakes_once test_watcher_keeps_diagnostics_separate_from_contribution_wakes test_expired_child_unsupported_forge_stays_unmeasured test_watcher_surfaces_new_contribution_once test_home_summary_coverage test_unreadable_pending_is_not_empty test_budget_refusal_between_calls test_budget_bounded_call_timeout test_genuine_failure_near_deadline_is_unavailable test_shared_url_observed_once test_gitlab_merge_request_is_observed test_gitlab_terminal_merge_request_needs_nobody test_gitlab_forbidden_member_lookup_is_not_unavailable test_gitlab_failed_member_lookup_keeps_acknowledgement test_gitlab_resolved_note_keeps_acknowledgement test_gitlab_member_lookups_are_capped_per_poll test_gitlab_approval_states_map_to_review_decision test_unavailable_gitlab_notifies_once_and_stays_disclosed; do
  ( "$test_name" ) || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || fail "$failures contribution regressions"

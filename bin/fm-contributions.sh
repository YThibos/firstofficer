#!/usr/bin/env bash
# Observe published contributions owned by this home's durable task records.
#
# Usage:
#   fm-contributions.sh snapshot <input.json> [--all]
#   fm-contributions.sh poll
#   fm-contributions.sh pending
#   fm-contributions.sh verdict <task> <url> <judged-head> <source-url> <actor> <summary>
#   fm-contributions.sh ack <task> <url> <event-token>
#   fm-contributions.sh arm [--if-owned]
#
# snapshot is read-only and never contacts a forge. Its input is the canonical
# fleet snapshot's backlog/tasks pair; --all adds rows for supervisor inspection.
# Every URL explicitly linked by a structured backlog row or a task's pr= is
# owned. Previously observed URLs remain in data/<task>/contributions.json after
# endpoint teardown. Repository-wide PR discovery never establishes ownership.
# GitHub PRs and issues and GitLab merge requests are supported. A GitLab merge
# request that has never been read, or whose last read failed, stays visibly
# unmeasured rather than becoming fleet work or a clear result.
#
# This script owns fm-contributions.v1: one atomic file per durable task with
# task and records[]. Each record contains url, kind, checked_at, error,
# observation, verdict, seen event tokens, pending events, and notified tokens.
# observation is one coherent forge read (a PR head is rechecked after fetching
# checks/reviews). Checks are normalized by name, id, started_at, status and
# conclusion; projection picks the newest attempt per distinct name. The last
# observation's lane names also disclose a lane absent from the next head.
# GitLab is read through glab on the URL's own host, so self-hosted instances
# need only a glab login. Its merge request supplies state, head, draft,
# conflict state and merge permission; the head pipeline is the one check lane,
# named pipeline, and is omitted when it ran on another commit. GitLab has no
# per-commit review record, so reviews stay empty; detailed_merge_status
# not_approved and requested_changes become review_decision REVIEW_REQUIRED and
# CHANGES_REQUESTED.
# A verdict records the EXACT judged head, source URL, actor and summary. A
# comment's arrival time never supplies its judged head. Record a prose verdict
# only after its source identifies that head; otherwise leave it unbound and
# triage its signal. Formal reviews carry GitHub's own commit_id. Neither kind
# can grant merge authority. Captain-actor prose requires an existing live hold;
# an eligible merge remains a captain call, never an automatic forge action.
#
# poll consumes fm-fleet-snapshot.sh --contribution-input, a local-only read,
# and spends at most FM_CONTRIBUTIONS_BUDGET seconds on forge reads (default 20,
# 1..25). Each gh or glab call is bounded by the remaining budget and five seconds.
# Oldest observations go first, so a large corpus progresses across polls.
# Each distinct URL is observed once per poll and applied to every owner. When
# the budget runs out mid-observation, the poll ends with that URL's records
# untouched; only a genuine forge failure or head change records an error.
# API failure leaves error evidence; an expired or absent observation is not
# silence. poll prints "contributions: observation unavailable for <url>" on
# every failed read, except for a GitLab merge request: that line prints only
# when its recorded error appears or changes, not again while every owner already
# holds that same error; a successful read clears it and re-arms the line.
# FM_CONTRIBUTIONS_MAX_AGE (default 900 seconds) bounds freshness.
# FM_CONTRIBUTIONS_NOW supplies an ISO UTC clock for tests, otherwise UTC now.
# FM_CONTRIBUTIONS_READY_LABEL selects the equivalent triage label, default
# ready-for-pr. Labels are matched case-insensitively and exactly.
#
# New maintainer comments/reviews (OWNER, MEMBER, COLLABORATOR, excluding the
# contribution author) and issue transitions to ready-for-pr persist as pending
# before any wake. GitLab has no author association, so a non-system note counts
# when its author is not the merge request author and is a project member at
# Developer access or above. Only notes unseen by every owner need a member
# lookup, at most three distinct authors per observation, so steady-state polls
# make no lookup. A 404 or access below Developer marks the note seen without a
# signal; a note whose author was over the cap or whose lookup failed stays
# unseen for a later poll. A GitLab record keeps every token it has seen, so a
# lookup gap never re-raises an acknowledged note. poll appends ordinary durable
# check wakes through fm-wake-lib and emits only newly durable signals for the
# authenticated check to surface.
# ack removes
# only the named pending token. A crash after enqueue can duplicate a wake but
# cannot consume the pending signal. Source bodies are data, never commands.
# All mutations serialize on this home's .contributions.lock. Writes refuse
# symlinks and publish by rename. No forge writes are performed.
#
# arm registers the existing authenticated custom-check path. Startup and PR
# registration call it; when filing a linked upstream issue, call arm as well.
# jq_lib receives literal jq programs, not shell expressions.
# shellcheck disable=SC2016
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
export FM_HOME FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

fail() { printf 'fm-contributions: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || fail 'jq is required to measure contribution coverage'
NOW=${FM_CONTRIBUTIONS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
EPOCH=$(jq -nr --arg now "$NOW" '$now | fromdateiso8601') || fail 'invalid observation clock'
MAX_AGE=${FM_CONTRIBUTIONS_MAX_AGE:-900}
BUDGET=${FM_CONTRIBUTIONS_BUDGET:-20}
case "$MAX_AGE" in ''|*[!0-9]*) fail 'invalid freshness bound' ;; esac
case "$BUDGET" in ''|*[!0-9]*) fail 'invalid poll budget' ;; esac
[ "$BUDGET" -ge 1 ] && [ "$BUDGET" -le 25 ] || fail 'poll budget must be 1..25 seconds'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-contributions.XXXXXX")
LOCK_HELD=0
cleanup() {
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$STATE/.contributions.lock" || true
  rm -rf -- "$TMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

jq_lib() { # jq options/program via final argument
  local program=${!#}
  set -- "${@:1:$#-1}"
  jq -L "$SCRIPT_DIR" "$@" "include \"fm-contributions\"; $program"
}

read_saved() {
  local file
  : > "$TMP/saved.jsonl"
  ERRORS=0
  if [ -L "$DATA" ]; then
    ERRORS=1; printf '[]\n' > "$TMP/saved.json"; return 0
  fi
  for file in "$DATA"/*/contributions.json; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    if [ -L "$file" ] || [ -L "$(dirname "$file")" ] || [ ! -f "$file" ] \
      || [ "$(wc -c < "$file")" -gt 1048576 ] \
      || ! jq_lib -ne --slurpfile record "$file" '($record | length) == 1 and ($record[0] | valid_record)' >/dev/null 2>&1; then
      ERRORS=$((ERRORS + 1))
      continue
    fi
    # A file's task identity must match its durable directory, not arbitrary JSON.
    if ! jq -e --arg task "$(basename "$(dirname "$file")")" '.task == $task' "$file" >/dev/null; then
      ERRORS=$((ERRORS + 1)); continue
    fi
    jq -c . "$file" >> "$TMP/saved.jsonl"
  done
  jq -s . "$TMP/saved.jsonl" > "$TMP/saved.json"
}

get_input() {
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input > "$TMP/input.json"
}

project() {
  jq_lib -n --slurpfile input "$1" --slurpfile saved "$TMP/saved.json" \
    --argjson now "$EPOCH" --argjson max_age "$MAX_AGE" --argjson errors "$ERRORS" \
    --arg all "${2:-}" '
    projected($input[0];$saved[0];$now;$max_age) as $rows
    | summary($rows;($errors + (if $input[0].backlog.present == true then 0 else 1 end)))
    | .valid_until += $max_age
    | .captain_omitted = ([0, (.captain | length) - 20] | max)
    | .captain |= .[:20]
    | . + (if $all == "--all" then {rows:$rows} else {} end)'
}

acquire() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory unavailable'
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || fail 'data directory unavailable'
  # Keep the wake library's source-time state initialization off read-only paths.
  FM_WAKE_QUEUE="$STATE/.wake-queue"
  FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait "$STATE/.contributions.lock" || fail 'observation lock unavailable'
  LOCK_HELD=1
}

write_record() { # task record-json-file
  local task=$1 file dir device staged
  fm_pr_task_id_valid "$task" || fail 'invalid contribution task'
  dir="$DATA/$task"
  [ ! -L "$dir" ] || fail 'contribution directory is a symlink'
  mkdir -p "$dir"
  file="$dir/contributions.json"
  device=$(fm_pr_file_device "$dir")
  fm_pr_regular_destination_on_device_or_absent "$file" "$device" || fail 'unsafe contribution record destination'
  staged=$(umask 077; mktemp "$dir/.contributions.XXXXXX")
  # Preserve other contributions owned by this same task.
  if [ -f "$file" ]; then
    jq_lib -ne --arg task "$task" --slurpfile record "$file" '$record[0] | valid_record and .task == $task' >/dev/null || fail 'invalid stored contribution record'
    jq --slurpfile row "$2" '.records = ([.records[] | select(.url != $row[0].url)] + $row)' "$file" > "$staged"
  else
    jq -n --arg task "$task" --slurpfile row "$2" '{schema:"fm-contributions.v1",task:$task,records:$row}' > "$staged"
  fi
  chmod 600 "$staged"
  fm_pr_regular_destination_on_device_or_absent "$file" "$device" || fail 'contribution destination changed'
  mv -f -- "$staged" "$file"
}

forge_run() { # bounded forge CLI command
  local remaining bounded=0 rc=0
  remaining=$((DEADLINE - $(date +%s)))
  # The budget, not the forge, refused this read.
  [ "$remaining" -gt 0 ] || { BUDGET_EXHAUSTED=1; return 1; }
  if [ "$remaining" -le 5 ]; then bounded=1; else remaining=5; fi
  fm_run_timed "$remaining" "$@" 2> "$TMP/forge.err" || rc=$?
  # A read killed at the budget's own deadline is budget exhaustion too.
  [ "$rc" -ne 124 ] || [ "$bounded" -eq 0 ] || BUDGET_EXHAUSTED=1
  return "$rc"
}

forge() { forge_run env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@"; }

gitlab() { # validated-host endpoint [glab api options]: GET only
  local host=$1; shift
  forge_run env GITLAB_HOST="$host" NO_PROMPT=1 GLAB_CHECK_UPDATE=false \
    glab api --hostname "$host" --method GET "$@"
}

observe_gitlab() { # canonical URL, seen-token file; URL already parsed by fm_pr_url_parse -> normalized JSON
  local url=$1 host=$FM_PR_HOST project mr head after author
  if ! command -v glab >/dev/null 2>&1; then
    OBSERVE_ERROR='glab is required to observe a GitLab merge request'
    return 1
  fi
  # The path is already restricted to [A-Za-z0-9._/-], so only "/" needs encoding.
  project=${FM_PR_PATH//\//%2F}
  mr="projects/$project/merge_requests/$FM_PR_NUMBER"
  gitlab "$host" "$mr" > "$TMP/core.json" || return 1
  jq -e '(.state | IN("opened","locked","closed","merged")) and (.author.username | type == "string")' \
    "$TMP/core.json" >/dev/null || return 1
  head=$(jq -er '.sha | select(type == "string" and test("^[a-fA-F0-9]{40}$"))' "$TMP/core.json") || return 1
  author=$(jq -r .author.username "$TMP/core.json")
  gitlab "$host" "$mr/notes?per_page=100" --paginate > "$TMP/notes.raw" || return 1
  # glab may print one merged array or one array per page.
  jq -s 'if all(.[]; type == "array") then add // [] else error("notes are not arrays") end
    | map(. + {token:("note:" + (.id | tostring) + ":" + (.updated_at // .created_at // ""))})' \
    "$TMP/notes.raw" > "$TMP/notes.json" || return 1
  : > "$TMP/members.json"
  while IFS= read -r member; do
    if gitlab "$host" "projects/$project/members/all/$member" > "$TMP/member.json"; then
      jq -c --argjson id "$member" '{id:$id,access_level} | select(.access_level | type == "number")' \
        "$TMP/member.json" >> "$TMP/members.json" 2>/dev/null || :
    else
      [ "$BUDGET_EXHAUSTED" -eq 0 ] || return 1
      if jq -e '.message // "" | tostring | test("^404")' "$TMP/member.json" >/dev/null 2>&1; then
        printf '{"id":%s,"access_level":0}\n' "$member" >> "$TMP/members.json"
      fi
    fi
  done < <(jq -r --arg author "$author" --slurpfile seen "$2" '[.[] | select(.system != true and .author.username != $author)
    | select(.token as $t | $seen[0] | index($t) | not) | .author.id | select(type == "number") | floor]
    | reduce .[] as $id ([]; if index($id) then . else . + [$id] end) | .[:3][]' "$TMP/notes.json")
  gitlab "$host" "$mr" > "$TMP/after.json" || return 1
  after=$(jq -r '.sha // ""' "$TMP/after.json")
  [ "$head" = "$after" ] || { printf 'head changed during observation\n' > "$TMP/forge.err"; return 1; }
  jq -n --arg url "$url" --slurpfile core "$TMP/core.json" --slurpfile notes "$TMP/notes.json" \
    --slurpfile members "$TMP/members.json" --slurpfile seen "$2" '
    $core[0] as $c | $c.head_pipeline as $p
    | [$notes[0][] | select(.system != true and .author.username != $c.author.username)
        | select(.token as $t | $seen[0] | index($t) | not)] as $fresh
    | [$members[] | select(.access_level >= 30) | .id] as $maintainers
    | {head:$c.sha,state:(if $c.state == "merged" or $c.state == "closed" then $c.state else "open" end),
        draft:($c.draft // $c.work_in_progress // false),
        mergeable:(if $c.has_conflicts == true or $c.merge_status == "cannot_be_merged" then "conflicting"
          elif $c.merge_status == "can_be_merged" then "mergeable" else "unknown" end),
        can_merge:($c.user.can_merge == true),
        review_decision:({not_approved:"REVIEW_REQUIRED",requested_changes:"CHANGES_REQUESTED"}[$c.detailed_merge_status // ""] // ""),
        reviews:[],
        checks:(if ($p | type) == "object" and $p.sha == $c.sha and ($p.status | type) == "string" then
          [{name:"pipeline",id:$p.id,started_at:($p.started_at // $p.created_at)}
            + (({success:"success",failed:"failure",canceled:"cancelled",skipped:"skipped"}[$p.status]) as $done
              | if $done != null then {status:"completed",conclusion:$done}
                elif $p.status | IN("created","waiting_for_resource","preparing","pending","running","scheduled","manual","canceling")
                then {status:"in_progress",conclusion:null}
                else {status:"completed",conclusion:null} end)]
          else [] end),
        settled:[$fresh[] | select(.author.id as $id | ($members | map(.id) | index($id)) != null
          and ($maintainers | index($id)) == null) | .token],
        events:[$fresh[] | select(.author.id as $id | $maintainers | index($id) != null)
          | {token,
             type:(if .type == "DiffNote" then "review-comment" else "comment" end),
             source:($url + "#note_" + (.id | tostring)),
             head:(if .type == "DiffNote" then .position.head_sha else null end),
             author:.author.username,body:(.body // "" | tostring | .[:500])}]}' > "$TMP/observation.json" || return 1
  jq_lib -ne --arg url "$url" --slurpfile observed "$TMP/observation.json" '
    {schema:"fm-contributions.v1",task:"observation",records:[{url:$url,kind:"pr",pending:[],seen:[],
      observation:$observed[0]}]} | valid_record' >/dev/null
}

observe() { # canonical contribution URL, seen-token file -> normalized JSON
  local url=$1 part number kind endpoint head after label
  OBSERVE_ERROR='forge observation unavailable or changed during read'
  OBSERVE_ONCE=0
  if fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = gitlab ]; then
    OBSERVE_ONCE=1
    observe_gitlab "$url" "$2"
    return
  fi
  case "$url" in https://github.com/*) ;; *) return 1 ;; esac
  part=${url#https://github.com/}; number=${part##*/}; part=${part%/*}; kind=${part##*/}; part=${part%/*}
  case "$kind" in pull) endpoint="repos/$part/pulls/$number" ;; issues) endpoint="repos/$part/issues/$number" ;; *) return 1 ;; esac
  forge api "$endpoint" > "$TMP/core.json" || return 1
  jq -e '(.state == "open" or .state == "closed") and (.user.login | type == "string")' "$TMP/core.json" >/dev/null || return 1
  forge api "repos/$part/issues/$number/comments?per_page=100" --paginate --slurp > "$TMP/comments.json" || return 1
  jq -e 'type == "array" and all(.[]; type == "array")' "$TMP/comments.json" >/dev/null || return 1
  if [ "$kind" = pull ]; then
    head=$(jq -er '.head.sha | select(test("^[a-fA-F0-9]{40}$"))' "$TMP/core.json") || return 1
    forge api "$endpoint/reviews?per_page=100" --paginate --slurp > "$TMP/reviews.json" || return 1
    forge api "$endpoint/comments?per_page=100" --paginate --slurp > "$TMP/inline.json" || return 1
    forge api "repos/$part/commits/$head/check-runs?filter=all&per_page=100" --paginate --slurp > "$TMP/checks.json" || return 1
    forge api "repos/$part/commits/$head/statuses?per_page=100" --paginate --slurp > "$TMP/statuses.json" || return 1
    forge api "repos/$part" > "$TMP/repo.json" || return 1
    forge pr view "$url" --json headRefOid,reviewDecision > "$TMP/after.json" || return 1
    after=$(jq -er .headRefOid "$TMP/after.json")
    [ "$head" = "$after" ] || { printf 'head changed during observation\n' > "$TMP/forge.err"; return 1; }
    jq -n --slurpfile core "$TMP/core.json" --slurpfile comments "$TMP/comments.json" \
      --slurpfile reviews "$TMP/reviews.json" --slurpfile inline "$TMP/inline.json" --slurpfile after "$TMP/after.json" --slurpfile checks "$TMP/checks.json" \
      --slurpfile statuses "$TMP/statuses.json" --slurpfile repo "$TMP/repo.json" '
      $core[0] as $c
      | ($reviews[0] | add // []) as $reviews
      | {head:$c.head.sha,state:(if $c.merged_at != null then "merged" else $c.state end),
          draft:$c.draft,mergeable:(if $c.mergeable == true then "mergeable" elif $c.mergeable == false then "conflicting" else "unknown" end),
          can_merge:($repo[0].permissions.push // false),
          review_decision:($after[0].reviewDecision // ""),
          reviews:$reviews,
          checks:([ $checks[0][] | .check_runs[] | {name,id,status,conclusion,started_at} ]
            + [ $statuses[0][] | .[] | {name:.context,id,started_at:.created_at,
              status:(if .state == "pending" then "in_progress" else "completed" end),
              conclusion:(if .state == "pending" then null else .state end)} ]),
          events:((($comments[0] | add // [] | map(. + {_signal:"comment"})) + ($reviews | map(. + {_signal:"review"})) + ($inline[0] | add // [] | map(. + {_signal:"review-comment"})))
            | map(select(.user.login != $c.user.login and (.author_association | IN("OWNER","MEMBER","COLLABORATOR")))
              | {token:((._signal + ":") + (.id|tostring) + ":" + (.updated_at // .submitted_at // "") + ":" + (.state // "")),
                 type:._signal,source:.html_url,head:.commit_id,
                 author:.user.login,body:(.body // "" | .[:500])}))}' > "$TMP/observation.json" || return 1
  else
    label=${FM_CONTRIBUTIONS_READY_LABEL:-ready-for-pr}
    forge api "repos/$part/issues/$number/events?per_page=100" --paginate --slurp > "$TMP/issue-events.json" || return 1
    jq -n --slurpfile timeline "$TMP/issue-events.json" --arg label "$label" --slurpfile core "$TMP/core.json" --slurpfile comments "$TMP/comments.json" '
      $core[0] as $c | {state:$c.state,head:null,
        ready:any($c.labels[]; (.name | ascii_downcase) == ($label | ascii_downcase)),
        checks:[],reviews:[],events:($comments[0] | add // []
          | map(select(.user.login != $c.user.login and (.author_association | IN("OWNER","MEMBER","COLLABORATOR")))
            | {token:("comment:" + (.id|tostring) + ":" + (.updated_at // "")),type:"comment",source:.html_url,
               head:null,author:.user.login,body:(.body // "" | .[:500])})
          + [$timeline[0][] | .[] | select(.event == "labeled" and (.label.name | ascii_downcase) == ($label | ascii_downcase))
             | {token:("ready-for-pr:" + (.id | tostring)),type:"ready-for-pr",source:$c.html_url,head:null,body:"filed issue reached ready-for-pr"}])}' > "$TMP/observation.json" || return 1
  fi
  jq_lib -ne --arg url "$url" --arg kind "$kind" --slurpfile observed "$TMP/observation.json" '
    {schema:"fm-contributions.v1",task:"observation",records:[{url:$url,
      kind:(if $kind == "pull" then "pr" else "issue" end),pending:[],seen:[],observation:$observed[0]}]}
    | valid_record' >/dev/null
}

publish_pending() { # task canonical-url record-file
  local task=$1 url=$2 record=$3 token key count emitted status
  count=$(jq '.pending | length' "$record")
  [ "$count" -gt 0 ] || return 0
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    key=$(printf '%s\n%s\n' "$url" "$token" | shasum -a 256 | awk '{print $1}')
    emitted=0
    status=0
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
    if ! fm_wake_queued_keys_locked check | grep -Fx "contribution-$key" >/dev/null; then
      fm_wake_append_locked check "contribution-$key" "check: contributions $task $key" || status=1
      [ "$status" -ne 0 ] || emitted=1
    fi
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
    [ "$status" -eq 0 ] || return 1
    jq --arg token "$token" '.notified = ((.notified // []) + [$token] | unique)' "$record" > "$TMP/notified.json"
    mv "$TMP/notified.json" "$record"
    write_record "$task" "$record"
    [ "$emitted" -eq 0 ] || printf 'contribution-wake: check: contributions %s %s\n' "$task" "$key"
  done < <(jq -r '. as $r | .pending[] | .token | select(. as $t | ($r.notified // [] | index($t)) == null)' "$record")
}

poll() {
  local task url old kind observed announce
  local -a row
  acquire
  get_input
  read_saved
  [ "$ERRORS" -eq 0 ] || printf 'contributions: %s unreadable durable record(s)\n' "$ERRORS"
  # One line per distinct URL: the URL, then every owning task.
  jq_lib -nr --slurpfile input "$TMP/input.json" --slurpfile saved "$TMP/saved.json" '
    known($input[0];$saved[0]) | map(. as $k | . + {at:([$saved[0][] | select(.task == $k.task) | .records[] | select(.url == $k.url) | .checked_at] | first // "")})
    | group_by(.url) | map({url:.[0].url,at:(map(.at) | min),tasks:(map(.task) | unique)})
    | sort_by(.at,.tasks[0],.url)[] | [.url] + .tasks | @tsv' > "$TMP/known.tsv"
  DEADLINE=$(( $(date +%s) + BUDGET ))
  BUDGET_EXHAUSTED=0
  while IFS=$'\t' read -r -a row; do
    [ "${#row[@]}" -ge 2 ] || continue
    [ "$(date +%s)" -lt "$DEADLINE" ] || break
    url=${row[0]}
    observed=0
    # Only a note unseen by every owner needs a member lookup.
    jq -n --slurpfile saved "$TMP/saved.json" --arg url "$url" '$ARGS.positional
      | map(. as $t | [$saved[0][] | select(.task == $t) | .records[] | select(.url == $url) | .seen // []] | first // [])
      | reduce .[1:][] as $s (.[0]; . - (. - $s))' --args "${row[@]:1}" > "$TMP/seen.json"
    observe "$url" "$TMP/seen.json" || observed=$?
    # An observation the budget cut short is unmeasured, not unavailable: keep
    # every owner's prior record so the URL is observed first next poll.
    [ "$BUDGET_EXHAUSTED" -eq 0 ] || break
    announce=0
    [ "$observed" -eq 0 ] || [ "$OBSERVE_ONCE" -eq 1 ] || announce=1
    case "$url" in https://github.com/*/issues/*) kind=issue ;; *) kind="pr" ;; esac
    for task in "${row[@]:1}"; do
      fm_pr_task_id_valid "$task" || { printf 'contributions: invalid durable task id\n'; continue; }
      old="$TMP/old.json"
      jq -n --slurpfile saved "$TMP/saved.json" --arg task "$task" --arg url "$url" --arg kind "$kind" '
        ([$saved[0][] | select(.task == $task) | .records[] | select(.url == $url)] | first)
        // {url:$url,kind:$kind,checked_at:null,observation:null,verdict:null,seen:[],pending:[],notified:[]}' > "$old"
      if [ "$observed" -eq 0 ]; then
        jq -n --arg now "$NOW" --argjson once "$OBSERVE_ONCE" --slurpfile old "$old" --slurpfile observation "$TMP/observation.json" '
          $old[0] as $old | $observation[0] as $o
          | ($o.events + (if $o.ready == true and $old.observation.ready != true and (any($o.events[]; .type == "ready-for-pr") | not) then
              [{token:("ready-for-pr:" + $now),type:"ready-for-pr",source:$old.url,head:null,body:"filed issue reached ready-for-pr"}]
              else [] end)) as $events
          | $old + {checked_at:$now,error:null,
            observation:($o + {absent_checks:((($old.observation.absent_checks // []) + [($old.observation.checks // [])[] | .name]) - [$o.checks[].name] | unique)} | del(.settled)),
            seen:(($events | map(.token)) + (if $once == 1 then ($old.seen // []) + ($o.settled // []) else [] end) | unique),
            pending:(($old.pending // []) + [$events[] | select(.token as $t | ($old.seen // [] | index($t)) == null)] | unique_by(.token))}' > "$TMP/row.json"
      else
        # A GitLab owner that already holds this exact error has been told once.
        jq -e --arg error "$OBSERVE_ERROR" '.error == $error' "$old" >/dev/null || announce=1
        jq --arg now "$NOW" --arg error "$OBSERVE_ERROR" '.checked_at=$now | .error=$error' "$old" > "$TMP/row.json"
      fi
      write_record "$task" "$TMP/row.json"
      publish_pending "$task" "$url" "$TMP/row.json"
    done
    [ "$announce" -eq 0 ] || printf 'contributions: observation unavailable for %s\n' "$url"
  done < "$TMP/known.tsv"
}

arm() {
  local device staged
  acquire
  if [ "${1:-}" = --if-owned ]; then
    get_input; read_saved
    if [ "$ERRORS" -eq 0 ] && ! jq_lib -ne --slurpfile input "$TMP/input.json" \
      --slurpfile saved "$TMP/saved.json" 'known($input[0];$saved[0]) | length > 0' >/dev/null; then
      return 0
    fi
  fi
  device=$(fm_pr_file_device "$STATE")
  fm_pr_regular_destination_on_device_or_absent "$STATE/contributions.check.sh" "$device" || fail 'unsafe check destination'
  staged=$(umask 077; mktemp "$STATE/.contributions-check.XXXXXX")
  printf '%s\n' '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")" \
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-contributions.sh") poll" > "$staged"
  chmod 700 "$staged"
  mv -f -- "$staged" "$STATE/contributions.check.sh"
  "$SCRIPT_DIR/fm-check-register.sh" contributions
}

case "${1:-}" in
  snapshot)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail 'snapshot needs canonical input'
    read_saved
    project "$2" "${3:-}"
    ;;
  poll) poll ;;
  arm) arm "${2:-}" ;;
  pending)
    read_saved
    [ "$ERRORS" -eq 0 ] || fail "$ERRORS unreadable contribution record(s); pending signals are unverified"
    jq '[.[] | .task as $task | .records[] | .url as $url | .pending[] | . + {task:$task,url:$url}]' "$TMP/saved.json"
    ;;
  verdict|ack)
    action=$1; shift
    [ "$#" -ge 3 ] || fail 'task, URL and evidence required'
    task=$1; url=$2; shift 2
    acquire; get_input; read_saved
    jq_lib -ne --slurpfile input "$TMP/input.json" --arg task "$task" --arg url "$url" --slurpfile saved "$TMP/saved.json" \
      'any(known($input[0];$saved[0])[]; .task == $task and .url == $url)' >/dev/null \
      || fail 'contribution is not owned by this durable task'
    jq -e --arg task "$task" --arg url "$url" '.[] | select(.task == $task) | .records[] | select(.url == $url)' "$TMP/saved.json" > "$TMP/row.json" \
      || fail 'observe the contribution before recording evidence'
    if [ "$action" = ack ]; then
      [ "$#" -eq 1 ] || fail 'ack needs one exact event token'
      jq --arg token "$1" '.pending |= map(select(.token != $token))' "$TMP/row.json" > "$TMP/update.json"
    else
      [ "$#" -eq 4 ] || fail 'verdict needs judged-head, source-url, actor and summary'
      fm_pr_head_valid "$1" || fail 'an exact judged commit is required'
      case "$3" in captain|fleet|maintainer|nobody) ;; *) fail 'invalid required actor' ;; esac
      case "$2" in "$url"\#*) ;; *) fail 'verdict source must be a comment or review on this contribution' ;; esac
      jq --arg head "$1" --arg source "$2" --arg actor "$3" --arg summary "$4" \
        '.verdict={head:$head,source:$source,actor:$actor,summary:$summary}' "$TMP/row.json" > "$TMP/update.json"
    fi
    write_record "$task" "$TMP/update.json"
    ;;
  *) usage >&2; exit 2 ;;
esac

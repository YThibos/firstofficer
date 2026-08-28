#!/usr/bin/env bash
# Record and verify the independent craftsmanship review that stands between
# validation and publication on a local-only delivery.
#
# The delivery contract is that a ship task validates through the no-mistakes
# pipeline with its publication and merge-request steps skipped, then stops for a
# reviewer that did not write the code, then publishes. Prose alone cannot make
# that middle stage unskippable, so publication is gated on a durable verdict:
# `verify` exits non-zero, with the concrete missing requirement named, until a
# `pass` verdict exists for the exact commit about to be published.
#
# The verdict is pinned to the reviewed commit, not to the task, so any commit
# made after the review - including a fix for the review's own findings -
# invalidates it and requires a fresh review. That is the whole point: an
# unreviewed commit can never reach the remote by outliving its verdict.
#
# The reviewer works in the implementing task's own worktree, so that one story
# keeps one checkout: independence comes from it being a separate agent that did not
# write the code, not from a separate directory. `record` therefore refuses a dirty
# tree, which is the evidence that the reviewer only read and that the implementer
# was idle rather than editing beside it.
#
# Which projects the review runs on is a per-home choice, because its cost falls
# on one captain's usage window while its value depends on what the project is.
# config/craft-review-projects (local, gitignored) enumerates the projects that
# require it, one literal name per non-empty, non-comment line. The boundary is
# by-project and hard-edged: a project is in the set or it is not, and there is
# no per-change judgement of triviality, because the moment such a rule has
# exceptions the exception becomes the path.
#
# The file being ABSENT means required everywhere, not nowhere. A home that has
# never configured this is a home that has said nothing, and the safe reading of
# silence about a safety step is that it still applies: absence must never be
# what quietly switches a gate off on a project that expects it. Narrowing the
# set is therefore always a deliberate, written act, and an empty file - all
# comments, no names - is how a home says "nowhere" out loud.
#
# The reviewer's remit lives in .agents/skills/craftsmanship-review/SKILL.md.
# This script owns only the record, the gate, and which projects it applies to.
#
# Usage: fm-craft-review.sh record <task-id> --reviewer <id> --verdict pass|findings [--findings <path>]
#        fm-craft-review.sh verify <task-id>
#        fm-craft-review.sh required <project-name>
#   record  writes state/<task-id>.craft-review for the commit currently on the
#           task's branch. --reviewer names the reviewing task or agent and must
#           differ from <task-id>, because a worker cannot review its own code.
#           --verdict findings records that the work is not publishable yet;
#           --findings points at the document holding them.
#           It refuses while the worktree is dirty, whichever agent wrote there.
#   verify  exits 0 only when a pass verdict is recorded for the commit the task
#           branch currently points at, OR when this home does not require the
#           review for that task's project. Every other state exits 1 and says why.
#   required exits 0 when <project-name> requires the review and 1 when it does
#           not, printing the reason either way; a malformed call exits 2, so
#           only a real answer can ever read as "no". Firstmate and
#           bin/fm-brief.sh ask this so a generated brief promises the stages
#           that will actually run.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SCOPE="$CONFIG/craft-review-projects"
# shellcheck source=bin/fm-task-branch-lib.sh
. "$SCRIPT_DIR/fm-task-branch-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# 0 when project $1 requires the craftsmanship review in this home.
# Names are compared literally: no prefix, glob, or category rule, so a project
# can never drift into or out of the set by being named like another one.
# A name that could not be resolved at all is treated as required, for the same
# reason an absent scope file is: not knowing is never a reason to drop a gate.
review_required() {
  local project=$1 line
  [ -n "$project" ] || return 0
  [ -f "$SCOPE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    [ "$line" = "$project" ] && return 0
  done < "$SCOPE"
  return 1
}

report_required() {
  local project=$1
  if review_required "$project"; then
    if [ -f "$SCOPE" ]; then
      echo "craftsmanship review is required for $project"
    else
      echo "craftsmanship review is required for $project (no $SCOPE, so it applies everywhere)"
    fi
    return 0
  fi
  echo "craftsmanship review is not required for $project (not listed in $SCOPE)"
  return 1
}

# The project a task belongs to, by the name its registry and delivery mode use:
# the basename of the project= path in its durable record.
task_project() {
  local id=$1 meta project
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || { echo "error: no durable record for task $id at $meta" >&2; return 1; }
  project=$(grep '^project=' "$meta" | tail -1 | cut -d= -f2-)
  [ -n "$project" ] || { echo "error: durable record for task $id has no project=" >&2; return 1; }
  basename "$project"
}

record_review() {
  local id=$1 reviewer=$2 verdict=$3 findings=$4 wt commit

  reject_unusable_verdict "$verdict" || return 1
  reject_self_review "$id" "$reviewer" || return 1
  wt=$(task_worktree "$id") || return 1
  commit=$(reviewed_commit "$id" "$wt") || return 1
  reject_dirty_worktree "$id" "$wt" || return 1
  write_verdict "$id" "$reviewer" "$verdict" "$findings" "$commit"
  echo "recorded craftsmanship review for $id: $verdict at $commit"
}

reject_unusable_verdict() {
  local verdict=$1
  case "$verdict" in
    pass|findings) return 0 ;;
  esac
  echo "error: --verdict must be pass or findings, not \"$verdict\"" >&2
  return 1
}

reject_self_review() {
  local id=$1 reviewer=$2
  [ "$reviewer" = "$id" ] || return 0
  echo "error: reviewer \"$reviewer\" is the task under review; the craftsmanship review must come from an agent that did not write the code" >&2
  return 1
}

# Resolve the commit a verdict applies to: the tip of the branch the task's own
# worktree has checked out. A detached worktree has no branch to publish, so
# fm_task_branch refusing here is the correct outcome, not an obstacle.
reviewed_commit() {
  local id=$1 wt=$2 branch
  branch=$(fm_task_branch "$id" "$wt" "$wt") || return 1
  git -C "$wt" rev-parse --verify --quiet "refs/heads/$branch^{commit}" \
    || { echo "error: branch $branch in $wt has no commit to review" >&2; return 1; }
}

task_worktree() {
  local id=$1 meta wt
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || { echo "error: no durable record for task $id at $meta" >&2; return 1; }
  wt=$(grep '^worktree=' "$meta" | cut -d= -f2-)
  [ -n "$wt" ] || { echo "error: durable record for task $id has no worktree=" >&2; return 1; }
  [ -d "$wt" ] || { echo "error: worktree for task $id is missing: $wt" >&2; return 1; }
  printf '%s\n' "$wt"
}

# The reviewer works in the implementing task's own worktree, so a clean tree at
# record time is the evidence that co-location stayed safe: it proves the reviewer
# reported findings instead of editing, and that the implementer was idle rather
# than working in the same directory at the same time.
reject_dirty_worktree() {
  local id=$1 wt=$2 dirty
  dirty=$(uncommitted_changes "$wt")
  [ -n "$dirty" ] || return 0
  echo "REFUSED: the worktree of task $id has uncommitted changes, so this review cannot be recorded." >&2
  printf '%s\n' "$dirty" >&2
  echo "A review never edits the code and the implementing worker must be idle while it runs. Find out which of the two wrote here before recording any verdict." >&2
  return 1
}

# Agent-owned files never belong to the change under review, so they are not
# evidence that anyone edited it. The exemption list matches bin/fm-teardown.sh's.
uncommitted_changes() {
  local wt=$1
  git -C "$wt" status --porcelain 2>/dev/null \
    | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' | head -3 || true
}

write_verdict() {
  local id=$1 reviewer=$2 verdict=$3 findings=$4 commit=$5
  mkdir -p "$STATE"
  {
    printf 'verdict=%s\n' "$verdict"
    printf 'commit=%s\n' "$commit"
    printf 'reviewer=%s\n' "$reviewer"
    printf 'recorded=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ -n "$findings" ]; then printf 'findings=%s\n' "$findings"; fi
  } > "$STATE/$id.craft-review"
}

verify_review() {
  local id=$1 wt commit record verdict passed_commit project

  # A project this home does not review has no reviewer and no verdict to wait
  # for, so the gate stands aside and publication proceeds. A record that cannot
  # name its project is not evidence of that, and keeps the gate.
  project=$(task_project "$id") || return 1
  if ! review_required "$project"; then
    echo "craftsmanship review is not required for $project; nothing gates publication of $id"
    return 0
  fi

  wt=$(task_worktree "$id") || return 1
  commit=$(reviewed_commit "$id" "$wt") || return 1
  record="$STATE/$id.craft-review"
  if [ ! -f "$record" ]; then
    echo "REFUSED: task $id has no craftsmanship review; commit $commit is unreviewed and must not be published." >&2
    echo "Have an agent that did not write the code review it, then record the verdict with fm-craft-review.sh record." >&2
    return 1
  fi

  verdict=$(recorded_field "$record" verdict)
  if [ "$verdict" != pass ]; then
    echo "REFUSED: the craftsmanship review of task $id returned findings, not a pass." >&2
    echo "Fix them on the branch, then have the reviewer re-review the new commit." >&2
    return 1
  fi

  passed_commit=$(recorded_field "$record" commit)
  if [ "$passed_commit" != "$commit" ]; then
    echo "REFUSED: the craftsmanship review of task $id passed commit $passed_commit, but the branch is now at $commit." >&2
    echo "The commits made since that review are unreviewed; have the reviewer re-review before publishing." >&2
    return 1
  fi

  echo "craftsmanship review passed for $id at $commit"
}

recorded_field() {
  local record=$1 key=$2
  grep "^$key=" "$record" | tail -1 | cut -d= -f2-
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

ACTION=${1:-}
ID=${2:-}

# `required` takes a project name rather than a task id and reads no task state,
# so it answers before the task-shaped argument handling below - including that
# handling's own exit 1, which is this action's answer "no". Every malformed
# call exits 2 instead, a missing or empty project name among them: a caller
# that read a failed question as a no would drop the review on it.
if [ "$ACTION" = required ]; then
  [ -n "$ID" ] || { echo "error: required takes a project name" >&2; exit 2; }
  [ "$#" -le 2 ] || { echo "error: required takes only a project name" >&2; exit 2; }
  report_required "$ID"
  exit $?
fi

[ -n "$ACTION" ] && [ -n "$ID" ] || { usage >&2; exit 1; }
shift 2

REVIEWER=""
VERDICT=""
FINDINGS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reviewer) shift; [ "$#" -gt 0 ] || { echo "error: --reviewer requires a value" >&2; exit 1; }; REVIEWER=$1; shift ;;
    --verdict) shift; [ "$#" -gt 0 ] || { echo "error: --verdict requires a value" >&2; exit 1; }; VERDICT=$1; shift ;;
    --findings) shift; [ "$#" -gt 0 ] || { echo "error: --findings requires a value" >&2; exit 1; }; FINDINGS=$1; shift ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$ACTION" in
  record)
    [ -n "$REVIEWER" ] || { echo "error: record requires --reviewer <id>" >&2; exit 1; }
    [ -n "$VERDICT" ] || { echo "error: record requires --verdict pass|findings" >&2; exit 1; }
    record_review "$ID" "$REVIEWER" "$VERDICT" "$FINDINGS"
    ;;
  verify)
    if [ -n "$REVIEWER" ] || [ -n "$VERDICT" ] || [ -n "$FINDINGS" ]; then
      echo "error: verify reads the recorded verdict and takes no flags" >&2
      exit 1
    fi
    verify_review "$ID"
    ;;
  *)
    echo "error: unknown action \"$ACTION\"; expected record, verify, or required" >&2
    exit 1
    ;;
esac

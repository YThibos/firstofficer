#!/usr/bin/env bash
# Merge the original upstream project into this fork, safely and repeatably.
#
# Mechanical half of the /updatefirstofficer skill. This fork tracks
# kunchenguid/firstmate on the `upstream` remote while carrying its own
# divergence, so keeping current is a real merge, not the fast-forward
# /updatefirstmate (bin/fm-update.sh) performs from origin. The two are
# separate commands with separate jobs: fm-update.sh moves this home and its
# secondmate homes to what already landed on origin, and this script is what
# puts new upstream work onto origin in the first place.
#
# NEVER PUSHES TO UPSTREAM. The only push target this script will accept is
# `origin`; push_remote() refuses any other remote before git is invoked, and
# upstream is touched by `git fetch` alone. It also never forces, never
# stashes, and never discards unlanded work: every refusal below leaves the
# working tree exactly as it found it.
#
# Subcommands:
#   preflight   Fetch upstream, report whether there is anything to sync, and
#               print the empirical fork-drift set. Creates nothing.
#   merge       Create upstream-update/<YYYY-MM-DD> off the default branch and
#               merge the upstream default branch into it, classifying every
#               conflict. A no-op sync creates no branch.
#   land        Validate the merged sync branch and, only when validation is
#               green, fast-forward the default branch onto it and push both to
#               origin. This is the autonomous clean-merge path.
#   abort       Undo an in-progress merge and return to the default branch,
#               deleting the sync branch only when it carries no commits.
#
# CAPTAIN-DECISION PATHS (declared below in captain_decision_paths, validated
# empirically on every run): a conflict in one of these is never resolved by an
# agent, because the file differs from upstream by the captain's explicit
# choice. Every other conflict is ordinary fork divergence an agent may resolve
# once it understands how the two behaviours combine. "Validated empirically"
# means each declared path is checked against the real diff between the merge
# base and this fork's HEAD, and reported as `stale` when it no longer drifts,
# so the declaration can never quietly outlive the drift it describes.
#
# AGENTS.md gets a second, conflict-free trigger: it can merge cleanly and
# still need the captain, because tests/fm-anchor-budget.test.sh pins the
# AGENTS.md revision whose rules are reconciled into CLAUDE.md. `merge`
# therefore reports whether AGENTS.md moved at all, so the skill can surface the
# specific upstream rule changes for the captain rather than invent anchor
# wording.
#
# Repo under sync: FM_ROOT_OVERRIDE, else this script's own repo root. The
# validation `land` runs comes from that repo's own bin/ (fm-lint.sh, then
# fm-test-run.sh --all), so it always validates the tree it is about to land.
#
# Conflicts are an expected outcome, not a script failure: `merge` exits 0 and
# says what conflicted and who owns it. A non-zero exit always means the script
# refused to act or could not, and never that it acted partially.
#
# Usage: fm-upstream-sync.sh <preflight|merge|land|abort> [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
UPSTREAM_REMOTE=upstream
PUSH_REMOTE=origin
SYNC_BRANCH_PREFIX=upstream-update

usage() {
  cat >&2 <<'USAGE'
usage: fm-upstream-sync.sh <subcommand>

  preflight   fetch upstream and report what a sync would do (creates nothing)
  merge       create upstream-update/<YYYY-MM-DD> and merge upstream into it
  land        validate the merged sync branch, then land it and push to origin
  abort       undo an in-progress merge and return to the default branch

Never pushes to upstream, never forces, never discards unlanded work.
A conflict in one of these is a captain decision, never an agent's:
USAGE
  captain_decision_paths | sed 's/^/  /' >&2
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
refuse() { printf '%s: refused - %s\n' "$1" "$2" >&2; exit 1; }

git_repo() { git -C "$REPO" "$@"; }

# The one push chokepoint. Anything but origin is a bug, and upstream in
# particular is unpushable by design, so refuse before git ever runs.
push_remote() {
  local remote=$1
  shift
  [ "$remote" = "$PUSH_REMOTE" ] \
    || die "refusing to push to '$remote'; this script pushes only to $PUSH_REMOTE"
  git_repo push "$remote" "$@"
}

# Declared captain-decision paths, one tab-separated "<path><TAB><reason>" per
# line. Adding one is itself a captain decision: it says a file differs from
# upstream because the captain wanted it different, and no agent may reconcile
# it. report_declared_drift() checks every entry against the real drift.
captain_decision_paths() {
  cat <<'PATHS'
CLAUDE.md	fork-owned operating anchor that replaced upstream's symlink
AGENTS.md	upstream contract whose rule changes are reconciled into the anchor by hand
PATHS
}

# captain_decision_reason <path>: echo the declared reason and return 0, or
# return 1 when the path is ordinary fork divergence.
captain_decision_reason() {
  local want=$1 path reason
  while IFS=$'\t' read -r path reason; do
    [ "$path" = "$want" ] || continue
    printf '%s\n' "$reason"
    return 0
  done <<PATHS
$(captain_decision_paths)
PATHS
  return 1
}

default_branch() {
  local ref branch
  ref=$(git_repo symbolic-ref --quiet --short "refs/remotes/$PUSH_REMOTE/HEAD" 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#"$PUSH_REMOTE"/}"
    return 0
  fi
  for branch in main master; do
    if git_repo show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

upstream_default_branch() {
  local ref branch
  ref=$(git_repo symbolic-ref --quiet --short "refs/remotes/$UPSTREAM_REMOTE/HEAD" 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#"$UPSTREAM_REMOTE"/}"
    return 0
  fi
  for branch in main master; do
    if git_repo show-ref --verify --quiet "refs/remotes/$UPSTREAM_REMOTE/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

sync_branch_name() { printf '%s/%s\n' "$SYNC_BRANCH_PREFIX" "$(date +%Y-%m-%d)"; }

current_branch() { git_repo symbolic-ref --quiet --short HEAD 2>/dev/null || printf '\n'; }

working_tree_dirty() {
  [ -n "$(git_repo status --porcelain 2>/dev/null | head -1)" ]
}

# --absolute-git-dir, because `git -C <repo> rev-parse --git-dir` answers
# relative to <repo> and would be read against this script's own directory.
merge_in_progress() {
  [ -e "$(git_repo rev-parse --absolute-git-dir)/MERGE_HEAD" ]
}

require_upstream_remote() {
  git_repo remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 \
    || die "no '$UPSTREAM_REMOTE' remote in $REPO; this fork has nothing to sync from"
}

# Empirical fork drift: paths this fork changed relative to the merge base with
# upstream. This is what makes the declared captain-decision list checkable
# instead of merely asserted.
fork_drift_paths() {
  local base=$1
  git_repo diff --name-only "$base" HEAD
}

report_declared_drift() {
  local base=$1 drift path reason state
  drift=$(fork_drift_paths "$base")
  while IFS=$'\t' read -r path reason; do
    if printf '%s\n' "$drift" | grep -Fxq -- "$path"; then
      state=present
    else
      state=stale
    fi
    printf 'declared-drift: %s %s - %s\n' "$path" "$state" "$reason"
  done <<PATHS
$(captain_decision_paths)
PATHS
}

# AGENTS.md moving means tests/fm-anchor-budget.test.sh will fail until the
# rule-bearing changes are reconciled into CLAUDE.md and its pin bumped, which
# is a captain decision even when the merge itself was clean.
report_agents_md() {
  local before=$1 after=$2
  if [ "$before" = "$after" ]; then
    printf 'agents-md: unchanged\n'
  else
    printf 'agents-md: changed %s..%s captain-decision - anchor reconciliation and pin bump\n' \
      "$before" "$after"
  fi
}

# The repo's own validation, run from the repo being landed rather than from
# this script's checkout, so `land` can never green-light a different tree.
run_validation() {
  if ! ( cd "$REPO" && "$REPO/bin/fm-lint.sh" ); then
    printf 'validate: lint failed\n'
    return 1
  fi
  printf 'validate: lint ok\n'
  if ! ( cd "$REPO" && "$REPO/bin/fm-test-run.sh" --all ); then
    printf 'validate: tests failed\n'
    return 1
  fi
  printf 'validate: tests ok\n'
}

# --- subcommands -----------------------------------------------------------

cmd_preflight() {
  local default up_branch up_head base incoming drift

  require_upstream_remote
  default=$(default_branch) \
    || die "cannot determine this fork's default branch in $REPO"
  if [ "$(current_branch)" != "$default" ]; then
    refuse preflight "$REPO is on '$(current_branch)', expected the default branch '$default'"
  fi
  if working_tree_dirty; then
    refuse preflight "$REPO has uncommitted changes; commit or set them aside first"
  fi

  git_repo fetch --quiet "$UPSTREAM_REMOTE" \
    || die "could not fetch $UPSTREAM_REMOTE; check network access and the remote URL"
  up_branch=$(upstream_default_branch) \
    || die "cannot determine the $UPSTREAM_REMOTE default branch"
  up_head=$(git_repo rev-parse "$UPSTREAM_REMOTE/$up_branch")
  base=$(git_repo merge-base HEAD "$UPSTREAM_REMOTE/$up_branch") \
    || die "no common history with $UPSTREAM_REMOTE/$up_branch"
  incoming=$(git_repo rev-list --count "HEAD..$UPSTREAM_REMOTE/$up_branch")

  printf 'repo: %s\n' "$REPO"
  printf 'default-branch: %s\n' "$default"
  printf 'upstream-branch: %s/%s\n' "$UPSTREAM_REMOTE" "$up_branch"
  printf 'upstream-head: %s\n' "$up_head"
  printf 'merge-base: %s\n' "$base"
  printf 'incoming-commits: %s\n' "$incoming"

  fork_drift_paths "$base" | while IFS= read -r drift; do
    [ -n "$drift" ] || continue
    printf 'drift: %s\n' "$drift"
  done
  report_declared_drift "$base"

  if [ "$incoming" -eq 0 ]; then
    printf 'up-to-date: yes\n'
    printf 'preflight: nothing to sync; %s/%s is already merged\n' "$UPSTREAM_REMOTE" "$up_branch"
    return 0
  fi
  printf 'up-to-date: no\n'
  printf 'sync-branch: %s\n' "$(sync_branch_name)"
  printf 'preflight: ok\n'
}

cmd_merge() {
  local default up_branch up_head incoming branch agents_before agents_after base
  local conflicts captain_n=0 agent_n=0 total=0 path reason merge_log merge_rc

  require_upstream_remote
  default=$(default_branch) \
    || die "cannot determine this fork's default branch in $REPO"
  if merge_in_progress; then
    refuse merge "a merge is already in progress in $REPO; finish it or run 'abort'"
  fi
  if [ "$(current_branch)" != "$default" ]; then
    refuse merge "$REPO is on '$(current_branch)', expected the default branch '$default'"
  fi
  if working_tree_dirty; then
    refuse merge "$REPO has uncommitted changes; commit or set them aside first"
  fi

  git_repo fetch --quiet "$UPSTREAM_REMOTE" \
    || die "could not fetch $UPSTREAM_REMOTE; check network access and the remote URL"
  up_branch=$(upstream_default_branch) \
    || die "cannot determine the $UPSTREAM_REMOTE default branch"
  up_head=$(git_repo rev-parse "$UPSTREAM_REMOTE/$up_branch")
  base=$(git_repo merge-base HEAD "$UPSTREAM_REMOTE/$up_branch") \
    || die "no common history with $UPSTREAM_REMOTE/$up_branch"
  incoming=$(git_repo rev-list --count "HEAD..$UPSTREAM_REMOTE/$up_branch")
  report_declared_drift "$base"

  # A no-op sync reports plainly and creates no branch.
  if [ "$incoming" -eq 0 ]; then
    printf 'up-to-date: yes\n'
    printf 'merge: nothing to sync; %s/%s is already merged, no branch created\n' \
      "$UPSTREAM_REMOTE" "$up_branch"
    return 0
  fi

  branch=$(sync_branch_name)
  if git_repo show-ref --verify --quiet "refs/heads/$branch"; then
    if [ "$(git_repo rev-parse "$branch")" != "$(git_repo rev-parse "$default")" ]; then
      refuse merge "$branch already exists and carries work; land, abort, or rename it first"
    fi
    git_repo checkout --quiet "$branch"
  else
    git_repo checkout --quiet -b "$branch"
  fi

  agents_before=$(git_repo rev-parse "HEAD:AGENTS.md" 2>/dev/null || printf 'absent\n')

  printf 'sync-branch: %s\n' "$branch"
  printf 'merged-from: %s/%s %s\n' "$UPSTREAM_REMOTE" "$up_branch" "$up_head"

  merge_log=$(git_repo merge --no-edit "$UPSTREAM_REMOTE/$up_branch" 2>&1) && merge_rc=0 || merge_rc=$?
  if [ "$merge_rc" -eq 0 ]; then
    agents_after=$(git_repo rev-parse "HEAD:AGENTS.md" 2>/dev/null || printf 'absent\n')
    report_agents_md "$agents_before" "$agents_after"
    printf 'merge: clean\n'
    return 0
  fi

  conflicts=$(git_repo diff --name-only --diff-filter=U)
  if [ -z "$conflicts" ]; then
    printf '%s\n' "$merge_log" >&2
    refuse merge "the merge failed without conflicts; inspect $REPO by hand"
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    total=$((total + 1))
    if reason=$(captain_decision_reason "$path"); then
      captain_n=$((captain_n + 1))
      printf 'conflict: %s captain-decision - %s\n' "$path" "$reason"
    else
      agent_n=$((agent_n + 1))
      printf 'conflict: %s agent-resolve\n' "$path"
    fi
  done <<EOF
$conflicts
EOF
  # Report the incoming AGENTS.md even mid-conflict, so the anchor consequence
  # is visible without waiting for the merge to be committed.
  agents_after=$(git_repo rev-parse "$UPSTREAM_REMOTE/$up_branch:AGENTS.md" 2>/dev/null || printf 'absent\n')
  report_agents_md "$agents_before" "$agents_after"
  printf 'merge: conflicts %s captain-decision=%s agent-resolve=%s\n' \
    "$total" "$captain_n" "$agent_n"
  return 0
}

cmd_land() {
  local default branch up_branch up_head before after

  require_upstream_remote
  default=$(default_branch) \
    || die "cannot determine this fork's default branch in $REPO"
  branch=$(current_branch)

  case "$branch" in
    "$SYNC_BRANCH_PREFIX"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) refuse land "$REPO is on '$branch', not a dated $SYNC_BRANCH_PREFIX/<date> sync branch" ;;
  esac
  if merge_in_progress; then
    refuse land "the upstream merge is still in progress; resolve it and commit before landing"
  fi
  if working_tree_dirty; then
    refuse land "$REPO has uncommitted changes; commit the resolved merge before landing"
  fi

  up_branch=$(upstream_default_branch) \
    || die "cannot determine the $UPSTREAM_REMOTE default branch"
  up_head=$(git_repo rev-parse "$UPSTREAM_REMOTE/$up_branch")
  if ! git_repo merge-base --is-ancestor "$up_head" HEAD; then
    refuse land "$branch does not contain $UPSTREAM_REMOTE/$up_branch; it is not a completed sync"
  fi
  if ! git_repo merge-base --is-ancestor "$default" HEAD; then
    refuse land "$default is not an ancestor of $branch; rebuild the sync on the current $default"
  fi
  # Cheap checks all happen before validation, so a stale sync fails in seconds
  # rather than after a full suite run.
  git_repo fetch --quiet "$PUSH_REMOTE" \
    || die "could not fetch $PUSH_REMOTE; check network access and the remote URL"
  if git_repo show-ref --verify --quiet "refs/remotes/$PUSH_REMOTE/$default" \
    && ! git_repo merge-base --is-ancestor "$PUSH_REMOTE/$default" HEAD; then
    refuse land "$PUSH_REMOTE/$default has moved past this sync; rebuild it on the current $default"
  fi

  # Green before landing. The autonomous path stops here on anything red.
  if ! run_validation; then
    refuse land "validation is red; nothing was landed or pushed"
  fi

  before=$(git_repo rev-parse --short "$default")
  push_remote "$PUSH_REMOTE" "$branch:refs/heads/$branch"
  git_repo checkout --quiet "$default"
  git_repo merge --ff-only --quiet "$branch"
  push_remote "$PUSH_REMOTE" "$default:refs/heads/$default"
  after=$(git_repo rev-parse --short "$default")

  printf 'landed: %s %s..%s\n' "$default" "$before" "$after"
  printf 'pushed: %s %s and %s\n' "$PUSH_REMOTE" "$branch" "$default"
}

cmd_abort() {
  local default branch

  default=$(default_branch) \
    || die "cannot determine this fork's default branch in $REPO"
  branch=$(current_branch)

  if merge_in_progress; then
    git_repo merge --abort
    printf 'abort: upstream merge aborted\n'
  fi
  if working_tree_dirty; then
    refuse abort "$REPO still has uncommitted changes; nothing was discarded"
  fi

  case "$branch" in
    "$SYNC_BRANCH_PREFIX"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *)
      printf 'abort: %s is not a dated %s/<date> sync branch; left as is\n' "$branch" "$SYNC_BRANCH_PREFIX"
      return 0
      ;;
  esac

  git_repo checkout --quiet "$default"
  # -d, never -D: a sync branch that carries commits is unlanded work and stays.
  if git_repo branch -d "$branch" >/dev/null 2>&1; then
    printf 'abort: back on %s, empty %s deleted\n' "$default" "$branch"
  else
    printf 'abort: back on %s, %s kept because it carries commits\n' "$default" "$branch"
  fi
}

# --- entry point -----------------------------------------------------------

case "${1:-}" in
  preflight) cmd_preflight ;;
  merge) cmd_merge ;;
  land) cmd_land ;;
  abort) cmd_abort ;;
  --help|-h) usage; exit 0 ;;
  *) usage; exit 1 ;;
esac

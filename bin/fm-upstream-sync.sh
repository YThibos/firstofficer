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
# NEVER MERGES IN THE PRIMARY CHECKOUT. A running firstmate loads its skills
# and runs its hooks from the repo under sync, so a half-merged tree there
# would corrupt the live session for every turn spent resolving conflicts.
# `merge` therefore does all its work in an isolated sync copy: a git worktree
# of this repo at <repo>-upstream-sync, a sibling directory outside the
# primary checkout. The primary checkout's branch, HEAD, and working tree are
# never touched, conflicts are resolved in the sync copy, and bringing the
# primary checkout current after a landing stays /updatefirstmate's
# fast-forward. Only one sync copy exists at a time: while it does, `merge`
# refuses rather than creating a second or clobbering the first.
#
# Subcommands:
#   preflight   Fetch upstream, report whether there is anything to sync, and
#               print the empirical fork-drift set. Creates nothing.
#   merge       Create upstream-update/<YYYY-MM-DD> off the default branch in a
#               new sync copy, merge the upstream default branch into it there,
#               and classify every conflict. Prints `sync-copy: <path>`, the
#               directory where conflicts are resolved and the merge committed.
#               A no-op sync creates no branch and no sync copy.
#   land        Validate the merged sync branch in the sync copy and, only when
#               validation is green, push it to origin and fast-forward origin's
#               default branch onto it, then remove the sync copy. This is the
#               autonomous clean-merge path.
#   abort       Undo an in-progress merge and remove the sync copy, deleting the
#               sync branch only when it carries no commits.
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
# validation `land` runs comes from the sync copy's own bin/ (fm-lint.sh, then
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
SYNC_COPY="$REPO-upstream-sync"
UPSTREAM_REMOTE=upstream
PUSH_REMOTE=origin
SYNC_BRANCH_PREFIX=upstream-update

usage() {
  cat >&2 <<'USAGE'
usage: fm-upstream-sync.sh <subcommand>

  preflight   fetch upstream and report what a sync would do (creates nothing)
  merge       create upstream-update/<YYYY-MM-DD> in the sync copy and merge
              upstream into it there; prints the sync copy's path
  land        validate the sync copy, then push it and fast-forward origin's
              default branch onto it; removes the sync copy
  abort       undo an in-progress merge and remove the sync copy

The sync copy is a git worktree at <repo>-upstream-sync, outside the primary
checkout, which the sync never changes; resolve conflicts in the sync copy.
Never pushes to upstream, never forces, never discards unlanded work.
A conflict in one of these is a captain decision, never an agent's:
USAGE
  captain_decision_paths | sed 's/^/  /' >&2
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
refuse() { printf '%s: refused - %s\n' "$1" "$2" >&2; exit 1; }

git_repo() { git -C "$REPO" "$@"; }
git_copy() { git -C "$SYNC_COPY" "$@"; }

# The one push chokepoint. Anything but origin is a bug, and upstream in
# particular is unpushable by design, so refuse before git ever runs.
push_remote() {
  local remote=$1
  shift
  [ "$remote" = "$PUSH_REMOTE" ] \
    || die "refusing to push to '$remote'; this script pushes only to $PUSH_REMOTE"
  git_copy push "$remote" "$@"
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

is_sync_branch() {
  case "$1" in
    "$SYNC_BRANCH_PREFIX"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# current_branch [dir]: the checked-out branch of the primary checkout, or of
# the given directory.
current_branch() { git -C "${1:-$REPO}" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '\n'; }

working_tree_dirty() {
  [ -n "$(git -C "${1:-$REPO}" status --porcelain 2>/dev/null | head -1)" ]
}

# --absolute-git-dir, because `git -C <repo> rev-parse --git-dir` answers
# relative to <repo> and would be read against this script's own directory. In
# the sync copy it resolves to that worktree's own git dir, as it must.
merge_in_progress() {
  [ -e "$(git -C "${1:-$REPO}" rev-parse --absolute-git-dir)/MERGE_HEAD" ]
}

# The sync copy counts only when it is a worktree of this very repo, so a
# stray directory at that path is never merged into, landed, or removed.
require_sync_copy() {
  local cmd=$1 mine theirs
  [ -e "$SYNC_COPY" ] \
    || refuse "$cmd" "no upstream sync copy at $SYNC_COPY; run 'merge' first"
  mine=$(git_repo rev-parse --path-format=absolute --git-common-dir)
  theirs=$(git_copy rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  [ "$mine" = "$theirs" ] \
    || refuse "$cmd" "$SYNC_COPY is not a worktree of $REPO; move it aside by hand"
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

# The sync copy's own validation, run from the tree being landed rather than
# from this script's checkout, so `land` can never green-light a different tree.
run_validation() {
  if ! ( cd "$SYNC_COPY" && "$SYNC_COPY/bin/fm-lint.sh" ); then
    printf 'validate: lint failed\n'
    return 1
  fi
  printf 'validate: lint ok\n'
  if ! ( cd "$SYNC_COPY" && "$SYNC_COPY/bin/fm-test-run.sh" --all ); then
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
  git_repo show-ref --verify --quiet "refs/heads/$default" \
    || die "no local '$default' branch in $REPO to base the sync on"
  if [ -e "$SYNC_COPY" ]; then
    refuse merge "an upstream sync copy already exists at $SYNC_COPY; land or abort it first"
  fi

  git_repo fetch --quiet "$UPSTREAM_REMOTE" \
    || die "could not fetch $UPSTREAM_REMOTE; check network access and the remote URL"
  up_branch=$(upstream_default_branch) \
    || die "cannot determine the $UPSTREAM_REMOTE default branch"
  up_head=$(git_repo rev-parse "$UPSTREAM_REMOTE/$up_branch")
  base=$(git_repo merge-base "$default" "$UPSTREAM_REMOTE/$up_branch") \
    || die "no common history with $UPSTREAM_REMOTE/$up_branch"
  incoming=$(git_repo rev-list --count "$default..$UPSTREAM_REMOTE/$up_branch")
  report_declared_drift "$base"

  # A no-op sync reports plainly and creates no branch and no sync copy.
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
    git_repo worktree add --quiet "$SYNC_COPY" "$branch" \
      || die "could not create the sync copy at $SYNC_COPY"
  else
    git_repo worktree add --quiet -b "$branch" "$SYNC_COPY" "$default" \
      || die "could not create the sync copy at $SYNC_COPY"
  fi

  agents_before=$(git_copy rev-parse "HEAD:AGENTS.md" 2>/dev/null || printf 'absent\n')

  printf 'sync-branch: %s\n' "$branch"
  printf 'sync-copy: %s\n' "$SYNC_COPY"
  printf 'merged-from: %s/%s %s\n' "$UPSTREAM_REMOTE" "$up_branch" "$up_head"

  merge_log=$(git_copy merge --no-edit "$UPSTREAM_REMOTE/$up_branch" 2>&1) && merge_rc=0 || merge_rc=$?
  if [ "$merge_rc" -eq 0 ]; then
    agents_after=$(git_copy rev-parse "HEAD:AGENTS.md" 2>/dev/null || printf 'absent\n')
    report_agents_md "$agents_before" "$agents_after"
    printf 'merge: clean\n'
    return 0
  fi

  conflicts=$(git_copy diff --name-only --diff-filter=U)
  if [ -z "$conflicts" ]; then
    printf '%s\n' "$merge_log" >&2
    refuse merge "the merge failed without conflicts; inspect $SYNC_COPY by hand"
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
  printf 'merge: resolve and commit in %s, then run land\n' "$SYNC_COPY"
  return 0
}

cmd_land() {
  local default branch up_branch up_head before after

  require_upstream_remote
  default=$(default_branch) \
    || die "cannot determine this fork's default branch in $REPO"
  require_sync_copy land
  branch=$(current_branch "$SYNC_COPY")

  is_sync_branch "$branch" \
    || refuse land "$SYNC_COPY is on '$branch', not a dated $SYNC_BRANCH_PREFIX/<date> sync branch"
  if merge_in_progress "$SYNC_COPY"; then
    refuse land "the upstream merge is still in progress; resolve it and commit before landing"
  fi
  if working_tree_dirty "$SYNC_COPY"; then
    refuse land "$SYNC_COPY has uncommitted changes; commit the resolved merge before landing"
  fi

  up_branch=$(upstream_default_branch) \
    || die "cannot determine the $UPSTREAM_REMOTE default branch"
  up_head=$(git_repo rev-parse "$UPSTREAM_REMOTE/$up_branch")
  if ! git_copy merge-base --is-ancestor "$up_head" HEAD; then
    refuse land "$branch does not contain $UPSTREAM_REMOTE/$up_branch; it is not a completed sync"
  fi
  if ! git_copy merge-base --is-ancestor "$default" HEAD; then
    refuse land "$default is not an ancestor of $branch; rebuild the sync on the current $default"
  fi
  # Cheap checks all happen before validation, so a stale sync fails in seconds
  # rather than after a full suite run.
  git_repo fetch --quiet "$PUSH_REMOTE" \
    || die "could not fetch $PUSH_REMOTE; check network access and the remote URL"
  if git_repo show-ref --verify --quiet "refs/remotes/$PUSH_REMOTE/$default" \
    && ! git_copy merge-base --is-ancestor "$PUSH_REMOTE/$default" HEAD; then
    refuse land "$PUSH_REMOTE/$default has moved past this sync; rebuild it on the current $default"
  fi

  # Green before landing. The autonomous path stops here on anything red.
  if ! run_validation; then
    refuse land "validation is red; nothing was landed or pushed"
  fi

  # Pushing the sync branch onto origin's default branch without force is a
  # fast-forward or a rejection, never a rewrite. The primary checkout is not
  # touched; /updatefirstmate fast-forwards it from origin afterwards.
  before=$(git_repo rev-parse --short "refs/remotes/$PUSH_REMOTE/$default" 2>/dev/null || printf 'none\n')
  push_remote "$PUSH_REMOTE" --quiet "$branch:refs/heads/$branch"
  push_remote "$PUSH_REMOTE" --quiet "$branch:refs/heads/$default"
  after=$(git_copy rev-parse --short HEAD)

  printf 'landed: %s/%s %s..%s\n' "$PUSH_REMOTE" "$default" "$before" "$after"
  printf 'pushed: %s %s and %s\n' "$PUSH_REMOTE" "$branch" "$default"
  # The sync branch now lives on origin, so the disposable copy can go; a plain
  # remove refuses rather than discarding anything unexpected.
  if git_repo worktree remove "$SYNC_COPY"; then
    printf 'sync-copy: removed %s\n' "$SYNC_COPY"
  else
    printf 'sync-copy: kept %s; remove it by hand once inspected\n' "$SYNC_COPY"
  fi
}

cmd_abort() {
  local branch

  default_branch >/dev/null \
    || die "cannot determine this fork's default branch in $REPO"
  if [ ! -e "$SYNC_COPY" ]; then
    printf 'abort: no upstream sync copy at %s; nothing to undo\n' "$SYNC_COPY"
    return 0
  fi
  require_sync_copy abort
  branch=$(current_branch "$SYNC_COPY")

  if merge_in_progress "$SYNC_COPY"; then
    git_copy merge --abort
    printf 'abort: upstream merge aborted\n'
  fi
  if working_tree_dirty "$SYNC_COPY"; then
    refuse abort "$SYNC_COPY still has uncommitted changes; nothing was discarded"
  fi

  git_repo worktree remove "$SYNC_COPY" \
    || refuse abort "could not remove the sync copy at $SYNC_COPY; nothing was discarded"
  printf 'abort: sync copy %s removed\n' "$SYNC_COPY"

  if ! is_sync_branch "$branch"; then
    printf 'abort: %s is not a dated %s/<date> sync branch; left as is\n' "$branch" "$SYNC_BRANCH_PREFIX"
    return 0
  fi
  # -d, never -D: a sync branch that carries commits is unlanded work and stays.
  if git_repo branch -d "$branch" >/dev/null 2>&1; then
    printf 'abort: empty %s deleted\n' "$branch"
  else
    printf 'abort: %s kept because it carries commits\n' "$branch"
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

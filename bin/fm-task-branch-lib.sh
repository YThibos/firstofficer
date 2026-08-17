# shellcheck shell=bash
# Shared resolution of "which branch holds this task's work?".
# Usage: . bin/fm-task-branch-lib.sh
#        BRANCH=$(fm_task_branch "$ID" "$WT" "$REPO") || exit 1
#
# firstmate never creates a task branch: the crewmate does, as its first action,
# using whatever name the project's convention requires. The captain's projects
# name every local-only branch after its JIRA ticket (feature/<KEY>-N,
# chore/<KEY>-N, research/<KEY>-N), so the internal fm/<id> naming firstmate once
# generated is retired and no current task creates it. Nothing writes the chosen
# name back, so state/<id>.meta carries no branch= field; the authoritative
# record is the branch the task's own worktree actually has checked out.
#
# Resolution order, most authoritative first:
#   1. The branch checked out in the task's worktree (meta's worktree=), when
#      that branch also exists in the repo being operated on.
#   2. The legacy fm/<id> branch, and only when it is genuinely present.
# A detached worktree is not a branch, so it contributes nothing to step 1 and
# falls through to the legacy name. When neither resolves, this refuses and names
# both candidates it looked for rather than guessing or defaulting.
#
# The order matters beyond naming: a stale fm/<id> ref left over in the same repo
# used to win over the branch actually carrying the work, which silently reviewed
# the wrong ref. The worktree's own checkout is the fact, so it wins.

# fm_task_branch <task-id> <worktree> <repo>
# Prints the resolved branch name on stdout. On failure, prints one loud error
# naming every candidate to stderr and returns 1.
fm_task_branch() {
  local id=$1 wt=$2 repo=$3 legacy="fm/$1" head_branch="" detail=""

  if [ -z "$wt" ]; then
    detail="no worktree recorded for the task"
  elif [ ! -d "$wt" ]; then
    detail="recorded worktree is missing: $wt"
  else
    head_branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [ -z "$head_branch" ]; then
      detail="worktree $wt has no branch checked out (detached HEAD)"
    elif git -C "$repo" rev-parse --verify --quiet "refs/heads/$head_branch" >/dev/null 2>&1; then
      printf '%s\n' "$head_branch"
      return 0
    else
      detail="worktree $wt is on '$head_branch', which does not exist in $repo"
    fi
  fi

  if git -C "$repo" rev-parse --verify --quiet "refs/heads/$legacy" >/dev/null 2>&1; then
    printf '%s\n' "$legacy"
    return 0
  fi

  echo "error: cannot resolve the branch for task $id: $detail, and the legacy branch $legacy does not exist in $repo" >&2
  return 1
}

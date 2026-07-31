#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh, firstmate's one sanctioned path for landing
# approved local-only work.
#
# The branch it merges must be RESOLVED from the task's worktree, not constructed
# as fm/<id>: that internal naming is retired and every current local-only task
# branches on its JIRA key (feature/<KEY>-N, chore/<KEY>-N), so a constructed name
# made the merge refuse work that was ready to land.
#
# Matrix:
#   (a) JIRA-keyed worktree branch -> merges
#   (b) legacy fm/<id> branch, detached worktree -> still merges
#   (c) neither resolvable -> refuses loudly, naming both candidates
#   (d) worktree branch wins over a stale fm/<id> left in the same repo
#   (e) worktree on the default branch -> refuses instead of reporting a no-op landing
#   (f)-(h) the guards are unchanged: mode, dirty tree, and non-fast-forward all refuse
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# make_case <name> <branch>: a project on main with one commit, plus a worktree
# on <branch> carrying one further commit that is a clean fast-forward.
make_case() {
  local name=$1 branch=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q "$case_dir/project"
  git -C "$case_dir/project" symbolic-ref HEAD refs/heads/main
  printf 'base\n' > "$case_dir/project/feature.txt"
  git -C "$case_dir/project" add feature.txt
  git -C "$case_dir/project" commit -qm "project baseline"

  git -C "$case_dir/project" worktree add -q -b "$branch" "$case_dir/wt" main
  printf 'the-deliverable\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "local-only deliverable"

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "mode=local-only" \
    "$@"
}

run_merge_local() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" "$@"
}

# run_merge_local_capture <case_dir> <task-id>: run without tripping set -e,
# leaving stdout in $OUT, stderr in $ERR and the exit code in $CODE.
run_merge_local_capture() {
  local case_dir=$1 id=$2
  set +e
  OUT=$(run_merge_local "$case_dir" "$id" 2> "$case_dir/stderr")
  CODE=$?
  set -e
  ERR=$(cat "$case_dir/stderr")
}

main_tip() {
  git -C "$1/project" rev-parse main
}

test_jira_keyed_branch_merges() {
  local case_dir wt_tip
  case_dir=$(make_case jira-keyed chore/JUSTMD-45)
  write_task_meta "$case_dir"
  wt_tip=$(git -C "$case_dir/wt" rev-parse HEAD)

  run_merge_local_capture "$case_dir" task-x1

  expect_code 0 "$CODE" "jira-keyed: merge should succeed"
  assert_contains "$OUT" 'merged chore/JUSTMD-45 into local main' \
    "jira-keyed: should report the JIRA-keyed branch it merged"
  [ "$(main_tip "$case_dir")" = "$wt_tip" ] \
    || fail "jira-keyed: main should have fast-forwarded to the worktree branch tip"
  pass "fm-merge-local lands a JIRA-keyed local-only branch"
}

test_legacy_fm_branch_still_resolves() {
  local case_dir wt_tip
  case_dir=$(make_case legacy-fm fm/task-x1)
  # A legacy task can be detached after its work landed on the fm/<id> ref; the
  # constructed name must still resolve so old tasks keep working.
  git -C "$case_dir/wt" checkout -q --detach HEAD
  write_task_meta "$case_dir"
  wt_tip=$(git -C "$case_dir/project" rev-parse fm/task-x1)

  run_merge_local_capture "$case_dir" task-x1

  expect_code 0 "$CODE" "legacy-fm: merge should succeed"
  assert_contains "$OUT" 'merged fm/task-x1 into local main' \
    "legacy-fm: should fall back to the legacy branch name"
  [ "$(main_tip "$case_dir")" = "$wt_tip" ] \
    || fail "legacy-fm: main should have fast-forwarded to the legacy branch tip"
  pass "fm-merge-local still resolves a legacy fm/<id> branch"
}

test_worktree_branch_beats_stale_legacy_ref() {
  local case_dir wt_tip
  case_dir=$(make_case stale-legacy chore/JUSTMD-46)
  # A leftover fm/<id> ref pointing at the baseline: resolving it would report a
  # successful merge while the real deliverable stayed unlanded.
  git -C "$case_dir/project" branch fm/task-x1 main
  write_task_meta "$case_dir"
  wt_tip=$(git -C "$case_dir/wt" rev-parse HEAD)

  run_merge_local_capture "$case_dir" task-x1

  expect_code 0 "$CODE" "stale-legacy: merge should succeed"
  assert_contains "$OUT" 'merged chore/JUSTMD-46 into local main' \
    "stale-legacy: the worktree branch must win over the stale fm/<id> ref"
  [ "$(main_tip "$case_dir")" = "$wt_tip" ] \
    || fail "stale-legacy: main should carry the real deliverable, not the stale ref"
  pass "fm-merge-local prefers the worktree branch over a stale fm/<id> ref"
}

test_unresolvable_branch_refuses_loudly() {
  local case_dir before
  case_dir=$(make_case unresolvable chore/JUSTMD-47)
  # Detached worktree and no legacy ref: nothing left to resolve.
  git -C "$case_dir/wt" checkout -q --detach HEAD
  git -C "$case_dir/project" branch -q -D chore/JUSTMD-47
  write_task_meta "$case_dir"
  before=$(main_tip "$case_dir")

  run_merge_local_capture "$case_dir" task-x1

  expect_code 1 "$CODE" "unresolvable: must refuse"
  assert_contains "$ERR" 'cannot resolve the branch for task task-x1' \
    "unresolvable: must say it could not resolve the branch"
  assert_contains "$ERR" 'detached HEAD' \
    "unresolvable: must name why the worktree gave no branch"
  assert_contains "$ERR" 'the legacy branch fm/task-x1 does not exist' \
    "unresolvable: must name the legacy candidate it looked for"
  [ "$(main_tip "$case_dir")" = "$before" ] \
    || fail "unresolvable: main must not move when the branch cannot be resolved"
  pass "fm-merge-local refuses loudly and names every branch it looked for"
}

test_default_branch_resolution_refuses() {
  local case_dir before
  case_dir=$(make_case default-branch chore/JUSTMD-48)
  # A worktree that never left the default branch: merging main into main would
  # print a landing that never happened.
  rm -rf "$case_dir/wt"
  git -C "$case_dir/project" worktree prune
  git clone -q "$case_dir/project" "$case_dir/wt"
  write_task_meta "$case_dir"
  before=$(main_tip "$case_dir")

  run_merge_local_capture "$case_dir" task-x1

  expect_code 1 "$CODE" "default-branch: must refuse"
  assert_contains "$ERR" "resolves to the default branch 'main'" \
    "default-branch: must say the task has no separate work branch"
  [ "$(main_tip "$case_dir")" = "$before" ] \
    || fail "default-branch: main must not move"
  pass "fm-merge-local refuses a task that resolves to the default branch"
}

test_non_local_only_mode_still_refuses() {
  local case_dir before
  case_dir=$(make_case wrong-mode chore/JUSTMD-49)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "mode=no-mistakes"
  before=$(main_tip "$case_dir")

  run_merge_local_capture "$case_dir" task-x1

  expect_code 1 "$CODE" "wrong-mode: must refuse a non local-only task"
  assert_contains "$ERR" 'is mode=no-mistakes, not local-only' \
    "wrong-mode: must name the mode it refused"
  [ "$(main_tip "$case_dir")" = "$before" ] || fail "wrong-mode: main must not move"
  pass "fm-merge-local still refuses a task that is not local-only"
}

test_dirty_project_still_refuses() {
  local case_dir before
  case_dir=$(make_case dirty-tree chore/JUSTMD-50)
  write_task_meta "$case_dir"
  printf 'uncommitted\n' > "$case_dir/project/feature.txt"
  before=$(main_tip "$case_dir")

  run_merge_local_capture "$case_dir" task-x1

  expect_code 1 "$CODE" "dirty-tree: must refuse a dirty project"
  assert_contains "$ERR" 'has a dirty working tree; refusing to merge into it' \
    "dirty-tree: must say why it refused"
  [ "$(main_tip "$case_dir")" = "$before" ] || fail "dirty-tree: main must not move"
  pass "fm-merge-local still refuses a dirty project working tree"
}

test_diverged_branch_still_refuses() {
  local case_dir before
  case_dir=$(make_case diverged chore/JUSTMD-51)
  write_task_meta "$case_dir"
  # Advance main past the branch point so the branch is no longer a fast-forward.
  printf 'moved-on\n' > "$case_dir/project/other.txt"
  git -C "$case_dir/project" add other.txt
  git -C "$case_dir/project" commit -qm "main moved on"
  before=$(main_tip "$case_dir")

  run_merge_local_capture "$case_dir" task-x1

  expect_code 1 "$CODE" "diverged: must refuse a non-fast-forward"
  assert_contains "$ERR" 'is not a fast-forward of main (it has diverged)' \
    "diverged: must say the branch diverged"
  assert_contains "$ERR" 'Have the crewmate rebase chore/JUSTMD-51 onto main' \
    "diverged: must name the resolved branch in the rebase instruction"
  [ "$(main_tip "$case_dir")" = "$before" ] || fail "diverged: main must not move"
  pass "fm-merge-local still refuses a diverged branch and never discards it"
}

test_jira_keyed_branch_merges
test_legacy_fm_branch_still_resolves
test_worktree_branch_beats_stale_legacy_ref
test_unresolvable_branch_refuses_loudly
test_default_branch_resolution_refuses
test_non_local_only_mode_still_refuses
test_dirty_project_still_refuses
test_diverged_branch_still_refuses

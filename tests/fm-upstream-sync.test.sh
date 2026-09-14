#!/usr/bin/env bash
# Behaviour tests for bin/fm-upstream-sync.sh, the mechanical half of
# /updatefirstofficer.
#
# Everything here drives the real script against real git fixtures: a bare
# "upstream" the fork may only ever fetch from, a bare "origin" the fork pushes
# to, and a fork checkout that carries its own divergence. The guarantees under
# test are the ones a wrong sync would quietly break: a no-op sync that creates
# no branch, conflicts on the captain-decision paths never being resolved by an
# agent, a red tree never landing, and upstream never receiving a push.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/fm-upstream-sync.sh"
TODAY=$(date +%Y-%m-%d)
SYNC_BRANCH="upstream-update/$TODAY"

git_q() { git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "${@:2}"; }

commit_in() {
  local dir=$1 message=$2
  git_q "$dir" add -A
  git_q "$dir" commit -qm "$message"
}

# Validation stubs the fork's own bin/ provides, so `land` runs the repo it is
# about to land rather than this repo's real suite. Exit code is read from a
# gitignored control file so a test can flip validation red without a commit.
write_validation_stubs() {
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/fm-lint.sh" <<'SH'
#!/usr/bin/env bash
exit "$(cat "$(dirname "$0")/../.lint-rc" 2>/dev/null || echo 0)"
SH
  cat > "$dir/bin/fm-test-run.sh" <<'SH'
#!/usr/bin/env bash
exit "$(cat "$(dirname "$0")/../.tests-rc" 2>/dev/null || echo 0)"
SH
  chmod +x "$dir/bin/fm-lint.sh" "$dir/bin/fm-test-run.sh"
}

# fixture <tmp>: build upstream (bare) + origin (bare) + fork (checkout).
# The fork starts identical to upstream, then diverges on CLAUDE.md and
# tool.sh so later merges have something real to collide with.
fixture() {
  local tmp=$1 seed="$1/seed" up="$1/upstream.git" origin="$1/origin.git" fork="$1/fork"

  mkdir -p "$seed"
  git -C "$seed" init -q -b main
  printf 'upstream anchor\n' > "$seed/CLAUDE.md"
  printf 'upstream contract\n' > "$seed/AGENTS.md"
  printf '# upstream tool\n' > "$seed/tool.sh"
  printf '.lint-rc\n.tests-rc\n' > "$seed/.gitignore"
  write_validation_stubs "$seed"
  commit_in "$seed" 'seed'
  git clone -q --bare "$seed" "$up"

  git clone -q "$up" "$fork"
  git clone -q --bare "$up" "$origin"
  git -C "$fork" remote rename origin upstream
  git -C "$fork" remote set-url --push upstream DISABLED-never-push-to-upstream
  git -C "$fork" remote add origin "$origin"
  git -C "$fork" fetch -q origin
  git -C "$fork" branch --set-upstream-to=origin/main main >/dev/null 2>&1
  git -C "$fork" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  # The fork's own divergence: a replaced anchor and a changed tool.
  printf 'fork anchor, replaced\n' > "$fork/CLAUDE.md"
  printf '# fork tool\n' > "$fork/tool.sh"
  commit_in "$fork" 'fork divergence'
  git -C "$fork" push -q origin main
}

# upstream_commit <tmp> <file> <content> <message>: advance the bare upstream.
upstream_commit() {
  local tmp=$1 file=$2 content=$3 message=$4 work="$1/upwork"
  rm -rf "$work"
  git clone -q "$tmp/upstream.git" "$work"
  printf '%s\n' "$content" > "$work/$file"
  commit_in "$work" "$message"
  git -C "$work" push -q origin main
  git -C "$tmp/fork" fetch -q upstream
}

run_sync() {
  local fork=$1
  shift
  FM_ROOT_OVERRIDE="$fork" "$SYNC" "$@" 2>&1
}

# --- surfaced contract ------------------------------------------------------

test_help_names_every_captain_decision_path() {
  local out rc=0
  out=$("$SYNC" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help did not exit cleanly"
  assert_contains "$out" "CLAUDE.md" "--help did not name the fork-owned anchor as a captain decision"
  assert_contains "$out" "AGENTS.md" "--help did not name the upstream contract as a captain decision"
  assert_contains "$out" "captain decision" "--help did not say who owns those conflicts"
  assert_contains "$out" "Never pushes to upstream" "--help did not state the upstream-push boundary"
  pass "--help names every captain-decision path and the upstream-push boundary"
}

# --- no-op path -------------------------------------------------------------

test_nothing_upstream_is_a_plain_no_op() {
  local tmp out branches
  tmp=$(fm_test_tmproot fm-upstream-sync-noop)
  fixture "$tmp"

  out=$(run_sync "$tmp/fork" preflight) || fail "preflight failed on an up-to-date fork: $out"
  assert_contains "$out" "up-to-date: yes" "preflight did not report an up-to-date fork"
  assert_not_contains "$out" "sync-branch:" "preflight named a sync branch with nothing to sync"

  out=$(run_sync "$tmp/fork" merge) || fail "merge failed on an up-to-date fork: $out"
  assert_contains "$out" "nothing to sync" "merge did not report the no-op plainly"
  assert_contains "$out" "no branch created" "merge did not say it created no branch"

  branches=$(git -C "$tmp/fork" for-each-ref --format='%(refname:short)' 'refs/heads/upstream-update/*')
  [ -z "$branches" ] || fail "no-op merge created a sync branch: $branches"
  [ "$(git -C "$tmp/fork" symbolic-ref --short HEAD)" = main ] \
    || fail "no-op merge left the fork off its default branch"
  pass "nothing new upstream reports plainly and creates no branch"
}

# --- drift reporting --------------------------------------------------------

test_preflight_reports_empirical_drift_and_validates_the_declared_set() {
  local tmp out
  tmp=$(fm_test_tmproot fm-upstream-sync-drift)
  fixture "$tmp"
  upstream_commit "$tmp" README.md 'upstream readme' 'upstream readme'

  out=$(run_sync "$tmp/fork" preflight) || fail "preflight failed: $out"
  assert_contains "$out" "drift: CLAUDE.md" "preflight did not report the fork's real anchor drift"
  assert_contains "$out" "drift: tool.sh" "preflight did not report the fork's real tool drift"
  assert_contains "$out" "declared-drift: CLAUDE.md present" \
    "the declared anchor drift was not confirmed against the real diff"
  assert_contains "$out" "declared-drift: AGENTS.md stale" \
    "an undrifted declared path was not reported stale"
  assert_contains "$out" "sync-branch: $SYNC_BRANCH" "preflight did not name today's sync branch"
  pass "preflight reports the empirical drift set and validates the declared list against it"
}

test_preflight_refuses_a_dirty_fork_without_touching_it() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-upstream-sync-dirty)
  fixture "$tmp"
  printf 'uncommitted\n' >> "$tmp/fork/tool.sh"

  out=$(run_sync "$tmp/fork" preflight) || rc=$?
  expect_code 1 "$rc" "preflight accepted a dirty fork"
  assert_contains "$out" "uncommitted changes" "preflight did not name the uncommitted changes"
  assert_grep 'uncommitted' "$tmp/fork/tool.sh" "preflight disturbed the uncommitted change"
  pass "preflight refuses a dirty fork and leaves the working tree alone"
}

# --- merge classification ---------------------------------------------------

test_clean_merge_reports_clean_on_the_dated_branch() {
  local tmp out
  tmp=$(fm_test_tmproot fm-upstream-sync-clean)
  fixture "$tmp"
  upstream_commit "$tmp" NOTES.md 'upstream notes' 'upstream notes'

  out=$(run_sync "$tmp/fork" merge) || fail "merge failed: $out"
  assert_contains "$out" "sync-branch: $SYNC_BRANCH" "merge did not name today's sync branch"
  assert_contains "$out" "merge: clean" "a non-conflicting upstream merge was not reported clean"
  assert_contains "$out" "agents-md: unchanged" "an untouched AGENTS.md was reported as changed"
  [ "$(git -C "$tmp/fork" symbolic-ref --short HEAD)" = "$SYNC_BRANCH" ] \
    || fail "merge did not leave the fork on the sync branch"
  assert_present "$tmp/fork/NOTES.md" "the clean merge did not bring in the upstream change"
  pass "a clean upstream merge lands on the dated sync branch and reports clean"
}

test_an_ordinary_conflict_is_left_for_the_agent_to_resolve() {
  local tmp out
  tmp=$(fm_test_tmproot fm-upstream-sync-agent-conflict)
  fixture "$tmp"
  upstream_commit "$tmp" tool.sh '# upstream tool, rewritten' 'upstream rewrites the tool'

  out=$(run_sync "$tmp/fork" merge) || fail "merge failed: $out"
  assert_contains "$out" "conflict: tool.sh agent-resolve" \
    "an ordinary fork/upstream conflict was not offered to the agent"
  assert_contains "$out" "captain-decision=0" "an ordinary conflict was escalated to the captain"
  assert_contains "$out" "agent-resolve=1" "the agent-resolvable conflict was not counted"
  pass "an ordinary conflict is classified as the agent's to resolve"
}

test_a_conflict_on_a_captain_decision_path_is_never_resolved_here() {
  local tmp out unmerged
  tmp=$(fm_test_tmproot fm-upstream-sync-captain-conflict)
  fixture "$tmp"
  upstream_commit "$tmp" CLAUDE.md 'upstream anchor, rewritten' 'upstream rewrites the anchor'

  out=$(run_sync "$tmp/fork" merge) || fail "merge failed: $out"
  assert_contains "$out" "conflict: CLAUDE.md captain-decision" \
    "a conflict on the fork-owned anchor was not routed to the captain"
  assert_contains "$out" "fork-owned operating anchor" \
    "the captain-decision conflict did not carry its reason"
  assert_contains "$out" "captain-decision=1" "the captain-decision conflict was not counted"

  unmerged=$(git -C "$tmp/fork" diff --name-only --diff-filter=U)
  assert_contains "$unmerged" "CLAUDE.md" "the anchor conflict was silently resolved"
  assert_grep '<<<<<<<' "$tmp/fork/CLAUDE.md" "the anchor conflict markers were removed for the captain"
  pass "a conflict on a captain-decision path is reported, never resolved"
}

test_an_upstream_agents_md_change_is_flagged_for_hand_reconciliation() {
  local tmp out
  tmp=$(fm_test_tmproot fm-upstream-sync-agents-md)
  fixture "$tmp"
  upstream_commit "$tmp" AGENTS.md 'upstream contract, new rule' 'upstream changes a rule'

  out=$(run_sync "$tmp/fork" merge) || fail "merge failed: $out"
  assert_contains "$out" "merge: clean" "the AGENTS.md-only change did not merge cleanly"
  assert_contains "$out" "agents-md: changed" "an upstream AGENTS.md change was not surfaced"
  assert_contains "$out" "anchor reconciliation and pin bump" \
    "the AGENTS.md change did not name the anchor consequence"
  assert_contains "$out" "captain-decision" "the AGENTS.md change was not marked a captain decision"
  pass "an upstream AGENTS.md change is surfaced as a captain reconciliation, even on a clean merge"
}

# --- landing ----------------------------------------------------------------

# upstream_refs <tmp>: a stable snapshot of every ref in the bare upstream, so a
# test can prove the sync never wrote to it.
upstream_refs() {
  git -C "$1/upstream.git" for-each-ref --format='%(refname) %(objectname)' | LC_ALL=C sort
}

test_a_green_sync_lands_and_pushes_only_to_origin() {
  local tmp out before_upstream after_upstream origin_main fork_main
  tmp=$(fm_test_tmproot fm-upstream-sync-land)
  fixture "$tmp"
  upstream_commit "$tmp" NOTES.md 'upstream notes' 'upstream notes'
  before_upstream=$(upstream_refs "$tmp")

  out=$(run_sync "$tmp/fork" merge) || fail "merge failed: $out"
  assert_contains "$out" "merge: clean" "the merge under test was not clean: $out"

  out=$(run_sync "$tmp/fork" land) || fail "land failed on a green clean sync: $out"
  assert_contains "$out" "validate: lint ok" "land did not run the repo's lint"
  assert_contains "$out" "validate: tests ok" "land did not run the repo's tests"
  assert_contains "$out" "landed: main" "land did not report the default branch advancing"

  [ "$(git -C "$tmp/fork" symbolic-ref --short HEAD)" = main ] \
    || fail "land did not return the fork to its default branch"
  origin_main=$(git -C "$tmp/origin.git" rev-parse main)
  fork_main=$(git -C "$tmp/fork" rev-parse main)
  [ "$origin_main" = "$fork_main" ] || fail "land did not push the default branch to origin"
  git -C "$tmp/origin.git" rev-parse --verify --quiet "$SYNC_BRANCH" >/dev/null \
    || fail "land did not push the dated sync branch to origin"

  after_upstream=$(upstream_refs "$tmp")
  [ "$before_upstream" = "$after_upstream" ] || fail "the sync wrote to upstream"
  pass "a green clean sync lands autonomously, pushes to origin, and never touches upstream"
}

test_land_refuses_a_red_tree_and_pushes_nothing() {
  local tmp out rc=0 origin_main_before origin_main_after before_upstream
  tmp=$(fm_test_tmproot fm-upstream-sync-red)
  fixture "$tmp"
  upstream_commit "$tmp" NOTES.md 'upstream notes' 'upstream notes'
  origin_main_before=$(git -C "$tmp/origin.git" rev-parse main)
  before_upstream=$(upstream_refs "$tmp")

  out=$(run_sync "$tmp/fork" merge) || fail "merge failed: $out"
  printf '1\n' > "$tmp/fork/.tests-rc"

  out=$(run_sync "$tmp/fork" land) || rc=$?
  expect_code 1 "$rc" "land accepted a red tree"
  assert_contains "$out" "validate: tests failed" "land did not report which validation was red"
  assert_contains "$out" "nothing was landed or pushed" "land did not say it landed nothing"

  origin_main_after=$(git -C "$tmp/origin.git" rev-parse main)
  [ "$origin_main_before" = "$origin_main_after" ] || fail "a red sync still advanced origin's default branch"
  git -C "$tmp/origin.git" rev-parse --verify --quiet "$SYNC_BRANCH" >/dev/null \
    && fail "a red sync still pushed the sync branch"
  [ "$before_upstream" = "$(upstream_refs "$tmp")" ] || fail "a red sync wrote to upstream"
  pass "land refuses a red tree and pushes nothing anywhere"
}

test_land_refuses_a_branch_that_is_not_a_sync_branch() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-upstream-sync-wrong-branch)
  fixture "$tmp"
  upstream_commit "$tmp" NOTES.md 'upstream notes' 'upstream notes'
  git -C "$tmp/fork" checkout -q -b feat/unrelated

  out=$(run_sync "$tmp/fork" land) || rc=$?
  expect_code 1 "$rc" "land accepted an unrelated branch"
  assert_contains "$out" "not a dated upstream-update/<date> sync branch" \
    "land did not say why the branch was rejected"
  pass "land refuses any branch that is not a dated sync branch"
}

test_land_refuses_an_unfinished_merge() {
  local tmp out rc=0
  tmp=$(fm_test_tmproot fm-upstream-sync-unfinished)
  fixture "$tmp"
  upstream_commit "$tmp" CLAUDE.md 'upstream anchor, rewritten' 'upstream rewrites the anchor'

  out=$(run_sync "$tmp/fork" merge) || fail "merge failed: $out"
  out=$(run_sync "$tmp/fork" land) || rc=$?
  expect_code 1 "$rc" "land accepted an unresolved merge"
  assert_contains "$out" "still in progress" "land did not name the unresolved merge"
  pass "land refuses while the upstream merge is still unresolved"
}

# --- abort ------------------------------------------------------------------

test_abort_returns_to_the_default_branch_without_discarding_work() {
  local tmp out
  tmp=$(fm_test_tmproot fm-upstream-sync-abort)
  fixture "$tmp"
  upstream_commit "$tmp" CLAUDE.md 'upstream anchor, rewritten' 'upstream rewrites the anchor'

  out=$(run_sync "$tmp/fork" merge) || fail "merge failed: $out"
  out=$(run_sync "$tmp/fork" abort) || fail "abort failed: $out"
  assert_contains "$out" "upstream merge aborted" "abort did not report undoing the merge"
  [ "$(git -C "$tmp/fork" symbolic-ref --short HEAD)" = main ] \
    || fail "abort did not return the fork to its default branch"
  assert_grep 'fork anchor, replaced' "$tmp/fork/CLAUDE.md" "abort did not restore the fork's anchor"
  pass "abort undoes an unresolved merge and returns to the default branch"
}

test_abort_keeps_a_sync_branch_that_carries_commits() {
  local tmp out
  tmp=$(fm_test_tmproot fm-upstream-sync-abort-keep)
  fixture "$tmp"
  upstream_commit "$tmp" NOTES.md 'upstream notes' 'upstream notes'

  out=$(run_sync "$tmp/fork" merge) || fail "merge failed: $out"
  out=$(run_sync "$tmp/fork" abort) || fail "abort failed: $out"
  assert_contains "$out" "carries commits" "abort did not say it kept the landed-nowhere sync branch"
  git -C "$tmp/fork" show-ref --verify --quiet "refs/heads/$SYNC_BRANCH" \
    || fail "abort deleted a sync branch that carried unlanded work"
  pass "abort never deletes a sync branch that carries unlanded work"
}

test_help_names_every_captain_decision_path
test_nothing_upstream_is_a_plain_no_op
test_preflight_reports_empirical_drift_and_validates_the_declared_set
test_preflight_refuses_a_dirty_fork_without_touching_it
test_clean_merge_reports_clean_on_the_dated_branch
test_an_ordinary_conflict_is_left_for_the_agent_to_resolve
test_a_conflict_on_a_captain_decision_path_is_never_resolved_here
test_an_upstream_agents_md_change_is_flagged_for_hand_reconciliation
test_a_green_sync_lands_and_pushes_only_to_origin
test_land_refuses_a_red_tree_and_pushes_nothing
test_land_refuses_a_branch_that_is_not_a_sync_branch
test_land_refuses_an_unfinished_merge
test_abort_returns_to_the_default_branch_without_discarding_work
test_abort_keeps_a_sync_branch_that_carries_commits

#!/usr/bin/env bash
# Tests for bin/fm-craft-review.sh, the gate that keeps an unreviewed commit from
# being published on the local-only delivery path.
#
# The contract this pins is that publication is refused by default. Prose in a
# brief cannot make a review stage unskippable, so `verify` must fail closed on
# every state that is not "this exact commit passed":
#   (a) no review recorded at all                -> REFUSE
#   (b) a recorded findings verdict              -> REFUSE
#   (c) a pass verdict for the current commit    -> ALLOW
#   (d) a pass verdict outlived by a new commit  -> REFUSE
#   (e) a dirty worktree                         -> REFUSE
# It also pins that a worker cannot record a verdict on its own task, and that a
# missing durable record or worktree refuses rather than being read as a pass.
#
# (e) is what makes co-location safe. The reviewer runs in the implementer's own
# worktree so one story keeps one checkout, and a clean tree at record time is the
# evidence that the reviewer only read and that the implementer was idle rather than
# editing beside it.
#
# Which projects the review runs on is a per-home choice, so the tests at the end
# pin both sides of that boundary and its default: a project in the set is gated
# exactly as above, a project outside it publishes with no reviewer and no gate,
# and a home that has configured nothing is gated everywhere - absence must never
# be what quietly switches the step off.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CRAFT_REVIEW="$ROOT/bin/fm-craft-review.sh"
TMP_ROOT=$(fm_test_tmproot fm-craft-review-tests)

# make_case <name>: a project on main plus a worktree on a JIRA-keyed branch
# carrying one commit, with a durable record pointing at both. Echoes the case dir.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  # An empty config dir, so a case says nothing about which projects are
  # reviewed unless it writes the scope file itself - and never reads the
  # developer's own home while doing it.
  mkdir -p "$case_dir/state" "$case_dir/config"

  git init -q "$case_dir/project"
  git -C "$case_dir/project" symbolic-ref HEAD refs/heads/main
  printf 'base\n' > "$case_dir/project/feature.txt"
  git -C "$case_dir/project" add feature.txt
  git -C "$case_dir/project" commit -qm "project baseline"

  git -C "$case_dir/project" worktree add -q -b feature/JUSTMD-7 "$case_dir/wt" main
  commit_in_worktree "$case_dir" the-deliverable "reviewable work"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "mode=local-only" \
    "kind=ship"
  printf '%s\n' "$case_dir"
}

commit_in_worktree() {
  local case_dir=$1 content=$2 msg=$3
  printf '%s\n' "$content" > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "$msg"
}

branch_tip() {
  git -C "$1/wt" rev-parse HEAD
}

# run_gate <case_dir> <args...>: run the gate, leaving stdout in $OUT, stderr in
# $ERR and the exit code in $CODE. Every refusal is an expected outcome here, so
# this must never enable errexit: this suite runs under set -u alone, and turning
# errexit on would leak into every later test in the same process.
run_gate() {
  local case_dir=$1
  shift
  OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_CONFIG_OVERRIDE="$case_dir/config" \
    "$CRAFT_REVIEW" "$@" 2> "$case_dir/stderr"); CODE=$?
  ERR=$(cat "$case_dir/stderr")
}

test_unreviewed_commit_is_refused() {
  local case_dir
  case_dir=$(make_case unreviewed)

  run_gate "$case_dir" verify task-x1

  expect_code 1 "$CODE" "unreviewed: verify must refuse"
  assert_contains "$ERR" "has no craftsmanship review" \
    "unreviewed: refusal should name the missing review"
  assert_contains "$ERR" "must not be published" \
    "unreviewed: refusal should say publication is blocked"
  assert_contains "$ERR" "$(branch_tip "$case_dir")" \
    "unreviewed: refusal should name the unreviewed commit"
  pass "an unreviewed commit is refused publication"
}

test_findings_verdict_is_refused() {
  local case_dir
  case_dir=$(make_case findings)

  run_gate "$case_dir" record task-x1 --reviewer task-x1-craft --verdict findings \
    --findings "$case_dir/craftsmanship-review.md"
  expect_code 0 "$CODE" "findings: recording a findings verdict should succeed"

  run_gate "$case_dir" verify task-x1

  expect_code 1 "$CODE" "findings: verify must refuse a findings verdict"
  assert_contains "$ERR" "returned findings, not a pass" \
    "findings: refusal should distinguish findings from a missing review"
  pass "a findings verdict is refused publication"
}

test_pass_verdict_for_the_current_commit_allows_publication() {
  local case_dir
  case_dir=$(make_case passing)

  run_gate "$case_dir" record task-x1 --reviewer task-x1-craft --verdict pass
  expect_code 0 "$CODE" "passing: recording a pass should succeed"
  assert_contains "$OUT" "$(branch_tip "$case_dir")" \
    "passing: the record should name the commit it reviewed"

  run_gate "$case_dir" verify task-x1

  expect_code 0 "$CODE" "passing: verify should allow publication"
  assert_contains "$OUT" "craftsmanship review passed" \
    "passing: verify should report the pass"
  pass "a pass verdict for the current commit allows publication"
}

test_pass_verdict_does_not_outlive_a_new_commit() {
  local case_dir reviewed
  case_dir=$(make_case stale-pass)
  reviewed=$(branch_tip "$case_dir")

  run_gate "$case_dir" record task-x1 --reviewer task-x1-craft --verdict pass
  expect_code 0 "$CODE" "stale-pass: recording a pass should succeed"
  commit_in_worktree "$case_dir" reworked "unreviewed follow-up"

  run_gate "$case_dir" verify task-x1

  expect_code 1 "$CODE" "stale-pass: verify must refuse after a new commit"
  assert_contains "$ERR" "$reviewed" "stale-pass: refusal should name the commit that passed"
  assert_contains "$ERR" "$(branch_tip "$case_dir")" \
    "stale-pass: refusal should name the commit the branch is now at"
  assert_contains "$ERR" "unreviewed" "stale-pass: refusal should say the new commits are unreviewed"
  pass "a pass verdict does not outlive the commit it reviewed"
}

# The reviewer works in the implementer's own worktree, so a clean tree at record
# time is the evidence that co-location stayed safe: it proves the reviewer only read
# and that the implementer was idle rather than editing beside it. Agent-owned files
# are not evidence of either, so they must not trip the refusal.
test_dirty_worktree_refuses_a_verdict() {
  local case_dir
  case_dir=$(make_case dirty-tree)
  printf 'edited by someone\n' > "$case_dir/wt/feature.txt"

  run_gate "$case_dir" record task-x1 --reviewer task-x1-craft --verdict pass

  expect_code 1 "$CODE" "dirty-tree: recording must refuse while the tree is dirty"
  assert_contains "$ERR" "has uncommitted changes" "dirty-tree: refusal should name the dirty tree"
  assert_contains "$ERR" "feature.txt" "dirty-tree: refusal should show what changed"
  assert_contains "$ERR" "must be idle" "dirty-tree: refusal should name the serialisation rule"
  assert_absent "$case_dir/state/task-x1.craft-review" "dirty-tree: no verdict should be written"

  git -C "$case_dir/wt" checkout -q -- feature.txt
  printf 'token\n' > "$case_dir/wt/.fm-grok-turnend"
  run_gate "$case_dir" record task-x1 --reviewer task-x1-craft --verdict pass
  expect_code 0 "$CODE" "dirty-tree: an agent-owned file must not block a verdict"
  pass "a dirty worktree refuses a verdict, while agent-owned files do not"
}

test_self_review_is_refused() {
  local case_dir
  case_dir=$(make_case self-review)

  run_gate "$case_dir" record task-x1 --reviewer task-x1 --verdict pass

  expect_code 1 "$CODE" "self-review: recording must refuse"
  assert_contains "$ERR" "did not write the code" \
    "self-review: refusal should say the reviewer must be independent"
  assert_absent "$case_dir/state/task-x1.craft-review" \
    "self-review: no verdict record should be written"
  pass "a worker cannot record a craftsmanship verdict on its own task"
}

test_unresolvable_task_refuses_rather_than_passing() {
  local case_dir
  case_dir=$(make_case unresolvable)

  run_gate "$case_dir" verify no-such-task
  expect_code 1 "$CODE" "unresolvable: an unknown task must refuse"
  assert_contains "$ERR" "no durable record" "unresolvable: refusal should name the missing record"

  rm -rf "$case_dir/wt"
  run_gate "$case_dir" verify task-x1
  expect_code 1 "$CODE" "unresolvable: a missing worktree must refuse"
  assert_contains "$ERR" "worktree for task task-x1 is missing" \
    "unresolvable: refusal should name the missing worktree"
  pass "an unresolvable task refuses rather than being read as reviewed"
}

test_bad_arguments_refuse() {
  local case_dir
  case_dir=$(make_case bad-args)

  run_gate "$case_dir" record task-x1 --reviewer task-x1-craft --verdict maybe
  expect_code 1 "$CODE" "bad-args: an unknown verdict must refuse"
  assert_contains "$ERR" "must be pass or findings" "bad-args: refusal should name the valid verdicts"

  run_gate "$case_dir" record task-x1 --verdict pass
  expect_code 1 "$CODE" "bad-args: a missing reviewer must refuse"
  assert_contains "$ERR" "requires --reviewer" "bad-args: refusal should name the missing reviewer"

  run_gate "$case_dir" publish task-x1
  expect_code 1 "$CODE" "bad-args: an unknown action must refuse"
  assert_contains "$ERR" "expected record, verify, or required" "bad-args: refusal should name the valid actions"
  pass "malformed invocations refuse instead of guessing"
}

# --- which projects the review runs on --------------------------------------

# A project the home lists is gated exactly as it always was: an unreviewed
# commit is refused, and only a pass verdict for that exact commit publishes.
test_project_in_the_set_still_gates_publication() {
  local case_dir tip
  case_dir=$(make_case scoped-in)
  printf '# projects this home reviews\nproject\n' > "$case_dir/config/craft-review-projects"

  run_gate "$case_dir" verify task-x1
  expect_code 1 "$CODE" "a listed project must still refuse an unreviewed commit"
  assert_contains "$ERR" "has no craftsmanship review" \
    "a listed project's refusal should name the missing review"

  run_gate "$case_dir" record task-x1 --reviewer reviewer-y2 --verdict pass
  expect_code 0 "$CODE" "recording a pass verdict on a listed project should succeed"
  run_gate "$case_dir" verify task-x1
  expect_code 0 "$CODE" "a pass verdict for the current commit should publish"
  tip=$(branch_tip "$case_dir")
  assert_contains "$OUT" "$tip" "the passing verdict should name the commit it covers"
  pass "a project in the reviewed set still gates publication on a pass verdict for the exact commit"
}

# A project the home does not list has no reviewer to wait for, so the gate
# stands aside and says so rather than refusing a verdict that will never exist.
test_project_outside_the_set_publishes_with_no_reviewer() {
  local case_dir
  case_dir=$(make_case scoped-out)
  printf '# projects this home reviews\nsomething-else\n' > "$case_dir/config/craft-review-projects"

  run_gate "$case_dir" verify task-x1
  expect_code 0 "$CODE" "a project outside the set must publish with no reviewer"
  assert_contains "$OUT" "not required" \
    "the gate should say the review is not required rather than passing silently"
  [ ! -e "$case_dir/state/task-x1.craft-review" ] \
    || fail "publishing outside the set should need no recorded verdict"
  pass "a project outside the reviewed set publishes with no reviewer and no gate"
}

# The deliberate default: a home that has configured nothing has said nothing,
# and silence about a safety step leaves it in force.
test_absent_scope_configuration_keeps_the_gate_everywhere() {
  local case_dir
  case_dir=$(make_case scoped-absent)
  [ ! -e "$case_dir/config/craft-review-projects" ] || fail "fixture should have no scope file"

  run_gate "$case_dir" verify task-x1
  expect_code 1 "$CODE" "an unconfigured home must still gate publication"
  assert_contains "$ERR" "has no craftsmanship review" \
    "an unconfigured home's refusal should name the missing review"

  run_gate "$case_dir" required project
  expect_code 0 "$CODE" "an unconfigured home should report the review as required"
  assert_contains "$OUT" "applies everywhere" \
    "the reason should say why an unconfigured home is gated"
  pass "an absent scope configuration keeps the review required everywhere"
}

# The boundary is a list of literal names. A project must not drift into the set
# by being named like one that is in it, in either direction.
# Exit 1 is the answer "not required", so nothing else may produce it: a caller
# that read a failed question as a no would silently drop the review.
test_a_malformed_scope_question_is_not_an_answer() {
  local case_dir
  case_dir=$(make_case scoped-malformed)

  run_gate "$case_dir" required project extra-argument
  expect_code 2 "$CODE" "a malformed required call must not exit 1, which means not required"
  assert_contains "$ERR" "takes only a project name" \
    "the refusal should say what was wrong with the call"

  run_gate "$case_dir" required
  expect_code 2 "$CODE" "a required call with no project name must not exit 1"
  assert_contains "$ERR" "takes a project name" \
    "the refusal should say the project name was missing"

  run_gate "$case_dir" required ""
  expect_code 2 "$CODE" "a required call with an empty project name must not exit 1"
  assert_contains "$ERR" "takes a project name" \
    "the refusal should say the project name was missing"
  pass "a malformed scope question exits distinctly from the answer no"
}

test_scope_membership_is_literal() {
  local case_dir
  case_dir=$(make_case scoped-literal)
  printf 'project\n' > "$case_dir/config/craft-review-projects"

  run_gate "$case_dir" required project
  expect_code 0 "$CODE" "the listed name itself must be required"
  run_gate "$case_dir" required projec
  expect_code 1 "$CODE" "a prefix of a listed name must not be required"
  run_gate "$case_dir" required project-two
  expect_code 1 "$CODE" "a name extending a listed one must not be required"

  # Comments and blank lines are not names, and a file holding only those is how
  # a home says "nowhere" deliberately.
  printf '\n# project\n\n' > "$case_dir/config/craft-review-projects"
  run_gate "$case_dir" required project
  expect_code 1 "$CODE" "a commented-out name must not be required"
  pass "reviewed-set membership is a literal name match, never a prefix or a comment"
}

test_help_renders_the_complete_header() {
  local help
  help=$("$CRAFT_REVIEW" --help)
  assert_contains "$help" "fm-craft-review.sh verify <task-id>" "--help omitted the verify usage"
  assert_contains "$help" "pinned to the reviewed commit" "--help omitted the pinning contract"
  pass "fm-craft-review.sh: --help renders the complete header"
}

test_unreviewed_commit_is_refused
test_findings_verdict_is_refused
test_pass_verdict_for_the_current_commit_allows_publication
test_pass_verdict_does_not_outlive_a_new_commit
test_dirty_worktree_refuses_a_verdict
test_self_review_is_refused
test_unresolvable_task_refuses_rather_than_passing
test_bad_arguments_refuse
test_project_in_the_set_still_gates_publication
test_project_outside_the_set_publishes_with_no_reviewer
test_absent_scope_configuration_keeps_the_gate_everywhere
test_a_malformed_scope_question_is_not_an_answer
test_scope_membership_is_literal
test_help_renders_the_complete_header

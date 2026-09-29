#!/usr/bin/env bash
# Tests for bin/fm-craft-rules.sh, which owns the captain's craftsmanship rules
# and which projects' no-mistakes review carries them.
#
# The scope is by-project and hard-edged, and its default is deliberate: a home
# that has configured nothing carries the rules everywhere, an all-comment file
# carries them nowhere, and names match literally. A malformed call exits 2, so a
# failed question can never read as the answer "no".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CRAFT_RULES="$ROOT/bin/fm-craft-rules.sh"
TMP_ROOT=$(fm_test_tmproot fm-craft-rules-tests)

# run_rules <config-dir> <args...>: leaves stdout in $OUT, stderr in $ERR and
# the exit code in $CODE, never enabling errexit in this set -u suite.
run_rules() {
  local config=$1
  shift
  OUT=$(FM_CONFIG_OVERRIDE="$config" "$CRAFT_RULES" "$@" 2>"$TMP_ROOT/stderr")
  CODE=$?
  ERR=$(cat "$TMP_ROOT/stderr")
}

make_config() {  # <name> [scope-file-content]; echoes the config dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  [ "$#" -lt 2 ] || printf '%s' "$2" > "$dir/craft-rules-projects"
  printf '%s\n' "$dir"
}

test_listed_projects_carry_the_rules_and_others_do_not() {
  local config
  config=$(make_config listed $'# craftsmanship scope\nJustMasterData\n  JustAuth  # trailing comment\n')
  run_rules "$config" applies JustMasterData
  expect_code 0 "$CODE" "a listed project must carry the rules"
  run_rules "$config" applies JustAuth
  expect_code 0 "$CODE" "a listed name with padding and a trailing comment must still match"
  run_rules "$config" applies onboarding
  expect_code 1 "$CODE" "an unlisted project must not carry the rules"
  assert_contains "$OUT" "do not apply to onboarding" "the no answer does not say why"
  run_rules "$config" applies JustMasterData-legacy
  expect_code 1 "$CODE" "a name that only shares a prefix must not match"
  pass "fm-craft-rules.sh: listed projects carry the rules, literally matched"
}

test_silence_means_everywhere_and_comments_mean_nowhere() {
  local config
  config=$(make_config absent)
  run_rules "$config" applies anything
  expect_code 0 "$CODE" "a home with no scope file must carry the rules everywhere"
  assert_contains "$OUT" "apply everywhere" "the everywhere answer does not name its reason"
  config=$(make_config nowhere $'# no project carries the rules\n')
  run_rules "$config" applies anything
  expect_code 1 "$CODE" "an all-comment scope file must mean nowhere"
  pass "fm-craft-rules.sh: an absent scope means everywhere, an all-comment one nowhere"
}

test_malformed_calls_never_read_as_no() {
  local config
  config=$(make_config malformed $'JustAuth\n')
  run_rules "$config" applies
  expect_code 2 "$CODE" "applies without a project must be malformed, not no"
  run_rules "$config" applies ""
  expect_code 2 "$CODE" "an empty project name must be malformed, not no"
  run_rules "$config" applies JustAuth extra
  expect_code 2 "$CODE" "applies with two names must be malformed, not no"
  run_rules "$config" verify some-task
  expect_code 2 "$CODE" "an unknown action must be malformed"
  assert_contains "$ERR" "expected applies" "the malformed call does not say what is expected"
  pass "fm-craft-rules.sh: malformed calls exit 2, so they can never read as no"
}

test_print_renders_the_rules_block() {
  local config
  config=$(make_config print)
  run_rules "$config" print
  expect_code 0 "$CODE" "print must succeed"
  assert_contains "$OUT" "Craftsmanship rules this change must meet" "print lost the block heading"
  assert_contains "$OUT" "Private helpers sit below their callers" "print lost the helper-ordering rule"
  assert_contains "$OUT" "No machine-generated tells" "print lost the AI-tells rule"
  run_rules "$config" print extra
  expect_code 2 "$CODE" "print with an argument must be malformed"
  pass "fm-craft-rules.sh: print renders the rules block"
}

test_listed_projects_carry_the_rules_and_others_do_not
test_silence_means_everywhere_and_comments_mean_nowhere
test_malformed_calls_never_read_as_no
test_print_renders_the_rules_block

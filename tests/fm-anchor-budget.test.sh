#!/usr/bin/env bash
# Budget guard for CLAUDE.md, the fork-owned always-loaded agent anchor.
#
# CLAUDE.md is loaded into every session of every fleet member, every time, so
# its byte size is a real operating cost rather than a style preference. The
# harness warns once an agent-instruction file passes roughly 40,000 characters,
# and the anchor exists precisely so the always-loaded surface stays below that
# line while AGENTS.md keeps growing upstream untouched.
#
# The size here IS the guarantee, so measuring it is not a source-byte stand-in
# for something else: no other observable expresses "this file stays inside the
# always-loaded budget". The guard itself is exercised against an
# over-budget fixture as well as the real anchor, so a broken measurement cannot
# silently report success.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ANCHOR="$ROOT/CLAUDE.md"
# Harness agent-instruction warning threshold. Raising this is not the fix for a
# breach: route the detail to its owner (a skill, a script header, docs/) and
# leave a one-line trigger in the anchor instead.
CEILING=40000

anchor_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

# anchor_budget_verdict <file> <ceiling>: print "ok <size> <headroom>" and
# return 0 when the file fits, or print the actionable overage and return 1.
anchor_budget_verdict() {
  local file=$1 ceiling=$2 size
  size=$(anchor_size "$file")
  if [ "$size" -gt "$ceiling" ]; then
    printf 'over budget: %s is %s bytes, %s over the %s-byte ceiling\n' \
      "$(basename "$file")" "$size" "$((size - ceiling))" "$ceiling"
    return 1
  fi
  printf 'ok %s %s\n' "$size" "$((ceiling - size))"
}

test_anchor_is_a_real_fork_owned_file() {
  [ -e "$ANCHOR" ] || fail "CLAUDE.md is missing; the fork-owned anchor must exist"
  [ ! -L "$ANCHOR" ] \
    || fail "CLAUDE.md is a symlink; the anchor is fork-owned and must be a regular file"
  [ -f "$ANCHOR" ] || fail "CLAUDE.md is not a regular file"
  [ "$(anchor_size "$ANCHOR")" -gt 0 ] || fail "CLAUDE.md is empty"
  pass "CLAUDE.md is a real fork-owned file, not a symlink to AGENTS.md"
}

test_anchor_stays_within_budget_with_headroom() {
  local verdict size headroom
  if ! verdict=$(anchor_budget_verdict "$ANCHOR" "$CEILING"); then
    fail "$verdict"
  fi
  size=$(printf '%s\n' "$verdict" | awk '{print $2}')
  headroom=$(printf '%s\n' "$verdict" | awk '{print $3}')
  [ "$headroom" -gt 0 ] \
    || fail "CLAUDE.md is $size bytes with no headroom under the $CEILING-byte ceiling"
  pass "CLAUDE.md is $size bytes, $headroom bytes of headroom under the $CEILING-byte ceiling"
}

test_budget_guard_rejects_an_over_budget_anchor() {
  local tmp fixture out
  tmp=$(fm_test_tmproot fm-anchor-budget)
  mkdir -p "$tmp"
  fixture="$tmp/CLAUDE.md"
  # One byte over a deliberately tiny ceiling: the guard must refuse, not round.
  printf '%0.sx' $(seq 1 65) > "$fixture"
  out=$(anchor_budget_verdict "$fixture" 64) && fail "budget guard accepted an over-budget anchor"
  assert_contains "$out" "over budget" "budget guard did not say the anchor is over budget"
  assert_contains "$out" "65 bytes" "budget guard did not name the current size"
  assert_contains "$out" "1 over" "budget guard did not name the overage"
  assert_contains "$out" "64-byte ceiling" "budget guard did not name the ceiling"
  pass "budget guard fails loudly and names the size, overage, and ceiling"
}

test_anchor_is_a_real_fork_owned_file
test_anchor_stays_within_budget_with_headroom
test_budget_guard_rejects_an_over_budget_anchor

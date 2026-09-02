#!/usr/bin/env bash
# Structural regression tests for the tracked documentation audience inventory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-doc-audience-check.sh"
INVENTORY="$ROOT/docs/documentation-audiences.json"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-doc-audiences.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

run_expect_failure() {
  local expected=$1
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected failure containing '$expected'"
  assert_contains "$out" "$expected" "failure did not explain '$expected'"
}

mutate_inventory() {
  local source=$1 destination=$2 mode=$3
  python3 - "$source" "$destination" "$mode" <<'PY'
import json
import sys
from pathlib import Path

source, destination, mode = map(Path, sys.argv[1:])
data = json.loads(source.read_text(encoding="utf-8"))
if mode.name == "duplicate":
    data["surfaces"].append(dict(data["surfaces"][0]))
elif mode.name == "bad-setup-audience":
    for entry in data["surfaces"]:
        if entry["path"] == "docs/tmux-backend.md":
            entry["audience"] = "maintainer-verification"
            break
elif mode.name == "missing-owner-pointer":
    data["requiredOwnerPointers"][0] = {
        "source": "README.md",
        "target": "docs/sessionstart-nudge.md",
    }
elif mode.name == "shrink-scope":
    data["scope"]["trackedPatterns"] = ["README.md"]
else:
    raise SystemExit(f"unknown mode: {mode.name}")
destination.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

test_repository_inventory_passes() {
  local out
  out=$("$CHECK") || fail "repository documentation audience check failed"
  assert_contains "$out" "fm-doc-audience-check: ok surfaces=" \
    "audience check did not report exact surface coverage"
  assert_contains "$out" "local_links=" \
    "audience check did not report local-link validation"
  pass "documentation inventory classifies every maintained prose surface exactly once"
}

test_duplicate_and_setup_classification_fail() {
  local duplicate="$TMP_ROOT/duplicate.json"
  local bad_setup="$TMP_ROOT/bad-setup.json"
  local shrink_scope="$TMP_ROOT/shrink-scope.json"
  mutate_inventory "$INVENTORY" "$duplicate" duplicate
  mutate_inventory "$INVENTORY" "$bad_setup" bad-setup-audience
  mutate_inventory "$INVENTORY" "$shrink_scope" shrink-scope
  run_expect_failure "surfaces classified more than once" \
    "$CHECK" --inventory "$duplicate"
  run_expect_failure "README setup target docs/tmux-backend.md has disallowed audience" \
    "$CHECK" --inventory "$bad_setup"
  run_expect_failure "scope.trackedPatterns must match the fixed maintained-prose scope" \
    "$CHECK" --inventory "$shrink_scope"
  pass "classification, setup routing, and maintained-prose scope fail safely"
}

test_required_pointer_fails() {
  local missing_pointer="$TMP_ROOT/missing-pointer.json"
  mutate_inventory "$INVENTORY" "$missing_pointer" missing-owner-pointer
  run_expect_failure "required owner pointer missing" \
    "$CHECK" --inventory "$missing_pointer"
  pass "required documentation owner pointers cannot silently disappear"
}

write_fixture_inventory() {
  local repo=$1
  cat > "$repo/docs/documentation-audiences.json" <<'JSON'
{
  "version": 1,
  "scope": {"trackedPatterns": ["*.md", "*.mdx", "*.rst", "*.txt", "docs/examples/*"]},
  "allowedAudiences": ["public-product", "operator-current", "maintainer-verification"],
  "setupAudiences": ["public-product", "operator-current"],
  "readmeSetupTargets": ["docs/setup.md"],
  "requiredOwnerPointers": [
    {"source": "README.md", "target": "docs/policy.md"}
  ],
  "surfaces": [
    {"path": "README.md", "audience": "public-product"},
    {"path": "docs/evidence.md", "audience": "maintainer-verification"},
    {"path": "docs/policy.md", "audience": "operator-current"},
    {"path": "docs/setup.md", "audience": "operator-current"}
  ]
}
JSON
}

test_local_links_and_no_keyword_heuristic() {
  local repo="$TMP_ROOT/fixture"
  mkdir -p "$repo/docs"
  git -C "$repo" init -q
  printf '%s\n' '[Setup](docs/setup.md) [Policy](docs/policy.md)' > "$repo/README.md"
  printf '%s\n' '# Setup' > "$repo/docs/setup.md"
  printf '%s\n' '# Policy' > "$repo/docs/policy.md"
  cat > "$repo/docs/evidence.md" <<'MD'
# Incident verification on 2026-07-23

```sh
/tmp/task-worktree/bin/tool --version
```

Observed version 1.2.3 on branch `fm/example`.
MD
  write_fixture_inventory "$repo"
  git -C "$repo" add README.md docs
  "$CHECK" --root "$repo" >/dev/null \
    || fail "structural checker rejected legitimate maintainer evidence prose"

  printf '%s\n' '[Setup](docs/setup.md) [Policy](docs/policy.md) [Broken](docs/missing.bin)' \
    > "$repo/README.md"
  git -C "$repo" add README.md
  run_expect_failure "unresolved local link" "$CHECK" --root "$repo"
  pass "local links resolve while dates, versions, commands, and incident prose remain semantically reviewed"
}

ADAPTER_SKILL_DIR="$ROOT/.agents/skills/harness-adapters"

# adapter_router_check <skill-dir>: structural invariants of the harness-adapters
# split. Prints every violation and returns non-zero, so a fixture copy can prove
# the check actually fails.
adapter_router_check() {
  local skill_dir=$1
  local skill="$skill_dir/SKILL.md"
  local rc=0 target ref rel seen routed_target
  local -a routed=()

  if [ ! -f "$skill" ]; then
    printf 'adapter-router: missing SKILL.md at %s\n' "$skill"
    return 1
  fi

  while IFS= read -r target; do
    [ -n "$target" ] || continue
    routed+=("$target")
    if [ ! -f "$skill_dir/$target" ]; then
      printf 'adapter-router: routing row points at missing reference: %s\n' "$target"
      rc=1
    fi
  done < <(grep -E '^\|' "$skill" \
    | grep -oE '\(references/[A-Za-z0-9._-]+\.md\)' \
    | tr -d '()' \
    | sort -u)

  if [ "${#routed[@]}" -eq 0 ]; then
    printf 'adapter-router: routing table names no reference\n'
    return 1
  fi

  for ref in "$skill_dir"/references/*.md; do
    [ -e "$ref" ] || continue
    rel="references/$(basename "$ref")"
    seen=0
    for routed_target in "${routed[@]}"; do
      [ "$routed_target" = "$rel" ] && seen=1
    done
    if [ "$seen" -eq 0 ]; then
      printf 'adapter-router: reference unreachable from the routing table: %s\n' "$rel"
      rc=1
    fi
    if ! grep -qE '^\| *Busy-pane signature *\| *[^ |]' "$ref"; then
      printf 'adapter-router: reference documents no busy-pane signature: %s\n' "$rel"
      rc=1
    fi
    if ! grep -qE '^\| *Interrupt *\| *[^ |]' "$ref"; then
      printf 'adapter-router: reference documents no interrupt: %s\n' "$rel"
      rc=1
    fi
  done

  if grep -qE '^\| *Busy-pane signature *\|' "$skill"; then
    printf 'adapter-router: SKILL.md still carries a per-adapter busy-pane signature\n'
    rc=1
  fi

  return "$rc"
}

test_adapter_routing_is_complete_and_safe() {
  adapter_router_check "$ADAPTER_SKILL_DIR" \
    || fail "harness-adapters routing, reference reachability, or safety facts regressed"
  pass "every harness-adapters routing row resolves and every reference carries its busy signature and interrupt"
}

test_adapter_routing_check_detects_regressions() {
  local missing="$TMP_ROOT/adapters-missing"
  local orphan="$TMP_ROOT/adapters-orphan"
  local stripped="$TMP_ROOT/adapters-stripped"

  cp -R "$ADAPTER_SKILL_DIR" "$missing"
  rm -f "$missing/references/codex.md"
  run_expect_failure "routing row points at missing reference: references/codex.md" \
    adapter_router_check "$missing"

  cp -R "$ADAPTER_SKILL_DIR" "$orphan"
  cat > "$orphan/references/unrouted.md" <<'MD'
# unrouted

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Interrupt | single Escape |
MD
  run_expect_failure "reference unreachable from the routing table: references/unrouted.md" \
    adapter_router_check "$orphan"

  cp -R "$ADAPTER_SKILL_DIR" "$stripped"
  grep -v '^| Interrupt ' "$ADAPTER_SKILL_DIR/references/claude.md" \
    > "$stripped/references/claude.md"
  run_expect_failure "reference documents no interrupt: references/claude.md" \
    adapter_router_check "$stripped"

  pass "a missing, orphaned, or safety-fact-stripped adapter reference fails the check"
}

test_repository_inventory_passes
test_duplicate_and_setup_classification_fail
test_required_pointer_fails
test_local_links_and_no_keyword_heuristic
test_adapter_routing_is_complete_and_safe
test_adapter_routing_check_detects_regressions

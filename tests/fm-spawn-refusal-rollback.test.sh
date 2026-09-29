#!/usr/bin/env bash
# Regression tests for what a refused or foreign-slot spawn leaves behind.
#
# A spawn creates its terminal window before it knows which worktree it will
# run in, so every refusal after that point used to strand the window (and, on
# the treehouse path, the pool lease held by the shell inside it) with no task
# record naming either: teardown then refused the missing record and the next
# spawn of the same id failed on the existing window. These cases drive the
# real spawn path with a recording fake tmux and prove:
#   - a refusal after the window exists closes that exact window, publishes no
#     record, and an immediate retry succeeds;
#   - a borrowed worktree is joined as-is: its uncommitted work does not refuse
#     the spawn and its branch is never reset to origin;
#   - pool slots that belong to another clone of the repository are kept busy
#     while `treehouse get` chooses, reported once per home, and released.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-refusal-rollback)

# A tmux stub that logs every call, returns a stable window id from new-window,
# and reports FM_FAKE_PANE_PATH as the pane's cwd. On the `treehouse get` send it
# snapshots FM_FENCE_LOG so a case can see which fences were live at that moment.
make_rollback_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TMUX_LOG:-/dev/null}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  new-window) printf '@77\n' ;;
  send-keys)
    case "$*" in
      *"treehouse get"*)
        [ -z "${FM_FENCE_LOG:-}" ] || cp "$FM_FENCE_LOG" "$FM_FENCE_LOG.at-get" 2>/dev/null || true
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # The foreign-slot fence runs `sleep` inside each slot: record where and as
  # which process, then really sleep so the fence is live until released.
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = 300 ] && [ -n "${FM_FENCE_LOG:-}" ]; then
  printf '%s %s\n' "$$" "$(pwd -P)" >> "$FM_FENCE_LOG"
  exec /bin/sleep "$@"
fi
exit 0
SH
  chmod +x "$fakebin/sleep"
  # treehouse: `status` lists FM_FAKE_POOL_SLOTS; every other verb is a no-op.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  n=0
  for slot in ${FM_FAKE_POOL_SLOTS:-}; do
    n=$((n + 1))
    printf '%s     available    %s\n' "$n" "$slot"
  done
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# <name> <id>: a home, a project clone with an origin, a second clone of the same
# origin, and a Treehouse-shaped pool holding one slot of each clone.
make_case() {
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  HOME_DIR="$case_dir/home"
  PROJECT_DIR="$case_dir/project"
  OTHER_CLONE="$case_dir/other/project"
  POOL="$case_dir/pool"
  FAKEBIN_DIR=$(make_rollback_fakebin "$case_dir/fake")
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" "$id"

  git init --quiet -b main "$case_dir/seed"
  git -C "$case_dir/seed" -c user.name=T -c user.email=t@e.invalid commit -q --allow-empty -m initial
  git clone --quiet --bare "$case_dir/seed" "$case_dir/origin.git"
  git clone --quiet "file://$case_dir/origin.git" "$PROJECT_DIR"
  git clone --quiet "file://$case_dir/origin.git" "$OTHER_CLONE"

  mkdir -p "$POOL"
  printf '{"worktrees":[]}\n' > "$POOL/treehouse-state.json"
  git -C "$OTHER_CLONE" worktree add --quiet --detach "$POOL/1/project"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL/2/project"
  FOREIGN_SLOT=$(cd "$POOL/1/project" && pwd -P)
  OWN_SLOT=$(cd "$POOL/2/project" && pwd -P)
  FM_TMUX_LOG="$case_dir/tmux.log"
  export FM_TMUX_LOG
  : > "$FM_TMUX_LOG"
}

run_spawn() {
  local pane=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$pane" "$FAKEBIN_DIR" "$@"
}

# A treehouse get that lands in another clone's slot is refused, and the refusal
# closes the window it had already opened and publishes no record, so the
# immediate retry for the same id is not blocked by a leftover.
test_refusal_closes_its_window_and_retry_succeeds() {
  local id=refusal-closes-r1 out status
  make_case refusal-closes "$id"

  out=$(run_spawn "$FOREIGN_SLOT" "$id" "$PROJECT_DIR" --scout)
  status=$?
  expect_code 1 "$status" "a spawn handed another clone's slot should refuse"$'\n'"$out"
  assert_contains "$out" "worktree of another clone" \
    "the refusal did not name the foreign clone as its reason"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused spawn published a task record"
  assert_grep 'kill-window -t @77' "$FM_TMUX_LOG" \
    "the refused spawn did not close the exact window it created"

  : > "$FM_TMUX_LOG"
  out=$(run_spawn "$OWN_SLOT" "$id" "$PROJECT_DIR" --scout)
  status=$?
  expect_code 0 "$status" "the retry after a refusal should launch"$'\n'"$out"
  assert_grep "worktree=$OWN_SLOT" "$HOME_DIR/state/$id.meta" \
    "the retry did not record its own clone's slot"
  assert_no_grep 'kill-window' "$FM_TMUX_LOG" \
    "a successful spawn closed its own window"
  pass "a refused spawn closes its window and publishes nothing, so an immediate retry launches"
}

# Borrowing joins another task's live copy: uncommitted work there is expected,
# and its branch must never be reset to origin.
test_borrowed_worktree_is_neither_refused_nor_reset() {
  local id=borrow-dirty-r2 out status borrowed head_before
  make_case borrow-dirty "$id"
  borrowed="$TMP_ROOT/borrow-dirty/owner-wt"
  git -C "$PROJECT_DIR" worktree add --quiet -b owner-branch "$borrowed"
  git -C "$borrowed" -c user.name=T -c user.email=t@e.invalid commit -q --allow-empty -m owner-work
  head_before=$(git -C "$borrowed" rev-parse HEAD)
  printf 'in progress\n' > "$borrowed/wip.txt"

  out=$(run_spawn "$borrowed" "$id" "$PROJECT_DIR" --scout --borrow-worktree "$borrowed")
  status=$?
  expect_code 0 "$status" "borrowing a worktree with uncommitted work should launch"$'\n'"$out"
  assert_equals "$head_before" "$(git -C "$borrowed" rev-parse HEAD)" \
    "the borrowed worktree's branch was moved"
  assert_present "$borrowed/wip.txt" "the borrowed worktree lost its uncommitted work"

  rm -f "$borrowed/wip.txt"
  fm_test_spawn_brief "$HOME_DIR" "$id-clean"
  out=$(run_spawn "$borrowed" "$id-clean" "$PROJECT_DIR" --scout --borrow-worktree "$borrowed")
  status=$?
  expect_code 0 "$status" "borrowing a clean worktree should launch"$'\n'"$out"
  assert_equals "$head_before" "$(git -C "$borrowed" rev-parse HEAD)" \
    "borrowing a clean worktree reset its branch to origin, discarding the owner's commit"
  pass "a borrowed worktree is joined as-is: no refusal for its work, no reset of its branch"
}

# Another clone's slots are fenced while treehouse get chooses, reported once
# per home, and released once the spawn is done with them.
test_foreign_pool_slots_are_fenced_reported_once_and_released() {
  local id=foreign-fence-r3 out status pid slot
  make_case foreign-fence "$id"
  FM_FENCE_LOG="$TMP_ROOT/foreign-fence/fence.log"
  FM_FAKE_POOL_SLOTS="$FOREIGN_SLOT $OWN_SLOT"
  export FM_FENCE_LOG FM_FAKE_POOL_SLOTS
  : > "$FM_FENCE_LOG"

  out=$(run_spawn "$OWN_SLOT" "$id" "$PROJECT_DIR" --scout)
  status=$?
  expect_code 0 "$status" "a spawn beside another clone's slot should launch"$'\n'"$out"
  assert_grep "worktree=$OWN_SLOT" "$HOME_DIR/state/$id.meta" \
    "the spawn did not record its own clone's slot"
  assert_grep " $FOREIGN_SLOT" "$FM_FENCE_LOG.at-get" \
    "the foreign slot was not held busy when treehouse get chose a slot"
  assert_no_grep " $OWN_SLOT" "$FM_FENCE_LOG.at-get" \
    "the spawn fenced a slot of its own clone"
  assert_contains "$out" "skipping Treehouse pool slot $FOREIGN_SLOT" \
    "the foreign slot was not reported"
  while read -r pid slot; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      fail "the fence in $slot outlived the spawn"
    fi
  done < "$FM_FENCE_LOG"

  fm_test_spawn_brief "$HOME_DIR" "$id-again"
  out=$(run_spawn "$OWN_SLOT" "$id-again" "$PROJECT_DIR" --scout)
  status=$?
  expect_code 0 "$status" "a second spawn beside the same foreign slot should launch"$'\n'"$out"
  assert_not_contains "$out" "skipping Treehouse pool slot" \
    "the same foreign slot was reported again"
  unset FM_FENCE_LOG FM_FAKE_POOL_SLOTS
  pass "another clone's pool slots are fenced during slot choice, reported once, and released"
}

test_refusal_closes_its_window_and_retry_succeeds
test_borrowed_worktree_is_neither_refused_nor_reset
test_foreign_pool_slots_are_fenced_reported_once_and_released

echo "# all fm-spawn-refusal-rollback tests passed"

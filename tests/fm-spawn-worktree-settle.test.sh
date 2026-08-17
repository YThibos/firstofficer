#!/usr/bin/env bash
# Tests for how fm-spawn.sh decides which worktree a task runs in: the
# treehouse-get settle loop, and the --borrow-worktree path that joins a worktree
# another live task already owns.
#
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "$@" 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# --borrow-worktree joins a worktree another live task owns, so one story keeps one
# checkout. It skips the settle loop entirely - there is no treehouse get and no
# pane to wait on - and the recorded worktree must be exactly the borrowed path,
# marked so teardown never treats it as this task's own.
test_borrowed_worktree_is_joined_and_marked() {
  local rec id out status borrowed
  id=borrow-joined-z3
  rec=$(make_settle_case borrow-joined "$id" 0)
  read_settle_record "$rec"
  # A second worktree, distinct from the one the fake pane reports, so the recorded
  # path proves it came from the flag rather than from polling the pane.
  borrowed="$PROJ_DIR-owner-wt"
  git -C "$PROJ_DIR" worktree add --quiet -b owner-branch-z3 "$borrowed"

  out=$(run_settle_spawn "$id" --borrow-worktree "$borrowed")
  status=$?
  expect_code 0 "$status" "a borrowing spawn should succeed"
  assert_grep "worktree=$borrowed" "$HOME_DIR/state/$id.meta" \
    "meta did not record the borrowed worktree"
  assert_no_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta recorded the pane's worktree instead of the borrowed one"
  assert_grep "borrowed_worktree=1" "$HOME_DIR/state/$id.meta" \
    "meta did not mark the worktree as borrowed, so teardown would return another task's checkout"
  pass "--borrow-worktree joins the owning task's worktree and marks it borrowed"
}

# A worktree-resident turn-end signal has one fixed name, so a borrower writing it
# would silently hijack the owning task's signal. That must be a loud refusal, never
# a spawn that leaves firstmate blind to the owner's turns.
test_borrow_refuses_a_worktree_resident_turn_end_signal() {
  local rec id out status
  id=borrow-refused-z4
  rec=$(make_settle_case borrow-refused "$id" 0)
  read_settle_record "$rec"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"

  out=$(run_settle_spawn "$id" --borrow-worktree "$WT_DIR")
  status=$?
  expect_code 1 "$status" "borrowing on claude must be refused"
  assert_contains "$out" "turn-end signal into the worktree" \
    "refusal did not name the hijacked turn-end signal"
  assert_contains "$out" "codex, pi, or pi-signed" \
    "refusal did not name a harness that can share a worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused borrowing spawn still recorded metadata"
  pass "--borrow-worktree refuses a harness whose turn-end signal lives in the worktree"
}

test_borrow_refuses_a_missing_worktree() {
  local rec id out status
  id=borrow-missing-z5
  rec=$(make_settle_case borrow-missing "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id" --borrow-worktree "$WT_DIR-does-not-exist")
  status=$?
  expect_code 1 "$status" "borrowing a nonexistent path must be refused"
  assert_contains "$out" "does not exist" "refusal did not name the missing path"
  pass "--borrow-worktree refuses a path that is not there"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_borrowed_worktree_is_joined_and_marked
test_borrow_refuses_a_worktree_resident_turn_end_signal
test_borrow_refuses_a_missing_worktree

echo "# all fm-spawn-worktree-settle tests passed"

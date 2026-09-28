#!/usr/bin/env bash
# Tests for how fm-spawn.sh decides which worktree a task runs in: the
# treehouse-get settle loop. Also covers where a claude crewmate's turn-end hook
# is written.
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
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

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
  send-keys)
    # Record literal text sent to the pane, so a test can read the launch command
    # the crewmate actually receives.
    if [ -n "${FM_FAKE_SENDLOG:-}" ]; then
      prev=
      for arg in "$@"; do
        [ "$prev" = -l ] && printf '%s\n' "$arg" >> "$FM_FAKE_SENDLOG"
        prev=$arg
      done
    fi
    exit 0
    ;;
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
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
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
    FM_FAKE_PANE_PATH="${FM_FAKE_PANE_PATH:-$WT_DIR}" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_SENDLOG="${FM_FAKE_SENDLOG:-}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$@" 2>&1
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

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 2 ] || fail "already-settled pane took $reads reads to confirm - expected the first read plus one confirmation"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

# --- a respawn does not inherit the previous session's idle clock ------------
# state/<id>.turn-ended is the harness-neutral "this task completed a turn"
# marker, and the watcher ages it to bound how long a busy pane may run with no
# completed turn. Nothing else clears it, so a task relaunched under the same id
# used to start life carrying the marker of the session it replaced: a
# relaunched task was observed reporting nearly six days idle within an hour of
# starting, while demonstrably working. Publishing new metadata is the moment
# the previous session stops being this task, so the marker goes with it.
test_respawn_does_not_inherit_the_previous_idle_clock() {
  local rec id out status
  id=respawn-idle-clock-z9
  rec=$(make_settle_case respawn-idle-clock "$id" 0)
  read_settle_record "$rec"

  # A marker left behind by a session that is long gone.
  printf 'x\n' > "$HOME_DIR/state/$id.turn-ended"
  touch -d '2026-08-20 09:00:00' "$HOME_DIR/state/$id.turn-ended"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "respawn should succeed"
  assert_contains "$out" "spawned $id" "respawn did not report success"
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "respawn published no durable record"
  [ ! -e "$HOME_DIR/state/$id.turn-ended" ] \
    || fail "the previous session's completed-turn marker survived the respawn, so the new session inherits its idle age"
  pass "a respawn does not inherit the previous session's idle clock"
}

# claude's turn-end hook is keyed on the task id and stored outside the worktree, so
# two claude agents in one checkout signal independently. This is the property the
# whole co-located-review design rests on, so it is asserted directly: a leftover
# worktree settings file would fire the other agent's hook on every turn of this one,
# because --settings merges with it rather than replacing it.
test_claude_spawn_keeps_its_hook_out_of_the_worktree() {
  local rec id out status settings
  id=claude-hook-relocated-z6
  rec=$(make_settle_case claude-hook-relocated "$id" 0)
  read_settle_record "$rec"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  FM_FAKE_SENDLOG="$HOME_DIR/sent.log"
  export FM_FAKE_SENDLOG

  out=$(run_settle_spawn "$id")
  status=$?
  unset FM_FAKE_SENDLOG

  expect_code 0 "$status" "a claude spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_absent "$WT_DIR/.claude/settings.local.json" \
    "the spawn wrote a fixed-name hook into the worktree, which a second agent would overwrite"
  settings="$HOME_DIR/state/$id.claude-settings.json"
  assert_present "$settings" "the spawn did not write the task's own turn-end hook outside the worktree"
  assert_grep "$HOME_DIR/state/$id.turn-ended" "$settings" \
    "the relocated hook does not signal this task's own turn-end"
  assert_grep "--settings '$settings'" "$HOME_DIR/sent.log" \
    "the launch command does not carry the relocated hook, so the agent would signal nothing"
  pass "a claude spawn keeps its turn-end hook outside the worktree and carries it on the launch"
}

# The raw-launch escape hatch bypasses the launch template, so a claude command
# passed that way must carry the placeholder itself. Claude used to find the hook in
# the worktree with no flag at all, so losing the signal silently is the failure this
# guards against.
test_raw_claude_launch_without_the_placeholder_warns() {
  local rec id out status
  id=raw-claude-z8
  rec=$(make_settle_case raw-claude "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id" 'claude --dangerously-skip-permissions')
  status=$?
  expect_code 0 "$status" "a raw claude launch should still spawn"
  assert_contains "$out" "will not signal turn-end" \
    "a raw claude launch lost its turn-end signal without saying so"

  id=raw-claude-placeholder-z9
  rec=$(make_settle_case raw-claude-placeholder "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id" 'claude --settings __CLAUDESETTINGS__ --dangerously-skip-permissions')
  status=$?
  expect_code 0 "$status" "a raw claude launch carrying the placeholder should spawn"
  case "$out" in
    *"will not signal turn-end"*) fail "a raw claude launch carrying the placeholder was warned about anyway" ;;
  esac
  pass "a raw claude launch is warned when it would silently lose its turn-end signal"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_respawn_does_not_inherit_the_previous_idle_clock
test_claude_spawn_keeps_its_hook_out_of_the_worktree
test_raw_claude_launch_without_the_placeholder_warns

echo "# all fm-spawn-worktree-settle tests passed"

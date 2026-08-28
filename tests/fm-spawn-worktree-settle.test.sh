#!/usr/bin/env bash
# Tests for how fm-spawn.sh decides which worktree a task runs in: the
# treehouse-get settle loop, and the --borrow-worktree path that joins a worktree
# another live task already owns. Also covers where a claude crewmate's turn-end hook
# is written, which is what lets two claude agents share one checkout.
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
    FM_FAKE_PANE_PATH="${FM_FAKE_PANE_PATH:-$WT_DIR}" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_SENDLOG="${FM_FAKE_SENDLOG:-}" \
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

  FM_FAKE_PANE_PATH="$borrowed"
  out=$(run_settle_spawn "$id" --borrow-worktree "$borrowed")
  status=$?
  unset FM_FAKE_PANE_PATH
  expect_code 0 "$status" "a borrowing spawn should succeed"
  assert_grep "worktree=$borrowed" "$HOME_DIR/state/$id.meta" \
    "meta did not record the borrowed worktree"
  assert_no_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta recorded the pane's worktree instead of the borrowed one"
  assert_grep "borrowed_worktree=1" "$HOME_DIR/state/$id.meta" \
    "meta did not mark the worktree as borrowed, so teardown would return another task's checkout"
  pass "--borrow-worktree joins the owning task's worktree and marks it borrowed"
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

# Independence comes from the hook being keyed on the task id, so a borrowing claude
# reviewer must never disturb the implementer's signal.
test_borrowing_claude_keeps_the_owners_hook_intact() {
  local rec id owner_settings out status
  id=borrow-claude-z7
  rec=$(make_settle_case borrow-claude "$id" 0)
  read_settle_record "$rec"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  owner_settings="$HOME_DIR/state/owner-task.claude-settings.json"
  printf '{"owner":true}\n' > "$owner_settings"

  out=$(run_settle_spawn "$id" --borrow-worktree "$WT_DIR")
  status=$?
  expect_code 0 "$status" "a claude reviewer should be able to join the implementer's worktree"
  assert_grep "borrowed_worktree=1" "$HOME_DIR/state/$id.meta" \
    "meta did not mark the worktree as borrowed"
  assert_present "$HOME_DIR/state/$id.claude-settings.json" \
    "the borrower got no turn-end hook of its own"
  assert_contains "$(cat "$owner_settings")" '"owner":true' \
    "the borrower overwrote the owning task's turn-end hook"
  assert_absent "$WT_DIR/.claude/settings.local.json" \
    "the borrower wrote into the worktree it only reads"
  pass "a borrowing claude reviewer signals independently and leaves the owner's hook alone"
}

# Nothing was measured for these three, and two of them do not even share claude's
# problem: grok and kimi already keep the hook outside the worktree but key it on the
# workspace path, which two co-located agents resolve identically. Refusing loudly is
# the only honest answer until each gets its own live two-agent experiment.
# Sending `cd <worktree>` is not the same as arriving there. A pane that never
# moves would launch the agent with --dangerously-skip-permissions in the primary
# checkout while the meta claims the borrowed worktree, so the spawn must confirm
# the pane's own cwd and fail loudly instead.
test_borrow_refuses_when_the_pane_never_enters_the_worktree() {
  local rec id out status borrowed
  id=borrow-no-cd-z9
  rec=$(make_settle_case borrow-no-cd "$id" 0)
  read_settle_record "$rec"
  borrowed="$PROJ_DIR-owner-wt-z9"
  git -C "$PROJ_DIR" worktree add --quiet -b owner-branch-z9 "$borrowed"

  export FM_BORROW_CD_POLLS=2
  out=$(run_settle_spawn "$id" --borrow-worktree "$borrowed")
  status=$?
  unset FM_BORROW_CD_POLLS
  expect_code 1 "$status" "a pane that never entered the borrowed worktree must not launch an agent"
  assert_contains "$out" "did not enter the borrowed worktree" \
    "refusal did not explain that the pane never reached the borrowed worktree"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused borrowing spawn still recorded a worktree the agent is not in"
  pass "--borrow-worktree refuses when the pane's cwd never becomes the borrowed worktree"
}

test_borrow_refuses_an_unverified_harness() {
  local rec id out status harness n
  n=0
  for harness in opencode grok kimi; do
    n=$((n + 1))
    id="borrow-refused-$harness-z4$n"
    rec=$(make_settle_case "borrow-refused-$harness" "$id" 0)
    read_settle_record "$rec"
    printf '%s\n' "$harness" > "$HOME_DIR/config/crew-harness"

    out=$(run_settle_spawn "$id" --borrow-worktree "$WT_DIR")
    status=$?
    expect_code 1 "$status" "borrowing on $harness must be refused"
    assert_contains "$out" "no verified way to signal turn-end from a shared worktree" \
      "$harness: refusal did not say the sharing behaviour is unverified"
    assert_contains "$out" "claude, codex, pi, or pi-signed" \
      "$harness: refusal did not name a harness that can share a worktree"
    assert_absent "$HOME_DIR/state/$id.meta" "$harness: a refused borrowing spawn still recorded metadata"
  done
  pass "--borrow-worktree refuses opencode, grok, and kimi, whose shared-worktree signalling is unverified"
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

# The orca backend allocates a managed worktree of its own, and teardown leaves a
# borrowed worktree untouched, so a borrowing orca spawn would abandon that
# allocation forever. It must be refused before anything is allocated.
test_borrow_refuses_the_orca_backend() {
  local rec id out status
  id=borrow-orca-z8
  rec=$(make_settle_case borrow-orca "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id" --backend orca --borrow-worktree "$WT_DIR")
  status=$?
  expect_code 1 "$status" "borrowing on the orca backend must be refused"
  assert_contains "$out" "--borrow-worktree does not apply to a backend=orca spawn"     "refusal did not explain that orca allocates its own worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused borrowing orca spawn still recorded metadata"
  pass "--borrow-worktree refuses the orca backend, so no orca worktree is allocated and abandoned"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_respawn_does_not_inherit_the_previous_idle_clock
test_borrowed_worktree_is_joined_and_marked
test_claude_spawn_keeps_its_hook_out_of_the_worktree
test_raw_claude_launch_without_the_placeholder_warns
test_borrowing_claude_keeps_the_owners_hook_intact
test_borrow_refuses_an_unverified_harness
test_borrow_refuses_when_the_pane_never_enters_the_worktree
test_borrow_refuses_a_missing_worktree
test_borrow_refuses_the_orca_backend

echo "# all fm-spawn-worktree-settle tests passed"

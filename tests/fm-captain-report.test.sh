#!/usr/bin/env bash
# End-to-end tests for bin/fm-captain-report.sh: the captain's end-of-turn
# report rendered from the canonical backlog snapshot plus a turn file.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-captain-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-report)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

NOW=2026-07-14T12:00:00Z

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/fakebin"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@" >/dev/null)
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_CAPTAIN_HOLD_NOW="${HOLD_NOW:-$NOW}" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# The report outside tmux, at a fixed snapshot time.
run_report() {  # <home> [report args...]
  local home=$1
  shift
  env -u TMUX -u TMUX_PANE FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SNAPSHOT_NOW="$NOW" "$REPORT" "$@"
}

card() {  # <path> <title> <projects-json> [context]
  local path=$1 title=$2 projects=$3 context=${4:-}
  jq -n --arg title "$title" --argjson projects "$projects" --arg context "$context" '
    {title: $title, projects: $projects,
     options: [{key: "A", text: "Take the first path"}, {key: "B", text: "Take the second path"}],
     recommend: {key: "A", why: "it keeps the work moving"}}
    + (if $context == "" then {} else {context: $context} end)' > "$path"
}

hold_card() {  # <home> <task-id> <title> <projects-json> [context] [hold args...]
  local home=$1 id=$2 title=$3 projects=$4 context=${5:-}
  shift 5 2>/dev/null || shift "$#"
  card "$home/$id.card.json" "$title" "$projects" "$context"
  run_captain "$home" hold "$id" --title "Call $id" --reason "captain call pending" \
    --repo sample --decision-card "$home/$id.card.json" "$@" >/dev/null \
    || fail "could not hold $id with a decision card"
}

test_busy_report_renders_the_chosen_layout() {
  local home out expected
  home=$(make_home busy)
  printf '52\n' > "$home/data/decision-seq"
  hold_card "$home" restart-call "Restart the stopped workers" '["JustMasterData"]' \
    "Both stopped mid-task; nothing is lost."
  hold_card "$home" merge-call "Merge the green pull request" '["JustFront-UIComponents"]'
  hold_card "$home" book-call "Book the research minutes" '["JustMasterData"]'
  hold_card "$home" shared-call "Share one sign-in setup" '["JustMasterData","JustAuth"]'
  tasks_in "$home" add backfill "SHIP JustMasterData: finish the backfill" --repo JustMasterData --start
  tasks_in "$home" add relaunch-fix "Relaunch fix" --repo firstofficer --start
  cat > "$home/turn.json" <<'EOF'
{"done": [{"projects": [], "text": "Took over monitoring for this session"},
          {"projects": ["firstofficer"], "text": "Report-format investigation finished"}],
 "next": [{"projects": ["JustMasterData"], "text": "Start the recovery workers one at a time"}],
 "tasks": {"backfill": {"text": "Finish the decision-log backfill", "state": "running"},
           "relaunch-fix": {"text": "Fix the relaunch of a stopped worker", "state": "running"}}}
EOF
  out=$(run_report "$home" --turn "$home/turn.json" --width 80) || fail "the busy report did not render"
  expected=$(cat <<'EOF'
╔══ NEEDS YOUR DECISION ══ 4 open ══════════════════════════════════════════════
║
╟── JustMasterData ──────────────────────────
║
║  D53   Restart the stopped workers
║        Both stopped mid-task; nothing is lost.
║
║        (A)  Take the first path
║
║        (B)  Take the second path
║
║        » Recommended: A - it keeps the work moving
║
║  D55   Book the research minutes
║
║        (A)  Take the first path
║
║        (B)  Take the second path
║
║        » Recommended: A - it keeps the work moving
║
╟── JustFront-UIComponents ──────────────────
║
║  D54   Merge the green pull request
║
║        (A)  Take the first path
║
║        (B)  Take the second path
║
║        » Recommended: A - it keeps the work moving
║
╟── JustMasterData + JustAuth ───────────────
║
║  D56   Share one sign-in setup
║
║        (A)  Take the first path
║
║        (B)  Take the second path
║
║        » Recommended: A - it keeps the work moving
║
╚═══════════════════════════════════════════════════════════════════════════════

DONE THIS TURN  (2)
───────────────────
  Fleet             • Took over monitoring for this session
  firstofficer      • Report-format investigation finished

ONGOING  (2)
────────────
  firstofficer      • Fix the relaunch of a stopped worker (running)
  JustMasterData    • Finish the decision-log backfill (running)

NEXT
────
  JustMasterData    • Start the recovery workers one at a time
EOF
)
  assert_equals "$expected" "$out" "the busy report does not match the chosen Rail layout"
  pass "the busy report renders the chosen Rail layout, grouped by project with oldest calls first"
}

test_open_decisions_are_cumulative_until_answered() {
  local home out
  home=$(make_home cumulative)
  hold_card "$home" first-call "First open call" '["JustAuth"]'
  hold_card "$home" second-call "Second open call" '["JustAuth"]'
  printf '{"tasks": {"first-call": {"text": "Reworded but still listed"}}}\n' > "$home/turn.json"
  out=$(run_report "$home" --turn "$home/turn.json") || fail "the report did not render"
  assert_contains "$out" "NEEDS YOUR DECISION ══ 2 open" "an open call was dropped from the count"
  assert_contains "$out" "D1    First open call" "a turn file reworded or dropped a carded call"
  assert_contains "$out" "D2    Second open call" "a call the turn file never mentioned was dropped"
  printf 'Captain: D1 A\n' > "$home/answer.txt"
  run_captain "$home" answer D1 --decision-file "$home/answer.txt" >/dev/null \
    || fail "the decision number alias did not answer the call"
  out=$(run_report "$home") || fail "the report did not render after the answer"
  assert_contains "$out" "NEEDS YOUR DECISION ══ 1 open" "the answered call is still counted"
  assert_not_contains "$out" "First open call" "the answered call is still in the decision box"
  assert_contains "$out" "D2    Second open call" "the remaining call lost its stable number"
  pass "every open call reappears until answered, and an answered call leaves the next report"
}

test_backlog_shows_only_when_nothing_is_open_or_ongoing() {
  local home out i
  home=$(make_home backlog)
  for i in 1 2 3 4 5 6 7; do
    tasks_in "$home" add "queued-$i" "Queued work $i" --repo firstofficer
  done
  run_captain "$home" hold demo-questions --title "Questions for the next demo" \
    --reason "keep parked" --repo JustMasterData --until 2026-10-20 >/dev/null \
    || fail "could not defer the parked call"
  tasks_in "$home" add paused-work "Paused work" --repo JustAuth
  tasks_in "$home" hold paused-work --reason "waiting on infrastructure"
  out=$(run_report "$home") || fail "the quiet report did not render"
  assert_contains "$out" "NEEDS YOUR DECISION ══ nothing open" "the empty decision box lost its count line"
  assert_contains "$out" "║  Nothing waiting on you" "the empty decision box lost its placeholder"
  assert_contains "$out" "BACKLOG  (7)" "the quiet report did not count the whole backlog"
  assert_contains "$out" "(+2 more queued)" "the quiet report did not show the top five plus a remainder"
  assert_contains "$out" "Questions for the next demo - deferred until 2026-10-20" "a dated call did not park with its date"
  assert_contains "$out" "Paused work - on hold" "a non-captain hold did not park"
  assert_contains "$out" "PARKED  (2)" "the parked count is wrong"

  tasks_in "$home" add busy-work "Busy work" --repo firstofficer --start
  out=$(run_report "$home") || fail "the report with ongoing work did not render"
  assert_not_contains "$out" "BACKLOG" "BACKLOG showed while work is ongoing"
  tasks_in "$home" "done" busy-work
  hold_card "$home" open-call "An open call" '[]'
  out=$(run_report "$home") || fail "the report with an open call did not render"
  assert_not_contains "$out" "BACKLOG" "BACKLOG showed while a call is open"
  assert_contains "$out" "╟── Fleet ──" "a call with no project did not group under Fleet"
  pass "BACKLOG shows only on a quiet fleet, and PARKED carries deferred and held work"
}

test_aged_calls_stay_open_and_parked_calls_keep_their_numbers() {
  local home out
  home=$(make_home aged)
  HOLD_NOW=2026-06-01T12:00:00Z hold_card "$home" aged-call "An old unanswered call" '["JustAuth"]'
  hold_card "$home" dated-call "A deferred call" '["JustAuth"]' "" --until 2026-10-20
  tasks_in "$home" add prereq "Prerequisite work" --repo JustAuth
  hold_card "$home" blocked-call "A blocked call" '["JustAuth"]'
  tasks_in "$home" block blocked-call --by prereq
  out=$(run_report "$home") || fail "the report did not render"
  assert_contains "$out" "NEEDS YOUR DECISION ══ 1 open" "the aged call was not counted as open"
  assert_contains "$out" "$(printf '%s\n' \
    "║  D1    An old unanswered call" \
    "║" \
    "║        (A)  Take the first path" \
    "║" \
    "║        (B)  Take the second path" \
    "║" \
    "║        » Recommended: A - it keeps the work moving")" \
    "the aged call did not stay in the decision box in full"
  assert_contains "$out" "PARKED  (2)" "the parked count is wrong"
  assert_contains "$out" "D2 A deferred call - deferred until 2026-10-20" \
    "the deferred call lost its number or its date in PARKED"
  assert_contains "$out" "D3 A blocked call - blocked by prereq" \
    "the blocked call lost its number or its blocker in PARKED"
  pass "an aged call stays open in full, and parked calls keep their number and reason"
}

test_items_group_under_project_titles() {
  local home out
  home=$(make_home groups)
  cat > "$home/turn.json" <<'EOF'
{"done": [{"projects": ["onboarding"], "text": "Onboarding item"},
          {"projects": ["JustFront-UIComponents"], "text": "Long title item"},
          {"projects": [], "text": "Fleet item"},
          {"projects": ["JustAuth"], "text": "JustAuth item"},
          {"projects": ["JustAuth"], "text": "Second JustAuth item"}]}
EOF
  out=$(run_report "$home" --turn "$home/turn.json") || fail "the grouped report did not render"
  assert_contains "$out" "$(printf '%s\n' \
    "DONE THIS TURN  (5)" \
    "───────────────────" \
    "  Fleet             • Fleet item" \
    "  JustAuth          • JustAuth item" \
    "                    • Second JustAuth item" \
    "  JustFront-UIComponents" \
    "                    • Long title item" \
    "  onboarding        • Onboarding item")" \
    "items are not grouped Fleet first, then by case-insensitive project title"
  pass "items group under project titles in the label column, with long titles on their own line"
}

test_width_is_fixed_and_narrows_to_a_smaller_pane() {
  local home out width
  home=$(make_home width)
  hold_card "$home" link-call "Review the pull request" '["firstofficer"]' \
    "https://github.com/example-organisation/example-repository-with-a-long-name/pull/12345"
  out=$(run_report "$home") || fail "the default-width report did not render"
  width=$(printf '%s\n' "$out" | head -1 | awk '{ print length($0) }')
  assert_equals 120 "$width" "the default report is not 120 columns wide"
  out=$(run_report "$home" --width 60) || fail "the narrow report did not render"
  assert_contains "$out" "║        https://github.com/example-organisation/example-repository-with-a-long-name/pull/12345" \
    "a link longer than the line was broken instead of overflowing the open edge"
  if run_report "$home" --width 59 >/dev/null 2>"$home/narrow.err"; then
    fail "a report narrower than 60 columns was accepted"
  fi

  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ "$1 $2 $3 $4 $5" = "display-message -p -t %7 #{pane_width}" ] || exit 1
printf '%s\n' "$FM_TEST_PANE_WIDTH"
SH
  chmod +x "$home/fakebin/tmux"
  width=$(PATH="$home/fakebin:$PATH" TMUX=/tmp/fake,1,0 TMUX_PANE=%7 FM_TEST_PANE_WIDTH=90 \
    FM_HOME="$home" FM_SNAPSHOT_NOW="$NOW" "$REPORT" | head -1 | awk '{ print length($0) }') \
    || fail "the report did not render inside a narrow pane"
  assert_equals 88 "$width" "the report did not narrow to the pane width minus two"
  width=$(PATH="$home/fakebin:$PATH" TMUX=/tmp/fake,1,0 TMUX_PANE=%7 FM_TEST_PANE_WIDTH=40 \
    FM_HOME="$home" FM_SNAPSHOT_NOW="$NOW" "$REPORT" | head -1 | awk '{ print length($0) }') \
    || fail "the report did not render inside a tiny pane"
  assert_equals 60 "$width" "the report narrowed below its 60-column floor"
  width=$(PATH="$home/fakebin:$PATH" TMUX=/tmp/fake,1,0 TMUX_PANE=%7 FM_TEST_PANE_WIDTH=318 \
    FM_HOME="$home" FM_SNAPSHOT_NOW="$NOW" "$REPORT" | head -1 | awk '{ print length($0) }') \
    || fail "the report did not render inside a wide pane"
  assert_equals 120 "$width" "a wide pane widened the fixed report"
  pass "the report is 120 columns, narrows to a smaller pane, and never breaks a long link"
}

test_cardless_calls_and_invalid_input_are_reported() {
  local home out err
  home=$(make_home invalid)
  run_captain "$home" hold bare-call --title "A call without a card" \
    --reason "captain must pick" --repo sample >/dev/null || fail "could not hold the cardless call"
  out=$(run_report "$home" 2>"$home/cardless.err") || fail "a cardless call stopped the report"
  assert_contains "$out" "║  --    A call without a card" "a cardless call was not shown with its title"
  assert_contains "$out" "║        captain must pick" "a cardless call lost its hold reason"
  assert_contains "$(cat "$home/cardless.err")" "bare-call" "the cardless call was not named on stderr"

  printf '{"done": [{"text": "Shipped \xf0\x9f\x9a\x80 today"}]}\n' > "$home/emoji.json"
  if run_report "$home" --turn "$home/emoji.json" >/dev/null 2>"$home/emoji.err"; then
    fail "an emoji that could widen a line was accepted"
  fi
  assert_contains "$(cat "$home/emoji.err")" "glyph allow-list" "the glyph refusal did not say why"
  printf '{"done": [{"text": "Caf\xc3\xa9 \xe2\x80\x93 na\xc3\xafve \xe2\x80\x9cquoted\xe2\x80\x9d \xe2\x80\xa6"}]}\n' > "$home/latin.json"
  run_report "$home" --turn "$home/latin.json" >/dev/null 2>&1 \
    || fail "accented letters and typographic punctuation were refused"
  printf '{"done": [{"text": "x"}], "extra": 1}\n' > "$home/extra.json"
  if run_report "$home" --turn "$home/extra.json" >/dev/null 2>"$home/extra.err"; then
    fail "an unknown turn key was accepted"
  fi
  assert_contains "$(cat "$home/extra.err")" "unknown turn key(s): extra" "the unknown key was not named"
  printf '{"next": [{"text": "two\\nlines"}]}\n' > "$home/multiline.json"
  if run_report "$home" --turn "$home/multiline.json" >/dev/null 2>"$home/multiline.err"; then
    fail "a multi-line turn text was accepted"
  fi
  err=$(cat "$home/multiline.err")
  assert_contains "$err" "turn next text must be one non-empty line" "the multi-line refusal did not say why"
  pass "a cardless call still shows, and unsafe glyphs or malformed turn files are refused"
}

test_busy_report_renders_the_chosen_layout
test_open_decisions_are_cumulative_until_answered
test_backlog_shows_only_when_nothing_is_open_or_ongoing
test_aged_calls_stay_open_and_parked_calls_keep_their_numbers
test_items_group_under_project_titles
test_width_is_fixed_and_narrows_to_a_smaller_pane
test_cardless_calls_and_invalid_input_are_reported

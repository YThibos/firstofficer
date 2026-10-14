#!/usr/bin/env bash
# fm-captain-report.sh - render the captain's end-of-turn report.
#
# Usage:
#   fm-captain-report.sh [--turn <turn.json>] [--width <columns>]
#
# Prints the boxed report that firstmate pastes verbatim, inside a fenced
# block, at the end of every state-changing turn. The script, not the model,
# owns its layout, widths, ordering, counts, and decision numbers, so every
# report has the same shape.
#
# SOURCES. Everything durable comes from the canonical backlog parse,
# `bin/fm-fleet-snapshot.sh --backlog`, run against the active FM_HOME:
#   NEEDS YOUR DECISION  every captain hold whose hold_bucket is "live" or
#                        "aged", with its decision card and stable D number
#                        from bin/fm-captain-hold.sh; age never moves an
#                        unanswered call out of the box. A hold without a card
#                        is still shown, as "--" with its title and hold
#                        reason, and named on stderr so it gets a card.
#   ONGOING              In-flight worker and program rows.
#   PARKED               captain holds that are dated (deferred with --until)
#                        or blocked, each with its D number and why it waits,
#                        and rows held for any other reason.
#   BACKLOG              Queued rows that are not held, newest filed first,
#                        top five plus a count of the rest.
# Only the turn-specific lines come from firstmate, in the optional turn file:
#   {"done": [{"projects": ["JustMasterData"], "text": "..."}],
#    "next": [{"projects": [], "text": "..."}],
#    "tasks": {"<task-id>": {"text": "plain wording", "state": "running",
#                            "projects": ["JustMasterData", "JustAuth"]}}}
# "tasks" rewords any backlog-sourced row by task id (text replaces the
# backlog title, state is appended in parentheses, projects replaces the row's
# project set); it can never add or remove a decision, so every open call
# reappears in every report until it is answered. Every text is one non-empty
# line; unknown keys are refused.
#
# LAYOUT (the captain's chosen "Rail" style).
#   - The decision zone always renders first: a double-ruled top line with the
#     open count ("nothing open" when empty), a double left rail, and a double
#     bottom rule; there is no right border, so wrapping or a long link never
#     breaks a frame.
#   - Inside it, each project set opens with a "╟── <title> ───" separator.
#     Groups are ordered by their lowest D number, and decisions within a group
#     by D number, so the oldest call is on top; cardless calls come last.
#   - A decision is its D number and title, optional context, then each
#     lettered option "(A)" after a blank rail line, then a blank rail line and
#     "» Recommended: <key> - <why>".
#   - Below it, in order: DONE THIS TURN (n), ONGOING (n), NEXT, PARKED (n)
#     only when non-empty, and BACKLOG (n) only when nothing is open and
#     nothing is ongoing. Each is an upper-case heading underlined to its own
#     length.
#   - Items group under their project set in an 18-column label column with
#     "•" bullets; a title longer than 16 characters sits on its own line.
#     Items with no project group under "Fleet", which comes first; other
#     groups follow in case-insensitive title order. A project set's title is
#     its members joined by " + " in stored order.
#   - Prose wraps at word boundaries with a hanging indent and never breaks a
#     word, so a URL longer than the line overflows the open right edge intact.
#
# WIDTH. The report is 120 columns, or --width (at least 60). When the
# script runs inside tmux and the pane is narrower than the report plus the two
# columns Claude Code indents a message by, it narrows to the pane width minus
# two, never below 60. Outside tmux the configured width is used as is.
#
# GLYPHS. Every glyph the report draws is single-width in common terminal
# fonts. Supplied text is limited to printable ASCII, Latin-1 and Latin
# Extended-A letters, the general punctuation block (dashes, quotes, bullet,
# ellipsis), and the euro sign; any other character - an emoji, a wide CJK
# character - is refused naming the text, because it could widen a line.
#
# Exit status: 0 with the report on stdout; 1 on invalid input or a failed
# snapshot, with the reason on stderr; 2 on a usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_WIDTH=120
MIN_WIDTH=60
CLAUDE_INDENT=2

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-captain-report: %s\n' "$*" >&2
  exit 1
}

turn_file=''
width=$DEFAULT_WIDTH
while [ "$#" -gt 0 ]; do
  case "$1" in
    --turn) shift; turn_file=${1:-}; [ -n "$turn_file" ] || { usage >&2; exit 2; } ;;
    --width) shift; width=${1:-} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

case "$width" in
  ''|*[!0-9]*) fail "--width must be a whole number of columns, not: $width" ;;
esac
[ "$width" -ge "$MIN_WIDTH" ] || fail "--width must be at least $MIN_WIDTH columns"
command -v jq >/dev/null 2>&1 || fail "jq is required"

# Narrow to the live pane only when it is smaller than the report.
pane_width() {
  [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux display-message -p -t "$TMUX_PANE" '#{pane_width}' 2>/dev/null
}
if pane=$(pane_width) && [ -n "$pane" ] && [ "$pane" -eq "$pane" ] 2>/dev/null; then
  if [ $((pane - CLAUDE_INDENT)) -lt "$width" ]; then
    width=$((pane - CLAUDE_INDENT))
    [ "$width" -ge "$MIN_WIDTH" ] || width=$MIN_WIDTH
  fi
fi

if [ -n "$turn_file" ]; then
  { [ -f "$turn_file" ] && [ -r "$turn_file" ]; } || fail "turn file is not readable: $turn_file"
  turn=$(cat -- "$turn_file") || fail "cannot read the turn file: $turn_file"
else
  turn='{}'
fi

snapshot=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --backlog) || fail "the backlog snapshot failed"

cardless=$(printf '%s' "$snapshot" | jq -r '
  [.backlog.records[]? | select(.structured and (.hold_bucket == "live" or .hold_bucket == "aged") and .decision_card == null) | .id]
  | join(", ")') || fail "the backlog snapshot is not valid JSON"
[ -z "$cardless" ] || printf 'fm-captain-report: held for the captain without a decision card (shown as --): %s\n' "$cardless" >&2

# shellcheck disable=SC2016
program='
  def one_line($label):
    if type == "string" and length > 0 and (test("[\r\n]") | not) then .
    else error("\($label) must be one non-empty line") end;
  def projects_of($label):
    if . == null then []
    elif type == "array" then map(one_line("\($label) project"))
    else error("\($label) projects must be an array") end;
  def turn_items($key):
    (.[$key] // []) as $items
    | if ($items | type) != "array" then error("turn \($key) must be an array") else $items end
    | map(if type != "object" then error("each turn \($key) item must be an object") else . end
        | if (keys - ["projects", "text"] | length) > 0 then error("turn \($key) items take only projects and text") else . end
        | {projects: (.projects | projects_of("turn \($key)")), text: (.text | one_line("turn \($key) text"))});
  def turn_tasks:
    (.tasks // {}) as $tasks
    | if ($tasks | type) != "object" then error("turn tasks must be an object keyed by task id") else $tasks end
    | with_entries(.key as $id | .value |= (
        if type != "object" then error("turn tasks.\($id) must be an object") else . end
        | if (keys - ["projects", "state", "text"] | length) > 0 then error("turn tasks.\($id) takes only text, state, and projects") else . end
        | {text: (if .text == null then null else .text | one_line("turn tasks.\($id) text") end),
           state: (if .state == null then null else .state | one_line("turn tasks.\($id) state") end),
           projects: (if .projects == null then null else .projects | projects_of("turn tasks.\($id)") end)}));

  def allowed: test("^[ -~ -ſ‐-‧€]*$");
  def checked: if allowed then . else error("text outside the report glyph allow-list: \(.)") end;

  def repeat($s; $n): if $n > 0 then $s * $n else "" end;
  def pad($n): . + repeat(" "; $n - length);
  def wrap($w):
    (split(" ") | map(select(length > 0))) as $words
    | if ($words | length) == 0 then [""]
      else reduce $words[] as $word ({lines: [], cur: ""};
          if .cur == "" then .cur = $word
          elif (.cur | length) + 1 + ($word | length) <= $w then .cur += " " + $word
          else .lines += [.cur] | .cur = $word end)
        | .lines + [.cur] end;
  def hang($w; $first; $rest):
    (wrap($w - ($first | length))) as $lines
    | [$first + $lines[0]] + [$lines[1:][] | $rest + .];
  def group_title: if length == 0 then "Fleet" else join(" + ") end;

  def task_groups:
    reduce .[] as $item ({};
      ($item.projects | group_title) as $title
      | .[$title] += [$item])
    | to_entries
    | sort_by((.key != "Fleet"), (.key | ascii_downcase))
    | map({title: .key, items: .value});

  def column_lines($groups; $w; $placeholder):
    if ($groups | length) == 0 then ["  " + $placeholder]
    else [ $groups[] as $g
      | if $g.title == "" then ($g.items[] | "  " + .text)
        else
          ($g.title | length <= 16) as $fits
          | (if $fits then empty else "  " + $g.title end),
            ($g.items | to_entries[] | . as $entry
              | (if $fits and $entry.key == 0 then "  " + ($g.title | pad(18)) else "  " + repeat(" "; 18) end) as $lead
              | $entry.value.text | hang($w; $lead + "• "; "  " + repeat(" "; 20))[])
        end ] end;

  def section($title; $count; $lines):
    ($title + (if $count == null then "" else "  (\($count))" end)) as $heading
    | ["", $heading, repeat("─"; $heading | length)] + $lines;

  if type != "object" then error("the turn file must hold one JSON object") else . end
  | (keys - ["done", "next", "tasks"]) as $extra
  | if ($extra | length) > 0 then error("unknown turn key(s): \($extra | join(", "))") else . end
  | . as $turn_raw
  | ($turn_raw | turn_items("done")) as $done
  | ($turn_raw | turn_items("next")) as $next
  | ($turn_raw | turn_tasks) as $over
  | [$snap.backlog.records[]? | select(.structured)] as $rows
  | def reworded: . as $row | ($over[$row.id] // {}) as $o
      | {text: ($o.text // $row.title), state: $o.state, projects: ($o.projects // $row.projects)};

  ([$rows[] | select(.hold_bucket == "live" or .hold_bucket == "aged")
    | . as $row | reworded as $r
    | {id: (.decision_id // "--"),
       n: (if .decision_id then (.decision_id[1:] | tonumber) else infinite end),
       order: .order,
       projects: $r.projects,
       title: (.decision_card.title // $r.text),
       context: (if .decision_card then .decision_card.context else .hold_reason end),
       options: (.decision_card.options // []),
       recommend: .decision_card.recommend}]
   | sort_by(.n, .order)) as $decisions
  | ([$rows[] | select(.state == "in_flight" and (.current_role == "worker" or .current_role == "program"))
      | reworded | {projects, text: (.text + (if .state then " (\(.state))" else "" end))}]) as $ongoing
  | ([$rows[] | select(.state != "done" and .hold_reason != null)
      | select(if .hold_kind == "captain" then (.hold_bucket == "dated" or .hold_bucket == "blocked") else true end)
      | . as $row | reworded
      | {projects,
         text: ((if $row.decision_id then "\($row.decision_id) " else "" end)
           + ($row.decision_card.title // .text) + " - " +
           (if $row.hold_kind != "captain" then "on hold"
            elif $row.hold_bucket == "dated" then "deferred until \($row.hold_until)"
            else "blocked by \($row.unresolved_blocker_ids | join(", "))" end))}]) as $parked
  | ([$rows[] | select(.state == "queued" and .hold_reason == null)]
      | sort_by(.order) | sort_by(if .since then (.since | explode | map(-.)) else [1] end)) as $queued
  | ([$queued[0:5][] | reworded | {projects, text}]) as $backlog
  | (($queued | length) - ($backlog | length)) as $more

  # Refuse any supplied glyph that could widen a line before drawing anything.
  | ([$decisions[] | .title, .context, (.options[] | .text), .recommend.why, .projects[]]
     + [($done + $next + $ongoing + $parked + $backlog)[] | .text, .projects[]]
     | map(select(. != null) | checked)) as $_

  | ($decisions | length) as $open
  | ($width - 3) as $bw
  | ("╔══ NEEDS YOUR DECISION ══ " + (if $open > 0 then "\($open) open " else "nothing open " end)) as $top
  | ($decisions
     | reduce .[] as $d ([]; ($d.projects | group_title) as $t
         | if any(.[]; .title == $t) then map(if .title == $t then .items += [$d] else . end)
           else . + [{title: $t, items: [$d]}] end)) as $dgroups
  | [ $top + repeat("═"; $width - ($top | length)),
      ($dgroups[] as $g
        | "║",
          ("╟── " + $g.title + " " + repeat("─"; ([4, 40 - ($g.title | length)] | max))),
          ($g.items[] as $d
            | "║",
              ($d.title | hang($bw; ($d.id | pad(6)); repeat(" "; 6))[] | "║  " + .),
              (if $d.context then ($d.context | hang($bw; repeat(" "; 6); repeat(" "; 6))[] | "║  " + .) else empty end),
              ($d.options[] as $o | "║", ($o.text | hang($bw; "      (\($o.key))  "; repeat(" "; 11))[] | "║  " + .)),
              (if $d.recommend then "║",
                 ("» Recommended: \($d.recommend.key) - \($d.recommend.why)"
                  | hang($bw; repeat(" "; 6); repeat(" "; 8))[] | "║  " + .)
               else empty end))),
      (if $open > 0 then "║" else "║  Nothing waiting on you" end),
      "╚" + repeat("═"; $width - 1) ]
    + section("DONE THIS TURN"; ($done | length); column_lines($done | task_groups; $width; "Nothing finished this turn"))
    + section("ONGOING"; ($ongoing | length); column_lines($ongoing | task_groups; $width; "Nothing running"))
    + section("NEXT"; null; column_lines($next | task_groups; $width; "Nothing planned"))
    + (if ($parked | length) > 0
       then section("PARKED"; ($parked | length); column_lines($parked | task_groups; $width; ""))
       else [] end)
    + (if $open == 0 and ($ongoing | length) == 0 and ($backlog | length) > 0
       then section("BACKLOG"; ($backlog | length) + $more;
              column_lines(($backlog | task_groups)
                + (if $more > 0 then [{title: "", items: [{text: "(+\($more) more queued)"}]}] else [] end);
                $width; ""))
       else [] end)
  | .[] | sub(" +$"; "")
'

if ! out=$(printf '%s' "$turn" | jq -r --argjson snap "$snapshot" --argjson width "$width" "$program" 2>&1); then
  fail "$(printf '%s\n' "$out" | sed -e 's/^jq: error (at [^)]*): //' -e 's/^jq: error: //' | head -1)"
fi
printf '%s\n' "$out"

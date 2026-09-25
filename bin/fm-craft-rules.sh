#!/usr/bin/env bash
# Own the captain's craftsmanship rules and which projects' no-mistakes review
# carries them.
#
# The rules ride in the no-mistakes `--intent`, which the pipeline hands to its
# review, test, document, lint, and PR agents. That puts them in front of the one
# review that already runs on every change, so no separate reviewer, verdict, or
# publication gate is needed, and a project's repository needs no committed
# pipeline config to carry them. bin/fm-dod-lib.sh renders the block into a ship
# brief's Definition of done for an applicable project and owns how the worker
# adds it to `--intent`.
#
# Which projects carry them is a per-home choice: config/craft-rules-projects
# (local, gitignored) lists one literal project name per non-empty, non-comment
# line. A project is in the set or it is not; there is no per-change judgement.
# The file being ABSENT means the rules apply everywhere, because a home that has
# said nothing must never silently lose the rules on a project that expects them.
# An all-comment file is how a home says "nowhere" out loud.
#
# Usage: fm-craft-rules.sh applies <project-name>
#        fm-craft-rules.sh print
#   applies exits 0 when <project-name> carries the rules and 1 when it does not,
#           printing the reason either way; a malformed call exits 2, so only a
#           real answer can ever read as "no".
#   print   prints the rules block exactly as it is added to `--intent`.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SCOPE="$CONFIG/craft-rules-projects"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

main() {
  case "${1:-}" in
    -h|--help) usage ;;
    applies) answer_applies "$@" ;;
    print) [ "$#" -eq 1 ] || malformed "print takes no arguments"; print_rules ;;
    *) malformed "expected applies <project-name> or print" ;;
  esac
}

answer_applies() {
  [ "$#" -eq 2 ] && [ -n "$2" ] || malformed "applies takes exactly one project name"
  if rules_apply_to "$2"; then
    echo "craftsmanship rules apply to $2$(scope_source_note)"
    return 0
  fi
  echo "craftsmanship rules do not apply to $2 (not listed in $SCOPE)"
  return 1
}

# Names are compared literally: no prefix, glob, or category rule, so a project
# can never drift into or out of the set by being named like another one.
rules_apply_to() {
  local project=$1 line
  scope_readable || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ "$line" = "$project" ] && return 0
  done < "$SCOPE"
  return 1
}

scope_readable() {
  [ -f "$SCOPE" ] && [ -r "$SCOPE" ]
}

scope_source_note() {
  scope_readable || echo " (no readable $SCOPE, so they apply everywhere)"
}

print_rules() {
  cat <<'EOF'
Craftsmanship rules this change must meet; review it against them as acceptance criteria:
- Clean Code and domain-driven design are the bar: quality first, no shortcuts or "good enough for now", and maintainability outweighs short-term speed.
- Names, boundaries, and abstractions carry the domain's language, not the mechanism's.
- Methods are short and do one thing at one level of abstraction.
- Main and public methods read as a table of contents: a sequence of named steps, with the detail below.
- Private helpers sit below their callers, ordered by first use, so the file reads top-down.
- Business-meaningful mappings are extracted into a well-named method even when they are one-liners.
- Writing: plain "-" never an em dash, United Kingdom English outside syntax and vendor terms, and one sentence per line in Markdown.
- No machine-generated tells: comments that restate the code, unrequested defensive boilerplate, docstrings narrating the implementation, a comment on every block, or an abstraction with one implementation and no second caller.
EOF
}

malformed() {
  echo "error: $1" >&2
  exit 2
}

main "$@"

#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> [<branch> <project>
# <state-dir> <config-dir>] prints the block on stdout with no trailing blank
# line. The caller validates the mode; an unknown mode is refused rather than
# silently rendered as the pipeline contract. The optional arguments shape only
# local-only: <branch> names the branch the worker publishes (default
# fm/<task-id>), and the rest let bin/fm-craft-review.sh decide, against the
# dispatching home's own scope file, whether the independent craftsmanship
# review gates publication. local-only keeps this fork's meaning - validate,
# pass that review where the home requires it, then publish the branch and open
# no merge request - and bin/fm-project-mode.sh's header owns why the name stays.
# Only the craft-review scope's definite "no" (exit 1) drops the review stage;
# an unanswerable check keeps it, because a contract must never quietly omit a
# safety stage because a check failed to run.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against.
# This file is the one owner of the no-mistakes `--intent` contract: only the
# brief's `## Captain's intent` subsection plus later captain words, never
# `## Firstmate spec` and never the worker's own tradeoffs.
# The string passed must be self-sufficient - it plus the codebase reconstructs
# roughly the same specification - so a report, decision, or PR the intent
# refers to is written into it as substance, never left as a pointer.
# bin/fm-brief.sh scaffolds those two `# Task` subsections; bin/fm-spawn.sh and
# bin/fm-promote.sh refuse leftover `{TASK}` / `{FIRSTMATE_SPEC}` placeholders
# through the helpers below. Other mentions of `--intent` point here rather than
# restating the rule.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).
# fm_brief_worker_role owns the ship/scout role scope. bin/fm-spawn.sh is its one
# emitter, supplying it to every ship/scout launch brief and never to a
# secondmate charter. Like fm_brief_intent_overlay it is a distinctly titled
# launch section that states its own precedence for Firstmate tasks, so a brief
# that authors its own role wording is superseded rather than duplicated.

fm_brief_worker_role() {
  cat <<'EOF'
# Current worker role contract
When this task works on Firstmate itself, this section supersedes every earlier brief instruction about your role and identity.
When this task works on Firstmate itself, the repository root `CLAUDE.md` and `AGENTS.md` are the primary/secondmate supervisor's contract: follow this brief instead of that supervisor contract.
For that Firstmate task, do the assigned work yourself and report to firstmate; do not adopt the supervisor identity, delegate the task, run fleet supervision, or address the captain.
This exception preserves this brief's safety and authority boundaries and applicable contributor guidance, including `CONTRIBUTING.md` and `firstmate-coding-guidelines` for Firstmate changes.
Other projects retain their own instructions unchanged.
EOF
}

# Return 0 when a Task subsection still consists only of its scaffold
# placeholder. A missing file and legacy briefs carry no such placeholders.
fm_brief_task_placeholders_present() {  # <file>
  local file=$1 intent spec
  [ -f "$file" ] || return 1
  intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
  spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
  [ "$(printf '%s' "$intent" | tr -d '[:space:]')" = '{TASK}' ] && return 0
  [ "$(printf '%s' "$spec" | tr -d '[:space:]')" = '{FIRSTMATE_SPEC}' ] && return 0
  return 1
}

# Parse an exact ATX heading outside fenced blocks. Body mode prints through
# the next unfenced heading at the same or a higher level; present mode reports
# whether the heading exists.
fm_brief_heading_parse() {  # <file|-> <heading> <body|present>
  local file=$1 heading=$2 mode=$3 input=$1
  if [ "$file" = - ]; then
    input=/dev/stdin
  else
    [ -f "$file" ] || { [ "$mode" = body ]; return; }
  fi
  awk -v heading="$heading" -v mode="$mode" '
    BEGIN {
      target_level = 0
      while (substr(heading, target_level + 1, 1) == "#") target_level++
    }
    {
      line = $0
      scan = line
      spaces = 0
      while (spaces < 3 && substr(scan, 1, 1) == " ") {
        scan = substr(scan, 2)
        spaces++
      }
      marker = substr(scan, 1, 1)
      marker_len = 0
      if (marker == "`" || marker == "~") {
        while (substr(scan, marker_len + 1, 1) == marker) marker_len++
      }
      is_fence = marker_len >= 3
      was_fenced = fenced

      if (is_fence) {
        rest = substr(scan, marker_len + 1)
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = marker_len
        } else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) {
          fenced = 0
        }
      }

      if (!found && !was_fenced && line == heading) {
        found = 1
        if (mode == "present") next
        grab = 1
        next
      }
      if (mode == "present" || !grab) next
      if (is_fence || was_fenced) {
        print line
        next
      }

      level = 0
      while (substr(scan, level + 1, 1) == "#") level++
      if (level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) exit
      print line
    }
    END {
      if (mode == "present" && !found) exit 1
    }
  ' "$input"
}

fm_brief_heading_body() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" body
}

fm_brief_heading_present() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" present >/dev/null
}

fm_brief_task_heading_body() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" body
}

fm_brief_task_heading_present() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" present >/dev/null
}

fm_brief_marked_captain_words() {  # <task-body>
  printf '%s\n' "$1" | awk '
    match($0, /^[[:space:]]*Captain('\''s (words|ask|intent))?:[[:space:]]*/) {
      words = substr($0, RLENGTH + 1)
      if (words ~ /[^[:space:]]/) print words
    }
  '
}

fm_brief_intent_overlay() {  # <captain-intent>
  cat <<'EOF'

# Current no-mistakes intent contract
This section supersedes every earlier brief instruction about constructing `--intent`, but not later clarifications actually supplied by the captain.
Use the serialized captain intent below plus any later words the captain actually supplied as `--intent`; never include Firstmate specification or other mixed Task content.

## Captain intent authorized for --intent
EOF
  printf '%s\n' "$1"
  cat <<'EOF'

Firstmate-authored constraints, acceptance criteria, implementation details, decisions, and tradeoffs are specification, not captain intent.
The Definition of done's rule that `--intent` must be self-sufficient still governs the string you pass: resolve any report, decision, or PR the intent above refers to into its substance rather than passing the pointer.
EOF
}

# Accept the current two-subsection contract only when both bodies have content;
# briefs predating that contract remain valid when their # Task body has content.
fm_brief_task_content_valid() {  # <file>
  local file=$1 intent spec task has_intent=0 has_spec=0
  [ -f "$file" ] && [ -r "$file" ] || return 1
  fm_brief_task_heading_present "$file" "## Captain's intent" && has_intent=1
  fm_brief_task_heading_present "$file" "## Firstmate spec" && has_spec=1
  if [ "$has_intent" -eq 1 ] || [ "$has_spec" -eq 1 ]; then
    [ "$has_intent" -eq 1 ] && [ "$has_spec" -eq 1 ] || return 1
    intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
    spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
    [ -n "$(printf '%s' "$intent" | tr -d '[:space:]')" ] || return 1
    [ -n "$(printf '%s' "$spec" | tr -d '[:space:]')" ] || return 1
    return 0
  fi
  task=$(fm_brief_heading_body "$file" "# Task")
  [ -n "$(printf '%s' "$task" | tr -d '[:space:]')" ]
}

fm_ask_user_escalation_block() {  # <data-dir> <task-id>
  local data=$1 id=$2
  cat <<EOF
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to \`$data/$id/nm-<run>-findings.txt\`, then report the gate with
   \`needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=$data/$id/nm-<run>-findings.txt\`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.
EOF
}

# The gate-driving contract every pipeline-running mode hands its worker,
# stated once so no-mistakes and local-only cannot drift apart.
fm_dod_pipeline_gates() {
  cat <<EOF
You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass \`--intent\` as only this brief's \`## Captain's intent\` subsection plus any later words the captain actually said.
For a legacy brief with no such subsection, include only words explicitly labeled \`Captain:\`, \`Captain's words:\`, \`Captain's ask:\`, or \`Captain's intent:\`; never copy its mixed \`# Task\` wholesale. If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include \`## Firstmate spec\`, later Firstmate build constraints, or your own decisions and tradeoffs.
The \`--intent\` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into \`--intent\` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich \`--intent\` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call and poll \`no-mistakes axi status\` from a separate call instead of sitting in one blocking hold your harness will kill.
Where a harness's own command limit is not established, assume it bounds commands and use that same background-and-poll shape.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.
EOF
}

fm_dod_shell_quote() {  # <string>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# local-only in this fork: validate without publishing, pass the independent
# craftsmanship review where this home requires it, then publish the branch and
# stop short of the merge request, which the captain's separate "ship it" word
# authorises later. A project with no remote ends at the guarded local merge.
fm_dod_local_only() {  # <task-id> <branch> <project> <state-dir> <config-dir>
  local id=$1 branch=$2 project=$3 state=$4 config=$5 root scope=0 gate
  root=${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
  if [ -n "$project" ]; then
    if [ -n "$config" ]; then
      FM_CONFIG_OVERRIDE=$config "$root/bin/fm-craft-review.sh" required "$project" >/dev/null 2>&1 || scope=$?
    else
      "$root/bin/fm-craft-review.sh" required "$project" >/dev/null 2>&1 || scope=$?
    fi
  fi
  cat <<EOF
# Definition of done
Delivery contract: mode=local-only
EOF
  if [ "$scope" -ne 1 ]; then
    # Every command a crewmate runs resolves the dispatching home explicitly,
    # because the crewmate runs outside it and its own FM_HOME would otherwise
    # read the code root's state and scope file instead.
    gate="FM_STATE_OVERRIDE=$(fm_dod_shell_quote "$state") FM_CONFIG_OVERRIDE=$(fm_dod_shell_quote "$config") $(fm_dod_shell_quote "$root/bin/fm-craft-review.sh") verify $id"
    cat <<EOF
This task ships **local-only**: you validate, an independent reviewer checks craftsmanship, then you publish your branch so the captain can look at it on the real repository.
That mode name is kept for compatibility and no longer means unpublished - publishing IS the delivery.
What you must NOT do is open the merge request: the captain gives a separate "ship it" word for that later.

Work these stages in order on your branch \`$branch\`.

1. Implement and commit.
   Keep the branch a clean fast-forward onto the current default branch - if the default branch has advanced, rebase onto it.
2. Validate without publishing. Confirm the flag spelling against \`no-mistakes axi run --help\`, then run the pipeline with its publication and merge-request steps skipped:
   \`no-mistakes axi run --intent '{captain intent, per the rule below}' --skip push,pr,ci\`
   It stops after the lint step, having pushed nothing.
3. Stop for the independent craftsmanship review.
   Append \`done: validated, ready for craftsmanship review\` to the status file and stop.
   Firstmate dispatches a reviewer that did not write this code. Do not review your own work, and do not publish yet.
4. When firstmate returns findings, fix them on this branch, run stage 2 again over the new commits, and report ready for re-review.
   The review is pinned to the exact commit it passed, so every new commit needs a fresh one.
5. Publish, and only once the review gate lets you:
   \`$gate\`
   If it refuses, do NOT publish: append \`blocked: {the exact reason it gave}\` to the status file and stop.
   Once it passes, publish the branch with the pipeline's own push step and nothing beyond it - every step that can commit a fix is skipped too, because stage 2 already ran them and a fix commit made now would reach the remote without the craftsmanship review the verdict is pinned to:
   \`no-mistakes axi run --intent '{captain intent, per the rule below}' --skip review,test,document,lint,pr,ci\`
   Then append \`done: branch $branch published\` and stop. Do NOT open a PR or merge request.
   If this project has no remote at all, publication does not apply: append \`done: reviewed and ready in branch $branch\` instead, and the configured merge authority approves before firstmate merges it into the local default branch through the guarded fast-forward path.

EOF
  else
    cat <<EOF
This task ships **local-only**: you validate, then you publish your branch so the captain can look at it on the real repository.
That mode name is kept for compatibility and no longer means unpublished - publishing IS the delivery.
What you must NOT do is open the merge request: the captain gives a separate "ship it" word for that later.

This home does not run the independent craftsmanship review on this project, so there is no reviewer to wait for and nothing gates your publish. Do not wait for one.

Work these stages in order on your branch \`$branch\`.

1. Implement and commit.
   Keep the branch a clean fast-forward onto the current default branch - if the default branch has advanced, rebase onto it.
2. Validate without publishing. Confirm the flag spelling against \`no-mistakes axi run --help\`, then run the pipeline with its publication and merge-request steps skipped:
   \`no-mistakes axi run --intent '{captain intent, per the rule below}' --skip push,pr,ci\`
   It stops after the lint step, having pushed nothing.
3. Publish the branch with the pipeline's own push step and nothing beyond it - every step that can commit a fix is skipped too, because stage 2 already ran them:
   \`no-mistakes axi run --intent '{captain intent, per the rule below}' --skip review,test,document,lint,pr,ci\`
   Then append \`done: branch $branch published\` and stop. Do NOT open a PR or merge request.
   If this project has no remote at all, publication does not apply: append \`done: ready in branch $branch\` instead, and the configured merge authority approves before firstmate merges it into the local default branch through the guarded fast-forward path.

EOF
  fi
  fm_dod_pipeline_gates
}

fm_dod_block() {  # <mode> <task-id> [<branch> <project> <state-dir> <config-dir>]
  local mode=$1 id=$2 branch=${3:-fm/$2} project=${4:-} state=${5:-} config=${6:-}
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      fm_dod_local_only "$id" "$branch" "$project" "$state" "$config"
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
EOF
      fm_dod_pipeline_gates
      cat <<EOF

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}

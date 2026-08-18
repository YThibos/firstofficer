#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> [--scout] [--herdr-lab] [--branch <name>]
#        fm-brief.sh <task-id> <repo-name> --craft-review <reviewed-task-id>
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --branch <name> sets the ship branch name the crewmate creates and works on
#   (e.g. feature/JUSTMD-123). It applies only to ship briefs (not --scout or
#   --secondmate). There is no default: an omitted --branch renders a loud,
#   unmistakable `{BRANCH}` placeholder in the brief instead of a silent guess,
#   so firstmate must supply the caller-owned branch name for every ship task
#   before dispatch.
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --craft-review <reviewed-task-id> writes the independent craftsmanship review
#   contract: the reviewer reads the named ship task's diff, writes findings to
#   data/<task-id>/craftsmanship-review.md, and records the verdict that
#   bin/fm-craft-review.sh gates publication on. It never branches, pushes,
#   merges, or edits the code it reviews. The remit itself is owned by the
#   craftsmanship-review skill, which the generated brief requires it to load.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see the project-management skill
# and AGENTS.md task lifecycle):
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> captain merge (default)
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> captain merge
#   local-only   implement -> pipeline with push/pr/ci skipped -> independent
#                craftsmanship review -> publish the branch, no merge request;
#                the captain's separate "ship it" word authorises the PR later
# The local-only name no longer describes that mode's delivery step, and is kept
# deliberately; bin/fm-project-mode.sh's header owns why. A project with no remote
# at all is the one case the name still fits: it ends at the guarded local merge.
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Scout tasks ignore mode - their deliverable is a report, not a merge.
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
BRANCH=""
REVIEWED_ID=""
POS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scout) KIND=scout; shift ;;
    --secondmate) KIND=secondmate; shift ;;
    --craft-review)
      KIND=craft-review
      shift
      [ "$#" -gt 0 ] || { echo "error: --craft-review requires the reviewed task id" >&2; exit 1; }
      REVIEWED_ID=$1
      shift
      ;;
    --herdr-lab) HERDR_LAB=1; shift ;;
    --no-projects) NO_PROJECTS=1; shift ;;
    --branch)
      shift
      [ "$#" -gt 0 ] || { echo "error: --branch requires a value" >&2; exit 1; }
      BRANCH=$1
      shift
      ;;
    *) POS+=("$1"); shift ;;
  esac
done
ID=${POS[0]}

if [ -n "$BRANCH" ] && [ "$KIND" != ship ]; then
  echo "error: --branch applies only to ship briefs" >&2
  exit 1
fi

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship, scout, or craft-review briefs" >&2
  exit 1
fi

# A worker cannot review its own code, so the reviewer and the reviewed task can
# never be the same task. Catching it here keeps the impossible brief from being
# written at all, rather than leaving bin/fm-craft-review.sh to refuse the verdict
# after a whole review has been run.
if [ "$KIND" = craft-review ] && [ "$REVIEWED_ID" = "$ID" ]; then
  echo "error: --craft-review cannot review its own task $ID; the reviewer must be a separate task" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")
# Every command a brief hands a crewmate resolves this home explicitly, because
# the crewmate runs outside it and its own FM_HOME would otherwise pick the code
# root's state dir instead of the home that dispatched the task.
STATE_ENV="FM_STATE_OVERRIDE=$(shell_quote "$STATE")"
CRAFT_REVIEW_BIN=$(shell_quote "$FM_ROOT/bin/fm-craft-review.sh")
REVIEW_DIFF_BIN=$(shell_quote "$FM_ROOT/bin/fm-review-diff.sh")

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.
Every commit your crewmates produce, in every project you supervise, is authored in the captain's name only:
never a \`Co-authored-by:\` trailer, or any other trailer, naming a model, an agent, Anthropic, or any other tool.
Claude Code adds this trailer BY DEFAULT, so brief your crewmates to actively suppress it and to verify it is
absent with \`git log -1 --format='%(trailers)'\` before reporting done.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: \`bin/fm-secondmate-report.sh\` can append a correlated status line for you, but a plain \`echo\` that includes the same \`corr=<id>\` is equally valid - do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
Before treating an investigation or visual review as complete, load \`decision-hold-lifecycle\` from this home's \`.agents/skills/\` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started.
When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
If its first reportable event is \`working [key=<work-slug>]: {material phase}\`, use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>]: {why it is no longer active}\`.
When a decision you escalated is answered or a blocker clears and your domain resumes, append \`resolved: {how it was decided or unblocked}\` (keyed with \`[key=<slug>]\` if you opened it with one) so it is durably closed instead of resurfacing behind later unrelated events.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
IFS= read -r -d '' HERDR_SECTION <<'EOF' || true
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
HERDR_SECTION=${HERDR_SECTION%$'\n'}
fi

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.
8. Never add a \`Co-authored-by:\` trailer, or any other trailer, naming a model, an agent, Anthropic,
   or any other tool, on any commit, including scratch commits in this worktree: every commit is
   authored in the captain's name only. Claude Code adds this trailer BY DEFAULT, so you must actively
   suppress it. Before reporting done, verify it is absent with \`git log -1 --format='%(trailers)'\`.

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

if [ "$KIND" = craft-review ]; then
FINDINGS_DOC="$DATA/$ID/craftsmanship-review.md"
FINDINGS_DOC_QUOTED=$(shell_quote "$FINDINGS_DOC")
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
Review the craftsmanship of ship task $REVIEWED_ID on $REPO, which has passed validation and is waiting on you before it may publish its branch.
{TASK}

$HERDR_SECTION

# Your remit is owned by a skill - load it first
Your FIRST action is to read \`$FM_ROOT/.agents/skills/craftsmanship-review/SKILL.md\`.
It owns your complete remit: the Clean Code and domain-driven-design bar, the captain's concrete style rules, the house writing rules, and the list of AI tells to flag.
If you cannot read it, append \`blocked: craftsmanship review remit is unreadable\` to the status file and stop.
Never review from memory: an unreviewed branch waiting is a better outcome than a review that held the wrong bar.

These boundaries hold whether or not that skill loaded:

- This is NOT a defect hunt. The validation pipeline's own review, test, document, and lint steps already ran and own correctness. Your question is whether the code reads as a craftsman wrote it.
- You never publish, never open a PR, and never merge.
- You never edit the code you review. You report findings; the implementing worker fixes them.
  You are sharing that worker's checkout, so this is a hard safety rule, not a preference.
- You never record a verdict for a task you implemented yourself.

# Setup
You are in task $REVIEWED_ID's OWN worktree, on the branch it built the work on. This is deliberate: one story keeps one checkout, so every step of it happens here.
You did not create this checkout and you do not own it. Task $REVIEWED_ID is idle while you work, and it resumes here afterwards to fix what you find.

**Verify before anything else.** Run \`pwd -P\`, \`git rev-parse --show-toplevel\`, and \`git status --porcelain\`.
The first two must agree on a worktree that is not the primary checkout firstmate operates from, and \`git status --porcelain\` must be clean apart from the untracked agent-owned files the verdict recorder already exempts.
Uncommitted changes here mean either the implementing worker is still active in this directory or someone edited the code under review, and both break the review.
If either check fails, append \`blocked: {which check failed and what it showed}\` to the status file and stop.

This is a REVIEW task: the deliverables are a findings document and a recorded verdict, not a code change.
Read the work under review with:
   \`$STATE_ENV $REVIEW_DIFF_BIN $REVIEWED_ID\`
Read enough surrounding code here to judge placement, ordering, and naming in context, not just the changed lines.

# Rules
1. Never push to any remote, never open a PR, and never merge.
2. **Write nothing in this worktree.** Not a file, not a fix, not a scratch note, not a commit, not a branch, not a stash, and never \`git checkout\` or \`git rebase\`.
   This is the whole reason it is safe for you to be in another task's checkout, and the verdict recorder refuses while the tree is dirty.
   The only files you may write are the findings document, the verdict record, and the status file below, all of which live outside this worktree.
   If you need to run something that writes, use your own temporary directory outside the worktree.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own: firstmate then leaves your idle pane alone
   and rechecks it on a long cadence instead of treating it as a possible wedge.
   Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. A question about what the code SHOULD do is not yours to settle: it belongs to the captain's accepted
   task criteria. Append \`needs-decision: {summary of options}\` and stop rather than turning a product
   question into a craftsmanship finding.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.
8. You make no commits at all here, so the repository's authorship rules never come into play for you:
   every commit on this branch is the implementing worker's, authored in the captain's name only.

# Definition of done
Write every finding to \`$FINDINGS_DOC\`, each with the file and line, what reads as uncraftsmanlike, and what shape the code should take instead.
Recommend the change; do not make it.

Then record the verdict, which is what decides whether the branch may be published:
   \`$STATE_ENV $CRAFT_REVIEW_BIN record $REVIEWED_ID --reviewer $ID --verdict pass --findings $FINDINGS_DOC_QUOTED\`
Use \`--verdict findings\` instead when the work is not publishable yet.
Record \`pass\` only when you would be content to maintain this code yourself; it is pinned to the exact commit you reviewed, so it cannot leak onto later work.
Finally append \`done: craftsmanship review of $REVIEWED_ID: {pass or findings}, {one-line conclusion}\` to the status file and stop.
EOF
echo "scaffolded: $BRIEF (craft-review of $REVIEWED_ID; replace {TASK})"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by the project's delivery mode.
# yolo does not affect the brief because the worker never owns approval decisions;
# firstmate applies the authority contract in AGENTS.md section 7, so discard it.
# No default branch name: the caller (firstmate) must supply one with --branch.
# An omitted name renders as the loud, unmistakable {BRANCH} placeholder instead
# of a silent guess like the historical `fm/$ID`, so a wrong or missing branch
# name can never ship unnoticed.
BRANCH_NAME=${BRANCH:-'{BRANCH}'}

read -r MODE _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF

# Both pipeline-running modes hand the worker the same gate-driving contract, so
# it is written once here rather than restated in each definition of done.
IFS= read -r -d '' PIPELINE_GATES <<'EOF' || true
You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies the authority contract in its `AGENTS.md` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid `--yes`: it would silently bypass firstmate's authority check and any required captain escalation.
EOF
PIPELINE_GATES=${PIPELINE_GATES%$'\n'}

case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1="1. Never push to the default branch (push only your \`$BRANCH_NAME\` branch). Never merge a PR."
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
This project ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
    ;;
  local-only)
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`.
   If this project has no \`origin\` remote at all, the pipeline has nowhere to push: skip stage 2's validation run and take stage 5's no-remote outcome instead."
    RULE1="1. Never push to the default branch (publish only your \`$BRANCH_NAME\` branch, and only at stage 5 below). Never open a PR or merge request, and never merge."
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
This project ships **local-only**: you validate, an independent reviewer checks craftsmanship, then you publish your branch so the captain can look at it on the real repository.
That mode name is kept for compatibility and no longer means unpublished - publishing IS the delivery.
What you must NOT do is open the merge request: the captain gives a separate "ship it" word for that later.

Work these stages in order on your branch \`$BRANCH_NAME\`.

1. Implement and commit.
   Keep the branch a clean fast-forward onto the current default branch - if the default branch has advanced, rebase onto it.
2. Validate without publishing. Confirm the flag spelling against \`no-mistakes axi run --help\`, then run the pipeline with its publication and merge-request steps skipped:
   \`no-mistakes axi run --intent '{what you set out to accomplish}' --skip push,pr,ci\`
   It stops after the lint step, having pushed nothing.
3. Stop for the independent craftsmanship review.
   Append \`done: validated, ready for craftsmanship review\` to the status file and stop.
   Firstmate dispatches a reviewer that did not write this code. Do not review your own work, and do not publish yet.
4. When firstmate returns findings, fix them on this branch, run stage 2 again over the new commits, and report ready for re-review.
   The review is pinned to the exact commit it passed, so every new commit needs a fresh one.
5. Publish, and only once the review gate lets you:
   \`$STATE_ENV $CRAFT_REVIEW_BIN verify $ID\`
   If it refuses, do NOT publish: append \`blocked: {the exact reason it gave}\` to the status file and stop.
   Once it passes, publish the branch with the pipeline's own push step and nothing beyond it:
   \`no-mistakes axi run --intent '{what you set out to accomplish}' --skip pr,ci\`
   Then append \`done: branch $BRANCH_NAME published\` and stop. Do NOT open a PR or merge request.
   If this project has no remote at all, publication does not apply: append \`done: reviewed and ready in branch $BRANCH_NAME\` instead, and the configured merge authority approves before firstmate merges it into the local default branch through the guarded fast-forward path.

$PIPELINE_GATES
EOF
    ;;
  *)  # no-mistakes (default)
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

$PIPELINE_GATES

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
    ;;
esac

# read -r -d '' preserves the heredoc's trailing newline that the removed
# $(...) command substitution used to strip. Drop that one newline so generated
# briefs stay byte-identical to the historical Bash 5 output.
DOD=${DOD%$'\n'}

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b $BRANCH_NAME\`$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs above the implementation worker (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will apply the configured authority and reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.
8. Never add a \`Co-authored-by:\` trailer, or any other trailer, naming a model, an agent, Anthropic,
   or any other tool, on any commit: every commit is authored in the captain's name only. Claude Code
   adds this trailer BY DEFAULT, so you must actively suppress it. Before reporting done, verify it is
   absent with \`git log -1 --format='%(trailers)'\`.

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"

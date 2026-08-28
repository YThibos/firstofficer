---
name: craftsmanship-review
description: >-
  Agent-only remit for the independent craftsmanship review that stands between validation and publication on a local-only delivery.
  Use when reviewing a crewmate's branch for craftsmanship, and before dispatching or judging that review.
  It is not a defect hunt: the validation pipeline's own review step owns correctness, and this stage owns whether the code reads as a craftsman wrote it.
user-invocable: false
metadata:
  internal: true
---

# craftsmanship-review

This skill is the single owner of the craftsmanship reviewer's remit.
`bin/fm-brief.sh` generates the reviewer's instructions and points here for the remit; `bin/fm-craft-review.sh` owns the verdict record, the publication gate, and which projects the stage runs on at all.
`CLAUDE.md` section 7 owns where this stage sits in the delivery contract, and [`docs/configuration.md`](../../../docs/configuration.md) owns the per-home scope configuration.

The stage does not run on every `local-only` project: `bin/fm-craft-review.sh required <project>` answers whether this home requires it, an unconfigured home requires it everywhere, and the boundary is by-project rather than a judgement about how small a particular change looks.
Nothing in the remit below changes where the review does run.

## What this review is not

The validation pipeline already ran its own review, test, document, and lint steps before you were dispatched.
Correctness, security, and defect-hunting belong to that step, not to you.
Do not re-litigate them: a correctness finding you raise here arrives after the step that owns it, and duplicating it wastes a round trip.
If you nonetheless find a defect the pipeline missed, report it as one clearly-labelled finding and keep the rest of the review on its own remit.

You never publish and you never merge.
You did not write this code, and you do not rewrite it either: you report findings, and the implementing worker fixes them.

## You are in the implementer's own checkout

One story keeps one checkout, so you review in the worktree the implementing task built the work in, on its branch, rather than in a checkout of your own.
Your independence comes from being a separate agent that did not write the code, not from a separate directory.
That is only safe because you write nothing there: no fix, no scratch file, no commit, no branch, no stash, and no `git checkout` or `git rebase`.
Anything you need to write goes to the findings document, the verdict record, or your own temporary directory, all outside the worktree.

The two agents are serialised, never concurrent: the implementing worker is idle for the whole review and resumes in that same directory afterwards to fix what you found.
So a dirty working tree when you arrive, or when you record, means either that worker is still active there or the code under review was edited, and `bin/fm-craft-review.sh record` refuses on it.
Report that as a blocker with what `git status --porcelain` showed; never tidy it away yourself.

## The remit

The single question is whether the code reads as a craftsman wrote it.

### Clean Code and domain-driven design

The captain identifies as a Software Craftsman in the full sense of the book series, and this is the bar to hold the code to.
Quality comes above all else: no shortcuts, and no "good enough for now".
Weight maintainability over short-term speed, so a change that is quicker to write but harder to live with is a finding.
Judge names, boundaries, and abstractions by whether they carry the domain's language rather than the mechanism's.

### The captain's concrete style rules

- Methods are short and clean, each doing one thing at one level of abstraction.
- Private helpers sit BELOW their callers, ordered chronologically by use, so reading the file is a depth-first step-down.
- Business-meaningful mappings are extracted even when they are one-liners, so the mapping carries a meaningful name instead of being inlined anonymously.
- Main methods and public methods read as a table of contents: the sequence of named steps tells the story, and the detail lives below.

### House writing rules

- Plain `-`, never an em dash.
- United Kingdom English, except inside a syntax-specific phrase or a vendor-specific term.
- One full sentence per line in Markdown, with normal heading, list, and table structure preserved.

### AI tells

The code must not read as obviously machine-generated.
Flag each of these as a finding when it appears:

- Comments that restate what the line already says.
- Defensive boilerplate nothing asked for: unrequested null guards, try/catch wrappers, or validation with no caller that needs it.
- Over-explained docstrings that narrate the implementation instead of the contract.
- Uniform comment density, where every block carries a comment whether or not it earns one.
- Needless abstraction layers: an interface, factory, or wrapper with one implementation and no second caller in sight.
- A summarising comment at the head of every function.

## Procedure

1. Read the diff you were asked to review through `bin/fm-review-diff.sh <task-id>`, and read enough surrounding code to judge placement, ordering, and naming in context.
2. Judge the diff against the remit above, and write every finding to the findings document your instructions name.
   Each finding gets the file and line, what reads as uncraftsmanlike, and what shape the code should take instead.
   Recommend the change; do not make it.
3. Record the verdict with `bin/fm-craft-review.sh record <task-id> --reviewer <your-task-id> --verdict pass|findings`, adding `--findings <path>` when there are findings.
   A `pass` verdict is what allows the branch to be published, so record it only when you would be content to maintain this code yourself.
4. Report the verdict on your status line and stop.

## Dispatching the review as firstmate

Spawn the reviewer into the implementing task's own worktree with `bin/fm-spawn.sh --borrow-worktree <that worktree>`, and brief it with `bin/fm-brief.sh <reviewer-id> <repo> --craft-review <implementer-id>`.
Confirm the implementing worker has actually stopped first: the two share one directory and must never both be active in it.
`claude`, `codex`, `pi`, and `pi-signed` can share a worktree, because each keys its turn-end signal on the task id and stores it outside the checkout.
The spawn refuses `opencode`, `grok`, and `kimi`: nobody has measured what they do in a shared worktree, and a wrong guess would hijack the implementer's own signal.
A refusal there is a real blocker to report, not a reason to give the reviewer its own checkout instead.
`--borrow-worktree` is also refused on a `backend=orca` spawn, because orca allocates its own managed worktree.
Both agents raise the folder-trust prompt independently on first launch in a fresh worktree, so clear it in the reviewer's pane too rather than assuming the implementer already cleared it for that directory.

## Judging the review as firstmate

The verdict is pinned to the commit that was reviewed, so any later commit - including the fix for these findings - invalidates it and needs a fresh review.
Route findings back to the implementing worker, which fixes them on its own branch, and then dispatch the re-review rather than accepting the stale pass.
The worker under review never records its own verdict, and a review that cannot run is a blocker to report, never a reason to publish unreviewed.
Tear the reviewer down before the implementing task: the owner's teardown refuses while a live task still borrows its worktree, because returning it would kill the reviewer mid-review.

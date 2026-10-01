---
name: updatefirstofficer
description: Merge the original upstream firstmate project into this firstofficer fork without losing the fork's own divergence. Use when the captain invokes /updatefirstofficer (e.g. "/updatefirstofficer", "sync from upstream", "pull in the latest from the original project"). Creates a dated upstream-update branch on origin, merges the upstream default branch into it, resolves ordinary conflicts, hands conflicts on deliberately drifted files to the captain, and publishes the sync through the no-mistakes pipeline as a pull request whose GitHub CI is the test gate and which the captain merges. Distinct from /updatefirstmate, which only fast-forwards this home and its secondmate homes from origin.
user-invocable: true
metadata:
  internal: true
---

# updatefirstofficer

Bring this fork current with the original project it was forked from.

`firstofficer` tracks `kunchenguid/firstmate` on the `upstream` remote and carries its own divergence on top.
Keeping current is therefore a real merge with real conflicts, not the fast-forward `/updatefirstmate` performs.
The two commands are separate and neither replaces the other:

- `/updatefirstmate` moves this home and every registered secondmate home to what already landed on `origin`.
- `/updatefirstofficer` is what puts new upstream work onto `origin` in the first place.

Run `/updatefirstofficer` first when the captain wants the fork current, then `/updatefirstmate` to spread the result across the fleet.

`bin/fm-upstream-sync.sh` owns every git mechanic here; read its header and `--help` for exact flags and output lines rather than reconstructing them.
It never pushes to `upstream`, never forces, never stashes, and never discards unlanded work.
It touches only this firstmate repo, never anything under `projects/`.

## What it does

### 1. Preflight

```sh
bin/fm-upstream-sync.sh preflight
```

It fetches `upstream`, refuses a dirty or off-default checkout without touching it, and prints what a sync would do.

**`up-to-date: yes` ends the command.**
Report plainly that the fork is already current and stop.
Do not create a branch, do not merge, and do not report a no-op as progress.

Otherwise read two things from the output.
`drift:` lines are the empirical fork-drift set, computed from the real diff between the merge base and this fork's HEAD.
`declared-drift:` lines check the captain-decision paths the script declares against that real diff, and mark one `stale` when it no longer drifts.
A `stale` line is worth a sentence to the captain, because the declaration and the reality have parted company.

### 2. Merge

```sh
bin/fm-upstream-sync.sh merge
```

It creates `upstream-update/<YYYY-MM-DD>` off the default branch in an isolated sync copy, merges the upstream default branch into it there, and classifies the outcome.
The `sync-copy:` line names that copy's path; every later step of the sync happens in it.
`merge: clean` goes straight to step 4.
`merge: conflicts <n> captain-decision=<n> agent-resolve=<n>` goes to step 3.

Either way, read the `agents-md:` line before moving on.
`agents-md: changed` means `AGENTS.md` moved even if nothing conflicted, and that is its own captain decision (step 3, third case).

The primary checkout this session runs from stays on its default branch, untouched, for the whole sync.
Never merge, resolve, or commit there: this session loads its skills and hooks from it, so a half-merged tree would corrupt every turn spent resolving.
If `merge` refuses because a sync copy already exists, an earlier sync is still open; land or abort that one first.

### 3. Conflicts

Three cases, and the classification in the output tells you which one you are in.

**`conflict: <path> agent-resolve`** is ordinary fork divergence.
Investigate each one: read both sides, understand what upstream changed and what this fork changed, and resolve it yourself where it is clear how the two behaviours should combine.
Where it is not clear, treat it as the third case and ask rather than guess.

**`conflict: <path> captain-decision`** is a file that differs from upstream because the captain explicitly wanted it different.
Never resolve one of these yourself and never let a worker resolve one.
Escalate with the concrete options: what upstream now says, what the fork says, and what each choice would cost.
The known ones are `CLAUDE.md`, the fork-owned operating anchor that replaced upstream's symlink to `AGENTS.md`, and `AGENTS.md` itself.

**`agents-md: changed`** is a captain decision even on a clean merge.
`tests/fm-anchor-budget.test.sh` pins the `AGENTS.md` revision whose rules are reconciled into `CLAUDE.md`, so CI stays red until the rule-bearing changes are reconciled into the anchor by hand and the pin is bumped in the same commit.
Read the upstream change in the sync copy named by the `sync-copy:` line with `git -C <sync-copy> diff <pre-merge-commit> HEAD -- AGENTS.md`, then surface the specific upstream changes and what each would mean for the anchor's operating text.
Do not invent anchor wording on your own.
A provably non-rule-bearing change, a typo fix or pure reformatting that alters no rule, may be reconciled directly, but say explicitly that you did so and why it changes no rule.

Resolve every conflict in the sync copy, never in the primary checkout.
Resolving conflicts edits firstmate's own shared tracked material, so section 1 of the anchor still applies: load `firstmate-coding-guidelines` before touching it, and when any worker is live, hand the resolution to a worker working in the sync copy rather than competing with supervision.
Resolve towards keeping the fork's behaviour and adding upstream's, not towards whichever side is easier to take whole.

Once every conflict is resolved or answered, commit the merge in the sync copy, then continue to step 4.
If the captain calls the sync off, `bin/fm-upstream-sync.sh abort` undoes the merge and removes the sync copy, keeping any sync branch that carries commits.

### 4. Land

```sh
bin/fm-upstream-sync.sh land
```

This is the standard way a sync lands.
It lints the sync copy, then drives the no-mistakes pipeline on the dated sync branch from the sync copy with its `test`, `rebase`, and `ci` steps skipped.
The pipeline reviews the sync, pushes the branch to `origin` unrebased, and opens a pull request against the default branch.
Once the pull request exists, `land` prints its URL on the `pull-request:` line.
GitHub CI on that pull request is the test gate, so run no full local suite: it costs hours here and CI covers the same ground in parallel.
The script writes nothing to the default branch.
With `rebase` and `ci` skipped, neither the script nor the pipeline rebases, squashes, or re-pushes the sync branch, and no CI monitor is left running to do so later.
It refuses a sync that the local or `origin`'s default branch has moved past.
When either happens, merge `origin`'s default branch into the sync branch in the sync copy - a merge, never a rebase - commit it, and run `land` again.

The pipeline returns at its first gate, and the script passes its output through.
Drive each gate with `no-mistakes axi respond` from the sync copy as `/no-mistakes` describes, never with `--yes`, and run `land` again to reattach until it prints the pull request URL.

Open the pull request without asking; the captain's invocation is the authority for that.
Merging it is the captain's, under hard rule 2 of the anchor, and this command grants no merge authority of its own.
Because the pipeline skips its test step, the pull request is expected to fail the required "PR must be raised via no-mistakes" check.
The captain merges each sync pull request with an admin override once GitHub CI is green; neither you nor the script ever performs the override or the merge.
Give the captain the full pull request URL once CI is green, and say explicitly that it needs that admin override and must be merged with a merge commit, never a squash or rebase, because either would flatten the upstream history the sync preserves.

If CI is red, first bring the sync copy up to date with any commits the pipeline pushed: read `branch_sync` from `no-mistakes axi status` in the sync copy and run `no-mistakes axi sync` there when it says `sync`.
Then fix it in the sync copy, commit there, and run `land` again: the pipeline reviews the fix and pushes it to the same pull request.
Never rebase, squash, amend, or force-push the sync branch while fixing.

The offline path, `land --fast-forward`, validates with the full local suite and fast-forwards the default branch with no pull request.
Use it only when the captain asks for it.

### 5. Report and spread

Summarise the outcome in the captain's own nouns under section 9 of the anchor.
Say what came in from the original project, what you resolved, what still needs the captain, and where the fork now stands.
Once the captain confirms the pull request is merged, run `bin/fm-upstream-sync.sh land` once more to remove the sync copy; it does so even after the default branch or upstream has moved on.
Then run `/updatefirstmate` so this home and every secondmate home pick up what just landed, and re-read `CLAUDE.md` if the anchor changed.

## Safety

- **Never pushes to upstream.**
  The `upstream` remote's push URL is disabled on purpose, and the script refuses any push target but `origin` before git is invoked.
- **Never forces and never discards unlanded work.**
  Every refusal leaves the working tree exactly as it found it, `abort` keeps a sync branch that carries commits, and a refusal is a stop-and-investigate result rather than something to work around.
- **Never writes to the default branch in the standard flow.**
  Lint runs before the pipeline starts, a red lint pushes nothing, and only the merged pull request moves the default branch.
- **Never resolves a deliberately drifted file.**
  The captain-decision paths are declared in the script and checked against the real drift on every run, so the declaration cannot quietly outlive the drift it describes.
- **Only this repo.**
  Nothing under `projects/` is read or written.

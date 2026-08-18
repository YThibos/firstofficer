# Claude worktree co-location verification

Audience: maintainer verification.

This record supports the current guarantee that two `claude` agents may share one worktree, which `bin/fm-spawn.sh --borrow-worktree` relies on to place the independent craftsmanship reviewer in the implementing task's own checkout.
It also supports why that same option still refuses `opencode`, `grok`, and `kimi`.
Operator behaviour stays in [`docs/architecture.md`](../architecture.md) and the `harness-adapters` skill.

Verified 2026-08-18 with Claude Code 2.1.234, the only agent CLI installed on the verifying machine.
`codex`, `opencode`, `grok`, `pi`, and `kimi` returned nothing from `command -v`, so nothing below is an observation about them.

## The signal is per task; the declaration was per worktree

`bin/fm-spawn.sh` has always written the turn-end marker to `state/<task-id>.turn-ended`, outside the worktree.
What sat inside the worktree was the hook declaration, at the fixed path `<worktree>/.claude/settings.local.json`.
A second spawn into the same worktree therefore overwrote the first spawn's declaration with its own task id, and supervision could no longer tell whose turn ended.
Teardown of the first task removed the shared file outright, leaving the survivor with no hook at all.

`bin/fm-spawn.sh` now writes `state/<task-id>.claude-settings.json` and passes it with `--settings` on the launch command, so both the declaration and the marker are keyed on the task id.

## `--settings` relocates the hook

```
$ claude --help
  --settings <file-or-json>             Path to a settings JSON file or a JSON
                                        string to load additional settings from
```

Both accepted forms were run rather than only read.

Inline JSON, print mode:

```sh
claude -p --settings '{"hooks":{"Stop":[{"hooks":[{"type":"command",
  "command":"touch /tmp/claude-colo-lab/sig/A.turn-ended"}]}]}}' 'Reply with exactly: PONG'
```

The reply was `PONG` and `A.turn-ended` appeared.
A file path outside the worktree, passed to an interactive TUI launch, produced the same result, and the hook kept firing across four separate turns in one session.

Firstmate uses the file form.
The launch string is assembled in shell, sent through tmux, and re-expanded in the pane, so a path avoids three layers of nested-quote risk that inline JSON would carry for no gain.

## Two agents in one worktree signal independently

Two interactive `claude` agents ran in the same directory with firstmate's launch shape (`CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions ...`), each with its own `--settings` hook and no `.claude/settings.local.json` present.
Marker mtimes were read with `stat -c '%n %.9Y'`.

| Step | `A.turn-ended` | `B.turn-ended` | Reading |
|---|---|---|---|
| both first turns | `1787037336.514773701` | `1787037336.410762856` | each agent created its own marker |
| steer A only | `1787037401.970114451` | `1787037336.410762856` (unchanged) | only A signalled |
| steer B only | `1787037401.970114451` (unchanged) | `1787037448.561328107` | only B signalled |
| steer both at once | `1787037670.102917990` | `1787037670.598967516` | both signalled independently, 496 ms apart |

The simultaneous step was not a bare reply: each agent created a file in the shared worktree and ran `git status --short` concurrently, both files survived, and the two markers stayed distinct.

## `--settings` merges with a worktree settings file

This is the finding the design depends on, and it is why relocating only the second agent would not have worked.

With an implementer-shaped `.claude/settings.local.json` in the shared worktree touching `IMPL.turn-ended`, an agent launched with `--settings <file outside the worktree>` touching `C.turn-ended` produced both:

```
/tmp/claude-colo-lab/sig/C.turn-ended     1787037542.372058437
/tmp/claude-colo-lab/sig/IMPL.turn-ended  1787037542.372058437
```

Identical to the nanosecond: one agent's single turn fired both hooks.
Print mode behaved the same way.

So a leftover worktree settings file makes supervision see a turn-end for a task that did not take one, which is worse than a missing signal because it makes an idle agent look alive.
Every claude crewmate therefore launches with `--settings` and none writes the worktree file.
`tests/fm-spawn-worktree-settle.test.sh` asserts the worktree stays free of `.claude/settings.local.json` after a claude spawn.
`bin/fm-teardown.sh` still removes that path, both for worktrees spawned before this change and because the merge behaviour makes any stray copy harmful.

Settings are read once at session start and cached: an agent already running when a settings file appeared did not fire the hook that file declared.
That ordering is an accident of timing, not a boundary to rely on.

## What else two claude agents share in one worktree

Per session, with no collision found: transcripts under `~/.claude/projects/<cwd-slug>/<session-uuid>.jsonl`, file history, session environment, process sessions, and shell snapshots.
Under `--dangerously-skip-permissions` claude wrote nothing into the shared directory.

Shared and worth knowing:

- The `~/.claude.json` project entry is keyed by cwd, so both agents write one object and the last writer wins.
  This file is already shared by every claude crewmate on the machine, co-located or not.
- `~/.claude/projects/<cwd-slug>/memory/` is keyed by cwd, so two co-located agents share one memory store.
  Firstmate briefs do not direct crewmates to write there.
- Both agents raise the folder-trust prompt independently on first launch in an untrusted worktree, and both panes showed it at once.
  Post-spawn dialog handling must clear it per pane; sending Enter to each pane cleared both.
- One worktree means one git index, so concurrent commits from two agents contend on `index.lock`.
  That is a property of sharing a checkout rather than of claude, and the craftsmanship reviewer avoids it by only reading.
- `claude --continue` resolves the most recent conversation in the current directory, which is ambiguous with two sessions in one cwd.
  Firstmate never resumes claude, so this stays out of reach.

The tracked `.claude/settings.json` primary guards exempt themselves from linked worktrees through `fm_primary_scope_matches`, so they stay inert in crew task worktrees whether one agent is present or two.

## Why the other three stay refused

Nothing below was measured, and the claude result does not transfer to any of it.

`opencode` writes `<worktree>/.opencode/plugins/fm-turn-end.js`, a fixed-name file inside the worktree, which is claude's old problem shape.
Its launch template already delivers configuration through the environment, so an env-delivered plugin is plausible, but whether opencode accepts a plugin that way is untested.

`grok` and `kimi` have a different shape and need a different fix.
Both already keep the hook outside the worktree, as a global hook plus a worktree-resident identity pointer, and both resolve that pointer from the workspace path.
Two co-located agents share one workspace root, resolve the same pointer, and would touch the same marker, so relocation is not the missing piece for either.
They need per-agent identity, which requires knowing what their hook processes actually receive.

Answering any of the three needs its own live two-agent experiment on a machine where that CLI is installed.

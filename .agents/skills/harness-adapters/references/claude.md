# claude (VERIFIED; busy signature re-verified 2026-07-25 on Claude Code 2.1.220)

Adapter reference for `harness=claude`.
Load it only for the harness recorded in `state/<id>.meta`, or for the detected primary harness.
[`../SKILL.md`](../SKILL.md) owns every adapter-independent fact and remains the entry point for this reference.

| Fact | Value |
|---|---|
| Busy-pane signature | Current turns match the harness-scoped `…[[:space:]]+\([0-9]+[smh]` shape after a rotating glyph and word, for example `✢ Pollinating… (16s · ...)`; legacy `esc to interrupt` remains accepted, while `Worked for 31s` is idle. |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

First launch in a fresh worktree, or first ever on a machine, may show a trust or bypass-permissions confirmation.
After every spawn, peek the pane within about 20 seconds.
If such a dialog is showing, accept it from an active firstmate session using `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Enter`, or the choice the dialog requires, unless `FM_HOME` is already set to the active firstmate home; verify the brief started processing.
Two claude agents in one worktree each raise that dialog for themselves, so clear it per pane rather than once per directory.

Claude can share a worktree with another claude agent, which is what lets a craftsmanship reviewer join the implementing task's checkout.
`fm-spawn` writes each crewmate's turn-end hook to `state/<task-id>.claude-settings.json` and passes it with `--settings`, so the declaration is keyed on the task id like the marker it touches.
Nothing may write `<worktree>/.claude/settings.local.json` again: `--settings` merges with that file rather than replacing it, so a stray copy fires another task's hook on every turn of this one and makes an idle agent look alive.
[`docs/verification/claude-colocation.md`](../../../../docs/verification/claude-colocation.md) owns the measurements and what else two co-located agents share.

Claude renders a predicted-next-prompt suggestion as dim/faint text inside an otherwise-empty composer after a turn completes.
A plain `tmux capture-pane` cannot tell that ghost text apart from typed text.
Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to firstmate-launched agents through `bin/fm-spawn.sh`, so it never touches the captain's global config.
The CLI's `--prompt-suggestions` flag is print/SDK-mode only and does not suppress the interactive composer ghost text, verified empirically on v2.1.186.
As defense in depth for any pane that flag cannot reach, including the captain's own firstmate composer that away-mode reads, the shared `fm_composer_strip_ghost` extractor in `bin/fm-composer-lib.sh` removes dim/faint SGR 2 ghost runs before pending-input classification on both ANSI-capable readers (tmux and herdr).
Its broader dark-TRUECOLOR placeholder handling and dark-theme tradeoff are documented in `docs/herdr-backend.md` "Composer and injection safety", with active captures in `docs/verification/runtime-backends.md`.
That styled capture is internal to the boolean detector only.
`fm-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes.

**Primary-session guard fact (verified 2026-07-04, Claude Code 2.1.201; preserved 2026-07-08, Claude Code 2.1.204; Stop-owned auto-arm revalidated 2026-07-24, Claude Code 2.1.219).**
This is separate from the per-task crewmate turn-end hook above (that one just `touch`es a marker file from the task's own `state/<task-id>.claude-settings.json`).
The firstmate PRIMARY's own `.claude/settings.json` registers two Stop hooks: `bin/fm-turnend-guard.sh --claude` and the Stop-owned auto-arm `bin/fm-claude-stop-autoarm.sh` (`asyncRewake: true`, `timeout: 28800`), and exiting the guard with status 2 plus stderr reliably forces the model to continue.
Claude Code's stdin payload to a Stop hook carries a `stop_hook_active` boolean that is `true` when the current stop attempt follows ANY stop-hook-driven continuation, including `asyncRewake` rewakes; the primary guard therefore ignores it in `--claude` mode and uses the cooperative claim/epoch check plus a bounded re-block budget instead, while the codex-mode default still treats it as a one-block loop guard.
A project-level `.claude/settings.json` only takes effect when Claude Code's project root is that exact directory - it does not walk up from a subdirectory looking for one, so firstmate launches the primary from the repo root.
After those settings are loaded, hook command resolution is still cwd-sensitive because Claude Code runs commands through `/bin/sh` against the session's current cwd; keep the tracked commands anchored through `"$CLAUDE_PROJECT_DIR"/bin/...` and see `docs/turnend-guard.md` for the verified Stop-hook details.
Claude Code's primary watcher protocol is Stop-owned: the auto-arm hook fires on every Stop and foregrounds `bin/fm-watch-arm.sh` when the home is eligible and still needs supervision, and its exit-2 `asyncRewake` rewake is the wake; the model drains and handles wakes but never runs a routine re-arm command.

## Primary session-start nudge

[`../SKILL.md`](../SKILL.md) owns the shared contract; this is the verified fact for this adapter.

- `claude`: verified native `SessionStart` stdout injection; `.claude/settings.json` matches `startup`, `resume`, and `clear`, but not `compact`.

## Primary delegation-shape guard

[`../SKILL.md`](../SKILL.md) owns the shared contract; these are the verified Claude-specific facts.

Claude primaries should also use an untracked per-home local `permissions.deny` list as hardening for known Claude delegation tools, because it removes them from the model's schema so they are never offered.
That deny list must not ship in tracked `.claude/settings.json` because it is Claude-only rather than harness-agnostic, and because tracked project settings propagate into linked worktrees where they disarm legitimate crewmates.

Two verified facts worth pinning here.
The subagent tool presents to the model as `Agent`, and on Claude Code 2.1.217 both `Agent` and `Task` work as `permissions.deny` keys, verified by an A/B with a nonsense-name control.
`permissions.allow` is a pre-approval list rather than an availability list, so there is no fail-closed positive allowlist.

## no-mistakes skill invocation

[`../SKILL.md`](../SKILL.md) owns the shared rule; this is the verified form for this adapter.

- claude: `/<skill>`, for example `/no-mistakes`.

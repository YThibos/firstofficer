# Primary turn-end supervision guard

This is the authoritative current contract for the "no turn ends blind" primary backstop referenced from AGENTS.md section 8.
The predicate lives in `bin/fm-turnend-guard.sh`.
Primary scope lives in `bin/fm-primary-scope-lib.sh`, shared with the native session-start nudge in [`sessionstart-nudge.md`](sessionstart-nudge.md).
Harness hook files adapt each enabled primary harness integration's turn-end mechanism to that shared predicate.

Related PreToolUse guards deny unsafe commands before execution rather than detecting a blind turn end afterward.
Their separate owners are [`arm-pretool-check.md`](arm-pretool-check.md), [`cd-guard.md`](cd-guard.md), and [`subagent-guard.md`](subagent-guard.md).
Do not infer this guard's scope, loop safety, or compatibility tradeoffs for those guards.

## Current invariant

`bin/fm-guard.sh` is a pull-based warning that runs only when another supervision command invokes it.
The turn-end guard closes the remaining gap at the primary's own turn boundary.
When work is in flight and no identity-matched watcher has a fresh beacon, the harness integration must either block the turn end or force one bounded follow-up that uses the recovery instruction from the emitted session-start protocol.
The guard remains a backstop; [`watcher-continuity.md`](watcher-continuity.md) owns normal continuity.

## Shared predicate

The guard first calls the shared primary scope.
A secondmate home runs its own primary Firstmate session, so a genuine `.fm-secondmate-home` marker includes it whether the home is a linked worktree or plain clone.
The marker must be a regular non-symlink file whose whitespace-stripped first line is a non-empty identifier containing only letters, digits, dots, underscores, and dashes.
An unmarked checkout or invalid marker falls through to the git-dir check.
That check keeps crewmate and scout linked worktrees inert because their git dir differs from their git common dir.
It also requires `AGENTS.md`, `bin/`, and the effective state directory.

For an in-scope primary, the guard counts in-flight work from `state/*.meta`.
The default cross-harness mode exits silently with no work in flight.
Claude's `--claude` mode also treats `state/x-watch.check.sh` as supervision need, so X-mode relay polling remains guarded without an in-flight task.
Otherwise it calls `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`, the same identity-matched lock and fresh-beacon check used by `bin/fm-watch-arm.sh`.
A stale beacon blocks even when a watcher pid is live.
A fresh leftover beacon blocks when the lock is missing, dead, or identity-mismatched.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repository-root `state/`.
`FM_GUARD_GRACE` controls beacon freshness and defaults to 300 seconds.
If `jq` is missing or hook stdin is empty, the guard exits 0 because it cannot safely read loop-guard fields.

## Harness integrations

- Claude registers two `Stop` hooks in `.claude/settings.json`, both anchored through `CLAUDE_PROJECT_DIR`: `bin/fm-turnend-guard.sh --claude`, and `bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
- Codex registers a `Stop` hook in `.codex/hooks.json`, anchors the executable to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and passes the original payload to the shared guard.
- OpenCode listens for `session.idle` in `.opencode/plugins/fm-primary-turnend-guard.js`, lets the watcher coordinator act first, and calls `client.session.promptAsync` once when the guard returns 2.
- Pi listens for `agent_settled` in `.pi/extensions/fm-primary-turnend-guard.ts`, runs once per logical agent run, and calls `pi.sendUserMessage(..., { deliverAs: "followUp" })` once when the guard returns 2.
- Grok registers a `Stop` hook in `.grok/hooks/fm-primary-turnend-guard.json` and delegates capability selection to `bin/fm-turnend-guard-grok.sh`.
  The tracked Claude Stop entries are inert when `GROK_AGENT` is present, so Grok's Claude-compatible settings loading cannot create a second continuation path.

Claude and Codex can block a Stop directly with exit status 2 and stderr.
Both payloads carry `stop_hook_active`.
In the default Codex mode, a true value lets the second stop finish after one forced continuation.

Claude runs the guard with `--claude`, which ignores `stop_hook_active` and cooperates with the Stop-owned auto-arm.
Claude Code sets `stop_hook_active=true` on every stop after any stop-hook continuation, including `asyncRewake` rewakes, which re-opened the 2026-07-21 blind window under the default one-shot behavior.
The Claude mode waits up to `FM_CLAUDE_AUTOARM_SYNC_WAIT_MS` (default 800 milliseconds) and allows the stop when the watcher is healthy, `state/.claude-autoarm.lock` has a live owner, or `state/.claude-autoarm-epoch` contains a fresh rewake outcome.
When none of those proofs appears, it re-blocks up to `FM_CLAUDE_TURNEND_BLOCK_BUDGET` times (default 3, below Claude's 8-block override), then allows degraded with a visible `systemMessage`.
Any allow resets the budget.

OpenCode, Pi, and pi-signed expose passive callbacks for this purpose.
Their adapters fail open at the hook boundary to protect the user session but schedule one bounded follow-up when the predicate blocks.
The generated prompts use the canonical `turn-end-guard` kind after the U+2063 `FIRSTMATE_OP: ` prefix, so Ahoy does not treat them as captain messages.
Each passive adapter owns a loop latch.
Pi keeps the latch across internal tool turns and clears it only when the generated follow-up settles or delivery fails.
OpenCode's forced follow-up is supported for persistent TUI sessions and remains fail-open in headless `opencode run`.

Grok makes exactly one typed capability decision from each running Stop payload.
A boolean `stopHookActive` selects native blocking, including both false on the initial stop and true on the bounded continuation.
The camel-case field has precedence when both spellings appear; when it is absent, a boolean `stop_hook_active` selects the same native path for compatibility.
The native path returns the shared guard's status and stderr to the same Grok process and never starts `grok --resume`.
When both capability spellings are absent, the adapter preserves one pre-native `grok --resume` fallback guarded by `GROK_TURNEND_GUARD_ACTIVE` and intentionally omits `--permission-mode`.
Malformed JSON, a selected field with a non-boolean type, missing `jq`, missing hook prerequisites, or an already-active legacy guard allows the stop without starting either continuation path.
Grok's project hook requires the checkout to be trusted with `/hooks-trust` or launch-time `--trust`; genuine pre-native builds can run the same tracked hook from an isolated global hook directory.

If a passive adapter cannot invoke its SDK, or the Grok legacy fallback cannot find `grok` or a session id, the next pull-based `fm-guard.sh` call reports the problem.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it always points to the active harness protocol rather than embedding another repair command.

## Forced stow before the usage budget runs out

The same `Stop` event is the last reliable moment to react to Claude's approaching-limit warning, so `--claude` mode also reads its own pane for that warning and blocks once per usage window to force a brief knowledge stow.
This is deliberately not a second hook: adding a competing turn-end registration would give the primary two independent blockers with no shared block budget.
Detection and the once-per-episode ledger live in `bin/fm-limit-warning-lib.sh`; only the blocking lives in the guard.
The split exists because the library is pure pane-text classification plus one ledger, with no dependency on a `Stop` payload, a supervision predicate, or a blocking mechanism, so it is testable directly against captured pane text and reusable by a future crewmate-side reader of the same warnings.

Claude Code shows two distinct end-of-window states and only the first is actionable.
`Approaching your <window> usage limit` means the session can still run one short step, and it is the only trigger.
`You've hit your session limit ... Press ⏎ to continue after reset` means the session has already stopped, so it is detected only to suppress a stow that could no longer run, and it wins when both are visible.
That stopped state is read through `bin/fm-limit-park-lib.sh`, which already owns Claude's stopped-footer signature for parked workers, so the two features cannot drift on what "stopped" means.

The forced stow runs before the supervision predicate because it must fire even when supervision is perfectly healthy, which is that predicate's normal silent exit.
It never replaces the blind-turn block: it claims its episode and blocks once, and the next turn end reaches the supervision predicate normally.
It contributes at most one block per usage window on top of the re-block budget's default 3, so the pair stays well below Claude's 8-consecutive-block override.
The block instruction names the window that is running out, puts writing to disk ahead of every other action, and points at the `stow` skill's "Budget nearly gone" section for the short mode rather than the full sweep.
Its wording deliberately never quotes the warning it matches on, so the banner cannot read as the warning itself on the next pane capture.

The episode marker is `state/.turnend-limit-stow-episode`, a bounded two-line overwritten file following the same shape as `bin/fm-guard.sh`'s stale-banner episode marker.
The key differs because the approaching warning carries no reset time: it is the harness, the window descriptor the warning names, and the harness session id, and its expiry is the claim time plus the named window's own length.
That yields exactly one stow per session per usage window and re-arms a session that outlives its own window.

Every uncertain path leaves the turn alone, because a bug here must never wedge the captain's own session.
An unsupported harness, a terminal that is not tmux, a pane that cannot be captured, an absent or unwritable episode marker, an unreadable clock, or an already-claimed episode all return "not due" silently.
Only Claude's wording has been observed, so every other harness is a silent no-op until its exact strings are captured and pinned by a test.
Scrollback is excluded from the capture so a warning from a previous window still in history cannot read as a live one.
Child crewmate and scout worktrees are already outside the shared primary scope, so the forced stow inherits that exclusion rather than re-deriving it.
`FM_TURNEND_LIMIT_STOW=0` disables the forced stow without affecting the blind-turn block.

## Compatibility limits

- Child crewmate and scout worktrees are outside scope.
- A valid secondmate home is in scope; an idle secondmate endpoint with no X-mode relay poll remains healthy because it has no supervision need.
- The direct-blocking and bounded passive-follow-up split is limited to the primary integrations listed above.
- OpenCode headless mode and untrusted Grok project hooks remain fail-open at the host boundary.
- Kimi Code CLI 0.29.1 exposes only global `[[hooks]]` configuration in `~/.kimi-code/config.toml`, including a `Stop` event with snake_case payload fields `hook_event_name`, `session_id`, `cwd`, and `stop_hook_active`.
- Kimi has no project-level hook configuration and remains outside the primary guard integrations above.
- Captain-approved Kimi crew wake support uses `bin/fm-kimi-turnend-hook.sh` to edit only one marker-delimited Firstmate region in that global config and install a silent always-zero hook.
- The hook remains inert unless the payload `cwd` contains a per-task token pointer that resolves through Firstmate's private registry to one `state/<id>.turn-ended` marker.
- Installation refuses before writing unless `python3` with `tomllib` and `jq` are available.
- If `jq` is removed after installation, the hook remains silent and exits 0, turn-end wakes stop, and Kimi crews fall back to idle detection.
- Unreadable hook input remains fail-open.
- No harness adapter uses a shell ampersand to manufacture supervision.
- The forced stow before the usage budget runs out is Claude-only and tmux-only; every other harness and every non-tmux terminal is a silent no-op because their wording, or the pane itself, is unavailable.
- A pane that merely quotes the warning, for example a session discussing this feature, matches it; the cost is bounded at one brief stow per window and is the deliberate direction to err in, because a missed stow loses knowledge while a spurious one does not.

## Regression coverage

`tests/fm-turnend-guard.test.sh` covers the predicate, main and secondmate primary scope, child-worktree exclusion, `FM_HOME` and `FM_STATE_OVERRIDE` precedence, the cooperative `--claude` claim wait, epoch allow, re-block budget, Pi logical-run latching, missing-`jq` behavior, all five primary registrations, Grok native and legacy selection, typed field precedence, malformed input, and exactly-one-path safety.
It also covers the forced stow: classification of both observed end-of-window states, the window descriptor and its length, Claude-only wording support, exactly one block per episode, re-arming in a later window, and the fail-open paths for the exhausted state, an ordinary pane, a non-tmux terminal, an uncapturable pane, an unverified harness, a child worktree, and `FM_TURNEND_LIMIT_STOW=0`.
`tests/fm-kimi-harness.test.sh` covers the separate Kimi crew hook's format preservation, idempotence, refusal cases, token guard, spawn registration, and teardown cleanup.
`tests/fm-supervision-instructions.test.sh` covers recovery-line ownership and pi-signed's identity-preserving reuse of Pi's protocol.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` is the opt-in isolated Pi path.
[`verification/supervision.md`](verification/supervision.md#turn-end-guard) records the active cross-harness empirical evidence, including the 2026-07-24 Claude `asyncRewake` revalidation and the 2026-09-14 live tmux pass on the forced stow.

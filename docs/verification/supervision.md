# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, turn-end, watcher-continuity, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Native session-start delivery

The cross-harness transport pass ran on 2026-07-17 with Codex 0.144.4, Grok 0.2.103, OpenCode 1.17.18, Pi 0.80.10, and the tracked Claude hook wiring.

Codex command shape:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message last.txt \
  'Follow any SessionStart hook context before this prompt.'
```

Observed result: the `SessionStart` hook completed and its stdout reached model context.

Grok command shape:

```sh
grok --trust -p 'Follow any SessionStart hook context before this prompt.' \
  --permission-mode bypassPermissions --output-format plain
```

Observed result: the project hook ran, but its stdout did not reach model context.
This is the current Grok fail-open limit.

OpenCode was checked in both headless and interactive modes.
`client.session.promptAsync` accepted the nudge in both cases; the persistent TUI completed the generated turn, while `opencode run` exited before another turn.
This is the current headless fail-open limit.

Pi command shape:

```sh
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts \
  --no-context-files --no-session \
  'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'
```

Observed result: `PI_SMOKE_DONE`, with one session-start execution.
That cold positional-prompt check established eventual custom-message delivery, but it did not submit immediately after `/new` while native digest generation was still running, so its earlier race-free inference is superseded by the provider-prerequisite evidence below.
The installed pi-signed 0.82.0 wrapper repeated the shared Pi primary extension and session-start path on 2026-07-27.
[`runtime-backends.md`](runtime-backends.md#tmux) owns the shared-ancestry evidence and authoritative selection-marker boundary.

### omp (Oh My Pi) native delivery, 2026-09-05

The omp Run-tier adapter was verified on 2026-09-05 with omp 18.1.11 and the openai-codex `gpt-6-astra` model through `FM_OMP_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh`, which drives a real omp in its JSON-RPC stdio mode inside an isolated lab clone.
Both tracked `.omp/extensions/*.ts` files loaded by auto-discovery alone (no `-e`, no trust dialog), `before_agent_start` returned the digest as a persistent context message, the model quoted the lab's `SESSION START -` heading back on its first turn, `state/.session-start-complete` was recorded, and `state/.lock` named the omp process, so ancestry detection identified the markerless binary.
omp's `session_start` payload carries no reason field, so the adapter derives the source: the first start of the process is `startup` (or `resume` from a `--continue`/`--resume` launch line) and a later in-process start is `clear`; `tests/fm-omp-harness.test.sh` pins that mapping over a fake omp API.
A file named both by `-e` and by auto-discovery loads twice (two factory calls, doubled `session_stop` continuations), which is why the secondmate launch names no `-e` and the per-task worker extension lives in `state/`.

### Run-tier source vocabulary and context-reset injection

The run tier depends on three facts only the vendor can supply: the session-open source it reports, whether hook stdout reaches model context on a context-RESET open rather than only a cold one, and whether a worker the hook detaches survives the hook returning.
The first two were measured on 2026-08-05 against a throwaway Firstmate-shaped lab carrying each harness's own tracked registration with a recorder standing in for `bin/fm-sessionstart-run.sh`.
Each open printed a source-stamped token, and the model was asked to quote that token back, so producing hook stdout could never be mistaken for delivering it.
The third is recorded below.

| Harness | Version verified | Cold open | Context reset | Context-preserving reopen |
| --- | --- | --- | --- | --- |
| Claude | 2.1.222 (Claude Code) | `source=startup`, token quoted back in both `-p` and the TUI | `/clear` reports `source=clear` and `/compact` reports `source=compact`; both re-injected a fresh token that the model quoted back | `claude --continue` reports `source=resume` |
| Codex | codex-cli 0.146.0 | `source=startup` under `codex exec`, token quoted back | Not reachable from a tracked project registration; see the limit below | `codex exec resume --last` reports `source=resume` |
| Pi | 0.82.0 | `source=startup`, token quoted back in both `-p` and the TUI | `/new` raises `session_start` reason `new`, which the extension maps to `clear`; `/compact` raises `session_compact`, and both freshly injected source-stamped tokens were quoted back | `pi -c` reports reason `startup`, not `resume` |

Two harness-specific consequences are load-bearing rather than incidental.

Codex's interactive TUI fired no project `SessionStart` hook at all in the same lab where `codex exec` fired it reliably, which matches the earlier 2026-07-28 finding for 0.145.0.
Codex's run tier is therefore verified only for `codex exec` startup and context-preserving resume.
The interactive TUI is a known uncovered gap: Firstmate has no tracked session-open, compaction, or re-emit channel there, ships no global hook, and does not claim instruction-refresh delivery for that surface.

Pi compaction was verified on 2026-08-05 with Pi 0.82.0 in the same throwaway lab after setting `.pi/settings.json` `compaction.keepRecentTokens` to 200 and completing one substantial assistant-prose turn before issuing `/compact`.
Pi reported `Compacted from 7,697 tokens`, the recorder observed `session_compact`, and the model quoted the freshly injected `source=compact` token back.
Both preconditions are load-bearing: the stock 20,000-token keep window exceeds a small lab session, and `AgentSession.compact()` aborts an in-flight turn before measuring compactable history, which otherwise discards that turn and reports `Nothing to compact (session too small)`.
Tool output alone does not grow compactable context; the completed assistant prose does.

Observed compaction output and recorder source:

```text
Compacted from 7,697 tokens
compact
```

Pi disagrees with Claude and Codex on `resume`: a new Pi process continuing a session reports `startup`, and Pi's `resume` reason is reserved for an in-process session switch.
The current adapter classification and baseline mechanics are owned by [`../sessionstart-nudge.md`](../sessionstart-nudge.md#harness-transports) and the `bin/fm-session-start.sh` header.
Their continuation classification is covered by portable tests, not claimed as live validation in this record.

### Pi `/new` provider prerequisite

The real offline Pi regression ran on 2026-08-26 with Pi 0.84.0, an isolated home and session directory, a barrier-controlled native digest, and a deterministic local `streamSimple` provider.
The provider makes no HTTP request and requires no user credential.
Its missing-native branch deliberately requests `bin/fm-session-start.sh`, so an escaped first call reproduces the duplicate-producing manual path rather than passing vacuously.

```sh
FM_PI_SESSIONSTART_RACE_LIVE_E2E=1 \
  tests/fm-sessionstart-hook-live-e2e.test.sh
```

Observed output:

```text
ok - Pi 0.84.0: immediate and completed-before-prompt /new paths each made one first provider call with exactly one native startup context and no manual execution
# fm-sessionstart-hook-live-e2e.test.sh: offline Pi /new race assertions passed
```

The immediate case submitted its first prompt only after the native `clear` child published `started`, held the child behind a release barrier, and proved the provider log remained absent for 500 milliseconds before release.
After release, the first payload reported one native context and no manual result, the session persisted one matching custom message, and the fixture recorded one native execution.
The control case let native generation complete before prompt submission and produced the same first-payload result.
The portable public-event regression in `tests/fm-sessionstart-nudge.test.sh` separately covers interruption, process-tree retirement, two rapid replacements, stale completion, empty output, spawn error, timeout output, truncation, ineligible stand-down, and compaction cancellation.
Pi and pi-signed load the same tracked extension bytes; pi-signed was not installed on this host for a separate 0.84.0 live rerun.

### Post-start instruction refresh

The isolated real-Pi instruction-refresh regression ran on 2026-08-11 with Pi 0.84.0.
It used a scratch `FM_HOME`, a private tmux socket, and a disposable Firstmate checkout.
The historical `origin/main` implementation first reproduced the stale original marker after a real compaction.
The current implementation then recorded `source=startup`, changed and committed the lab's `AGENTS.md`, compacted the same real Pi session, and answered with the replacement marker.
The fixed run also proved that the true-start baseline remained different from the updated file after compaction.

```sh
FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
FM_SESSIONSTART_INSTRUCTION_REFRESH_REF=origin/main \
FM_SESSIONSTART_INSTRUCTION_REFRESH_EXPECT=stale \
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
# ok - Pi 0.84.0 reproduces stale AGENTS.md after a real compact

FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
# ok - Pi 0.84.0 re-injects updated AGENTS.md after a real compact in an isolated session
```

This is live coverage only for Pi compaction.
The portable session-start tests cover continuation classification, baseline immutability, and source-routing behavior.
Pi compaction is the only supported stale-cache refresh pair.
Codex exec exposes only startup and context-preserving resume through tracked registration; Codex interactive reset behavior remains uncovered rather than inferred from direct wrapper invocation.

### Detached session-open workers survive the hook

Session start composes its digest from local reads and runs every external-network call in a worker detached by the hook (`bin/fm-startup-network.sh`), so a harness that reaped the hook's process tree would silently stop running the sweeps rather than merely delaying them.
Verified on 2026-08-06 with Claude Code 2.1.222 in a throwaway lab whose `bin/fm-bootstrap.sh` sleeps 6s before writing a marker, so the marker can exist only if the worker outlived the hook and the whole `claude -p` process.

```text
$ claude -p --permission-mode bypassPermissions '<quote the session-start token>'
FMHOOKTOKEN-startup-1-abc123
--- claude exited at 13:38:40; polling for the detached worker's marker ---
MARKER at +4s: detached worker survived the hook
state=done
started=1786048716
finished=1786048723
```

The worker started before the harness exited and published 6s after it was gone.

The latency this buys was re-measured on 2026-08-06 against default-branch tip `8398d31`, in a throwaway home holding one remote secondmate whose host hangs 25s per SSH connection (an `FM_SSH_BIN`-shaped stub; no real host was contacted).
Both runs used the same fixture and the same `bin/fm-session-start.sh` invocation, differing only in which checkout supplied the script:

```text
before (8398d31)   real 1m21.15s   3 blocking SSH attempts inside the digest
after              real 0m3.36s    digest prints IN PROGRESS; the same 3 SSH attempts
                                   run in the detached worker and finish at +77s
```

The remaining seconds are entirely local subprocess work; the `NETWORK CHECKS` section named GitHub authentication, dead-secondmate relaunch, secondmate convergence, pending handoff delivery, and project clone refresh as not yet confirmed.

Deferring the sweeps changed only when they run, not what they conclude.
The deferred worker's published report was byte-identical to the three sweep lines the blocking baseline printed, on the same fixture:

```text
SECONDMATE_LIVENESS: secondmate ios: skipped: remote host unavailable or endpoint state unknown; route preserved on remote-mac
SECONDMATE_SYNC: secondmate ios: skipped: remote tracked-file sync failed on remote-mac:
SECONDMATE_SYNC: secondmate ios: skipped: remote inheritance failed on remote-mac:
```

The unreachable route was preserved rather than relaunched in both runs, and the result surfaced durably as a queued `check: startup-network` wake once the worker finished.

Codex and Pi were not installed as run-tier labs in this measurement, so their evidence for this fact is NOT refreshed; `tests/fm-sessionstart-hook-live-e2e.test.sh` asserts it for each installed Claude, Codex exec, and Pi adapter and is the command that refreshes their record.
Cursor's separate primary live guard covers its source-free session-open transport but does not claim this detached-worker measurement.
A harness that did reap the worker degrades loudly rather than silently: the leftover record reads as an abandoned run needing a rerun, and the next session start re-derives every finding, because these sweeps are idempotent detectors.

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
tests/fm-session-start.test.sh
tests/fm-startup-network.test.sh
FM_SESSIONSTART_HOOK_LIVE_E2E=1 tests/fm-sessionstart-hook-live-e2e.test.sh
FM_PI_SESSIONSTART_RACE_LIVE_E2E=1 tests/fm-sessionstart-hook-live-e2e.test.sh
FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh
```

`tests/fm-sessionstart-hook-live-e2e.test.sh` is the command that refreshes the Claude, Codex exec, and Pi table above; run it after upgrading any of those harnesses.
It reports an absent adapter explicitly, asserts Pi compaction rather than noting it, and refuses to pass when none of those three adapters was installed.
Cursor's refresh command is `FM_CURSOR_PRIMARY_LIVE_E2E=1 tests/fm-cursor-primary-live-e2e.test.sh`, recorded under [Cursor primary park](#cursor-primary-park-2026-08-13).

The Ahoy first-message boundary was reverified on 2026-07-22 with Pi 0.81.1 and OpenCode 1.17.18.
Marked current operational input and the two exact legacy compatibility shapes selected Bearings, while genuine near-miss captain messages remained real boundaries.
The detailed reconciliation and task chronology stay in the private audit report and PR evidence.

## Semantic busy state

The per-adapter semantic sources behind [`bin/fm-busy-lib.sh`](../../bin/fm-busy-lib.sh) were live-verified on 2026-07-28 against firstmate-launched workers wired exactly as `fm-spawn` writes them.
Each pass polled `state/<id>.busy-state` while a real turn ran.

| Harness | Version verified | Semantic source | Observed result |
| --- | --- | --- | --- |
| Pi | 0.82.0 | Extension `agent_start` / `agent_settled` with `ctx.isIdle()` | The spawn seed `busy source=fm-spawn`, then `busy source=pi-ext event=agent-start`, then `idle source=pi-ext event=agent-settled`; the turn-end marker was still touched. |
| omp | 18.1.11 | Extension `agent_start` / `agent_end` without `willContinue` | Live Herdr scout on `openai-codex/gpt-6-astra` (2026-09-05): the spawn seed `busy source=fm-spawn`, then `busy source=omp-ext event=agent-start`, then `idle source=omp-ext event=agent-end` at the natural end of the brief; a steer through `fm-send` reopened `busy … agent-start`, and a control-plane interrupt closed it with `idle … agent-end` (omp fires `agent_end` on an interrupted turn). `ctx.isIdle()` is deliberately not consulted because it reads false at a natural TUI `agent_end`. |
| OpenCode | 1.17.18 | Plugin `session.status` | In a real TUI pane: seed, then `busy source=opencode-plugin event=session-busy`, then `idle source=opencode-plugin event=session-status-idle`. |
| Claude | 2.1.220 (Claude Code) | Hooks `UserPromptSubmit`, `Stop`, `StopFailure`, `SessionEnd` | `UserPromptSubmit` fired for the argv launch prompt and each steer, and `Stop` closed every completed turn. A mid-stream Escape interrupt fired no closing hook, which is why the firstmate-controlled clear exists. `StopFailure` and `SessionEnd` are wired from the four hook names present in the installed binary; only the abnormal paths they cover were not reproduced live. |
| Codex | codex-cli 0.145.0 | None usable | See below; classifies `unknown codex-unverified`. |
| Kimi (standalone) | not installed | None usable | No binary on `PATH`, so the gate stays closed and it classifies `unknown kimi-unverified`. |
| Grok | 0.2.112 | Isolated rendered-tail fallback | Retained unconverted; the approved audit could not credit a live structured-lifecycle run. |

Codex was probed two ways, both refused:

```sh
codex app-server daemon start
codex exec --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust 'Reply with exactly PROBE2.'
```

The daemon refused with `managed standalone Codex install not found`, and an interactive TUI worker neither starts nor attaches to the app-server control socket, so no client can observe its turns.
In this 2026-07-28 Codex 0.145.0 semantic-busy probe, Firstmate-written lifecycle project hooks under `<worktree>/.codex/hooks.json` fired for neither an interactive pane whose directory trust was granted nor `codex exec`, in both cases with `--dangerously-bypass-hook-trust`, while an untracked global probe fired in the same runs; Firstmate does not ship, install, recommend, or depend on that global path.
Codex also exposes no `StopFailure` hook, so an API-error turn end would need separate coverage even after hook discovery works.
The app-server protocol schema does define the required lifecycle (`turn/started`, plus a `turn/completed` status of `completed`, `interrupted`, `failed`, or `inProgress`), so the gate is a reachability problem rather than a protocol gap.

Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-crew-state.test.sh
```

## Turn-end guard

The blocking and bounded-follow-up mechanisms were validated across seven harnesses on 2026-07-08 through 2026-09-05, with Claude's replacement Stop-owned path revalidated on 2026-07-24, Cursor's stop-hook park validated on 2026-08-13, and omp's blocking `session_stop` hook validated on 2026-09-05.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.219 | Cooperative blocking `Stop` guard plus `asyncRewake` auto-arm | A fresh unsupervised session ran session start first, reclaimed a stale dead-owner lock, completed two tokenless rewake cycles with no model arm command or guard continuation, and left a competing live owner unchanged. |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| OpenCode | 1.17.6 | Passive `session.idle` callback | Throwing could not block, while `promptAsync` scheduled one TUI follow-up; headless remained fail-open. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |
| omp | 18.1.11 | Blocking `session_stop` hook returning `{ continue: true, additionalContext }` | In the isolated rpc lab (2026-09-05), the successor watcher was frozen with `SIGSTOP` until its beacon passed the lab `FM_GUARD_GRACE` of 20s while its arm child stayed attached (a killed watcher closes its arm child and the extension re-arms before the guard can fire); the next turn end raised the guard, the guard spy recorded `rc=2` followed by a stop carrying `stop_hook_active: true`, omp compelled a continuation carrying the `turn-end-guard` operational text, the `fm_watch_arm_omp` invocation count then rose to at least two, and a live watcher held the home lock after the thaw; the flagged stop was allowed, so exactly one continuation ran. `session_stop` never fired for an interrupted turn. |
| Grok | 0.2.112 native and 0.2.73 pre-native | Running-payload adaptive `Stop` | Native false-to-true continuation stayed in one process with two model turns and zero resume launches; the field-absent pre-native process launched exactly one guarded resume. |
| Cursor | 2026.08.11-e8db854 | Awaited `stop` hook park returning one `followup_message` | Exit 2 ended the turn normally, proving it cannot block; a returned follow-up ran a genuine second turn; a sleeping hook held the boundary open and the wake landed after it; `loop_limit` stopped the hook being invoked at its ceiling. |

### Cursor primary park, 2026-08-13

Cursor was validated as a primary on 2026-08-13 against the installed CLI on macOS 26.5.2 arm64 with tmux 3.6a, in a throwaway firstmate home on a private tmux socket, never against a live home and never with a user-scope hook.

Mechanism facts established first, in a separate throwaway workspace:

| Question | Method | Result |
| --- | --- | --- |
| Can `stop` block? | hook exits 2 | No. The turn ended normally; Cursor's blocked-response mapper returns `{}` for the `stop` step. |
| Can `stop` force one turn? | hook returns `{"followup_message":...}` | Yes. A genuine second turn ran and answered. |
| Can `stop` park? | hook sleeps, then returns a follow-up | Yes. It is awaited; a 20s sleep held the boundary and the follow-up landed after it. |
| What is `loop_count`? | four consecutive follow-ups, then a real user message | `0,1,2,3`, then `0` again. It counts follow-up-driven stops since the last real user message. |
| Does `loop_limit` bind? | `loop_limit: 2` with an always-follow-up hook | Yes. The hook was invoked at `loop_count` 0 and 1 and never at 2. |
| Does a captain message terminate an existing park? | captain message typed during a 600s park | No. Cursor leaves the park running, and without a baton an older park can still deliver after the captain turn's next `stop` has started another park. |
| Does Cursor load `.claude/settings.json`? | Claude-shaped `SessionStart`, `PreToolUse`, `Stop` in the same workspace | `SessionStart` and `PreToolUse` fired with a CURSOR-shaped payload carrying `cursor_version`; `Stop` did not fire. |

The integration itself is exercised by the opt-in guard:

```sh
FM_CURSOR_PRIMARY_LIVE_E2E=1 tests/fm-cursor-primary-live-e2e.test.sh
```

Observed output:

```text
harness: cursor-agent 2026.08.11-e8db854
ok - cursor primary: the sessionStart hook takes the fleet lock as the Cursor process itself
ok - cursor primary: the run-tier session start completes every stage
ok - cursor primary: sessionStart additional_context reaches model context before the first turn
ok - cursor primary: the stop-hook park delivers a real watcher wake as one follow-up
ok - cursor primary: the park owns exactly one arm cycle with a live watcher beacon
ok - cursor primary: the captain keeps control and the older park stands down after the next stop claim
ok - cursor primary: an away-mode escalation is delivered, confirmed, and processed
```

The live run proved that session start acquires the fleet lock through Cursor's structural process identity in `bin/fm-cursor-lib.sh`; `tests/fm-session-lock-ancestry.test.sh` pins the same ancestry path portably.
It also proved that Cursor's `autoarm` supervision model lets the mid-turn pull guard accept a fresh beacon after the between-turn watcher closes; `tests/fm-guard-stale-banner.test.sh` pins that model-aware verdict.
The baton is claimed only by the next `stop`, so an actionable close before that claim can still produce one real follow-up from the sole existing park; durable wake handling is idempotent, and any older park still running after the claim stands down.
Cursor's `beforeSubmitPrompt` step could close that exact window because it fires once on a real captain message and not on hook-driven follow-ups, but registering it is deliberately deferred alongside `preCompact`.

Away-mode delivery needed no daemon change once the composer reader was correct for Cursor; [`runtime-backends.md`](runtime-backends.md#composer) owns that evidence.

Cursor compaction instruction refresh is DEFERRED and not shipped, so a Cursor primary does not re-emit its digest after a compaction.
Two static facts decided that: `PreCompactRequestResponse` carries only `user_message`, and `preCompact` is absent from the `additional_context` step set (`index.js` @ 4814884), so the step cannot inject a digest and any delivery has to be routed through a later boundary.
A staged-then-delivered design is rejected because carrying a digest across two concurrently running `stop` hooks can deliver it twice or strand it indefinitely, while closing those races enlarges a critical section inside a hook Cursor awaits at the turn boundary.
Native `preCompact` firing was not observed because a real compaction could not be forced in the isolated session, so the surface has no empirical basis yet.
It is therefore recorded as uncovered in the same sense as the Codex interactive TUI, and `tests/fm-cursor-primary.test.sh` asserts `preCompact` stays unregistered so it cannot return unnoticed without its own design and evidence.

The Grok adaptive matrix ran on 2026-07-28 with separate scratch repositories and homes, dedicated tmux sockets, one target plus one control window, ambient tmux variables removed, and a socket-bound wrapper first in `PATH`.

```sh
FM_GROK_STOP_LIVE_E2E=1 \
  FM_GROK_NATIVE_BIN="$native_grok_0_2_112" \
  FM_GROK_LEGACY_BIN="$official_pre_native_grok_0_2_73" \
  tests/fm-grok-stop-live-e2e.test.sh
```

Observed bounded output:

```text
ok - grok 0.2.112 (9bbd559437aa) [stable] native Stop kept one session across false->true, two model turns, and zero resume processes
ok - grok 0.2.73 (9ff14c43bbe5) [stable] legacy Stop omitted capability, resumed exactly once, and stopped normally
ok - Grok adaptive Stop real-process matrix passed with exact target cleanup and control-window survival
```

The same run proved the Claude-compatible Stop entries stay inert under `GROK_AGENT`, the legacy resume carries `GROK_TURNEND_GUARD_ACTIVE=1`, and every replacement root is removed after exact target cleanup while its control window survives.
That inertness result is scoped to the builds it exercised: it did not establish that `GROK_AGENT` reaches a Grok HOOK process, and on grok 1.0.0 it does not, so the marker set was widened to `GROK_HOOK_EVENT` as well (docs/turnend-guard.md "Harness integrations").
`tests/fm-turnend-guard.test.sh` now pins every tracked `.claude/settings.json` hook entry against a real grok 1.0.0 hook environment so the inertness contract is covered deterministically rather than only by the opt-in live matrix.

The secondmate-home scope and manual-repair wake path were measured with Claude Code 2.1.207 on 2026-07-12, when a native background completion re-invoked the idle model with no human input.
The current Stop-owned main/secondmate inclusion and child-worktree exclusion are covered deterministically by `tests/fm-claude-stop-autoarm.test.sh`.
Session-lock ownership in `bin/fm-session-lock-lib.sh` is decided against a session's whole contiguous harness ancestry rather than one chosen pid, so the Stop auto-arm reaches its lock owner wherever that owner sits: the outermost pid of Claude Code's multi-level `bg-spare` hook worker chain, or an inner pid when a harness-named daemon parents the session.
Harness identity is read from the executable path and `argv[0]` as well as the command basename, because Claude Code's native installer names the per-session executable by its version (`.../share/claude/versions/2.1.220`): `ps -o comm=` reports that path on macOS and the bare version string on Linux, and neither basename names a harness.
`tests/fm-session-lock-ancestry.test.sh` pins both platforms' reporting semantics behind a deterministic process table and runs the real Stop auto-arm in version-named, daemon-parented, and combined real process trees.
`tests/fm-watch-arm.test.sh` runs real watcher and arm cycles against durable on-disk state to verify that a delivered reason survives until post-handling acknowledgement and stops replaying after acknowledgement, while an unrelated queue append cannot make a watcher cycle that delivered nothing look successful.
The same suite ingests a keyed remote-secondmate parent reply through the real adapter, establishes the incremental OPEN DECISIONS cursor, interrupts supervision, and proves re-arm replays every unacknowledged queue row plus the still-open decision through the ordinary drain path.
It also covers decision-only recovery, interrupted handling, handling-window generation reuse, non-fatal moved-generation acknowledgement with sequence-bounded consumption, and a persistent successor remaining live after recovery is acknowledged.

On 2026-08-20 with Claude Code 2.1.235, a session launched from a versioned release binary could not acquire its home lock at all: Claude Code execs that binary directly, so the process name is the version string (`2.1.235`), which matches no harness name and is not the bare `node` or `python` the interpreter fallback expected.
That fix added a rule reading argv[0] rather than the rest of the command line, so a process that merely mentions a harness in an argument still cannot claim a home's lock; `fm_harness_process_matches()` now owns that rule together with the path-component evidence above.
`bin/fm-session-lock-lib.sh` owns the full rule and `tests/fm-session-lock-identity.test.sh` pins the argv[0] cases deterministically.

On 2026-08-27 with Claude Code 2.1.247, that same walk was found resolving a background session to `claude daemon run`, the supervisor every background session on the machine descends from and which outlives all of them.
`ps -eo pid,ppid,comm,args` showed the session's own host `claude bg-pty-host` (pid 3617, process name `2.1.247`) parented directly by that daemon (pid 3492, process name `claude`), and because the daemon is claude-named the walk extended past the host and returned the daemon instead.
That breaks ownership twice: the daemon never exits, so a lock recording it reads as live forever and refuses every later session, and every concurrent background session in the home resolves to that one pid, so no two of them can tell each other apart.
`fm_harness_process_matches()` now rejects a process shared across sessions before any of its three rules, matching the subcommand in argv[1] rather than a substring of the command line, so the walk stops one hop below such a process and keeps the session's own host, and a lock already recording one reads back as stale and reclaimable.
Re-run against the same live processes, the daemon is rejected while pids 3617, 3655, 2827, and a plain foreground `claude` all still resolve as harnesses.

On the same date, `bin/fm-lock.sh` gained the one takeover a live holder permits: a holder whose session is positively identified as stopped on a usage limit.
The two verbatim messages `bin/fm-transcript-limit-stop.mjs` matches, `You've hit your session limit` and `You've hit your monthly spend limit`, were both read from real transcripts under `~/.claude/projects`, alongside transient `API Error:` records that must never authorise a takeover.
Run over the 60 real transcripts on that machine containing the session-limit text, the classifier called 28 stopped and 32 still working, the latter being sessions that resumed after the limit cleared and therefore end on an ordinary record.
Review of that change found the transcript tail alone insufficient: resuming a limit-stopped session reuses its session id and its `.jsonl`, so until the resumed session writes a new conversational record the tail still ends on the limit error while that session is live and holding the lock.
The same 60-transcript survey confirms resumed sessions continue in the same file rather than starting a new one, which is what makes that window reachable in normal use.
The takeover therefore also requires the last record's own instant to be at or after the holder process's start time, read from that process's age via the POSIX `ps -o etime=` field rather than from any file timestamp, and refuses when either value is missing or unparseable.
`etimes` was tried first and rejected: it is a procps extension that BSD `ps` refuses outright, so on macOS, a supported host, every takeover would have refused and the feature would have been a silent no-op.

A later review found the sibling window still open: a holder's argv is fixed at exec, so a session that replaces its conversation in place through `/clear`, `/new`, or `/fork` keeps naming the transcript of the session it replaced, whose tail is the limit record that same process wrote.
Claude Code's per-pid session record at `<config-root>/sessions/<pid>.json` was checked against every live session on that machine: it carries the session's CURRENT `sessionId`, its `cwd`, and a `procStart` that exactly matches field 22 of `/proc/<pid>/stat`, and its `sessionId` resolves to a real existing transcript in every case.
The takeover now refuses when such a record inside the holder's own process tree names a different session, as a purely restrictive cross-check: resolution still comes from argv alone, and a record that is missing, unreadable, unparseable, or whose `procStart` does not match the live process adds no restriction at all.
That `procStart` verification needs `/proc`, so on a non-Linux host every record is unverifiable and the cross-check changes nothing there.

A third review closed the last resolution window, in the argv the two rules above both trust.
The session id was resolved from the space-joined string `ps -o args=` prints, in which a real `--session-id <uuid>` pair cannot be told apart from that text inside a single argument.
That was reproduced on 2026-08-28 with Claude Code 2.1.247 against the live session implementing the change, whose task brief is one argv element and quotes a session id:

```sh
ps -o args= -p 9378 | sed 's/.* --session-id //; s/ .*//'
tr '\0' '\n' < /proc/9378/cmdline | grep -cx -- --session-id
node bin/fm-transcript-limit-stop.mjs \
  ~/.claude/projects/-home-thibyann001-firstofficer/8d537afb-bead-496f-9d7d-d2bdc7c8d6d8.jsonl 0
```

Observed result: the flattened parse yielded `8d537afb-bead-496f-9d7d-d2bdc7c8d6d8`, a session that process has never run; the discrete argv holds `0` elements equal to `--session-id`; and the classifier exits `0` on that quoted session's transcript.
A working session would therefore have had its lock taken on a stranger's limit-stop evidence.
`fm_claude_session_id()` now reads the NUL-separated elements of `/proc/<pid>/cmdline` and takes the element after a `--session-id` element, so the pair is unambiguous.
There is deliberately no fallback to the flattened string, because a fallback reinstates the ambiguity, which makes the takeover Linux-only and a no-op on macOS; that supersedes the earlier `etimes` rationale above, where portable process age was expected to be what carried the feature to Darwin.
The live sessions on that machine were re-checked in the same pass.
Pids 2768, 2769, 2823, and 2825 each expose exactly one `--session-id` argv element followed by a session id, of which 2769 and 2823 name a transcript present on disk while 2768 and 2825 name one that does not exist yet and therefore refuse, as an unreadable transcript must.
Pid 9378, a session started with no explicit session id, exposes no such element at all and is unresolvable, which is the documented consequence for any session whose id never reaches its own argv.

The transcript directory mangling was checked at the same time and deliberately left narrow.
All 72 real project directories on that machine were compared with the working directory each transcript records internally, 72 of 72 matched the `/` and `.` to `-` rule exactly, and the only special characters appearing in any recorded path were `-`, `.` and `/`.
Widening it to every non-alphanumeric character was rejected because it would break a path holding an underscore that resolves correctly today, and a path mangled differently only ever yields no transcript, which refuses.

`docs/session-lock.md` owns the ownership contract and `tests/fm-session-lock-limit-stop.test.sh` pins every half deterministically, including a resumed-session case that fails without that start-time condition, a replaced-session case that fails without the per-pid cross-check, and a quoted-session-id case that fails without the discrete argv read.
That suite's fixture holders are real processes carrying the observed argv, so each session id under test is read from a live process rather than supplied to the code under test.

On 2026-09-25 with Claude Code 2.1.282, a home's lock was found held by an unclaimed Claude Code standby, which is why the captain's real session started read-only and the turn-end guard then blocked it in a loop.
The background daemon keeps pre-warmed spare session hosts, and its own log records each one and each claim:

```sh
grep -E 'bg (spawned|claimed-spare|spare spawned|settled)' ~/.claude/daemon.log
cat ~/.claude/sessions/15705.json ~/.claude/sessions/7940.json
tr '\0' ' ' < /proc/7940/cmdline
```

Observed result: the lock holder pid 4434 hosted session `a1d94548`, logged `bg spawned a1d94548 (spare)`, which ran SessionStart and never received a prompt, so no transcript exists for it.
Standbys claimed for a real session are logged `bg claimed-spare <id> (fleet)`, and their per-pid record carries no `spare` field, while standbys that ran SessionStart without being used carry `"kind":"bg"` and `"spare":true`.
Pid 7940, a claimed standby hosting a real working session, still shows `claude bg-spare --bg-spare <...>.claim.sock` as its argv, so the argv cannot separate a standby from a session in use and the record's flag is the signal.
`fm_claude_session_is_spare()` in `bin/fm-session-lock-lib.sh` reads that flag from the `procStart`-verified record; run read-only against the live processes, pid 15705 (`"spare":true`) was not a live holder and pid 7940 (claimed) was.
A standby that has not started its session has no per-pid record at all and is decided by the naming rules, which is safe because such a process has not run SessionStart and cannot hold the lock.
`docs/session-lock.md` owns the contract, and `tests/fm-session-lock-identity.test.sh` and `tests/fm-claude-stop-autoarm.test.sh` pin it over real processes and verified records.

The Claude product live path ran with Claude Code 2.1.219 on 2026-07-24:

```sh
claude --version
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
2.1.219 (Claude Code)
ok - Claude 2.1.219 (Claude Code) live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary
```

The forced stow before the usage budget runs out was validated live on 2026-09-14 with tmux 3.4, against isolated primary-shaped homes and a real tmux server rather than a stubbed `capture-pane`.
The approaching wording is the literal read out of the shipped Claude Code 2.1.270 binary that day, `Approaching your 5-hour usage limit` followed by its separator and `Claude will wrap up the current step.`, and the stopped state is the observed `You've hit your session limit` footer read through `bin/fm-limit-park-lib.sh`.
A driver running inside the pane painted that wording into the pane's own visible buffer, then ran the guard so its `tmux capture-pane -t "$TMUX_PANE"` read the live pane back.
This matters because a guard that no-ops silently cannot be proven working by absence of effect; the trigger was observed firing, not assumed.

```sh
tmux -S /tmp/fmlive-<pid>.sock new-session -d -x 200 -y 50 -n live \
  "bash drive.sh <checkout> <workdir> <out> <socket>"
```

Observed results, one stage per line:

```text
approaching, first turn end   exit 2, stderr banner "USAGE BUDGET NEARLY SPENT - STOW NOW, BRIEFLY", naming the 5-hour window
                              state/.turnend-limit-stow-episode = "key=claude:5-hour:live-sess-1 at=<epoch>"
approaching, second turn end  exit 0, no output, marker unchanged (episode already claimed)
exhausted only                exit 0, no output, marker absent
ordinary pane                 exit 0, no output, marker absent
approaching, outside tmux     exit 0, no output, marker absent
```

The banner deliberately never quotes the warning it matches on, so the live pass also confirms the block cannot re-trigger itself from its own output on the next capture.

Current entry points:

```sh
tests/fm-turnend-guard.test.sh
tests/fm-supervision-instructions.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_GROK_STOP_LIVE_E2E=1 FM_GROK_NATIVE_BIN="$native_grok" FM_GROK_LEGACY_BIN="$pre_native_grok" tests/fm-grok-stop-live-e2e.test.sh
```

The Claude auto-arm false-failure, guard-predicate, and monotonic bounded fail-open correction was verified on 2026-08-02 with the installed ShellCheck 0.11.0 and isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=61 local_links=174
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=102585
```

The fresh-beacon portion of the model-aware pull-guard predicate (`bin/fm-guard.sh` accepts a beacon within grace without a live watcher under the Claude Stop auto-arm model) was verified on 2026-08-04 with the installed ShellCheck 0.11.0 and the same isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=64 local_links=188
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=80078
```

The Pi extension-model pull-guard correction (`bin/fm-guard.sh` no longer reports a false watcher-down on a Pi primary during the extension's own watcher hand-off) was verified on 2026-08-13 with the installed ShellCheck 0.11.0 and isolated behavior suites.
The guard verdict itself reads only state files and process liveness, so the portable suites are the enforcing evidence; `bin/fm-harness.sh`'s Pi marker detection, which selects the model, is exercised in the same suite through `PI_CODING_AGENT`.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-session-start.test.sh tests/fm-pi-watch-extension.test.sh tests/fm-watch-arm.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=67 local_links=243
FM_TEST_SUMMARY total=5 failed=0 skipped_gate=0 duration_ms=280160
```

The same correction was verified against a live Pi primary's own supervision evidence on 2026-08-13.
The hand-off was captured live at beacon age 63s, then the home's `state/.lock`, `state/.last-watcher-beat`, both `state/.pi-*-extension-loaded` markers, and both `.pi/extensions/*.ts` builds were copied into an isolated fixture with no watcher lock.
The fixture's copied beacon was fresh at 0s in the output below; the deterministic stale-beacon case separately verifies the grace boundary.

```sh
FM_SUPERVISION_MODEL=persistent FM_GUARD_READ_ONLY=1 bin/fm-guard.sh
FM_SUPERVISION_MODEL=extension FM_GUARD_READ_ONLY=1 bin/fm-guard.sh
```

Observed output, before and after the model correction, then with the recorded Pi session pid replaced by a dead one:

```text
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher process holds this home lock (last beat: 0s ago).
(silent)
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher process holds this home lock (last beat: 0s ago).
```

The broader relevant regression pass was rerun on 2026-08-02 without live-home or daemon mutation.

```sh
bin/fm-test-run.sh tests/fm-watch-triage.test.sh tests/fm-watcher-lock.test.sh tests/fm-afk-inject-e2e.test.sh tests/fm-afk-return.test.sh tests/fm-x-mode.test.sh tests/fm-backend.test.sh tests/fm-backend-tmux-smoke.test.sh tests/fm-secondmate-safety.test.sh
```

Observed output:

```text
FM_TEST_SUMMARY total=8 failed=0 skipped_gate=0 duration_ms=617507
```

The actionable-close ordering correction was reverified on 2026-08-02 against an identity-matched live successor.

```sh
tests/fm-claude-stop-autoarm.test.sh >/dev/null && echo "fm-claude-stop-autoarm: ok"
```

Observed output:

```text
fm-claude-stop-autoarm: ok
```

## Watcher continuity

The cross-harness evidence combines the 2026-07-17 live pass with Claude's replacement Stop-owned path revalidated on 2026-07-24, all against isolated project and home state.
No credential material was copied into a fixture.

```text
Claude Code 2.1.219
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Claude | `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` | Session start reclaimed a stale owner before two Stop-owned cycles, and a competing live owner prevented arm, rewake, epoch write, or lock replacement. |
| Codex | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh` | The one-second foreground checkpoint returned without switching to the arm wrapper. |
| OpenCode | `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh` | A verified successor existed before prompt handling, with no model re-arm or turn-end fallback. |
| Pi | `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` | One initial tool call led to extension-owned successors and clean child retirement on exit. |
| omp | `FM_OMP_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh` | One initial `fm_watch_arm_omp` invocation (the openai-codex model reaches extension tools through omp's `xd://` virtual-file bridge, a `write` to `xd://fm_watch_arm_omp`, counted as the same invocation) started a live watcher; an actionable close spawned a ledger-linked successor and woke main exactly once; the lab is reaped by path, and omp 18.1.11 did not exit within 30s of its rpc stdin closing, recorded as a note. omp 18.1.11, 2026-09-05. |
| Grok | `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh` | Native task completion surfaced the actionable close and the cycle ledger recorded `reason=actionable-signal`. |

Pi 0.81.1 repeated the continuity and clean-exit lifecycle on 2026-07-23 after the Calm presentation changes.

Pi same-process session-transition ownership was verified on 2026-09-01 against the tracked extension with provider-free public lifecycle events, retained and fresh extension-module rebinds, and real arm children:

```sh
pi --version
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Observed guarantee: after ordinary `session_shutdown` for `/new`, `/resume`, `/fork`, and reload, plus same-instance shutdown-plus-start, an owning `session_start` armed the replacement generation before any model turn and without the `watcher: not armed - Pi session is shutting down` refusal.
A fresh module rebind also received exactly once the actionable close whose first delivery was still in flight at shutdown, while retaining one live successor.
Stale prior-generation tool callbacks could not mutate the active child, repeated transitions kept exactly one live arm cycle, and terminal `quit` still refused late rearm.
The strict no-emit check used the installed Pi SDK declarations to hold the lifecycle event contract.
Plain Pi and pi-signed share the same tracked `.pi/extensions/fm-primary-pi-watch.ts` path, so both inherit the generation owner; other primary harnesses are not applicable because they do not use this Pi extension lifecycle.

On 2026-09-02 the same suite, the strict typecheck, and the credential-free real-SDK guard were rerun against `@earendil-works/pi-coding-agent` 0.84.4 after the extension stopped waiting for `before_agent_start` before settling a main delivery; [`runtime-backends.md`](runtime-backends.md#2026-09-02-streaming-time-watcher-delivery) owns the exact commands and output.
Observed guarantee: a wake delivered while main was streaming was followed by a verified successor and by delivery of the next actionable close, a replacement replayed only the follow-up Pi had not consumed, an exhausted restoration delivered its typed failure without launching an arm past the retry bound, and a verified successor that failed while a branch settlement still held its wake took the ordinary bounded retry once that delivery settled.

The once-per-generation recovery bound and immediate handling-successor poll were verified on 2026-08-21 with the tracked Pi extension, real watcher processes, and an isolated home.
The regression forced handling confirmation to fail, observed one recovery follow-up across the former repeat window, confirmed the successor remained live, and then proved a separate handling successor durably queued a crew event within the bounded poll window.

```sh
bin/fm-test-run.sh tests/fm-watch-recovery-loop.test.sh
```

Observed output:

```text
ok - a resurfacing handling successor stays alive and supervises instead of going blind
ok - unacknowledged recovery is announced at most once per generation and the successor stays alive
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=59357
```

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-watch-arm.test.sh
tests/fm-watch-recovery-loop.test.sh
tests/fm-wake-queue.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-turnend-guard.test.sh
```

## Wedge escalation liveness evidence

The CI-monitor exemption in `bin/fm-crew-state.sh --pipeline-liveness` rests on the installed validator's own quiet threshold and CI-monitor bound, checked on 2026-09-03 against no-mistakes v1.41.2.

```sh
no-mistakes axi status
no-mistakes axi logs --step ci --run 01M1K1E6GJE46J39EYS36T3Q7P
```

Observed: the completed run reported `ci,completed,0,1796271`, a CI step of 29m56s, whose entire step log held five entries - monitoring start, checks running, checks passed, one base-branch re-arm, and the merge.
The installed defaults are `step_quiet_warning: "10m"` and `ci_timeout: "168h"`, so `last_activity` carries the `quiet` prefix for most of any real CI phase while the run is healthy.
`axi status` builds `active_steps` from the running and fixing steps alone, so a row's presence is itself the evidence that its step is active.

Deterministic entry points:

```sh
tests/fm-crew-state.test.sh
tests/fm-watch-triage.test.sh
tests/fm-watcher-lock.test.sh
```

## Parked-by-usage-limit footers

The footers `bin/fm-limit-park-lib.sh` matches for the `claude` harness were read on 2026-09-03 out of the shipped Claude Code binary, version 2.1.259, rather than transcribed from a screenshot.

```sh
strings -n 6 ~/.local/share/claude/versions/2.1.259 | grep -nE 'resets|usage limit|session limit'
```

Observed, as the separate message fragments that component assembles with a middle dot:

```
Usage limit reached · continuing automatically · esc or type to cancel
Usage limit reached · continuing automatically at <time> · esc to cancel
Usage limit reached · continuing automatically when it resets · esc to cancel
Usage limit reached · continuing shortly · esc to cancel
Usage limit reached again after you continued · continuing automatically · …
Your usage limit has reset · press enter to continue
Usage limit available again · continuing now
Automatic continue was turned off · this task will not resume on its own
Automatic continue did not run · … · send a prompt to continue
Automatic continue stopped after repeated usage-limit hits · …
You've hit your session limit · resets 12:40pm (Europe/Brussels) · progress saved
```

The same read is what bounds the scope: the binary's spend, weekly, and credit-exhaustion messages (`You've hit your monthly spend limit`, `you have reached your weekly usage limit`, `You're out of usage credits`) are deliberately unmatched, because no prompt clears them and an auto-resume would spend attempts on a worker only a human can free.

That a resume must be a real message and not a keystroke was verified on 2026-08-20 on the `fo-session-lock-versioned-harness` worker: a bare Enter left it parked, a message resumed it.
This is why `bin/fm-limit-resume.sh` never uses the `--key` path and reads the pane back afterwards instead of trusting the send's exit status.

Deterministic entry points:

```sh
tests/fm-watch-triage.test.sh
```

## Wedge-alarm channels

The two real notification channels were bounded manually on 2026-07-10 on macOS 26.5.2 with Herdr 0.7.3.
Automated suites never execute these real notification commands.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

Herdr command:

```sh
herdr notification show 'FIRSTMATE TEST - IGNORE' \
  --body 'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)' \
  --sound request
```

Observed output:

```json
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
```

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.

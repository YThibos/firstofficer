# Session lock ownership

The per-home session lock decides which single session may mutate a home's fleet state.
`state/.lock` holds one pid, `state/.lock-session` holds the trusted Claude session id recorded beside it, `bin/fm-lock.sh` claims and inspects both, and `bin/fm-session-lock-lib.sh` owns every decision behind them.
This page owns the two rules this fork adds on top of that ownership model and their safety rationale; the scripts' own headers and `--help` own their flags and exact output.

## Identity is the shared ancestry model

Which process counts as a harness, which pid a running session resolves to, and whether a Stop hook runs inside the lock-owning session are decided by the shared model in `bin/fm-session-lock-lib.sh`'s header: the recorded pid is a member of this process's contiguous harness ancestry, or the trusted Claude session id matches the id recorded beside a live lock.
That model covers version-named Claude executables, daemon-parented background sessions, and a background session whose helper chain is recycled, and [`verification/supervision.md`](verification/supervision.md) records its evidence.
The fork adds nothing to it, and the two rules below only ever narrow which live holder keeps a lock.

## A standby never holds the lock

Claude Code's background daemon keeps pre-warmed spare session hosts ready for the next session to claim, and they run as `claude bg-spare`.
A standby runs the project's SessionStart hooks while it is being pre-warmed, before anyone uses it, so it used to claim a free or stale lock and then sit on it: it never takes a turn and never exits, so every later session in the home started read-only.
That is how a read-only Claude primary was held in a turn-end loop until its usage limit ran out, on 2026-09-24 and 2026-09-25.

Claude Code marks an unclaimed standby `"spare": true` in its per-pid record at `<config root>/sessions/<pid>.json` and drops the flag once a client claims it, and `fm_claude_session_is_spare` answers from that flag alone.
The argv cannot decide it, because a claimed standby keeps its `bg-spare` command line for the whole of the session it now hosts.
The record is trusted only when its `procStart` matches the live process's own start value in `/proc/<pid>/stat`, so a record left behind by a since-recycled pid claims nothing.
That verification needs `/proc` and therefore exists only on Linux; on any other host every record is unverifiable, answers no, and nothing changes.

Two rules follow, and both are needed.
`bin/fm-lock.sh` refuses to claim the lock from inside an unclaimed standby, and says why, so a standby cannot win the lock in the first place.
`fm_harness_pid_alive` does not count an unclaimed standby as a live holder, so a lock one already holds reads as stale: the real session claims it at session start, or at its next Stop through the Stop-owned auto-arm's ordinary stale-lock recovery, with no manual step.
Once claimed, the same process is an ordinary live session and holds or claims the lock like any other.
This is not a takeover of a session in use, so it is independent of the usage-limit takeover below and announces nothing.

## Taking over from a session stopped by a usage limit

A Claude session that stops because a usage limit was reached does not exit.
Its process stays alive for as long as its terminal or the daemon keeps it, so a liveness test alone answers "still working" indefinitely, every later session in that home is refused the lock and runs read-only, and supervision stays down while work is in flight.

`fm_session_limit_stopped` is the one positive test that resolves this.
It reads the holder's session id from `state/.lock-session`, the id the holder itself recorded beside the lock under the trusted-id gate, locates that session's transcript under the config root for the home's working directory, and asks `bin/fm-transcript-limit-stop.mjs` whether the last conversational record in that transcript is the usage-limit API error.
Only that answer permits a takeover, and `bin/fm-lock.sh` always announces one on stdout, records it in `state/.lock.takeover`, and surfaces it through the session-start digest and the bearings snapshot, so a takeover is never silent.

The recorded id names the conversation the holder is on now.
A live session that replaces its conversation in place, through `/clear`, re-keys its session id, and `bin/fm-lock.sh` refreshes the sidecar to the new id when that same process confirms its lock, so an older conversation's transcript ending on the limit error is never the one consulted.
The holder's argv is never a source: a `--session-id` pair can sit inside a single argument such as a prompt, and a holder with no recorded id has nothing tying it to a transcript and is never taken over.
The id must be an exact session id before it is used as a path component.

The transcript tail alone is not enough, because a stopped session is not the only thing that leaves one ending on that error.
Resuming a limit-stopped session reuses its session id and its transcript, so between the resume and its first new conversational record the tail is unchanged while that session is live, working, and holding the lock.
The holder's process start time separates the two: a session that hit the limit itself was already running when that record was written, while a resumed one started after it.
So the takeover additionally requires the last record's own instant to be at or after the holder process's start, and a start time that cannot be read refuses like every other unavailable value.
That start time is read from the process's own age through the POSIX `ps -o etime=` field rather than the procps-only `etimes`, which BSD `ps` rejects outright, so the takeover works on every supported host.

Three evidence rules matter enough to state here, because each was established against real transcripts and each is easy to get wrong.

The classification is a real JSON parse of the last `user` or `assistant` record, never a text match over the file.
An ordinary tool result inside a live session's transcript can quote a past limit message verbatim - a session working on this very mechanism does exactly that - and a text match would hand a working session's lock away.

The transcript directory is named after the home's absolute path with only `/` and `.` replaced by `-`.
That mapping was checked against every real project directory on the machine this rule was established on, with no other special character appearing in any recorded path; [`verification/supervision.md`](verification/supervision.md) owns that evidence.
Widening it to every non-alphanumeric character was rejected deliberately: if Claude Code really maps only these two, an all-punctuation rule would break a path holding an underscore that resolves correctly today.
A path mangled differently simply yields no transcript, which refuses, so the narrow rule costs a missed takeover and never a wrong one.

Transcript timestamps are not evidence of idleness.
Claude rewrites trailing metadata records long after a session ends, so the file's mtime can be hours newer than its last real record, and neither mtime nor elapsed idle time is used anywhere in this decision.

## Why every other case refuses

Taking the lock from a session that is genuinely working is far worse than refusing one that is finished, so the test is deliberately asymmetric: it returns true only for a positively identified limit stop and false for everything else.
Refusal is the outcome when the holder is not a Claude process, when no session id is recorded beside the lock or the recorded one is not an exact session id, when the transcript is missing, unreadable, or unparseable, when its last conversational record is anything other than the limit error, when that record carries no instant, and when the holder's start time cannot be read or is later than that record.
Inventing a link between a holder and a transcript would be exactly the guess this contract exists to avoid.

## Where the condition is reported

`bin/fm-session-start.sh` prints one `TAKEOVER:` line in its digest when the claim took the lock, so a fresh session knows why it is in control.

`bin/fm-bearings-snapshot.sh` projects the lib's report into its `session_lock` field, and the `bearings` skill renders it as a Charted Next line.
Bearings reports the condition and names `bin/fm-lock.sh`; it never runs it.
The `took-over-from` line is reported only to the session that actually performed the takeover, so a session merely reading a lock someone else took is never told it took anything.
Claiming a lock is a fleet mutation, and taking one from a live process is precisely the kind of act the skill's read-only contract exists to keep out of a status read, so the claim stays with the normal lifecycle even though the report is what makes it discoverable.

## Verification

`tests/fm-session-lock-identity.test.sh` pins the standby rules against real processes and verified records: an unclaimed standby is not a live holder while the same process counts once its record drops the flag, a real session takes the lock over from a standby through `bin/fm-lock.sh`, a standby cannot claim even a free lock, and a claimed standby keeps its lock like any live session.
`tests/fm-claude-stop-autoarm.test.sh` pins the automatic side: a real session reclaims a home a standby holds at its next Stop.

`tests/fm-session-lock-limit-stop.test.sh` drives the shared lib and `bin/fm-lock.sh` against fixture process tables, recorded session ids, and fixture transcripts.
It pins the takeover of a limit-stopped holder in both the plain and the version-named process shape, and the continued refusal of a working holder, a holder that only quoted a limit message, a resumed session whose process is younger than its own last record, a holder whose recorded session moved on from an older limit-stopped transcript, and a holder with no recorded id, a malformed one, or a non-Claude process.
One case gives a holder a real `--session-id` pair in its own argv with no recorded id and requires that it keep its lock.

## Maintaining this file

Keep this page to the fork's two rules and the safety rationale behind them.
Flags, exact output, and mechanics belong in the scripts' headers and `--help`; fleet-wide operating rules belong in the anchor or a skill.

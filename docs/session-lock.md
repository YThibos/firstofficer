# Session lock ownership

The per-home session lock decides which single session may mutate a home's fleet state.
`state/.lock` holds one pid, `bin/fm-lock.sh` claims and inspects it, and `bin/fm-session-lock-lib.sh` owns every decision behind both: which process counts as a harness, which pid a running session resolves to, and whether a holder that is still running has actually stopped.
This page owns the ownership contract and the safety rationale; the scripts' own headers and `--help` own their flags and exact output.

## What a lock pid must be

A lock is only useful if its pid identifies one session and dies with it.
Two properties are therefore required of the pid the ancestry walk selects, and both have been violated in practice by real process shapes.

It must live as long as the session.
That is why the walk climbs past the transient subshell of the current tool call to the harness process itself.

It must be unique to that session.
Claude Code's background sessions all descend from `claude daemon run`, a supervisor that serves every background session in the machine and outlives all of them.
It is claude-named, so a walk that keeps extending through claude-named ancestors reaches it and stops there, which breaks ownership twice over: the daemon never exits, so a lock recording it reads as live forever and refuses every later session; and every concurrent background session in the home resolves to that same pid, so no two of them can tell each other apart and each believes it owns the lock.
`fm_harness_shared_service` is the boundary that stops the walk one hop below such a process, and the same predicate rejects a shared service in the liveness test, so a lock already recording one is reclaimable instead of pinning the home read-only for as long as that service runs.

## Taking over from a session stopped by a usage limit

A Claude session that stops because a usage limit was reached does not exit.
Its host process stays alive for as long as its terminal or the daemon keeps it, so a liveness test alone answers "still working" indefinitely, every later session in that home is refused the lock and runs read-only, and supervision stays down while work is in flight.

`fm_session_limit_stopped` is the one positive test that resolves this.
Given the holder's pid it reads the holder's own argv for a session id, locates that session's transcript under the config root for the home's working directory, and asks `bin/fm-transcript-limit-stop.mjs` whether the last conversational record in that transcript is the usage-limit API error.
Only that answer permits a takeover, and `bin/fm-lock.sh` always announces one on stdout, records it in `state/.lock.takeover`, and surfaces it through the session-start digest and the bearings snapshot, so a takeover is never silent.

Two evidence rules matter enough to state here, because both were established against real transcripts and both are easy to get wrong.

The classification is a real JSON parse of the last `user` or `assistant` record, never a text match over the file.
An ordinary tool result inside a live session's transcript can quote a past limit message verbatim - a session working on this very mechanism does exactly that - and a text match would hand a working session's lock away.

Transcript timestamps are not evidence of idleness.
Claude rewrites trailing metadata records long after a session ends, so the file's mtime can be hours newer than its last real record, and neither mtime nor elapsed idle time is used anywhere in this decision.

## Why every other case refuses

Taking the lock from a session that is genuinely working is far worse than refusing one that is finished, so the test is deliberately asymmetric: it returns true only for a positively identified limit stop and false for everything else.
Refusal is the outcome when the holder is not Claude, when its session id never reaches its own argv, when the transcript is missing, unreadable, or unparseable, when the tail holds no conversational record at all, and when the last conversational record is anything other than the usage-limit error, including every other API error.
A session hosted without an explicit session id in its argv, such as a plain foreground `claude`, is therefore never taken over; nothing else can tie that process to a transcript, and inventing a link would be exactly the guess this contract exists to avoid.

## Where the condition is reported

`bin/fm-session-start.sh` prints one `TAKEOVER:` line in its digest when the claim took the lock, so a fresh session knows why it is in control.

`bin/fm-bearings-snapshot.sh` projects the lib's report into its `session_lock` field, and the `bearings` skill renders it as a Charted Next line.
Bearings reports the condition and names `bin/fm-lock.sh`; it never runs it.
Claiming a lock is a fleet mutation, and taking one from a live process is precisely the kind of act the skill's read-only contract exists to keep out of a status read, so the claim stays with the normal lifecycle even though the report is what makes it discoverable.

## Verification

`tests/fm-session-lock-limit-stop.test.sh` drives the shared lib and `bin/fm-lock.sh` against fixture process tables and fixture transcripts.
It pins the shared-service boundary in both the ancestry walk and the liveness test, the takeover of a limit-stopped holder, the continued refusal of a working holder, and the refusal of every missing, unparseable, non-limit, and non-Claude case.

## Maintaining this file

Keep this page to the ownership contract and the safety rationale behind it.
Flags, exact output, and mechanics belong in the scripts' headers and `--help`; fleet-wide operating rules belong in the anchor or a skill.

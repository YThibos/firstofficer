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

The transcript tail alone is not enough, because a stopped session is not the only thing that leaves one ending on that error.
Resuming a limit-stopped session reuses its session id and its transcript, so between the resume and its first new conversational record the tail is unchanged while that session is live, working, and holding the lock.
The holder's process start time separates the two: a session that hit the limit itself was already running when that record was written, while a resumed one started after it.
So the takeover additionally requires the last record's own instant to be at or after the holder process's start, and a start time that cannot be read refuses like every other unavailable value.
This compares two recorded instants rather than guessing at idleness, which is what keeps it clear of the timestamp rule below.

Three evidence rules matter enough to state here, because each was established against real transcripts and each is easy to get wrong.

The classification is a real JSON parse of the last `user` or `assistant` record, never a text match over the file.
An ordinary tool result inside a live session's transcript can quote a past limit message verbatim - a session working on this very mechanism does exactly that - and a text match would hand a working session's lock away.

Transcript timestamps are not evidence of idleness.
Claude rewrites trailing metadata records long after a session ends, so the file's mtime can be hours newer than its last real record, and neither mtime nor elapsed idle time is used anywhere in this decision.

## Why every other case refuses

Taking the lock from a session that is genuinely working is far worse than refusing one that is finished, so the test is deliberately asymmetric: it returns true only for a positively identified limit stop and false for everything else.
Refusal is the outcome when the holder is not Claude, when its session id never reaches its own argv, when the transcript is missing, unreadable, or unparseable, when the tail holds no conversational record at all, when the last conversational record is anything other than the usage-limit error, including every other API error, when that record carries no instant or one that does not parse, when the holder's start time cannot be read, and when the holder started after that record was written.
A session hosted without an explicit session id in its argv, such as a plain foreground `claude`, is therefore never taken over; nothing else can tie that process to a transcript, and inventing a link would be exactly the guess this contract exists to avoid.

## Where the condition is reported

`bin/fm-session-start.sh` prints one `TAKEOVER:` line in its digest when the claim took the lock, so a fresh session knows why it is in control.

`bin/fm-bearings-snapshot.sh` projects the lib's report into its `session_lock` field, and the `bearings` skill renders it as a Charted Next line.
Bearings reports the condition and names `bin/fm-lock.sh`; it never runs it.
The `took-over-from` line is reported only to the session that actually performed the takeover, so a session merely reading a lock someone else took is never told it took anything.
Claiming a lock is a fleet mutation, and taking one from a live process is precisely the kind of act the skill's read-only contract exists to keep out of a status read, so the claim stays with the normal lifecycle even though the report is what makes it discoverable.

## Verification

`tests/fm-session-lock-limit-stop.test.sh` drives the shared lib and `bin/fm-lock.sh` against fixture process tables and fixture transcripts.
It pins the shared-service boundary in both the ancestry walk and the liveness test, the takeover of a limit-stopped holder, the continued refusal of a working holder and of a resumed session whose process is younger than its own last record, the refusal of every missing, unparseable, timestamp-less, non-limit, and non-Claude case, and that only the session which performed a takeover is ever told it did.

## Maintaining this file

Keep this page to the ownership contract and the safety rationale behind it.
Flags, exact output, and mechanics belong in the scripts' headers and `--help`; fleet-wide operating rules belong in the anchor or a skill.

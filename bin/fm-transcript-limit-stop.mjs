#!/usr/bin/env node
// fm-transcript-limit-stop.mjs - classify the tail of a Claude Code transcript.
//
// Answers exactly one question for bin/fm-session-lock-lib.sh: is the LAST
// conversational record of this transcript the API error Claude Code writes
// when a session stops because a usage limit was reached? A session in that
// state keeps its process alive indefinitely, so process liveness alone cannot
// tell it apart from a session that is still working, and this file is the one
// place that reads the transcript to tell them apart.
//
// A real JSON parse, not a text match: a tool result inside an ordinary user
// record can quote a past limit message verbatim - a session doing this very
// kind of work does exactly that - and mistaking one for a stopped session
// would hand a working session's lock to someone else.
//
// A stopped session is not the only thing that leaves a transcript ending on
// that error. Resuming a limit-stopped session REUSES its session id and its
// transcript, so between the resume and its first new conversational record the
// tail is unchanged while the session is live and working again. The holder's
// process start time separates the two: a session that hit the limit itself was
// already running when that record was written, while a resumed one started
// after it. So the caller passes the holder's start time and the record must be
// at or after it. That is a comparison of two recorded instants, not an idle
// heuristic: the transcript's mtime and any elapsed-time signal stay unused,
// because Claude rewrites trailing metadata records long after a session ends.
//
// Usage: fm-transcript-limit-stop.mjs <transcript.jsonl> <holder-start-epoch>
//   exit 0  the last conversational record is a usage-limit stop that the
//           holder process was already running to write
//   exit 1  everything else, including every unreadable, unparseable, empty,
//           timestamp-less, or otherwise ambiguous transcript
// Nothing is printed on either path; the exit status is the whole contract.

import { closeSync, fstatSync, openSync, readSync } from 'node:fs';

// Transcripts reach several megabytes; the decision only ever needs the tail.
// A tail that holds no conversational record at all is an ambiguous read and
// takes the refusing path rather than being searched further back.
const TAIL_BYTES = 256 * 1024;

// Observed verbatim on real transcripts. Both are terminal for the session:
// it stops and stays stopped until a human comes back to it.
const LIMIT_STOP = [
  /^You've hit your session limit\b/,
  /^You've hit your monthly spend limit\b/,
];

function readTail(path) {
  const fd = openSync(path, 'r');
  try {
    const size = fstatSync(fd).size;
    const start = size > TAIL_BYTES ? size - TAIL_BYTES : 0;
    const buffer = Buffer.alloc(size - start);
    let filled = 0;
    while (filled < buffer.length) {
      const read = readSync(fd, buffer, filled, buffer.length - filled, start + filled);
      if (read === 0) break;
      filled += read;
    }
    return { text: buffer.toString('utf8', 0, filled), truncated: start > 0 };
  } finally {
    closeSync(fd);
  }
}

// The last record whose type is user or assistant. Everything else Claude
// writes to a transcript - attachments, system records, queue operations, and
// the title/mode/agent metadata it appends after a session ends - is skipped.
function lastConversationalRecord(path) {
  const { text, truncated } = readTail(path);
  const lines = text.split('\n');
  // A truncated read can start mid-record, so that first fragment is not a line.
  const first = truncated ? 1 : 0;
  for (let i = lines.length - 1; i >= first; i--) {
    const line = lines[i].trim();
    if (line === '') continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      return null; // Unparseable: ambiguous, so refuse.
    }
    if (record === null || typeof record !== 'object') return null;
    if (record.type === 'user' || record.type === 'assistant') return record;
  }
  return null;
}

function errorText(record) {
  const content = record?.message?.content;
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return null;
  const block = content.find((entry) => entry?.type === 'text');
  return typeof block?.text === 'string' ? block.text : null;
}

function isLimitStop(record) {
  if (record === null || record.type !== 'assistant') return false;
  if (record.isApiErrorMessage !== true) return false;
  const text = errorText(record);
  return typeof text === 'string' && LIMIT_STOP.some((pattern) => pattern.test(text));
}

// True when the record was written while the holder was already running. A
// record with no timestamp, or one that does not parse, is ambiguous and so
// refuses rather than falling back to a weaker signal.
function writtenByHolder(record, startEpoch) {
  if (typeof record.timestamp !== 'string') return false;
  const written = Date.parse(record.timestamp);
  if (!Number.isFinite(written)) return false;
  return Math.floor(written / 1000) >= startEpoch;
}

const [path, startArg] = process.argv.slice(2);
if (path === undefined || startArg === undefined) process.exit(1);
// The start time is required, so a caller that could not read it cannot reach
// the permitting path by omitting it.
if (!/^[0-9]+$/.test(startArg)) process.exit(1);
const startEpoch = Number(startArg);
let stopped = false;
try {
  const record = lastConversationalRecord(path);
  stopped = isLimitStop(record) && writtenByHolder(record, startEpoch);
} catch {
  stopped = false; // Missing, unreadable, or truncated mid-read: refuse.
}
process.exit(stopped ? 0 : 1);

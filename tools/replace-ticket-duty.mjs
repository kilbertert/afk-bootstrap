#!/usr/bin/env node
/**
 * Replace the "write the result back to the source ticket" paragraph with the
 * version that does not ask for something the agent cannot know.
 *
 * Usage: node replace-ticket-duty.mjs <path> <subject>
 *   <subject> is the noun the paragraph opens with: "this work" for a single
 *   issue, "this sub-issue" for a leaf of a PRD, "this change" for PR feedback.
 *
 * Exit codes:
 *   0  replaced, or inserted where the paragraph was missing
 *   3  the file has neither the old paragraph nor the anchor to insert after
 *   4  already the new text
 *   1  anything else
 *
 * WHAT WAS WRONG WITH THE OLD TEXT, and why this is a replacement rather than an
 * insert:
 *
 *   1. It asked the agent to write "the branch, the pull request, and which
 *      acceptance criteria this change satisfies" into the commit body. The pull
 *      request DOES NOT EXIST when the commit is made — the host opens it
 *      afterwards, from that commit. The agent was told to record a fact it
 *      could not have. Measured on the 1.7.18-1.7.20 text.
 *
 *   2. It named the commit body as the only carrier. `implement-pr` accepts a
 *      run that produces replies and zero commits, so on that path there is no
 *      commit to carry it and the handoff silently does not happen.
 *
 * The replacement asks only for what the agent knows — the ticket's identity and
 * the acceptance criteria met — and names a carrier that exists on BOTH paths.
 * The delivery link is the host's job and the host now does it, so the text does
 * not promise a mechanism that is not there.
 *
 * Replacement rather than insertion, because the old paragraph is already in
 * five prompts across four repositories and an insert would sit beside it.
 */
import { readFileSync, writeFileSync } from "node:fs";

const NEW = (subject) => `If ${subject} came from an outside ticket — a requirements
platform, a chat thread, a support queue — that ticket is where someone is
waiting. Record its identifier and the acceptance criteria this change satisfies
in the commit body under \`Source ticket:\`. Do not name a pull request: none
exists until the host opens one after this commit, and the host posts that link
to the issue itself. If you are replying without changing code, put the same
\`Source ticket:\` line in a top-level PR comment instead — there is no commit
to carry it. A result that stays in this repository is one the next person to
open that ticket has to rediscover.`;

// The old paragraph, matched line by line so a project's own rewording is left
// alone. Only the opening line varies (it names the subject), so the block is
// matched from it by shape.
const OLD_TAIL = [
  "thread, a support queue — that ticket is where someone is waiting. When the work",
  "is done, write back to it: the branch, the pull request, and which acceptance",
  "criteria this change satisfies. You cannot post to a system this sandbox does not",
  "reach; record the text in the commit body under `Source ticket:` and the host",
  "runner or the human who owns that ticket posts it. A result that stays in this",
  "repository is one the next person to open that ticket has to rediscover.",
];

const [path, subject, anchor] = process.argv.slice(2);
if (!path || !subject) {
  console.error("usage: replace-ticket-duty.mjs <path> <subject> [<anchor-substring>]");
  process.exit(1);
}

const src = readFileSync(path, "utf8");
const lines = src.split("\n");
const wanted = NEW(subject).split("\n");

const hasNew = lines.some(
  (_, i) => wanted.every((l, k) => lines[i + k] === l),
);
if (hasNew) process.exit(4);

// Find the old block: the opener is `If <subject> came from an outside ticket —
// a chat` (the em-dash and the wrap are the template's), and the rest must match
// OLD_TAIL exactly. A project that reworded it keeps it — the opener is loose on
// purpose, the six lines below it are not.
const opener = (l) => /^If .+ came from an outside ticket — a requirements platform, a chat$/.test(l);
let at = -1;
for (let i = 0; i < lines.length; i++) {
  if (!opener(lines[i])) continue;
  if (OLD_TAIL.every((l, k) => lines[i + 1 + k] === l)) {
    at = i;
    break;
  }
}

if (at >= 0) {
  const out = [...lines.slice(0, at), ...wanted, ...lines.slice(at + 1 + OLD_TAIL.length)];
  writeFileSync(path, out.join("\n"));
  process.exit(0);
}

// Absent: insert after the anchor, with the blank line on both sides, the same
// shape `add-search-duty.mjs` uses. The anchor is required here — a file with
// neither the old paragraph nor a known anchor is one this tool must not guess
// at, and 3 says so.
if (!anchor) process.exit(3);
const anchorAt = lines.findIndex((l) => l.includes(anchor));
if (anchorAt < 0) process.exit(3);
const lead = lines[anchorAt] === "" ? [] : [""];
const tail = anchorAt + 1 < lines.length && lines[anchorAt + 1] !== "" ? [""] : [];
lines.splice(anchorAt + 1, 0, ...lead, ...wanted, ...tail);
writeFileSync(path, lines.join("\n"));
process.exit(0);

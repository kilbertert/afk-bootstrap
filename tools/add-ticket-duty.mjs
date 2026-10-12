#!/usr/bin/env node
/**
 * Append the "write the result back to the source ticket" paragraph after a
 * known line in an AFK prompt.
 *
 * Usage: node add-ticket-duty.mjs <path> <anchor-substring>
 *
 * Exit codes, and why they are codes rather than messages:
 *   0  inserted
 *   3  the anchor is not in the file — the project reworded this prompt, and a
 *      migration must say so rather than guess where the paragraph belongs
 *   4  already present, so a re-run is a no-op instead of a duplicate
 *   1  anything else
 *
 * Line-anchored on purpose. `next_open_title`'s sibling in the 1.7.12 migration
 * was anchored on a sentence WITH its punctuation, and the same sentence is
 * written three ways across this repository's prompts — so it matched one file
 * and silently skipped the rest. The anchor here is a whole line that is
 * identical wherever the paragraph belongs, and the insertion point is the end
 * of it.
 *
 * Idempotent by a marker that only this paragraph contains, not by the anchor:
 * a re-run after the anchor line has moved must still be a no-op.
 */
import { readFileSync, writeFileSync } from "node:fs";

// One line of the paragraph names the situation (`this work` / `this
// sub-issue`), so the caller chooses the opening and the rest is shared — the
// alternative is two near-identical copies that drift.
const DUTY = (subject) => `
If ${subject} came from an outside ticket — a requirements platform, a chat
thread, a support queue — that ticket is where someone is waiting. When the work
is done, write back to it: the branch, the pull request, and which acceptance
criteria this change satisfies. You cannot post to a system this sandbox does not
reach; record the text in the commit body under \`Source ticket:\` and the host
runner or the human who owns that ticket posts it. A result that stays in this
repository is one the next person to open that ticket has to rediscover.

`;

const [path, anchor, subject = "this work"] = process.argv.slice(2);
if (!path || !anchor) {
  console.error("usage: add-ticket-duty.mjs <path> <anchor-substring> [<what the work is>]");
  process.exit(1);
}

const src = readFileSync(path, "utf8");
if (src.includes("Source ticket:")) process.exit(4);

const lines = src.split("\n");
const at = lines.findIndex((line) => line.includes(anchor));
if (at < 0) process.exit(3);

// Trailing newlines are stripped from the inserted text and the blank line the
// original file already had after the anchor becomes the paragraph separator.
// Kept exact rather than approximate because the scaffold's own copy of this
// prompt is the result of running this insert — if the two drifted, a freshly
// bootstrapped project and an upgraded one would carry different text for the
// same rule.
lines.splice(at + 1, 0, DUTY(subject).replace(/\n+$/, ""));
writeFileSync(path, lines.join("\n"));
process.exit(0);

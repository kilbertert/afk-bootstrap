#!/usr/bin/env node
/**
 * Insert the "search the records before you settle on an approach" paragraph
 * after a known line in an AFK prompt — and collapse the copies an earlier run
 * of this insert left behind.
 *
 * Usage: node add-search-duty.mjs <path> <anchor-substring>
 *
 * Exit codes:
 *   0  inserted, or duplicate copies removed
 *   3  the anchor is not in the file — the project reworded this prompt, and a
 *      migration must say so rather than guess where the paragraph belongs
 *   4  already there, so a re-run is a no-op instead of a duplicate
 *   1  anything else
 *
 * WHY THE DEDUPE IS PART OF THIS TOOL. The 1.7.13 step carried this insert as a
 * heredoc whose idempotency test read
 *
 *     if (src.includes("search what this repository has already decided"))
 *
 * but the paragraph is inserted as LINES, and that phrase is split across two of
 * them -- line 1 ends "has already", line 2 begins "decided:". The marker
 * therefore never matched, `exit 4` never fired, and EVERY upgrade at or above
 * 1.7.13 inserted another copy. Measured on all four consumer repositories: four
 * identical copies in each of the three prompts the step touched.
 *
 * So the presence test uses text that lies on ONE line, and a file that already
 * carries duplicates is repaired on the way through rather than left to
 * accumulate. A project that reworded the paragraph keeps its wording and is not
 * given a second copy (see PHRASES below for why that test is what it is).
 */
import { readFileSync, writeFileSync } from "node:fs";

// The paragraph, as the lines it is inserted as. `PHRASES` is derived from it
// below, so the marker cannot drift from the text it marks.
const BLOCK = [
  "Before you settle on an approach, search what this repository has already",
  'decided: `rg -i "<机制名或关键词>" docs/adr/`, and read the two or three records',
  "whose titles touch the area. Facts the code or those records can answer, answer",
  "yourself — do not spend a human's time on them.",
];

// Any ONE of the paragraph's lines, not a nominated one.
//
// Nominating a single line is the mistake this file has already made twice. The
// first version tested the CLOSING line and appended a second copy to a prompt
// whose last line had been reworded; the fix then nominated the OPENING line,
// which the same objection defeats — reword the opening and the tool appends
// again. Both were reproduced. Every line of BLOCK is a long, distinctive
// sentence, so the presence of ANY of them is evidence the paragraph is there,
// and a project must reword all four before this test loses its grip.
//
// It is deliberately not anchored to the line ABOVE the paragraph: that line is
// the insertion anchor and varies per prompt.
const PHRASES = BLOCK;

const [path, anchor] = process.argv.slice(2);
if (!path || !anchor) {
  console.error("usage: add-search-duty.mjs <path> <anchor-substring>");
  process.exit(1);
}

const src = readFileSync(path, "utf8");
const lines = src.split("\n");

const matchesBlock = (i) =>
  i + BLOCK.length <= lines.length &&
  BLOCK.every((line, k) => lines[i + k] === line);

const starts = [];
for (let i = 0; i < lines.length; i++) if (matchesBlock(i)) starts.push(i);

if (starts.length > 1) {
  // Keep the first copy — the one the original insert placed after the anchor —
  // and drop the rest, each with the blank line the insert put in front of it.
  const drop = new Set();
  for (const at of starts.slice(1)) {
    if (at > 0 && lines[at - 1] === "") drop.add(at - 1);
    for (let k = 0; k < BLOCK.length; k++) drop.add(at + k);
  }
  const kept = lines.filter((_, i) => !drop.has(i));
  writeFileSync(path, kept.join("\n"));
  console.log(`removed ${starts.length - 1} duplicate copy/copies`);
  process.exit(0);
}

if (starts.length === 1 || PHRASES.some((p) => src.includes(p))) {
  // Either the exact paragraph, or a copy the project reworded — any surviving
  // line means the duty is there and this run owes nothing. See PHRASES above
  // for why this is not a single nominated line.
  //
  // ponytail: a copy with ALL FOUR lines rewritten is not recognised, and the
  // template's paragraph is inserted beside it. Deliberate — a paragraph that
  // shares no text with the template is not identifiable as the duty by any
  // marker this tool can carry, and the alternative (anchoring on the line
  // ABOVE, which is the same line in every prompt that lacks the duty) would
  // report "already present" for every prompt that never had it. Upgrade path
  // if a real project hits it: match on the section it sits in, not on its text.
  process.exit(4);
}

const at = lines.findIndex((line) => line.includes(anchor));
if (at < 0) process.exit(3);

// Blank line first: the paragraph is a section of its own, and the anchor line
// already has a blank after it in some prompts but not others — inserting the
// separator here makes the result identical everywhere.
lines.splice(at + 1, 0, "", ...BLOCK);
writeFileSync(path, lines.join("\n"));
process.exit(0);

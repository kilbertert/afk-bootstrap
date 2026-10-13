#!/usr/bin/env node
/**
 * Insert the "search the records before you settle on an approach" paragraph
 * after a known line in an AFK prompt — and repair the copies an earlier run of
 * this insert left behind.
 *
 * Usage: node add-search-duty.mjs <path> <anchor-substring>
 *
 * Exit codes:
 *   0  inserted, moved, or duplicate copies removed
 *   3  the anchor is not in the file — the project reworded this prompt, and a
 *      migration must say so rather than guess where the paragraph belongs
 *   4  already correct, so a re-run is a no-op
 *   1  anything else
 *
 * TWO DEFECTS THIS FILE EXISTS TO REPAIR, both measured, both from the heredoc
 * the 1.7.13 step used to carry:
 *
 *   1. The idempotency test read
 *          src.includes("search what this repository has already decided")
 *      while the paragraph is inserted as LINES, with that phrase split across
 *      two of them ("has already" / "decided:"). The marker never matched,
 *      `exit 4` never fired, and every upgrade at or above 1.7.13 stacked
 *      another copy. Measured: four identical copies in each of the three
 *      prompts that step touched, in all four consumer repositories.
 *
 *   2. It inserted at `anchor + 1`, unconditionally. Where the anchor is a
 *      numbered list item whose text continues on indented lines, that put the
 *      paragraph BETWEEN the item and its own continuation — so
 *      `.sandcastle/implement-pr/prompt.md` read "3. Make the code changes …
 *      then 4. If you made no changes…", with step 3's verification instruction
 *      orphaned in the middle. Measured on health-flow after the 1.7.19
 *      rollout. The insertion point is the end of the ITEM.
 *
 * So the file is handled as: find the anchor, find the end of that list item,
 * remove every copy of the paragraph this template wrote, and put one back at
 * the right point. A paragraph the project reworded matches none of those and is
 * left strictly alone.
 */
import { readFileSync, writeFileSync } from "node:fs";

// The paragraph, as the lines it is inserted as.
const BLOCK = [
  "Before you settle on an approach, search what this repository has already",
  'decided: `rg -i "<机制名或关键词>" docs/adr/`, and read the two or three records',
  "whose titles touch the area. Facts the code or those records can answer, answer",
  "yourself — do not spend a human's time on them.",
];

// Presence markers, derived from BLOCK so they cannot drift from it. ANY one of
// them means the duty is present.
//
// A single nominated line is the mistake this file has already made twice: the
// first marker was the CLOSING line, and a prompt whose last line had been
// reworded got a second copy; the fix then nominated the OPENING line, which
// the same objection defeats — reword the opening and it happens again. Both
// were reproduced. Every line here is a long, distinctive sentence, so a project
// has to reword all four before this test loses its grip. Deliberately not
// anchored to the line ABOVE the paragraph: that is the insertion anchor, and it
// differs per prompt.
const PHRASES = BLOCK;

// A list item, and a line that continues one. `implement-pr/prompt.md` is the
// prompt where this matters.
const isItem = (l) => /^\s*(?:\d+[.)]|[-*+])\s/.test(l);
const continues = (l) => /^\s+\S/.test(l) && !isItem(l);

/**
 * The line after which the paragraph belongs: the end of the anchor's item.
 *
 * Walks past an existing copy of the paragraph on the way. After the defected
 * insert, the shape is `step 3 / blank / PARAGRAPH / continuation`, so the
 * continuation is only reachable by skipping the paragraph — and without that
 * skip the tool would compute the same wrong answer it is here to correct.
 */
function insertionPoint(lines, anchor) {
  const at = lines.findIndex((line) => line.includes(anchor));
  if (at < 0) return -1;
  let end = at;
  while (end + 1 < lines.length) {
    const next = end + 1;
    if (continues(lines[next])) {
      end = next;
    } else if (lines[next] === "" || BLOCK.some((b) => lines[next] === b)) {
      // Part of what may be a copy sitting in the gap. Look ahead past it.
      let probe = next;
      while (probe < lines.length && (lines[probe] === "" || BLOCK.some((b) => lines[probe] === b))) {
        probe += 1;
      }
      if (probe < lines.length && continues(lines[probe])) {
        end = probe;
        continue;
      }
      break;
    } else {
      break;
    }
  }
  return end;
}

const [path, anchor] = process.argv.slice(2);
if (!path || !anchor) {
  console.error("usage: add-search-duty.mjs <path> <anchor-substring>");
  process.exit(1);
}

const src = readFileSync(path, "utf8");
const lines = src.split("\n");

// The paragraph as this template writes it, verbatim. Returns every start index.
function exactCopiesIn(arr) {
  const hits = [];
  const matches = (i) =>
    i + BLOCK.length <= arr.length && BLOCK.every((line, k) => arr[i + k] === line);
  for (let i = 0; i < arr.length; i++) if (matches(i)) hits.push(i);
  return hits;
}

const copies = exactCopiesIn(lines);
const want = insertionPoint(lines, anchor);

/**
 * Insert the paragraph into `arr` after line `at`, with the blank lines it needs
 * on BOTH sides. Returns nothing; `arr` is modified in place.
 *
 * The trailing blank is not cosmetic. Without it the numbered step that follows
 * is swallowed into the paragraph and stops being a list item — measured: `4. If
 * you made no changes` rendered as body text rather than a fourth step, in the
 * scaffold and in every migrated prompt. The leading blank is what separates the
 * paragraph from the item it follows. A blank that is already there is not
 * doubled, and nothing is appended at end-of-file.
 */
function spliceParagraph(arr, at) {
  const lead = at >= 0 && arr[at] === "" ? [] : [""];
  const tail = at + 1 < arr.length && arr[at + 1] !== "" ? [""] : [];
  arr.splice(at + 1, 0, ...lead, ...BLOCK, ...tail);
}

// A copy is `"" , BLOCK` — a blank line, the four lines of the paragraph — and
// it must be FOLLOWED by a blank line when anything non-blank comes after.
const correct = (at) =>
  at === want + 2 &&
  (at + BLOCK.length >= lines.length || lines[at + BLOCK.length] === "");

if (copies.length === 1 && correct(copies[0])) process.exit(4);

// The duty is present in the project's own words. Not this tool's business.
if (copies.length === 0) {
  if (PHRASES.some((p) => src.includes(p))) process.exit(4);
  if (want < 0) process.exit(3);
  spliceParagraph(lines, want);
  writeFileSync(path, lines.join("\n"));
  process.exit(0);
}

// No anchor to place against: leave the file EXACTLY as it is and report.
//
// This used to delete the copies and then exit 3, on the reasoning that the step
// prints a warning and publication continues. It does continue — which is the
// problem: the upgrade would remove an instruction from a project-owned prompt
// and stamp the new version, with a warning as the only trace. Measured with an
// anchor that no longer exists: rc=3, paragraph count 1 -> 0. A tool that cannot
// place a paragraph must not remove one.
if (want < 0) process.exit(3);

// Every exact copy is removed and one is written back at the correct point.
//
// The replacement is placed by ORIGINAL index, walked in one pass: `want` was
// computed against the file before anything was removed, so re-finding the
// anchor in the filtered list would be wrong. That was the previous version's
// bug — `insertionPoint` on the shifted list returned -1 and the file was
// written with every copy deleted and none restored. Measured on all four
// repositories' `implement-prd/prompt.md`; the smoke test caught it.
const drop = new Set();
for (const at of copies) {
  if (at > 0 && lines[at - 1] === "") drop.add(at - 1);
  else if (lines[at + BLOCK.length] === "") drop.add(at + BLOCK.length);
  for (let k = 0; k < BLOCK.length; k++) drop.add(at + k);
}

// The paragraph goes in after `want`, and the surrounding blank lines are the
// ones spliceParagraph computes — so this path and the "no copy yet" path above
// cannot disagree about spacing.
//
// Built in two passes because the insertion is by ORIGINAL index: `want` was
// computed before anything was removed. Recomputing it on the filtered list is
// what the previous version got wrong — `insertionPoint` returned -1 there and
// the file was written with every copy deleted and none restored, measured on
// all four repositories' `implement-prd/prompt.md`.
const before = lines.slice(0, want + 1).filter((_, i) => !drop.has(i));
const after = lines.slice(want + 1).filter((_, i) => !drop.has(want + 1 + i));
const out = [...before, ...after];
// `before.length - 1` is the anchor's line in `out` — including when `after` is
// empty and the anchor ended the file, where spliceParagraph then adds no
// trailing blank.
spliceParagraph(out, before.length - 1);
writeFileSync(path, out.join("\n"));
console.log(
  copies.length > 1
    ? `removed ${copies.length - 1} duplicate copy/copies`
    : "moved a copy that sat inside a list item",
);

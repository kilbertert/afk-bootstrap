#!/usr/bin/env node
/**
 * Right-size the agent's test discipline in an AFK prompt.
 *
 * Usage: node right-size-tests.mjs <path>
 *
 * Exit codes:
 *   0  rewritten
 *   3  no red-green block — the project restructured this prompt, and a
 *      migration must say so rather than guess
 *   4  already correct, so a re-run is a no-op
 *   1  anything else
 *
 * WHY THIS REPLACES WHOLE-FILE RESTAGING.
 *
 * The 1.7.19 and 1.7.22 steps restage a prompt by `cmp`-ing it against a
 * `references/*.1.7.NN` snapshot and copying the scaffold's copy over it. That
 * works only while a prompt is still byte-identical to what the template
 * shipped — and after four rollouts, none of the consumer repositories' live
 * prompts are. Two independent reasons, both measured:
 *
 *   * the python repositories carry a hand-applied language substitution
 *     (`uv run pytest` where the scaffold says `npm run check`); `upgrade-afk.sh`
 *     has no substitution logic at all, so the swap was made by hand;
 *   * every repository carries hand-written project-specific verification
 *     paragraphs. AI-Ops' names its verification skill, its throwaway data root,
 *     and a credential red line ("never record a device token in evidence or a
 *     commit"). That paragraph is better than the template's and must survive.
 *
 * A `cmp` guard therefore fails on every consumer and the step silently no-ops
 * everywhere — the failure mode ADR 0003 exists to prevent, one layer out.
 *
 * WHAT IT CHANGES, and why this block is the right target.
 *
 * It rewrites ONE region: the `Use red-green-refactor` list. That list is not
 * merely a testing convention — it is the loop. `3. REPEAT until the issue is
 * done` sits directly above a gate that is `typecheck + full suite + build`, so
 * the instruction the agent reads is "run everything, then go round again".
 * Measured in AI-Ops: the full suite is 299.62 s against 2.91 s for a single
 * test file (103x), and runs 92-99 invoked that gate four or more times each.
 * The cost is the repetition, not the test-writing, which is why the replacement
 * keeps red-green for the cases where a test IS the cheapest oracle while
 * demoting the full run from "every lap" to "once, at the end".
 *
 * The block is byte-identical in every file and language it appears in, which is
 * what makes an anchored edit safe here where whole-file restaging is not:
 * verified identical across all four consumer repositories for
 * `implement-prompt.md`, `implement/prompt.md`, and `implement-prd/prompt.md`,
 * and identically worded in both language templates.
 *
 * The other prompts are deliberately NOT touched. `implement.md`,
 * `implement-pr/prompt.md`, and the two review prompts run the gate once rather
 * than in a loop, so they carry no repetition to remove.
 *
 * This says nothing against regression tests. A regression test is the durable
 * record that old behavior still holds — `CODING_STANDARDS.md` says so, and the
 * clause there is widened rather than weakened. What stops is manufacturing
 * tests to hit a number, which is what the retired
 * `~/.claude/rules/common/testing.md` ("Minimum Test Coverage: 80%") induced
 * while no repository in the fleet enforced any coverage threshold at all.
 */
import { readFileSync, writeFileSync } from "node:fs";

// The head, as found. The colon/period varies by file — implement-prompt.md ends
// it with a colon and the others with a period — so the terminator is optional
// rather than two patterns.
const HEAD = /^Use red-green-refactor where applicable[:.]?\s*$/;

// The tail. `4. REFACTOR` in implement/ and implement-prd/; `4. REFACTOR the
// code` in implement-prompt.md.
const TAIL = /^4\. REFACTOR(?: the code)?\s*$/;

// What the block becomes. Prose, not a numbered ritual: the numbering is what
// did the damage, because `3. REPEAT` reads as "loop forever" and the paragraph
// that followed it was a full-suite run. The cadence duty is folded in here
// rather than inserted separately at the gate, so the whole change is one region
// and no second anchor can drift out from under it.
const BLOCK = [
  "Let a test lead where a test is the cheapest way to pin the behavior: write it",
  "first, watch it fail, then implement to pass it. That is one technique, not a",
  "ritual. Reach for it where the behavior is non-trivial or a regression would",
  "otherwise be silent — branching logic, parsers, persistence, money, auth,",
  "data transforms.",
  "",
  "Do not manufacture a test to satisfy a quota. Prose, formatting, a rename, or",
  "a one-line wiring change owes none. Name the input that would break your",
  "change and pin that input; if you cannot name one, say so in the commit body",
  "rather than writing a test that asserts the implementation back to itself.",
  "",
  "While you iterate, run only the narrowest check that can falsify what you just",
  "did — the test files touching your change, the typecheck, the linter. The full",
  "gate below runs everything; run it once, when the change is complete, not after",
  "every edit.",
];

// One distinctive line, long enough that a project would have to reword the whole
// sentence to defeat it. `add-search-duty.mjs` documents two rounds of a shorter
// marker losing its grip, so this is a full sentence rather than a phrase.
const MARK = "Do not manufacture a test to satisfy a quota.";

const [path] = process.argv.slice(2);
if (!path) {
  console.error("usage: right-size-tests.mjs <path>");
  process.exit(1);
}

const lines = readFileSync(path, "utf8").split("\n");

// Idempotency. A file already carrying the guidance is done; so is a file with
// no block. Checked before the region lookup because the region no longer exists
// once this tool has run.
if (lines.some((l) => l.includes(MARK))) process.exit(4);

// Locate the block. Returns [start, end) — head through tail, inclusive of both.
//
// The shape is `head / blank / 1. RED / 2. GREEN / 3. REPEAT / 4. REFACTOR`, so
// the walk tolerates the blank after the head and then requires every following
// line to be a numbered item until the tail. A line that is neither means the
// list was restructured and this tool does not own it — returning null rather
// than scanning on to some other `REFACTOR` further down the file, which would
// splice out whatever sat between.
const ITEM = /^\d+[.)]\s/;

function region() {
  const at = lines.findIndex((l) => HEAD.test(l));
  if (at < 0) return null;
  let i = at + 1;
  while (i < lines.length && lines[i] === "") i++;
  for (; i < lines.length; i++) {
    if (TAIL.test(lines[i])) return [at, i + 1];
    if (!ITEM.test(lines[i])) return null;
  }
  return null;
}

const span = region();
if (!span) process.exit(3);

// One splice, by original index — no second edit can shift it. `add-search-duty.mjs`
// shipped the opposite bug: it recomputed an anchor on a filtered list and wrote
// four repositories' `implement-prd/prompt.md` with every copy deleted and none
// restored, which its smoke test caught.
lines.splice(span[0], span[1] - span[0], ...BLOCK);
writeFileSync(path, lines.join("\n"));
console.log("red-green loop -> risk-based guidance plus a gate cadence");

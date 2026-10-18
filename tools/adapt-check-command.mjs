#!/usr/bin/env node
/**
 * Point every prompt's "run the check" line at THIS project's check command.
 *
 * The scaffold's prompts were written for a Node project and say
 * `npm run check`. Two of them — `merge-prompt.md` and `update-branch/prompt.md`
 * — are LANGUAGE-AGNOSTIC: nothing in either file is about Node, so neither was
 * ever given a per-language render, and `upgrade-afk.sh` has no step that
 * restages them. A Python project therefore keeps a `npm run check` that cannot
 * run, in the two prompts whose whole job is "resolve a conflict, then verify".
 * Measured 2026-10-18 on the three Python consumers (AI-Ops, health-flow,
 * genesis-evidence): 2 hits each, in exactly those two files, while all five
 * per-language prompts were correctly translated.
 *
 * `bootstrap-afk.sh` already substitutes this, but with the command HARDCODED
 * and only for projects created after that block existed — hence two shapes for
 * one rule. This tool exists so there is ONE rule with TWO callers, the shape
 * ADR 0003 keeps finding missing in this repository.
 *
 * ── How the target command is chosen ─────────────────────────────────────────
 *
 * From the project's `language` in `.afk-bootstrap.json`, resolved through the
 * templates that bootstrap itself uses (`templates/implement.<lang>.md`). One
 * source of truth for the mapping, and no flag to get wrong.
 *
 * The first version read the command out of the project's own
 * `.sandcastle/implement.md` instead, on the theory that a project may have
 * adapted it. Measured against AI-Ops, that file is HEAVILY hand-customised, and
 * the first backticked token after "before committing" is prose (`/diag/*`) — it
 * wrote `/diag/*` into both prompts. A heuristic over prose cannot survive a
 * prompt a human has edited, and both of these files are ones humans edit.
 *
 * Falling back to the templates is the honest trade: a project that changed its
 * own command gets the template's command, which is at least a real command and
 * a visible one. Guessing from prose gets a plausible-looking wrong one.
 *
 * If the language is unrecorded or has no template, this exits 4 and changes
 * nothing.
 *
 * Run:
 *   node tools/adapt-check-command.mjs --root <project> [--scaffold <dir>]
 *   node tools/adapt-check-command.mjs --root <project> --file .sandcastle/x.md
 *
 * Exit: 0 = files rewritten, 3 = nothing to do, 4 = command unknown,
 *       1 = usage/IO error.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const CHECK = "npm run check";
const HERE = path.dirname(fileURLToPath(import.meta.url));

function usage(message) {
  process.stderr.write(`${message}\nusage: adapt-check-command.mjs --root DIR [--scaffold DIR] [--file REL]\n`);
  process.exit(1);
}

const argv = process.argv.slice(2);
let root = "";
let scaffold = path.join(HERE, "..");
const files = [];
for (let i = 0; i < argv.length; i += 1) {
  if (argv[i] === "--root") root = argv[++i] ?? "";
  else if (argv[i] === "--scaffold") scaffold = argv[++i] ?? "";
  else if (argv[i] === "--file") files.push(argv[++i] ?? "");
  else usage(`unknown argument: ${argv[i]}`);
}
if (!root) usage("--root is required");
if (!fs.existsSync(root)) usage(`no such directory: ${root}`);

function projectCheck() {
  const provenance = path.join(root, ".afk-bootstrap.json");
  if (!fs.existsSync(provenance)) return { check: "", why: "no .afk-bootstrap.json" };
  let language;
  try {
    language = JSON.parse(fs.readFileSync(provenance, "utf8")).language;
  } catch (error) {
    return { check: "", why: `unreadable .afk-bootstrap.json: ${error.message}` };
  }
  if (!language) return { check: "", why: "no `language` recorded" };

  const template = path.join(scaffold, "templates", `implement.${language}.md`);
  if (!fs.existsSync(template)) return { check: "", why: `no template for language \`${language}\`: ${template}` };
  // Anchored on `Run \`…\` before` — the templates' commit step. A bare "first
  // backtick" found `.sandcastle/REPO-MAP.md` (the read-first line) and wrote
  // that into both prompts. The other `Run \`…\` before` line is the
  // policy-check one, and the pattern `before committing` does not follow it.
  const source = fs.readFileSync(template, "utf8");
  const match = source.match(/Run `([^`\n]+)` before/);
  if (!match || match[1].includes("policy-check")) {
    return { check: "", why: `no \`Run \\\`…\\\` before\` check line in ${template}` };
  }
  return { check: match[1].trim(), why: "" };
}

function targets() {
  if (files.length) return files.map((rel) => path.join(root, rel));
  const found = [];
  (function walk(dir) {
    if (!fs.existsSync(dir)) return;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith(".md")) found.push(full);
    }
  })(path.join(root, ".sandcastle"));
  return found;
}

const { check, why } = projectCheck();
if (!check) {
  process.stderr.write(
    `cannot determine the check command (${why}) — nothing changed, because a guessed ` +
      "command looks like a real one and the agent reading it cannot tell.\n",
  );
  process.exit(4);
}

// A Node project's command already IS `npm run check`. Report rather than
// rewrite, so the callers can tell "adapted" from "nothing to do".
if (check === CHECK) {
  process.stdout.write(`check command is already \`${CHECK}\` — nothing to adapt\n`);
  process.exit(3);
}

let rewritten = 0;
for (const file of targets()) {
  if (!fs.existsSync(file)) continue;
  const before = fs.readFileSync(file, "utf8");
  if (!before.includes(CHECK)) continue;
  fs.writeFileSync(file, before.split(CHECK).join(check));
  rewritten += 1;
  process.stdout.write(`adapted ${path.relative(root, file)}\n`);
}

if (rewritten === 0) {
  const where = files.length ? "the named files" : ".sandcastle/";
  process.stdout.write(`no \`${CHECK}\` in ${where} — nothing to do\n`);
  process.exit(3);
}
process.stdout.write(`rewrote ${rewritten} file(s) to \`${check}\`\n`);

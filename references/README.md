Shapes of `.sandcastle/profile.ts` that per-project templates have produced, kept
here — not under `test/` — because `upgrade-afk.sh` reads them at run time.
`test/` is not part of the shipped tool; a migration that needed it would fail
for anyone who installed the script without the test fixtures.

- `profile-1.1.x.ts` — a template's own output (five profiles, settings-driven).
- `profile-handport.ts` — the same code with a single `claude-stepfun` entry and
  the endpoint baked into the image, as a project that applied the change by hand
  would have left it.

The migration compares a candidate to these with the profile table and image name
normalised away, which is what makes it able to refuse a file carrying project
edits instead of overwriting it.

- `mcp-config.ts.1.6.0` / `mcp-config.check.ts.1.6.0` — the two MCP modules as
  1.6.0 shipped them, before the config was written atomically and before the
  codebase-memory binary had to be executable. The 1.6.1 step replaces a project's
  copy only when it still matches these byte for byte; both revisions export the
  same names, so a presence test would accept a file the step must not touch.

- `repo-map.mjs.1.6.0` — the map generator before it read `pyproject.toml`. The
  1.6.1 step restages it only when a project's copy still matches this, so a
  project that taught its generator about something local keeps that.

- `repo-map.mjs.1.6.1` — the map generator as 1.6.1 shipped it: `pyproject.toml`
  console scripts were read, but the `package.json` entry-point filter was still
  an allowlist of five script names and the test count still stopped at the top
  level of each test directory. The 1.6.2 step replaces a project's copy only when
  it matches this byte for byte.

- `repo-map.mjs.1.6.3` — the map generator as 1.6.3 shipped it: entry points and
  test counts were correct, but the file set behind the map still came from a
  filesystem walk. The 1.6.4 step replaces a project's copy only when it matches
  this byte for byte.

- `mcp-config.ts.1.7.0` — the MCP config as 1.7.0 shipped it, before the serena
  entry named an active project. The 1.7.1 step replaces a project's copy only
  when it matches this byte for byte.

- `repo-map.mjs.1.7.10` / `repo-map.check.mjs.1.7.10` — the map generator and its
  check as 1.7.10 shipped them: the map reported where things live but never said
  what NAME this repository's knowledge graph answers to. An agent asked to use
  the graph had to guess, and the name indexing derives on its own comes from the
  sandbox path, so the guess always missed. The 1.7.11 step replaces a project's
  copy only when it matches these two byte for byte.

- `profile.ts.1.7.10` — the same file with the graph's `--name` argument
  removed, which is the shape a 1.7.10 project carries. Derived from the current
  scaffold by deleting exactly the token the 1.7.11 step adds, so the fixture and
  the step's anchor cannot drift apart: change either spelling and the smoke test
  fails instead of the migration silently skipping.

- `adr.check.mjs.1.7.12` / `architecture-decisions.md.1.7.12` — the checker and the
  convention as 1.7.12 shipped them: the gate decided whether to ENFORCE from the
  *value* of the base ref, so an empty `AFK_ADR_BASE` downgraded it to a report
  (measured: `--base ""` exited 0); coverage was judged over the whole merge-base
  diff rather than per commit; and the convention said nothing about searching for
  an existing record before writing one. The 1.7.13 step replaces a project's copy
  only when it matches these byte for byte. Taken from the 1.7.12 commit, not from
  the current tree — a reference that tracks HEAD anchors nothing.
- `adr-0002-self-application.md` — the record the 1.7.13 step installs into
  consuming projects. It explains the three defects above, so a project that later
  wonders why its gate refuses an empty base has the answer in its own tree.

- `adr.check.mjs.1.7.14` — the checker as 1.7.14 shipped it: `git diff-tree` was
  called without `-m`, so a MERGE COMMIT reported no paths at all and any merge was
  waived in silence. The 1.7.15 step replaces a project's copy only when it matches
  this byte for byte — so a project older than 1.7.14 gets the merge fix and the
  collision fix together, and one at 1.7.14 gets only the latter.

- `adr.check.mjs.1.7.15` — the checker as 1.7.15 shipped it: the empty-base guard
  was `!ALL`, treating `--base ""` and an empty `AFK_ADR_BASE` as one case. So
  `--all --base ""` exited 0 with coverage silently unevaluated — someone asked
  for a diff and the coverage half was skipped without a word. The 1.7.16 step
  replaces a project's copy only when it matches this byte for byte.

  Three consecutive releases fixed the same three lines, each time closing the
  case that had been measured and leaving a sibling open. That is the argument for
  the combination tests now in `test/smoke.sh`: the pairs, not the cases.

- `afk-policy.yml.1.7.12` — the policy workflow as 1.7.11 left it: the scaffold's
  steps, no decision-record step, and a shallow checkout. This is the shape the
  1.7.12 step replaces wholesale, and the smoke fixture copies it rather than
  assembling it by stripping — a strip that silently stops matching leaves the
  fixture already-fixed, and the assertions then prove nothing. Measured twice.

- `afk-policy.yml.1.7.12` — the policy workflow as 1.7.11 left it: the scaffold's
  steps, no decision-record step, and a shallow checkout. The 1.7.12 step replaces
  it wholesale, and it is also the shape table: a live project's instructions are
  that list plus the lines later releases added to the checkout, so the comparison
  removes those lines from BOTH sides before comparing. Leaving them in is what
  made the first version miss every repository on this host.

- `implement-prd-prompt.1.7.17.md` — the PRD implement prompt as 1.7.17 shipped
  it: the sub-issue's spec is pulled in and nothing says what to do with the
  result once the work is done. The 1.7.18 step does not compare against this —
  it INSERTS a paragraph after a line the prompt still contains, and the smoke
  fixture builds the pre-migration shape by removing what 1.7.18 adds from the
  current scaffold. Kept anyway as the before-picture: an anchor that drifts is
  easier to see next to the text it used to be, and the step's "already present"
  path keys on `Source ticket:`, so this file is what a project at 1.7.17 has.

- `implement.node.1.7.17.md` — the local-run implement prompt as 1.7.17 shipped
  it. The 1.7.18 write-back paragraph is appended after the document's closing
  line, which is where `templates/implement.*.md` now carry it too, so a fresh
  bootstrap and an upgrade produce the same file for the same rule. Rendered
  prompts are project-owned after bootstrap (a project may reword them), which is
  why the step anchors on the closing line and inserts a fixed paragraph rather
  than copying a template over the result.

## 1.7.23 — the prompts that carry the loop, and the standards file

- `implement-prompt.1.7.22.md`, `implement-prompt-actions.1.7.22.md`,
  `implement-prd-prompt.1.7.22.md` — the three live prompts as 1.7.22 shipped
  them, taken from the 1.7.22 commit and not from HEAD. Each still carries the
  `Use red-green-refactor … 1. RED / 2. GREEN / 3. REPEAT / 4. REFACTOR` list,
  which is what the 1.7.23 step replaces. They exist as the before-picture and as
  the fixture source: the smoke test builds the pre-migration state from these
  files rather than by stripping text out of the current scaffold, because a
  fixture derived from the wrong side tests an insert that never happens (the
  mistake ADR 0003 records).

  The step does NOT `cmp` against these. After four rollouts no consumer's live
  prompts are byte-identical to any snapshot — measured 9-25 differing lines each,
  from the hand-applied language substitution and from hand-written
  project-specific verification paragraphs — so a `cmp` guard would refuse in
  every repository and the step would silently no-op everywhere. The snapshots are
  the fixture and the historical record; the migration edits anchors.

- `CODING_STANDARDS.md.1.7.22` — the coding standards as 1.7.22 shipped them,
  from `templates/`. This file HAS been measured byte-clean in all four consumer
  repositories, so it is the one artefact the step restages with a `cmp` guard
  rather than editing in place.

- `prompt.node.1.7.22.md`, `prompt.python.1.7.22.md` — the two PRD prompt
  templates as 1.7.22 shipped them. Kept for the same before-picture reason: the
  templates themselves are edited in place (the bootstrap copies them verbatim and
  no step reads `$S/templates/`), so these are what a project bootstrapped before
  1.7.23 received.

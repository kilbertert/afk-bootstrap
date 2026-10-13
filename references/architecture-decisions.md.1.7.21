# Architecture decisions

`docs/adr/` holds the decisions this repository has already settled: what was
chosen, what was rejected, and why. It is the only place a reader can learn
*why* the system is built the way it is — code answers "what runs", and tests
answer "what holds", and neither answers "what did we try first and abandon".

Written for a reader who arrives cold, months later, with the code in front of
them and none of this change's context.

## When a record is owed

A change owes a record when it moves something a later reader could reasonably
re-litigate. Any of these counts:

- **Behavior** — a user- or client-visible outcome changes.
- **Architecture** — module boundaries, package topology, who owns what.
- **A cross-file contract** — a wire format, an API shape, an on-disk schema, an
  event vocabulary, an auth boundary.
- **Process and tooling** — checks, release, delivery, how work is coordinated.
- **Test strategy** — what is verified how, and what is deliberately not.
- **A persisted, network, or configuration format.**

Most changes owe nothing. These do not:

- formatting, typos, unambiguous renames
- styling that changes no behavior
- a dependency patch that changes no behavior, a version tag
- ordinary CRUD, a fix whose diff explains itself within one module

The test that decides a close call: **could a careful reader reconstruct this
decision from the code and its tests alone?** If yes, they do not need the
record. If no — and especially if the change *narrows* something, or gives up an
approach other people would reach for — they do.

## What a record must carry

A record that can be read cold has three things. `node .sandcastle/adr.check.mjs`
enforces the shape; the first two are the ones it checks, the third is the one
that makes the other two worth anything.

1. **A status a reader can branch on.** `Status: Accepted` and
   `Status: Superseded by 0003` are different instructions to a reader. Without
   it, a record describing an intended shape reads exactly like one describing
   the shipped shape — and this repository has both.

2. **An alternatives section** (`## Alternatives considered`,
   `## Alternatives Considered`, `## 被否掉的替代形态` — any spelling already in
   use). Name the options that lost. A record with no alternatives answers a
   question nobody asked, and the next agent re-proposes the path that was
   already ruled out.

   Write the rejected option's **strongest** case first, then why it lost. An
   alternative described only by its weakness is a strawman, and a strawman is
   how a reader concludes the decision was never really weighed.

3. **Consequences, both kinds.** What became easier, and what became harder or
   is now capped. A record with only benefits is a record with the cost edited
   out, and the cost is the part the next reader needs.

Do not invent alternatives that were never considered. "We did not consider
anything else" is a legitimate thing to write; a fabricated option is not.

## Before writing: search what is already there

**This is the step that decides whether the rest is worth anything.** A record
nobody finds is a record nobody follows, and the whole point is that the next
agent — or the next you — sees the earlier decision *before* re-proposing a path
that was already ruled out.

Search before you write, and search before you act. Four ways, cheapest first:

1. **An anchor in the code.** If the entry point already carries a line like
   `// Note: … 见 docs/adr/…`, follow it. Do not add anchors for their own sake;
   they are a convenience, not a requirement.
2. **Read the tree by intent.** Do not read everything. Decided shape lives in
   `docs/adr/`; open the two or three records whose titles touch your area.
3. **Search by mechanism name.** The word a reader would use — a module, an
   event, a config key — not the word from this conversation:

   ```sh
   rg -i "<机制名或关键词>" docs/adr/
   ```

4. **Follow the links.** Records link to each other with relative markdown
   links; a record that looks adjacent usually points at the one that matters.

**Facts are yours to find, decisions are not.** Anything the code, the records
or a search can answer, answer yourself — do not spend a human's time on it.
Ask only about a real choice, and when you do, put every open question in one
message with your recommendation attached to each.

## Writing one

Records live at `docs/adr/NNNN-slug.md`, numbered in order. Take the next free
number — do not reuse one, and do not renumber. Write it in the **same change**
as the code it describes, so the two cannot drift.

**Prefer updating over adding.** Across the repositories this convention comes
from, the bulk of record changes are in-place corrections of fact — a path, a
symbol name, a default — not new files. An existing record that owns the
decision is where a fact change belongs.

A record still being written starts with `Draft` or `提案` in its title. Drafts
are exempt from the structure check, which is what lets a proposal be committed
before its alternatives are settled.

Revising an existing record:

- **A fact changed and the decision did not** — paths, symbol names, defaults,
  a status flip to `Superseded by NNNN`. Edit it in place, and **do not append a
  changelog**: the record must read as a statement about the current tree, not
  as a history of how it got there. "The session store uses SQLite", never "the
  session store no longer uses JSONL".
- **The decision itself is now the opposite** — that is a new record, linking to
  the one it replaces, which takes a `Status: Superseded by NNNN`. A record must
  never be rewritten into its own negation; the reader needs to see both.
- **A new record partly overlaps an old one** — keep both and link them, each
  way, rather than merging. Only when the new one absorbs everything the old one
  carried — its reasoning, its rejected options, the conditions that would make
  it worth revisiting — is the old one retired.
- **A record is retired** — link to it from the record that replaced it, and say
  which decisions it no longer governs. Deleting it outright is fine when
  nothing links to it and nothing in it could steer a future decision wrong; the
  test is whether a reader who never saw it could be led into a mistake.

## If no record is owed

Say so in the commit body, on its own line:

```
No-ADR: pure rename, no behavior change
```

That line is checked, because a decision not to write something and a decision
forgotten are indistinguishable in a diff — and only one of them is fine. It is
not authenticated: a line that merely *contains* `No-ADR:` counts, because
pretending otherwise would be a worse lie than the one it prevents. What it
buys is that a human reading the log sees a reason.

## Checking

```sh
node .sandcastle/adr.check.mjs                     # report; never blocks
node .sandcastle/adr.check.mjs --base origin/main  # gate: structure of touched records + coverage of this branch's commits
node .sandcastle/adr.check.mjs --all               # gate: every record in the repo
node .sandcastle/adr.check.mjs --base origin/main --all   # both
```

Two independent questions, and the flags map to them:

| | what it judges | which flag |
|---|---|---|
| **structure** | every record this change *touches* | `--base` (touched) or `--all` (all of them) |
| **coverage** | whether each of this branch's commits *owes* a record | `--base` only — the whole tree is not a diff |

Structure is scoped to touched records on purpose. Gating every record on every
change would mean a back catalogue has to be backfilled before this rule can be
adopted at all — and inventing alternatives a record never weighed is exactly
what the rule exists to prevent.

Coverage is judged **per commit**, each against its own parent. Not as one
`git diff <ref> HEAD`: that is the merge-base form, and it reports everything the
branch carries, so one tooling commit would answer for a feature commit beside
it. Each commit either carries a record, or says why it does not.

Two things the check cannot decide, left to whoever reads the diff:

- a commit that changes source *and* adds a record passes, even if the record is
  about something else;
- a commit whose body merely contains `No-ADR:` passes.

The bare form reports and exits 0 — it lists what the back catalogue would need,
which is work to schedule, not a reason to block today's pull request. Asking for
a gate and supplying nothing is a different thing and fails:

```sh
node .sandcastle/adr.check.mjs --base ""
# adr check failed: `--base` was passed with no ref … refusing to report success.
```

That is deliberate. A gate that quietly downgrades itself to a report reads as
passing exactly when it is misconfigured, which is the one moment it was needed.

### This rule owns itself

The convention above is a decision, and it is not exempt from its own rule. The
checker lives at `.sandcastle/adr.check.mjs`, its CI wiring is a workflow file,
and both are exactly the kind of change that owes a record — 1.7.12's own tooling
commit is the case that proves it: it changed the policy workflow, carried no
record, and the gate flagged it on the first honest run.

So the loop closes on itself. A change to how decisions get recorded is itself a
decision, and it lands the same way any other one does: with the record, in the
same commit, or with a `No-ADR:` line saying why not.

The first such record is the one explaining this gate and why it refuses an empty
`--base`: `*-adr-check-scope-and-self-application.md`, in `docs/adr/`. It is
referenced by name here, not by number — the serial is assigned per repository
when the record lands, so a number here would be wrong in most of them.

### The sweep

`--all` is the sweep: run it when you want the whole list. On this repository
type it usually finds records that predate this convention and are a title and a
status line with nothing under them. Those are worth a pass when someone next
touches the decision they describe; they are not worth a mechanical rewrite, and
nobody should invent alternatives a record never weighed just to turn a check
green.

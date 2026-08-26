# {{PROJECT_NAME}}

> Domain context / unified language for this project. The AFK implement and
> review prompts read this file to keep terminology and invariants consistent.
> **Edit this file to reflect the project's real domain** — the structure
> below is a safe baseline, not a substitute.

## Language

Define the project's core terms once. Each entry: the term, what it means,
and any **Avoid** terms that would introduce drift.

<!-- Example:

**Run**:
A single execution of a test workflow against a target environment, with its
own evidence, state file, and result. Identity is a path + timestamp.
_Avoid_: Test, Session (ambiguous), Job

**Case**:
One test scenario within a run, with deterministic expected outcomes and an
evidence contract.
_Avoid_: Test case, Scenario (when interchangeable)

-->

## Invariants & boundaries

State the rules that must never be broken by an implementation, and the
boundaries between layers/modules that must stay isolated.

<!-- Example:
- Fail-closed: any unverifiable outcome is a failure, not a pass.
- The public state file shape is a contract; changing it requires updating
  every reader + its tests.
-->

## Decisions

Record significant architecture/design decisions (or point to the ADR files
under `docs/adr/`). This is the "why" behind the current shape, so an agent
does not re-derive or undo them.

<!-- Example:
- We use X over Y because Z (see docs/adr/0003-x-vs-y.md).
-->

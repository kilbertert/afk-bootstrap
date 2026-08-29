# {{PROJECT_NAME}}

> Domain glossary / unified language for this project. Keep this file limited
> to terms and avoided synonyms. Requirements belong in specs/issues; durable
> implementation decisions belong in `docs/adr/`.

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

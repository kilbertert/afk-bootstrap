# QA Plan

## Scope

Verify that `afk-bootstrap` is the sole source of its scaffold payload and no
longer needs an Auto-Test checkout. This also verifies the portable governance
checker, SemVer metadata, bounded exceptions, and the host/container token
boundary.

## Cases

| ID | Environment | Preconditions | Test data | Actions | Expected observable result | Cleanup |
|---|---|---|---|---|---|---|
| AFK-B01 | Linux host, temporary Git repo | Node and npm available | Fake Node GitHub origin | Run `test/smoke.sh node` | Command exits 0 and reports a complete Node scaffold with template metadata and PR-gated planner delivery | Test trap removes temporary repo |
| AFK-B02 | Linux host, temporary Git repo | Node and npm available | Fake Python GitHub origin | Run `test/smoke.sh python` | Command exits 0 and every agent prompt uses the uv verification gate | Test trap removes temporary repo |
| AFK-B03 | Repository checkout with no Auto-Test path | Scaffold payload exists in this checkout | Temporarily hide or override external project paths | Run both smoke cases | Both cases pass without reading another repository | Test trap restores no external state because none is changed |
| AFK-B04 | GitHub Actions syntax job | Python 3 and PyYAML available | Workflow files from this checkout | Run `python3 test/workflows.py`, then inspect CI commands | Validator rejects duplicate keys, incomplete steps, unsafe fork execution, and force-push commands; CI invokes both smoke cases | None |
| AFK-B05 | Linux host, temporary Git repo | Generated metadata and checker | Compatible and incompatible versions; valid and non-exceptionable exceptions | Run the checker through both smoke cases | SemVer mismatch, default-branch use, malformed/expired exceptions, and non-exceptionable exceptions fail closed; valid exception passes | Test trap removes temporary repo |
| AFK-B06 | Docker build plus host workflow | Docker and migrated consumer checkouts | Host delivery tokens and read-only `AFK_AGENT_READ_TOKEN` | Build all four consumer images and inspect profile/workflow env | Images build; only the explicit read token can become container `GH_TOKEN`, while host tokens remain host-side | Local images retained for reuse |
| AFK-B07 | Linux host, temporary Git repo | Node and npm available | Generated Codex entry and planner output | Run `test/smoke.sh node`; inspect the generated entry and planner selection check | The generated entry stops after `GRILLING_COMPLETE` until an explicit next-phase invocation, and planner output drops issues without `ready-for-agent` | Test trap removes temporary repo |

## Traceability

| Requirement | Feature scenario | QA cases |
|---|---|---|
| Self-contained Node scaffold | Scaffold a Node project without an Auto-Test checkout | AFK-B01, AFK-B03 |
| Self-contained Python scaffold | Scaffold a Python project without an Auto-Test checkout | AFK-B02, AFK-B03 |
| Planner delivery uses a task PR | Scaffold a Node project without an Auto-Test checkout | AFK-B01 |
| Drift is detected in CI | Continuous integration validates both language adapters | AFK-B04 |
| Workflow payload is structurally valid and policy-safe | Continuous integration validates both language adapters | AFK-B04 |
| Portable policy and token boundaries | An incompatible AFK template is blocked; a container cannot deliver directly to the default branch | AFK-B05, AFK-B06 |
| Planning phase cannot silently enter implementation | Generated Codex entry preserves the grilling phase boundary | AFK-B07 |

## Risk Checks

- Complexity/coverage: not applicable; the change is shell orchestration with
  observable smoke coverage at its public interface.
- Mutation testing: not applicable; no authorization, money, persistence, or
  core business-rule implementation changes.

## Execution Results

Status: passed on `2026-08-28T23:25:32+0800`.

- Build identity: `afk-bootstrap` `origin/main` at
  `3ae3f3067479aebdf1d298e85efd24320086aef2` (PR #20). Repository CI runs
  [33182230044](https://github.com/kilbertert/afk-bootstrap/actions/runs/33182230044)
  and [33182286287](https://github.com/kilbertert/afk-bootstrap/actions/runs/33182286287)
  passed.
- Environment: Linux 5.15 x86_64, Node 24.15.0, npm 11.12.1, Python 3.13.13,
  PyYAML 6.0.3, Go 1.25.1, TypeScript 7.0.2 for the supplemental strict check.
- AFK-B01: passed, `test/smoke.sh node`.
- AFK-B02: passed, `test/smoke.sh python`.
- AFK-B03: passed; both tests copied only this checkout's `scaffold/` payload,
  and static scanning found no executable Auto-Test path or `--baseline` use.
- AFK-B04: passed, `python3 test/workflows.py`; 9 workflows validated.
- AFK-B05: passed; both smoke cases exercised SemVer metadata, task-branch
  rejection, valid `runner-isolation` exception, and rejection of a protected
  invariant exception.
- AFK-B06: passed; Node and Python images built as
  `sandcastle:auto-test-governance`, `sandcastle:health-flow-governance`,
  `sandcastle:genesis-evidence-governance`, and `sandcastle:ai-ops-governance`.
- ShellCheck 0.11.0 is installed at `/home/claude/.local/bin` (official
  release checksum verified) and passed for `bootstrap-afk.sh` and
  `test/smoke.sh`.
- `actionlint` 1.7.12 passed for the repository and scaffold workflows with
  ShellCheck enabled.
- Supplemental strict TypeScript compilation passed for every generated
  `.sandcastle/**/*.ts` file in a temporary Node scaffold.
- `bash -n bootstrap-afk.sh test/smoke.sh` and `git diff --check` passed.
- AFK-B07: passed on `2026-08-29T18:18:09+08:00`, build identity
  `fix/grill-phase-gate` at `6ae8ddd`; the generated phase gate and
  host-side `ready-for-agent` planner filter were verified by
  `test/smoke.sh node`.
- Credential-pattern and direct-default-branch/force-push scans returned no
  matches. New files are mode 640 and directories are mode 750.
- Source accounting: 37 of 49 scaffold files remain byte-identical to the
  validated Auto-Test source at `ee411e77d7bfc379d5f8eef20e0279c07a70af28`;
  the 12 adaptations were manually reviewed. Source PR #142 is merged and its
  Verify and Windows Verify checks passed.
- OpenCodeReview delegation coverage: 61 total files, 33 reviewable and 28
  excluded by extension; every file was reviewed or explicitly accounted for
  through byte equivalence and manual diff review (100% coverage).
- `dev-worktree audit` passed for all 3 repository worktrees.

Additional authorized delivery verification:

- Consumer migrations merged and verified on their canonical `main` branches:
  Auto-Test PR #144 (`b34ff87c9d0ed73990ca7d9bf32e15ab13d302ea`), Health-Flow
  PR #78 (`ab22b507b75f3a3ab519823b183cb0c489c62e21`), genesis-evidence PR
  #124 (`e8a03c94f4f2a334d991409b3c03cf76dd9a5cd5`), and AI-Ops PR #62
  (`09a56979946c3fc6f3a4eba48338610b9589241e`).

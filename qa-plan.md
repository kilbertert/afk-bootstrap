# QA Plan

## Scope

Verify that `afk-bootstrap` is the sole source of its scaffold payload and no
longer needs an Auto-Test checkout. This is a repository bootstrap contract;
Docker image execution and existing consumer upgrades are outside this change.

## Cases

| ID | Environment | Preconditions | Test data | Actions | Expected observable result | Cleanup |
|---|---|---|---|---|---|---|
| AFK-B01 | Linux host, temporary Git repo | Node and npm available | Fake Node GitHub origin | Run `test/smoke.sh node` | Command exits 0 and reports a complete Node scaffold with template metadata and PR-gated planner delivery | Test trap removes temporary repo |
| AFK-B02 | Linux host, temporary Git repo | Node and npm available | Fake Python GitHub origin | Run `test/smoke.sh python` | Command exits 0 and every agent prompt uses the uv verification gate | Test trap removes temporary repo |
| AFK-B03 | Repository checkout with no Auto-Test path | Scaffold payload exists in this checkout | Temporarily hide or override external project paths | Run both smoke cases | Both cases pass without reading another repository | Test trap restores no external state because none is changed |
| AFK-B04 | GitHub Actions syntax job | Python 3 and PyYAML available | Workflow files from this checkout | Run `python3 test/workflows.py`, then inspect CI commands | Validator rejects duplicate keys, incomplete steps, unsafe fork execution, and force-push commands; CI invokes both smoke cases | None |

## Traceability

| Requirement | Feature scenario | QA cases |
|---|---|---|
| Self-contained Node scaffold | Scaffold a Node project without an Auto-Test checkout | AFK-B01, AFK-B03 |
| Self-contained Python scaffold | Scaffold a Python project without an Auto-Test checkout | AFK-B02, AFK-B03 |
| Planner delivery uses a task PR | Scaffold a Node project without an Auto-Test checkout | AFK-B01 |
| Drift is detected in CI | Continuous integration validates both language adapters | AFK-B04 |
| Workflow payload is structurally valid and policy-safe | Continuous integration validates both language adapters | AFK-B04 |

## Risk Checks

- Complexity/coverage: not applicable; the change is shell orchestration with
  observable smoke coverage at its public interface.
- Mutation testing: not applicable; no authorization, money, persistence, or
  core business-rule implementation changes.

## Execution Results

Status: passed on `2026-08-28T21:09:34+0800`.

- Build identity: `afk-bootstrap` `origin/main` at
  `d4aad50dce7a1df5333052c3153c095ba237dc34` (PR #17). Repository CI run
  [33173409721](https://github.com/kilbertert/afk-bootstrap/actions/runs/33173409721)
  passed.
- Environment: Linux 5.15 x86_64, Node 24.15.0, npm 11.12.1, Python 3.13.13,
  PyYAML 6.0.3, Go 1.25.1, TypeScript 7.0.2 for the supplemental strict check.
- AFK-B01: passed, `test/smoke.sh node`.
- AFK-B02: passed, `test/smoke.sh python`.
- AFK-B03: passed; both tests copied only this checkout's `scaffold/` payload,
  and static scanning found no executable Auto-Test path or `--baseline` use.
- AFK-B04: passed, `python3 test/workflows.py`; 9 workflows validated.
- ShellCheck 0.11.0 is installed at `/home/claude/.local/bin` (official
  release checksum verified) and passed for `bootstrap-afk.sh` and
  `test/smoke.sh`.
- `actionlint` 1.7.12 passed for the repository and scaffold workflows with
  ShellCheck enabled.
- Supplemental strict TypeScript compilation passed for every generated
  `.sandcastle/**/*.ts` file in a temporary Node scaffold.
- `bash -n bootstrap-afk.sh test/smoke.sh` and `git diff --check` passed.
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

Additional authorized delivery verification, outside the acceptance scope
above:

- Local Docker images built successfully: `sandcastle:auto-test`,
  `sandcastle:health-flow`, `sandcastle:genesis-evidence`, and
  `sandcastle:ai-ops`.
- Consumer migrations merged and verified on their canonical `main` branches:
  Auto-Test PR #143 (`ede9654cf6de62670b04d85e2dc620bff9156ae7`), health-flow
  PR #76 (`d529affef56ccd3a266f76722b1f6d8f73df28a8`), genesis-evidence PR
  #119 (`cb0b35e98f51b68278cb0dab895c7697905ed242`), and AI-Ops PR #61
  (`2013c423b262a59c9beeed39c9e07da33d95745c`).

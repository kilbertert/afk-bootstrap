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

Status: passed locally on `2026-08-28T20:07:26+08:00`.

- Build identity: branch `refactor/self-contained-baseline`, base and current
  HEAD `3d133e7cec248b1a88374b2f8b0395946794a8d7`. The result is an uncommitted
  working tree because this task did not authorize commit, push, or PR creation.
- Environment: Linux 5.15 x86_64, Node 24.15.0, npm 11.12.1, Python 3.13.13,
  PyYAML 6.0.3, Go 1.25.1, TypeScript 7.0.2 for the supplemental strict check.
- AFK-B01: passed, `test/smoke.sh node`.
- AFK-B02: passed, `test/smoke.sh python`.
- AFK-B03: passed; both tests copied only this checkout's `scaffold/` payload,
  and static scanning found no executable Auto-Test path or `--baseline` use.
- AFK-B04: passed, `python3 test/workflows.py`; 9 workflows validated.
- ShellCheck 0.11.0 was installed to `/home/claude/.local/bin` (official
  release checksum verified) and passed for `bootstrap-afk.sh` and
  `test/smoke.sh`.
- `actionlint` 1.7.7 passed for the repository and scaffold workflows with
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

Not run: local Shellcheck (not installed), Docker image build, remote CI, and
consumer-repository upgrades. Docker and consumer changes are outside this
change; remote CI awaits an authorized commit/push/PR delivery step.

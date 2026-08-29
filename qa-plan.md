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
| AFK-B07 | Linux host, temporary Git repo | Node and npm available | Generated Claude Code/Codex entries, pre-existing instruction files, and planner output | Run both smoke cases; inspect generated entries and planner selection check | Both harnesses stop after `GRILLING_COMPLETE` until an explicit next-phase invocation, existing instruction files remain intact, and planner output drops issues without an eligible leaf shape | Test trap removes temporary repo |
| AFK-B08 | Linux host, generated Node scaffold | Node, npm, TypeScript available | Review axis prompt, orchestration, and provider profile | Compile generated `.sandcastle/**/*.ts` with TypeScript bundler resolution and inspect review workflow | Standards and Spec passes are parallel, provider-neutral, and feed a separate fixer; no container-installed project-local review skill is required | Temporary scaffold is disposable |
| AFK-B09 | Linux host, generated Node/Python scaffolds | Node, Python, PyYAML, actionlint, ShellCheck available | Deleted splitter payload and native planning docs | Run smoke, workflow validator, actionlint, and repository scans | No splitter workflow/script/skill is generated; official `/to-spec` and `/to-tickets` remain the only interactive planning entry | Test traps remove temporary repos |
| AFK-B10 | Linux host, temporary Git repositories | Git available | Stale local main, advanced origin main, and a PR branch with a merge result | Run `test/trusted-pr-delivery.sh` | Candidate preparation resets local main to the trusted base; bundle delivery preserves commits and rejects a raced remote branch | Test trap removes temporary repositories |
| AFK-B11 | GitHub Actions syntax job | Python 3 and PyYAML available | The three `pull_request_target` workflows and delivery-label workflows | Run `python3 test/workflows.py` | Mutation jobs require same-repository owner PRs, execute controller scripts, avoid runtime skill installation, keep write tokens out of candidate execution, reject masked GitHub API failures, and fail closed without AGENT_PAT | None |
| AFK-B12 | Live self-hosted runner canary | Merged template deployment, online runner, configured read token and AGENT_PAT | One owner-authored canary PR | Run `agent:review`, retain the workflow URL, and inspect the resulting branch/review | The review uses current main, completes through trusted bundle delivery, posts its review, and leaves no blocked label | Close or merge the disposable canary PR and remove temporary labels/branches |

## Traceability

| Requirement | Feature scenario | QA cases |
|---|---|---|
| Self-contained Node scaffold | Scaffold a Node project without an Auto-Test checkout | AFK-B01, AFK-B03 |
| Self-contained Python scaffold | Scaffold a Python project without an Auto-Test checkout | AFK-B02, AFK-B03 |
| Planner delivery uses a task PR | Scaffold a Node project without an Auto-Test checkout | AFK-B01 |
| Drift is detected in CI | Continuous integration validates both language adapters | AFK-B04 |
| Workflow payload is structurally valid and policy-safe | Continuous integration validates both language adapters | AFK-B04 |
| Portable policy and token boundaries | An incompatible AFK template is blocked; a container cannot deliver directly to the default branch | AFK-B05, AFK-B06 |
| Planning phase cannot silently enter implementation | Generated agent entries preserve the grilling phase boundary | AFK-B07 |
| Official skills are the only planning entry | Official planning skills remain the only interactive planning entry | AFK-B08, AFK-B09 |
| Provider-neutral two-axis review | Review is provider-neutral and preserves two axes | AFK-B08 |
| Current default-branch review base | Persistent runner review uses the current default branch | AFK-B10, AFK-B12 |
| Trusted pull-request control plane | Candidate code cannot receive host delivery credentials; untrusted pull requests cannot start mutation workflows | AFK-B10, AFK-B11, AFK-B12 |
| Delivery credential failures are blocked | Missing delivery credentials stop the workflow | AFK-B11, AFK-B12 |

## Risk Checks

- Complexity/coverage: no compatible complexity tool applies to GitHub Actions
  YAML and the small shell state machine; focused branch coverage is provided by
  AFK-B10 and AFK-B11.
- Mutation testing: no practical mutator is configured for workflow YAML or
  shell delivery guards. AFK-B10 exercises stale-base, merge-preservation, and
  race rejection; AFK-B12 verifies the credential boundary on the live runner.

## Execution Results

Status: passed on `2026-08-30T06:25:00+08:00`.

- Current build identity: `afk-bootstrap` `origin/main` at
  `5391c76d9b6b950dd41fea175c2153c188cb88de` (PR #28). The four consumer
  repositories were updated through focused PRs and their required checks
  passed; the four local sandbox images were rebuilt from those canonical
  checkouts.

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
- `bash -n bootstrap-afk.sh test/smoke.sh test/trusted-pr-delivery.sh` and
  `git diff --check` passed.
- AFK-B07: passed on `2026-08-29T20:12:04+08:00`, build identity
  `fix/grill-phase-gate` at `a539c11`; both smoke cases verified the Claude
  Code and Codex phase gates, preservation of existing Claude instructions,
  and the host-side `ready-for-agent` planner filter.
- AFK-B08/B09: passed on `2026-08-29`, build identity `fix/grill-phase-gate`
  after the native-planning and harness-neutral review changes. Node/Python
  smoke, TypeScript bundler compilation, actionlint, ShellCheck, workflow
  validation, and generated-payload scans passed; no automatic splitter or
  project-local planning/review skill is emitted.
- Credential-pattern and direct-default-branch/force-push scans returned no
  matches. New files are mode 640 and directories are mode 750.
- Source accounting: 37 of 49 scaffold files remain byte-identical to the
  validated Auto-Test source at `ee411e77d7bfc379d5f8eef20e0279c07a70af28`;
  the 12 adaptations were manually reviewed. Source PR #142 is merged and its
  Verify and Windows Verify checks passed.
- OpenCodeReview delegation coverage: 61 total files, 33 reviewable and 28
  excluded by extension; every file was reviewed or explicitly accounted for
  through byte equivalence and manual diff review (100% coverage).
- Cross-harness gate review: 7 changed files, 2 selected by OpenCodeReview and
  5 excluded by extension then manually reviewed (100% accounted for, no
  findings).
- `dev-worktree audit` passed for all 3 repository worktrees.

AFK-B10: passed on `2026-08-30T03:31:15+08:00`, build identity
`84e9537c661f676f68951eb3e7480472b91ff728` on Linux 5.15 x86_64, Node
v24.15.0, Python 3.13.13, actionlint 1.7.12 and ShellCheck 0.11.0. Evidence:
`python3 test/workflows.py`, actionlint, `bash -n`, ShellCheck and
`git diff --check` all passed; negative smoke cases reject a missing owner gate
and a GITHUB_TOKEN final push.

AFK-B11: passed at the same build identity and environment. Evidence:
`bash test/trusted-pr-delivery.sh` passed stale-main reset, merge-result bundle
preservation, successful push, and remote-race rejection; both Node and Python
smoke tests passed, including generated policy checks.

AFK-B12: passed on `2026-08-30T06:13:07+08:00` during the authorized Auto-Test
canary (PR #156, issue #157; workflow run
[33277541353](https://github.com/kilbertert/Auto_Test/actions/runs/33277541353)).
The owner-authored PR completed both parallel Standards and Spec passes, posted
the `COMMENTED` review at head `34bc36681201f300febb42ff15a67f2381d7a464`,
verified candidate policy, captured the trusted bundle (no candidate commits
were needed), and finished without `agent:blocked`. The disposable PR and issue
were closed and the canary branch was deleted after retaining the workflow and
review evidence. An earlier invalid canary without a linked issue failed before
the controller; this run confirms the linked-issue path end to end. PR #28 then
fixed the no-linked-issue prompt path, which the follow-up canary below verifies.

A follow-up no-linked-issue canary also passed on `2026-08-30T06:47:48+08:00`
(Auto-Test PR #159; workflow run
[33279142516](https://github.com/kilbertert/Auto_Test/actions/runs/33279142516)).
Both axes completed with no findings, the review was posted at head
`6f46d41ea13bf1def7954e63df4d267b8359585c`, and policy/bundle checks passed
without `agent:blocked`; the disposable PR and branch were then removed.

The private-GitHub transport path was also exercised on `2026-08-30` against
`kilbertert/genesis-evidence`: `trusted-pr-delivery.sh push` authenticated its
`ls-remote` check with the documented `x-access-token` Basic header and advanced
the disposable branch from `2f3ecb97f15687bb7235c822f70a46ced7ff8d85` to
`86c2b9d2477bde03dc2e5bd7438e843ed758c845`. The canary used the host GitHub
credential to verify the real private-repository protocol path; it does not
claim a separate least-privilege audit of the write-only repository secret.
The branch was deleted after verification.

Additional authorized delivery verification:

- Consumer migrations merged and verified on their canonical `main` branches:
  Auto-Test PR #144 (`b34ff87c9d0ed73990ca7d9bf32e15ab13d302ea`), Health-Flow
  PR #78 (`ab22b507b75f3a3ab519823b183cb0c489c62e21`), genesis-evidence PR
  #124 (`e8a03c94f4f2a334d991409b3c03cf76dd9a5cd5`), and AI-Ops PR #62
  (`09a56979946c3fc6f3a4eba48338610b9589241e`).

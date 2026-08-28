# AGENTS.md — afk-bootstrap

Scaffold the AFK development workflow (idea → PRD → sub-issues → AFK/Sandcastle
→ draft PR → QA feedback) into a target project. This is a *tool repo*, not a
runtime: `bootstrap-afk.sh` writes files into another repo and never commits.

## The delivery contract (read this first)

**When the user asks to "configure / set up / deliver AFK for project X", you
must deliver it end-to-end and leave ZERO manual steps.** Follow
[`docs/DELIVERY-PLAYBOOK.md`](docs/DELIVERY-PLAYBOOK.md): scaffold → branch →
PR → CI → merge → build image → set `AFK_PROFILE` + labels + `AGENT_PAT` +
workflow permissions → register the self-hosted runner → live-validate the
implement chain → clean up. The host runner owns delivery; the "Next steps"
the tool prints are your to-do list, not the user's.

## When to use

- A project should run AFK agents but has no `.sandcastle/` (check first —
  the script refuses if it already exists).
- Extending the workflow to a new language/toolchain.
- Delivering an already-scaffolded project (verify + finish the delivery:
  image, config, runner, live validation).

## Invocation

```bash
./bootstrap-afk.sh <target-repo> [--language node|python] [--repo owner/name]
                   [--no-build]
```

- `--language` drives the 4 generated files: `implement.md`,
  `implement-prd/prompt.md`, `Dockerfile`, `package.json`.
- `--repo` is written into `.claude/skills/to-prd-project/SKILL.md`
  (repo slug replace); derive from `git remote get-url origin` if omitted.
- `--no-build` skips `docker build` (use while reviewing the diff).

## Mechanics

1. Validates target is a git repo, not already scaffolded.
2. Copies the versioned **portable** payload from this repository's
   `scaffold/` directory:
   - `.sandcastle/`: `main.ts`, `profile.ts`, `run-with-retry.ts`,
     `retry-feedback.ts`, `to-issues-prd/`, `implement-prd/`, `write-prd-pr/`,
     `.env.example`, `.gitignore`
   - `.claude/skills/`: `to-prd-project`, `to-issues-project`
   - `.github/workflows/`: `agent-to-issues-prd.yml`, `agent-implement-prd.yml`
3. Generates per-language files from `templates/` and renders the target image
   and GitHub repository placeholders.
4. Writes `.afk-bootstrap.json` with the template version, language, and
   repository.
5. Appends `node_modules/` to the target `.gitignore` if missing.
6. Merges `afk` + `prd:to-issues` scripts and `tsx` + `@ai-hero/sandcastle`
   deps into the target `package.json`; creates a minimal one + `npm install
   --package-lock-only` when the target has no manifest.
7. Builds `sandcastle:<dir-slug>` from the generated Dockerfile (unless
   `--no-build`).
8. Prints next steps (AFK_PROFILE var, labels, runner/AGENT_PAT, local cmd).

It does **not** commit, push, or touch GitHub.

## After running — verify

```
ls <target>/.sandcastle/{main.ts,profile.ts,implement.md,Dockerfile}
grep '<language check cmd>' <target>/.sandcastle/implement.md
grep '<repo slug>'          <target>/.claude/skills/to-prd-project/SKILL.md
grep '"afk"'                <target>/package.json
cat                         <target>/.afk-bootstrap.json
docker images | grep sandcastle:<slug>   (unless --no-build)
```

## Language model

| language | check gate (`implement.md` / PRD prompt) | Dockerfile adds |
|---|---|---|
| `node` | `npm run check` (typecheck+test+build) | playwright deps behind a comment (enable only if the suite launches a browser) |
| `python` | `uv sync --extra dev && uv run pytest && uv run ruff check` | `python3` + `uv` (agent CLIs still come from the node 24 base) |

Both Dockerfiles: node 24 base (carries claude-code + codex 0.146.1), `gh`,
AFK_PROFILE dispatch wrapper (`claude` vs `claude-ark|agentrouter|psydo`), agent user
rename with `AGENT_UID`/`AGENT_GID` build args (= host uid/gid).

## Architecture — two execution paths (read this before comparing to the reference)

The AFK workflow has **two distinct execution paths** with different sandbox
mechanics. Do not conflate them (earlier sessions misread this and spread a
wrong "we diverged from upstream" story).

**1. Planner loop (`pnpm ralph`, `.sandcastle/planner.ts`)** — matches the
upstream `course-video-manager/.sandcastle/main.ts` mechanism exactly:
`createSandbox({ branch, sandbox: docker() })` creates a **per-issue docker
git worktree** (bind-mounted to `/home/agent/workspace`), and the worktree is
removed on `sandbox.close()` (upstream uses `await using` auto-release; ours
calls `close()` explicitly — equivalent). Branch/worktree cleanup is owned by
the **sandcastle library**, not app code. `.sandcastle/worktrees/` is gitignored.

**2. Label-Action implement/review (`agent-implement.yml` + `implement.ts`,
`review.ts`)** — runs on a **self-hosted GitHub runner's persistent workspace**:
`git checkout -b "$BRANCH"` on the runner workdir, then a `docker()` sandbox
(for profile/env injection). This is **NOT a per-issue docker worktree**. Note:
the upstream reference's label-Action path uses `noSandbox()` (agent runs
directly on the runner, no container) — ours uses `docker()` instead, which is
a deliberate enhancement for container isolation + profile injection, not a
mis-replication.

**Runner persistency — the real difference is hosted vs self-hosted, not the
workflow design.** `actions/checkout` on a hosted (`ubuntu-latest`) runner
starts from a **fresh** workspace each run; a **self-hosted** runner reuses the
same `_work/` directory, so `agent/*` local branches and workspace state
**persist between runs** and can accumulate. Upstream has the same property on
a self-hosted runner — leftover `agent/*` branches are inherent to the
label-Action path, not a unique defect.

Net: **the planner uses docker worktrees for each issue, then integrates the
completed branches into one delivery branch and opens a PR. The label-Action
path runs in a persistent runner workspace with a docker container for
isolation.** Neither path pushes the default branch directly.

## Gotchas

- **Git guard**: do not commit on `main` — use an isolated task worktree and
  the repository's branch → PR → CI → merge workflow.
- **pnpm 11 build-script gate**: pnpm ≥10 fails `pnpm install` on unreviewed
  build scripts (`strictDepBuilds`); the AFK runner auto-runs `pnpm install`,
  so esbuild's postinstall must be allowed or every `pnpm afk` dies first.
  The scaffold writes `pnpm-workspace.yaml` with `allowBuilds: esbuild: true`
  (do NOT set it to `false`). When editing the script, keep that step.
- **Delivery**: the script commits nothing; the host runner owns
  branch → PR → CI → merge.
- **Actions are inert without a self-hosted runner** (repo-scoped for personal
  accounts) and the `AGENT_PAT` secret for sub-issue chaining. Until then,
  drive locally: `AFK_PROFILE=<profile> pnpm afk -- <issue>`.
- **The sandbox image must match the project toolchain** — a mismatch is the
  exact cause of a false `<promise>BLOCKED</promise>` (agent can't self-verify
  in the container). Keep the generated Dockerfile in sync with the project.
- **Issue number**: the AFK target must be an *open issue*, not a PR (they
  share GitHub's number space).
- **Model providers are server-global** (`claude`, `claude-ark`, `agentrouter`, `psydo`,
  `aliyun-deepseek`); a new project adds zero new credentials. Pick one per
  repo via the `AFK_PROFILE` Actions variable.
- **Slow/hung providers are guarded**: the scaffold ships codex
  `request_timeout`/`request_max_retries` (env `AFK_REQUEST_TIMEOUT`,
  `AFK_REQUEST_RETRIES`) and a planner `withTimeout` wall-clock
  (`AFK_RUN_TIMEOUT`, `AFK_MERGE_TIMEOUT`, seconds; 0 = no cap). A stalled
  agent aborts as BLOCKED instead of hanging the loop.

## Files

```
bootstrap-afk.sh          the tool
scaffold/                 portable runners, skills, prompts, and workflows
templates/                per-language generated files (node | python)
  - AGENTS.override.md    Codex entry doc (auto-copied to project root)
  - codex-config.toml.snippet  notes + the `codebase-memory-mcp install -y`
                            command (the server has a built-in installer
                            that auto-detects Codex CLI; the snippet just
                            documents the path, no hand-written block)
TEMPLATE_VERSION          generated-project template version
test/smoke.sh             Node/Python interface smoke test
acceptance.feature        observable bootstrap acceptance contract
qa-plan.md                system verification plan and retained results
README.md                 human-readable guide
AGENTS.md                 this file
docs/DELIVERY-PLAYBOOK.md  end-to-end delivery + gotchas (read before configuring a project)
```

Beyond the single-issue runner, the scaffold now also ships the **planner loop**
(`planner.ts` + `plan/implement/review/merge-prompt.md`, entry `pnpm ralph`) and
the **label-driven Actions** (`implement/`, `write-pr/`, `review/`,
`implement-pr/`, `update-branch/`, `architecture-review/` + their workflows).
For a python project the tool rewrites `npm run check` → uv in every copied
prompt. The planner's merge agent only integrates and verifies locally; the
host then pushes one delivery branch and opens a PR. CI and the hosting service
remain the merge boundary.
```

## Extending

To add a language (e.g. `go`): add `templates/implement.go.md`,
`templates/prompt.go.md`, `templates/Dockerfile.go`, a case in the script's
`--language` guard, and a smoke assertion. Keep the "4 generated files per
language" invariant.

# AGENTS.md — afk-bootstrap

Scaffold the AFK development workflow (idea → grill → spec → native tickets → AFK/Sandcastle
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
- `--repo` is recorded in generated metadata; derive from `git remote get-url
  origin` if omitted.
- `--no-build` skips `docker build` (use while reviewing the diff).

To **upgrade** a project that already has `.sandcastle/`, use `upgrade-afk.sh`
— `bootstrap-afk.sh` refuses an already-scaffolded target:

```bash
./upgrade-afk.sh <target-repo> [--dry-run]
```

It applies each step of the version range recorded in the target's
`.afk-bootstrap.json`, then writes the new version back. It is **anchored, not
a template re-render**: a scaffolded Dockerfile is project-owned (the README
tells projects to enable the Playwright block by uncommenting it), so each step
matches only the exact lines the previous template generated, and a step whose
anchor does not match exits non-zero rather than guessing. Project prose is
reported, never edited. It refuses a major-version jump.

All writes are staged and published only after the last step succeeds, so a
refused migration leaves every file byte-identical. Without that, a step that
failed after an earlier step wrote would strand a migrated Dockerfile under
metadata still claiming the old version.

**Order matters after an upgrade**: rebuild the sandbox image from the new
Dockerfile *before* changing `AFK_PROFILE`. Pointing the variable at a profile
the running image does not dispatch on makes the wrapper exit 2.

## Mechanics

1. Validates target is a git repo, not already scaffolded.
2. Copies the versioned **portable** payload from this repository's
   `scaffold/` directory:
   - `.sandcastle/`: `main.ts`, `profile.ts`, `run-with-retry.ts`,
     `retry-feedback.ts`, `implement-prd/`, `write-prd-pr/`,
     `.env.example`, `.gitignore`
   - `.github/workflows/`: `agent-implement-prd.yml`, `agent-implement.yml`,
     review and branch workflows
   - `docs/agents/`: official tracker, triage-label, and domain pointers
3. Generates files from `templates/`, appending a managed phase gate to
   `AGENTS.md` (or an existing `AGENTS.override.md`) and `CLAUDE.md` without
   masking project instructions.
4. Writes `.afk-bootstrap.json` with the template version, language, and
   repository.
5. Appends `node_modules/` to the target `.gitignore` if missing.
6. Merges `afk` + `ralph` scripts and `tsx` + `@ai-hero/sandcastle`
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
AFK_PROFILE dispatch wrapper (`claude` vs `claude-stepfun`), agent user
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

**2. Label-Action PR implement/review (`agent-implement-pr.yml`,
`agent-review.yml`, and `agent-update-branch.yml`)** — runs on a self-hosted GitHub runner with three explicit
checkouts: current-`main` `controller/`, Docker-mounted `candidate/`, and clean
`delivery/`. Host dependencies and `.sandcastle` controllers come from
`controller/`; candidate commits cross through a verified Git bundle before a
short-lived write token pushes them. This is **NOT a per-issue docker
worktree**. The upstream reference's label-Action path uses `noSandbox()`;
ours uses `docker()` for candidate isolation and profile injection.

**Runner persistency — the real difference is hosted vs self-hosted.** A
self-hosted runner reuses `_work/`, so every PR mutation path must use the
controller/candidate/delivery directories, reset candidate `main` to the
controller SHA, and validate the recorded PR head again before delivery. Do
not replace this with a single mutable checkout.

The issue executors (`agent-implement.yml` and `agent-implement-prd.yml`) run
trusted controller code from the freshly checked-out default branch, push a
task branch with `AGENT_PAT`, and hand off through a PR. They do not execute a
PR candidate checkout.

Net: **the planner uses docker worktrees for each issue, the issue executors
create task branches, and the PR mutation path uses a trusted host controller,
Docker candidate, and clean delivery checkout.** Neither path pushes the
default branch directly.

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
  accounts) and the `AGENT_PAT` secret for sub-issue chaining. The Docker agent
  receives only the separate `AFK_AGENT_READ_TOKEN` secret, which must be
  read-only and is never used for host-side labels or pushes. Until then,
  drive locally: `AFK_PROFILE=<profile> pnpm afk -- <issue>`.
- **The sandbox image must match the project toolchain** — a mismatch is the
  exact cause of a false `<promise>BLOCKED</promise>` (agent can't self-verify
  in the container). Keep the generated Dockerfile in sync with the project.
- **Issue number**: the AFK target must be an *open issue*, not a PR (they
  share GitHub's number space).
- **Model providers are server-global** (`claude`, `claude-stepfun`); a new
  project adds zero new credentials. Pick one per repo via the `AFK_PROFILE`
  Actions variable. Both mount a host settings file read-only; neither bakes a
  key into the image, because a baked key is readable from the image layer and
  rotating it needs `--no-cache`.
- **Hung providers are guarded**: the planner bounds every step with a
  wall-clock `withTimeout` (`AFK_RUN_TIMEOUT`, `AFK_MERGE_TIMEOUT`, seconds;
  0 = no cap). A stalled agent aborts as BLOCKED instead of hanging the loop.
  The per-request knobs (`AFK_REQUEST_TIMEOUT`, `AFK_REQUEST_RETRIES`) retired
  with the Codex provider, which was their only consumer.

## Files

```
bootstrap-afk.sh          the tool (create; refuses an existing .sandcastle/)
upgrade-afk.sh            migrate an already-scaffolded project to the current version
scaffold/                 portable runners, skills, prompts, and workflows
templates/                per-language generated files (node | python)
  - AFK-MANAGED-BLOCK.md  managed phase gate appended to project instructions
  - CLAUDE.md             Claude Code planning gate (created or appended)
  - codex-config.toml.snippet  notes + the `codebase-memory-mcp install -y`
                            command (the server has a built-in installer
                            that auto-detects Codex CLI; the snippet just
                            documents the path, no hand-written block)
TEMPLATE_VERSION          generated-project template SemVer
test/smoke.sh             Node/Python interface smoke test (incl. the upgrade path)
test/fixtures/legacy-1.1.x/  verbatim previous-template output the upgrade is run against
acceptance.feature        observable bootstrap acceptance contract
qa-plan.md                system verification plan and retained results
README.md                 human-readable guide
AGENTS.md                 this file
docs/DELIVERY-PLAYBOOK.md  end-to-end delivery + gotchas (read before configuring a project)
docs/GOVERNANCE-ADAPTER.md  boundary and responsibility contract with server-development-consensus
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

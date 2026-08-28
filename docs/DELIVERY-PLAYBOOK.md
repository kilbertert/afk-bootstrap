# AFK Delivery Playbook

> How an agent **fully delivers** the AFK workflow to a new project — scaffold,
> merge, image, config, runner, live-validate — leaving **zero manual steps** for
> the user. **The host runner owns delivery**: when asked to "configure project X",
> execute this end-to-end; do not print steps for the user to run.

## When to use

- User says "配置好 X 仓库" / "用 afk-bootstrap 给 X 配 AFK" / "让我直接可用".
- Target: a git repo under `~/Projects/<name>` with a GitHub origin.

## Phase 0 — Inspect

```
cd ~/Projects/<name>
git status --short --branch            # clean? on main? user untracked files?
git remote -v                          # origin repo slug
ls pyproject.toml / package.json       # language
ls .github/workflows/                  # existing CI
ls -d .sandcastle                      # already scaffolded? (tool refuses)
gh repo view <owner>/<repo> --json visibility   # public/private (drives merge rules)
```

Key: **note untracked user files** (e.g. `docs/agent-skills-setup`, pnpm files) —
never stage or delete them. If already scaffolded, verify + deliver rather than
re-scaffold.

## Phase 1 — Scaffold

```bash
./bootstrap-afk.sh ~/Projects/<name> --language node|python --repo <owner>/<repo>
```

Creates `.sandcastle/`, skills, Actions, `CONTEXT.md`, `CODING_STANDARDS.md`,
`docs/afk-workflow.md`, `.afk-bootstrap.json`, `package.json`(+lock),
`pnpm-workspace.yaml`. Verify:
`planner.ts`, `implement-prompt.md`, `ralph` script, python prompts use uv, esbuild
approved.

## Phase 2 — Deliver (branch → PR → CI → merge)

1. `git checkout -b chore/afk-bootstrap` (from `origin/main`; user untracked files
   carry over, don't commit them).
2. `git add` **only the scaffold paths**; commit.
3. `git push -u origin <branch>`; open a PR.
4. **Merge gate**: wait for required checks, BUT —
   - **Free-tier private repos have NO branch protection** → remote enforcement
     is weaker, but deterministic checks are still mandatory. Do not merge a
     failing check; fix the failure or record a blocked delivery.
   - Public/protected repos (e.g. `Auto_Test`): wait for Verify + Windows Verify;
     flaky timeouts → re-run the failed job once before merging.
5. `gh pr merge <n> --squash --delete-branch`; `git fetch --prune`; fast-forward
   local `main`; delete the task branch.

## Phase 3 — Image + config + runner

- Build the image: `docker build --build-arg AGENT_UID=$(id -u) --build-arg AGENT_GID=$(id -g) -t sandcastle:<slug> .sandcastle`
- Config (all via API/gh — do it yourself):
  - `AFK_PROFILE` repo variable (`claude-ark` / `agentrouter` / `psydo` / `aliyun-deepseek`)
  - 7 `agent:*` labels: `to-issues implement review update-branch in-progress blocked queued`
  - `AGENT_PAT` repo secret (host-side label chaining only)
  - `AFK_AGENT_READ_TOKEN` repo secret (read-only/minimum-scope token for Docker agents)
  - workflow permissions: `default_workflow_permissions=write` +
    `can_approve_pull_request_reviews=true` (else Actions can't create PRs)
- Runner: register a self-hosted runner per repo (personal accounts = repo-level).
  Copy the base runner dir, `./config.sh` with a registration token (via
  `POST /repos/.../actions/runners/registration-token` using a PAT — the gho_
  device token 404s), name `server-dev-runner-<repo>`, labels
  `self-hosted,linux,x64,<repo>`; install as a systemd user service.

## Phase 4 — Live validation

Create a small, safe, `ready-for-agent` issue → label `agent:implement` → the
self-hosted runner should implement, push a branch, write PR metadata, open a
draft PR, and request `agent:review`. Watch the run; verify a PR appears. Then
close the test issue/PR and delete the branch.

## Gotchas (all hit live — fix before the user sees them)

| # | Symptom | Fix |
|---|---|---|
| 1 | Checkout `git remote add origin .../\${GH_REPO}.git` literal → repo not found | Unescape to `${GH_REPO}` (workflow YAML `\$` got double-escaped) |
| 2 | Retry of an issue fails `git checkout -b` "already exists" | Self-hosted runner workspace persists; add `git branch --list 'agent/*' 'sandcastle/*' \| xargs -r git branch -D` to the checkout |
| 3 | `ERR_MODULE_NOT_FOUND zod` at runtime | Scaffolded package.json must include `zod` (+ update package-lock) |
| 4 | `setup-node` fails "lock file not found: pnpm-lock.yaml" | `cache: pnpm` → `cache: npm` (repos use npm) |
| 5 | `gh issue view` → "Could not resolve to an issue" | Explicit `permissions:` block zeroes unspecified scopes; add `issues: write` |
| 6 | Review prompt `!gh issue view` → "gh auth login" in container | Set the separate read-only `AFK_AGENT_READ_TOKEN`; `profile.ts` maps only `AFK_AGENT_GH_TOKEN` into the container |
| 7 | Label workflows never dispatch | Orphan `- name:` stubs (Setup pnpm / Checkout PR branch) made YAML unparseable; remove consecutive `- name:` lines |
| 8 | `pull_request_target` labeled won't fire from API label-adds | Add `workflow_dispatch` (inputs pr_number+branch) as reliable trigger; allow it through the job `if:` |
| 9 | Actions can't create PRs ("not permitted to create") | `can_approve_pull_request_reviews: true` + `default_workflow_permissions: write` |
| 10 | Artifact quota "usage recalculated 6-12h" blocks windows-verify | Clear scoped caches/artifacts, re-run once, and leave delivery blocked until the deterministic check passes |
| 11 | Selected model provider is unavailable or out of quota | Select another server-global profile, such as `agentrouter`, and rerun the bounded issue command |

## Model providers (current health, 2026-08)

- `claude-ark` → GLM/Volcengine: **CodingPlan subscription expired**.
- `agentrouter` → server-managed Claude-compatible settings; availability is credential-dependent.
- `psydo` → api.psydo.top: **429 rate-limited**.
- `aliyun-deepseek` → `deepseek-v4-pro-0813`: **usable**, but complex agent
  sessions (review's two-axis skill, planner parallel) can stall — cancel + retry.

Pick per repo via the `AFK_PROFILE` variable; the tool/scaffold is provider-agnostic.

## Delivery checklist

- [ ] Scaffold merged to `main`
- [ ] Image built
- [ ] `AFK_PROFILE` + 7 labels + `AGENT_PAT` + workflow permissions set
- [ ] Self-hosted runner online
- [ ] Live-validated implement chain (test issue → PR)
- [ ] Test artifacts cleaned up; user untracked files untouched

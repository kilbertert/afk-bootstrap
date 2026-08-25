# afk-bootstrap

Scaffold the AFK development workflow into any project:

```
想法 → grill → PRD (parent issue) → native sub-issues → AFK/Sandcastle Docker
→ draft PR → deterministic CI → human QA → QA feedback issue → background AFK fix
```

It copies the battle-tested `.sandcastle` runner, PRD tooling, skills, and
GitHub Actions from a baseline project (`Auto-Test`, itself a minimal-adaptation
port of `mattpocock/course-video-manager`), then generates the per-project,
per-language parts (`implement.md`, PRD prompt, `Dockerfile`, `package.json`).

## Usage

```bash
# Node.js project
./bootstrap-afk.sh ~/Projects/some-node-repo --language node

# Python (uv) project
./bootstrap-afk.sh ~/Projects/genesis-evidence --language python --repo kilbertert/genesis-evidence
```

Flags:

| flag | default | purpose |
|---|---|---|
| `--language` | `node` | toolchain for `implement.md` / PRD prompt / `Dockerfile` (`node` or `python`) |
| `--repo` | from `origin` | GitHub slug written into the `to-prd-project` skill |
| `--baseline` | `/home/claude/Projects/Auto-Test` | source of the copy-verbatim files |
| `--no-build` | build | skip the `docker build` of the sandbox image |

The script only creates files — it never commits or pushes. **The host runner
owns delivery**: commit the scaffold on a task branch, open a PR, merge.

## What it scaffolds

Copy-verbatim from the baseline (portable, server-local config):

- `.sandcastle/`: `main.ts`, `profile.ts`, `run-with-retry.ts`, `retry-feedback.ts`,
  `to-issues-prd/`, `implement-prd/`, `write-prd-pr/`, `.env.example`, `.gitignore`
- `.claude/skills/`: `to-prd-project`, `to-issues-project`
- `.github/workflows/`: `agent-to-issues-prd.yml`, `agent-implement-prd.yml`

Generated per language:

- `.sandcastle/implement.md` — the AFK verification gate
  (`npm run check` for node; `uv sync --extra dev && uv run pytest && uv run ruff check` for python)
- `.sandcastle/implement-prd/prompt.md` — per-sub-issue prompt with the same gate
- `.sandcastle/Dockerfile` — sandbox image (node 24 + claude-code/codex + AFK_PROFILE
  dispatch, plus python3 + uv for python projects)
- `package.json` — minimal runner manifest (`afk` + `prd:to-issues` scripts, `tsx`,
  `@ai-hero/sandcastle`); merged into an existing manifest when present, otherwise
  created + `package-lock.json` generated

Plus one string fix: the `to-prd-project` skill's repo slug.

## Model providers

Profiles are **server-global** (`claude`, `claude-ark`, `psydo`, `aliyun-deepseek`) and
read their credentials from server-local files — a new project adds no new secrets.
Pick one per repo via the `AFK_PROFILE` Actions variable:

```bash
gh variable set AFK_PROFILE --repo <owner/name> --body claude-ark   # or psydo / aliyun-deepseek
```

## Prerequisites / caveats

- The host needs: `node` + `npm`, `docker`, `gh`, and the server's AFK profiles.
- The sandbox **image must match the project's toolchain** (the template does this;
  a mismatch is exactly what causes a false `<promise>BLOCKED</promise>` — see the
  browser comment in `Dockerfile.node`).
- GitHub Actions runs on a **self-hosted runner**, which is repo-scoped for personal
  accounts. Each repo needs its own runner registration, or drive it locally with
  `AFK_PROFILE=<profile> pnpm afk -- <issue>`.
- The `agent-implement-prd.yml` chain needs an `AGENT_PAT` secret to re-label and
  chain from one sub-issue to the next; without it the chain stops after one.

## Testing

```bash
./test/smoke.sh     # scaffolds a throwaway copy and asserts the layout
```

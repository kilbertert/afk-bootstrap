# AGENTS.md — afk-bootstrap

Scaffold the AFK development workflow (idea → PRD → sub-issues → AFK/Sandcastle
→ draft PR → QA feedback) into a target project. This is a *tool repo*, not a
runtime: `bootstrap-afk.sh` writes files into another repo and never commits.

## When to use

- A project should run AFK agents but has no `.sandcastle/` (check first —
  the script refuses if it already exists).
- Extending the workflow to a new language/toolchain.

## Invocation

```bash
./bootstrap-afk.sh <target-repo> [--language node|python] [--repo owner/name]
                   [--baseline /home/claude/Projects/Auto-Test] [--no-build]
```

- `--language` drives the 4 generated files: `implement.md`,
  `implement-prd/prompt.md`, `Dockerfile`, `package.json`.
- `--repo` is written into `.claude/skills/to-prd-project/SKILL.md`
  (repo slug replace); derive from `git remote get-url origin` if omitted.
- `--no-build` skips `docker build` (use while reviewing the diff).

## Mechanics

1. Validates target is a git repo, not already scaffolded.
2. Copies **portable** files verbatim from the baseline (default
   `/home/claude/Projects/Auto-Test`):
   - `.sandcastle/`: `main.ts`, `profile.ts`, `run-with-retry.ts`,
     `retry-feedback.ts`, `to-issues-prd/`, `implement-prd/`, `write-prd-pr/`,
     `.env.example`, `.gitignore`
   - `.claude/skills/`: `to-prd-project`, `to-issues-project`
   - `.github/workflows/`: `agent-to-issues-prd.yml`, `agent-implement-prd.yml`
3. Generates per-language files from `templates/`.
4. Appends `node_modules/` to the target `.gitignore` if missing.
5. Merges `afk` + `prd:to-issues` scripts and `tsx` + `@ai-hero/sandcastle`
   deps into the target `package.json`; creates a minimal one + `npm install
   --package-lock-only` when the target has no manifest.
6. Builds `sandcastle:<dir-slug>` from the generated Dockerfile (unless
   `--no-build`).
7. Prints next steps (AFK_PROFILE var, labels, runner/AGENT_PAT, local cmd).

It does **not** commit, push, or touch GitHub.

## After running — verify

```
ls <target>/.sandcastle/{main.ts,profile.ts,implement.md,Dockerfile}
grep '<language check cmd>' <target>/.sandcastle/implement.md
grep '<repo slug>'          <target>/.claude/skills/to-prd-project/SKILL.md
grep '"afk"'                <target>/package.json
docker images | grep sandcastle:<slug>   (unless --no-build)
```

## Language model

| language | check gate (`implement.md` / PRD prompt) | Dockerfile adds |
|---|---|---|
| `node` | `npm run check` (typecheck+test+build) | playwright deps behind a comment (enable only if the suite launches a browser) |
| `python` | `uv sync --extra dev && uv run pytest && uv run ruff check` | `python3` + `uv` (agent CLIs still come from the node 24 base) |

Both Dockerfiles: node 24 base (carries claude-code + codex 0.146.1), `gh`,
AFK_PROFILE dispatch wrapper (`claude` vs `claude-ark|psydo`), agent user
rename with `AGENT_UID`/`AGENT_GID` build args (= host uid/gid).

## Gotchas

- **Git guard**: do not commit on `main` even in this tool repo — task branch
  + `git merge --ff-only` (see project CLAUDE.md). This repo has no origin.
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
- **Model providers are server-global** (`claude`, `claude-ark`, `psydo`,
  `aliyun-deepseek`); a new project adds zero new credentials. Pick one per
  repo via the `AFK_PROFILE` Actions variable.

## Files

```
bootstrap-afk.sh          the tool
templates/                per-language generated files (node | python)
test/smoke.sh             smoke test (scaffold a throwaway copy, assert layout)
README.md                 human-readable guide
AGENTS.md                 this file
```

## Extending

To add a language (e.g. `go`): add `templates/implement.go.md`,
`templates/prompt.go.md`, `templates/Dockerfile.go`, a case in the script's
`--language` guard, and a smoke assertion. Keep the "4 generated files per
language" invariant.

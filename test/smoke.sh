#!/usr/bin/env bash
# Smoke test: scaffold a throwaway fake repo (python) and assert the layout.
set -euo pipefail
S="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir "$TMP/fake-project"
git -C "$TMP/fake-project" init -q -b main
git -C "$TMP/fake-project" remote add origin https://github.com/kilbertert/fake-project.git

"$S/bootstrap-afk.sh" "$TMP/fake-project" --language python --no-build >/dev/null

for f in \
  .sandcastle/main.ts .sandcastle/profile.ts .sandcastle/planner.ts .sandcastle/run-with-extraction.ts \
  .sandcastle/implement.md .sandcastle/Dockerfile .sandcastle/.env.example .sandcastle/.gitignore \
  .sandcastle/CODING_STANDARDS.md .sandcastle/skills/code-review/SKILL.md CONTEXT.md \
  .sandcastle/implement-prd/prompt.md .sandcastle/to-issues-prd .sandcastle/write-prd-pr \
  .sandcastle/implement .sandcastle/write-pr .sandcastle/review .sandcastle/implement-pr \
  .sandcastle/update-branch .sandcastle/architecture-review \
  .sandcastle/plan-prompt.md .sandcastle/implement-prompt.md .sandcastle/review-prompt.md .sandcastle/merge-prompt.md \
  .claude/skills/to-prd-project/SKILL.md .claude/skills/to-issues-project \
  .github/workflows/agent-implement-prd.yml .github/workflows/agent-to-issues-prd.yml \
  .github/workflows/agent-implement.yml .github/workflows/agent-review.yml \
  .github/workflows/agent-update-branch.yml .github/workflows/architecture-review.yml \
  package.json package-lock.json; do
  [ -e "$TMP/fake-project/$f" ] || { echo "MISSING: $f" >&2; exit 1; }
done

grep -q 'uv run pytest' "$TMP/fake-project/.sandcastle/implement.md"  || { echo "implement.md not python" >&2; exit 1; }
grep -q 'uv run pytest' "$TMP/fake-project/.sandcastle/implement-prd/prompt.md" || { echo "prd prompt not python" >&2; exit 1; }
grep -q 'kilbertert/fake-project' "$TMP/fake-project/.claude/skills/to-prd-project/SKILL.md" || { echo "repo slug not fixed" >&2; exit 1; }
grep -q '"afk"' "$TMP/fake-project/package.json" || { echo "afk script missing" >&2; exit 1; }
grep -q 'python3' "$TMP/fake-project/.sandcastle/Dockerfile" || { echo "Dockerfile not python" >&2; exit 1; }
grep -q 'esbuild: true' "$TMP/fake-project/pnpm-workspace.yaml" || { echo "pnpm esbuild approval missing" >&2; exit 1; }
grep -q '"ralph"' "$TMP/fake-project/package.json" || { echo "ralph script missing" >&2; exit 1; }
grep -q 'uv run pytest' "$TMP/fake-project/.sandcastle/implement-prompt.md" || { echo "planner implement prompt not python" >&2; exit 1; }
grep -q 'sandcastle:fake-project' "$TMP/fake-project/.sandcastle/profile.ts" || { echo "profile image name not slugged to this project" >&2; exit 1; }
grep -qv 'auto-test-sandcastle' "$TMP/fake-project/.sandcastle/profile.ts" || { echo "profile still pins auto-test image" >&2; exit 1; }

echo "smoke test passed"

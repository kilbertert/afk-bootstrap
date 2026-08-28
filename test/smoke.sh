#!/usr/bin/env bash
# Smoke test: scaffold a throwaway repo and assert the public output.
set -euo pipefail
S="$(cd "$(dirname "$0")/.." && pwd)"
LANGUAGE="${1:-}"
case "$LANGUAGE" in
  node|python) ;;
  *) echo "usage: $0 node|python" >&2; exit 1 ;;
esac
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TARGET="$TMP/fake-$LANGUAGE-project"
REPO="kilbertert/fake-$LANGUAGE-project"
mkdir "$TARGET"
git -C "$TARGET" init -q -b main
git -C "$TARGET" remote add origin "https://github.com/$REPO.git"

INVALID_TARGET="$TMP/invalid-$LANGUAGE-project"
mkdir "$INVALID_TARGET"
git -C "$INVALID_TARGET" init -q -b main
if "$S/bootstrap-afk.sh" "$INVALID_TARGET" --language "$LANGUAGE" --repo 'invalid#repo' --no-build >/dev/null 2>&1; then
  echo "invalid GitHub repository was accepted" >&2
  exit 1
fi
[ ! -e "$INVALID_TARGET/.sandcastle" ] || { echo "invalid input wrote scaffold files" >&2; exit 1; }

"$S/bootstrap-afk.sh" "$TARGET" --language "$LANGUAGE" --no-build >/dev/null

for f in \
  .sandcastle/main.ts .sandcastle/profile.ts .sandcastle/planner.ts .sandcastle/run-with-extraction.ts \
  .sandcastle/implement.md .sandcastle/Dockerfile .sandcastle/.env.example .sandcastle/.gitignore \
  .sandcastle/CODING_STANDARDS.md .sandcastle/skills/code-review/SKILL.md CONTEXT.md AGENTS.override.md docs/afk-workflow.md \
  .sandcastle/implement-prd/prompt.md .sandcastle/to-issues-prd .sandcastle/write-prd-pr \
  .sandcastle/implement .sandcastle/write-pr .sandcastle/review .sandcastle/implement-pr \
  .sandcastle/update-branch .sandcastle/architecture-review \
  .sandcastle/plan-prompt.md .sandcastle/implement-prompt.md .sandcastle/review-prompt.md .sandcastle/merge-prompt.md \
  .claude/skills/to-prd-project/SKILL.md .claude/skills/to-issues-project \
  .github/workflows/agent-implement-prd.yml .github/workflows/agent-to-issues-prd.yml \
  .github/workflows/agent-implement.yml .github/workflows/agent-review.yml \
  .github/workflows/agent-update-branch.yml .github/workflows/architecture-review.yml \
  .github/workflows/agent-implement-pr.yml .github/workflows/agent-promote-queued.yml \
  .afk-bootstrap.json package.json package-lock.json; do
  [ -e "$TARGET/$f" ] || { echo "MISSING: $f" >&2; exit 1; }
done

grep -q "$REPO" "$TARGET/.claude/skills/to-prd-project/SKILL.md" || { echo "repo slug not rendered" >&2; exit 1; }
grep -q '"afk"' "$TARGET/package.json" || { echo "afk script missing" >&2; exit 1; }
grep -q '"ralph"' "$TARGET/package.json" || { echo "ralph script missing" >&2; exit 1; }
grep -q 'esbuild: true' "$TARGET/pnpm-workspace.yaml" || { echo "pnpm esbuild approval missing" >&2; exit 1; }
grep -q "sandcastle:fake-$LANGUAGE-project" "$TARGET/.sandcastle/profile.ts" || { echo "profile image name not rendered" >&2; exit 1; }
grep -q 'agentrouter' "$TARGET/.sandcastle/profile.ts" || { echo "agentrouter profile missing" >&2; exit 1; }
grep -q 'agentrouter' "$TARGET/.sandcastle/main.ts" || { echo "agentrouter CLI option missing" >&2; exit 1; }
grep -q 'claude-ark|agentrouter|psydo' "$TARGET/.sandcastle/Dockerfile" || { echo "agentrouter Docker dispatch missing" >&2; exit 1; }
grep -q 'agentrouter' "$TARGET/docs/afk-workflow.md" || { echo "agentrouter workflow documentation missing" >&2; exit 1; }
node -e '
  const metadata = require(process.argv[1]);
  if (metadata.templateVersion !== 1 || metadata.language !== process.argv[2] || metadata.repository !== process.argv[3]) process.exit(1);
' "$TARGET/.afk-bootstrap.json" "$LANGUAGE" "$REPO" || { echo "template metadata invalid" >&2; exit 1; }

if grep -R -n '__AFK_' "$TARGET/.sandcastle" "$TARGET/.claude"; then
  echo "unrendered scaffold placeholder" >&2
  exit 1
fi
if grep -R -n -E 'auto-test-issue|sandcastle:auto-test|kilbertert/Auto_Test' "$TARGET/.sandcastle" "$TARGET/.claude"; then
  echo "Auto-Test project identity leaked into scaffold" >&2
  exit 1
fi
if grep -R -n -E 'git push( origin)? main|pushes main|push main \+ closes' "$TARGET/.sandcastle"; then
  echo "planner can bypass the delivery PR" >&2
  exit 1
fi
grep -q '"pr", "create"' "$TARGET/.sandcastle/planner.ts" || { echo "planner delivery PR missing" >&2; exit 1; }

if [ "$LANGUAGE" = "python" ]; then
  grep -q 'python3' "$TARGET/.sandcastle/Dockerfile" || { echo "Dockerfile not python" >&2; exit 1; }
  grep -q 'uv run pytest' "$TARGET/.sandcastle/implement.md" || { echo "implement.md not python" >&2; exit 1; }
  if grep -R -n --include='*.md' 'npm run check' "$TARGET/.sandcastle"; then
    echo "node check leaked into python prompts" >&2
    exit 1
  fi
else
  grep -q 'npm run check' "$TARGET/.sandcastle/implement.md" || { echo "implement.md not node" >&2; exit 1; }
  grep -q 'npm run check' "$TARGET/.sandcastle/implement-prompt.md" || { echo "planner prompt not node" >&2; exit 1; }
  PROFILE_HOME="$TMP/profile-home"
  mkdir -p "$PROFILE_HOME/.config/auto-test"
  printf 'apiKey,fake-key\nopenAiCompatible,https://example.invalid/v1\n' > "$PROFILE_HOME/.config/auto-test/aliyun-deepseek.csv"
  : > "$PROFILE_HOME/.config/auto-test/codex.aliyun-deepseek.toml"
  (
    cd "$TARGET"
    npm install --silent
    HOME="$PROFILE_HOME" npm exec -- tsx -e '
      Promise.all([import("./.sandcastle/profile.ts"), import("./.sandcastle/planner.ts")]).then(([{ claudeProfile }, { extractClaimedIssues, parsePlanOutput }]) => {
        if (parsePlanOutput("<plan>{\"issues\":[]}</plan>").length !== 0) process.exit(1);
        if (!extractClaimedIssues(["Closes #12\nFixes #34"]).has(34)) process.exit(1);
        try { claudeProfile("invalid"); }
        catch (error) {
          if (String(error).includes("Unsupported profile")) {
            claudeProfile("aliyun-deepseek");
            return;
          }
          throw error;
        }
        process.exit(1);
      });
    '
  ) || { echo "generated profile did not load" >&2; exit 1; }
  grep -q 'base_url = "https://example.invalid/v1"' "$PROFILE_HOME/.config/auto-test/codex.aliyun-deepseek.toml" \
    || { echo "legacy Aliyun settings fallback not used" >&2; exit 1; }
  [ ! -e "$PROFILE_HOME/.config/afk/codex.aliyun-deepseek.toml" ] \
    || { echo "new Aliyun settings path bypassed existing legacy config" >&2; exit 1; }
fi

echo "$LANGUAGE smoke test passed"

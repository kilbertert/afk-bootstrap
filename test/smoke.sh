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

# ⚠️ The throwaway repos below get `git commit`ed, and a machine-wide
# `core.hooksPath` applies to them too. On a self-hosted runner that carries the
# server's global pre-commit hook, that hook refuses any commit outside a linked
# worktree ("the canonical checkout is for reading and syncing, not for task
# work") — a rule about the operator's checkout, applied to a temp fixture that is
# not one. Measured 2026-10-23: every smoke run on the self-hosted runner died
# within seconds with that message, while the same script passed on a box without
# the hook. Scoping the fixtures off the global hooks is what makes the test
# depend on the scaffold rather than on the host it happens to run on.
#
# Done with the environment rather than a `git -c` wrapper because the commits are
# not all made here: `bootstrap-afk.sh` and `upgrade-afk.sh` commit inside these
# fixtures too, and only the environment reaches their children.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.hooksPath
export GIT_CONFIG_VALUE_0=/dev/null

TARGET="$TMP/fake-$LANGUAGE-project"
REPO="kilbertert/fake-$LANGUAGE-project"
mkdir "$TARGET"
git -C "$TARGET" init -q -b main
git -C "$TARGET" remote add origin "https://github.com/$REPO.git"
mkdir -p "$TARGET/docs/agents" "$TARGET/docs/adr"
printf '# Existing glossary\n' > "$TARGET/GLOSSARY.md"
printf '# Existing workflow\nagentrouter\n' > "$TARGET/docs/afk-workflow.md"
printf '# Existing domain docs\n' > "$TARGET/docs/agents/domain.md"
printf '# Existing ADR\n' > "$TARGET/docs/adr/0001-existing.md"
if [ "$LANGUAGE" = "node" ]; then
  printf '# Existing Claude instructions\n\nKeep this project rule.\n' > "$TARGET/CLAUDE.md"
  printf '# Existing Codex instructions\n\nKeep this Codex rule.\n' > "$TARGET/AGENTS.md"
  CODEX_INSTRUCTIONS="$TARGET/AGENTS.md"
else
  printf '# Existing Codex override\n\nKeep this override rule.\n' > "$TARGET/AGENTS.override.md"
  CODEX_INSTRUCTIONS="$TARGET/AGENTS.override.md"
fi

INVALID_TARGET="$TMP/invalid-$LANGUAGE-project"
mkdir "$INVALID_TARGET"
git -C "$INVALID_TARGET" init -q -b main
if "$S/bootstrap-afk.sh" "$INVALID_TARGET" --language "$LANGUAGE" --repo 'invalid#repo' --no-build >/dev/null 2>&1; then
  echo "invalid GitHub repository was accepted" >&2
  exit 1
fi
[ ! -e "$INVALID_TARGET/.sandcastle" ] || { echo "invalid input wrote scaffold files" >&2; exit 1; }

"$S/bootstrap-afk.sh" "$TARGET" --language "$LANGUAGE" --no-build >/dev/null

EXISTING_TARGET="$TMP/fake-$LANGUAGE-existing"
mkdir "$EXISTING_TARGET"
git -C "$EXISTING_TARGET" init -q -b main
printf '{"name":"existing","scripts":{"check":"echo check"}}\n' > "$EXISTING_TARGET/package.json"
"$S/bootstrap-afk.sh" "$EXISTING_TARGET" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
# A project with its own `check` keeps it. Overwriting would silently drop that
# project's gates (typecheck, lint, build) — the scaffold fills in a missing
# check, it does not replace one that exists.
node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).scripts || {};
  if (s.check !== "echo check") { console.error("project check was overwritten: " + s.check); process.exit(1); }
' "$EXISTING_TARGET/package.json" || { echo "scaffold replaced an existing check script" >&2; exit 1; }

grep -q '"afk"' "$EXISTING_TARGET/package.json" \
  || { echo "installer could not merge an existing package manifest" >&2; exit 1; }
[ -f "$EXISTING_TARGET/package-lock.json" ] \
  || { echo "installer did not update an existing package lockfile" >&2; exit 1; }
grep -q 'node_modules/tsx' "$EXISTING_TARGET/package-lock.json" \
  || { echo "existing package lockfile lacks the AFK runtime dependency" >&2; exit 1; }

WORKTREE_SEED="$TMP/worktree-seed-$LANGUAGE"
WORKTREE_TARGET="$TMP/fake-$LANGUAGE-worktree"
git init -q -b seed "$WORKTREE_SEED"
git -C "$WORKTREE_SEED" config user.name test
git -C "$WORKTREE_SEED" config user.email test@example.com
printf '# worktree seed\n' > "$WORKTREE_SEED/README.md"
git -C "$WORKTREE_SEED" add README.md
git -C "$WORKTREE_SEED" commit -qm 'test: worktree seed'
git -C "$WORKTREE_SEED" worktree add -q -b chore/afk-target "$WORKTREE_TARGET" HEAD
"$S/bootstrap-afk.sh" "$WORKTREE_TARGET" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
[ -f "$WORKTREE_TARGET/.sandcastle/CODING_STANDARDS.md" ] \
  || { echo "installer rejected a valid linked worktree" >&2; exit 1; }
grep -q "sandcastle:fake-$LANGUAGE-project" "$WORKTREE_TARGET/.sandcastle/profile.ts" \
  || { echo "linked worktree image name is not repository-stable" >&2; exit 1; }

for f in \
  .sandcastle/main.ts .sandcastle/profile.ts .sandcastle/planner.ts .sandcastle/run-with-extraction.ts \
  .sandcastle/policy-check.mjs .sandcastle/consensus-contract.json .sandcastle/trusted-pr-delivery.sh \
  .sandcastle/implement.md .sandcastle/Dockerfile .sandcastle/.env.example .sandcastle/.gitignore \
  .sandcastle/CODING_STANDARDS.md GLOSSARY.md CLAUDE.md docs/afk-workflow.md \
  .sandcastle/mcp-config.ts .sandcastle/mcp-config.check.ts \
  .sandcastle/repo-map.mjs .sandcastle/repo-map.check.mjs .sandcastle/REPO-MAP.md \
  .sandcastle/profile-network.ts .sandcastle/profile-network.check.ts \
  .sandcastle/sandbox-prepare.sh .sandcastle/adr.check.mjs \
  docs/agents/issue-tracker.md docs/agents/triage-labels.md docs/agents/domain.md \
  docs/agents/architecture-decisions.md \
  .sandcastle/implement-prd/prompt.md .sandcastle/write-prd-pr \
  .sandcastle/implement .sandcastle/write-pr .sandcastle/review .sandcastle/implement-pr \
  .sandcastle/update-branch .sandcastle/architecture-review \
  .sandcastle/plan-prompt.md .sandcastle/implement-prompt.md .sandcastle/review-prompt.md .sandcastle/merge-prompt.md \
  .github/workflows/agent-implement-prd.yml \
  .github/workflows/agent-implement.yml .github/workflows/agent-review.yml \
  .github/workflows/agent-update-branch.yml .github/workflows/architecture-review.yml \
  .github/workflows/agent-implement-pr.yml .github/workflows/agent-promote-queued.yml \
  .github/workflows/afk-policy.yml \
  .afk-bootstrap.json package.json package-lock.json; do
  [ -e "$TARGET/$f" ] || { echo "MISSING: $f" >&2; exit 1; }
done
[ -e "$CODEX_INSTRUCTIONS" ] || { echo "Codex instructions missing" >&2; exit 1; }

grep -q '"afk"' "$TARGET/package.json" || { echo "afk script missing" >&2; exit 1; }
grep -q '"ralph"' "$TARGET/package.json" || { echo "ralph script missing" >&2; exit 1; }
if grep -q 'prd:to-issues' "$TARGET/package.json"; then echo "automatic splitter script remains" >&2; exit 1; fi
grep -q 'esbuild: true' "$TARGET/pnpm-workspace.yaml" || { echo "pnpm esbuild approval missing" >&2; exit 1; }
grep -q "sandcastle:fake-$LANGUAGE-project" "$TARGET/.sandcastle/profile.ts" || { echo "profile image name not rendered" >&2; exit 1; }
grep -q 'claude-deepseek' "$TARGET/.sandcastle/profile.ts" || { echo "claude-deepseek profile missing" >&2; exit 1; }
grep -q 'claude-deepseek' "$TARGET/.sandcastle/main.ts" || { echo "claude-deepseek CLI option missing" >&2; exit 1; }
grep -q 'claude-deepseek)' "$TARGET/.sandcastle/Dockerfile" || { echo "claude-deepseek Docker dispatch missing" >&2; exit 1; }
# Every runner that drives an agent logs the calls it made. Asserted on a fresh
# scaffold so a template edit that drops the flag fails here rather than
# silently shrinking what a future run's log can answer.
for runner in \
  .sandcastle/implement/implement.ts \
  .sandcastle/implement-prd/implement-prd.ts \
  .sandcastle/implement-pr/implement-pr.ts; do
  grep -q 'verbose: true' "$TARGET/$runner" \
    || { echo "scaffolded $runner does not log every tool call" >&2; exit 1; }
done
# The generated workflow doc is project-owned once it lands (the fixture above
# pre-creates one), so the provider documentation is asserted on the template.
grep -q 'claude-deepseek' "$S/templates/afk-workflow.md" || { echo "claude-deepseek workflow documentation missing" >&2; exit 1; }
if grep -qE 'claude-ark|agentrouter|psydo|aliyun-deepseek' "$TARGET/.sandcastle/profile.ts" "$TARGET/.sandcastle/main.ts" "$TARGET/.sandcastle/Dockerfile" "$S/templates/afk-workflow.md"; then
  echo "a retired provider profile is still scaffolded" >&2
  exit 1
fi
grep -q 'vars.AFK_PROFILE || .claude-deepseek.' "$TARGET/.github/workflows/agent-implement.yml" \
  || { echo "workflow does not fall back to claude-deepseek" >&2; exit 1; }
# The scaffold's own instruction says "Run `npm run check` before committing", so a
# project must actually HAVE it — a fresh scaffold previously shipped neither
# `check` nor a test runner, and every agent was handed an instruction that failed
# on its first use. Asserted on the fresh target, which had no package.json.
node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).scripts || {};
  if (!s.check) { console.error("fresh scaffold defines no check script"); process.exit(1); }
  if (!s.test) { console.error("fresh scaffold defines no test script"); process.exit(1); }
' "$TARGET/package.json" || { echo "fresh scaffold is missing check/test" >&2; exit 1; }
# And the runner must actually be installed, not merely named.
node -e '
  const fs = require("fs");
  const d = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).devDependencies || {};
  if (!d.vitest) { console.error("no test runner in devDependencies"); process.exit(1); }
' "$TARGET/package.json" || { echo "scaffold names a test script with no runner" >&2; exit 1; }

grep -q '# Existing glossary' "$TARGET/GLOSSARY.md" || { echo "existing glossary was overwritten" >&2; exit 1; }
# A fresh scaffold must pass its own map freshness check. The map lists the
# package scripts and the files at the repository root, so generating it before
# `package.json` is merged leaves it describing a tree the scaffold then changes
# — and the policy job regenerates from the finished repository and compares, so
# an untouched new project would go red on its first push.
( cd "$TARGET" && node .sandcastle/repo-map.check.mjs >/dev/null ) \
  || { echo "a fresh scaffold ships a stale REPO-MAP.md" >&2; exit 1; }
if grep -q '{{PROJECT_NAME}}' "$WORKTREE_TARGET/GLOSSARY.md"; then
  echo "generated glossary contains an unrendered project name" >&2
  exit 1
fi
grep -q "# fake-$LANGUAGE-project" "$WORKTREE_TARGET/GLOSSARY.md" \
  || { echo "generated glossary project name is incorrect" >&2; exit 1; }
grep -q '# Existing workflow' "$TARGET/docs/afk-workflow.md" || { echo "existing workflow was overwritten" >&2; exit 1; }
grep -q '# Existing domain docs' "$TARGET/docs/agents/domain.md" || { echo "existing domain docs were overwritten" >&2; exit 1; }
grep -q '# Existing ADR' "$TARGET/docs/adr/0001-existing.md" || { echo "existing ADR was overwritten" >&2; exit 1; }
# The map's tree section lists these. A map generated from a shadow tree that
# reaches the real project through symlinks omits them — the generator skips
# symlinked entries — so the map is generated from the finished tree instead, and
# this is what says so.
grep -q 'docs/' "$TARGET/.sandcastle/REPO-MAP.md" \
  || { echo "repository map omits docs/ — generated from something other than the project" >&2; exit 1; }
grep -q 'docs/agents/' "$TARGET/.sandcastle/REPO-MAP.md" \
  || { echo "repository map tree does not descend into the project" >&2; exit 1; }
grep -q 'GRILLING_COMPLETE' "$CODEX_INSTRUCTIONS" || { echo "Codex planning phase gate missing" >&2; exit 1; }
grep -q 'explicitly invoke' "$CODEX_INSTRUCTIONS" || { echo "Codex explicit phase invocation gate missing" >&2; exit 1; }
grep -q 'GRILLING_COMPLETE' "$TARGET/CLAUDE.md" || { echo "Claude Code planning phase gate missing" >&2; exit 1; }
grep -q 'explicitly invoke' "$TARGET/CLAUDE.md" || { echo "Claude Code explicit phase invocation gate missing" >&2; exit 1; }
if [ "$LANGUAGE" = "node" ]; then
  grep -q 'Keep this project rule.' "$TARGET/CLAUDE.md" || { echo "existing Claude instructions were overwritten" >&2; exit 1; }
  grep -q 'Keep this Codex rule.' "$TARGET/AGENTS.md" || { echo "existing Codex instructions were overwritten" >&2; exit 1; }
  [ ! -e "$TARGET/AGENTS.override.md" ] || { echo "new Codex override was generated" >&2; exit 1; }
fi
grep -q 'AFK_AGENT_GH_TOKEN' "$TARGET/.sandcastle/profile.ts" || { echo "agent token boundary missing" >&2; exit 1; }
if grep -q 'process.env.GH_TOKEN' "$TARGET/.sandcastle/profile.ts"; then
  echo "host GH_TOKEN is still forwarded by profile" >&2
  exit 1
fi
grep -q 'github.event.pull_request.user.login == github.repository_owner' "$TARGET/.github/workflows/agent-review.yml" \
  || { echo "owner-only PR mutation gate missing" >&2; exit 1; }
grep -q '../controller/node_modules/.bin/tsx' "$TARGET/.github/workflows/agent-review.yml" \
  || { echo "trusted review controller missing" >&2; exit 1; }
grep -q 'AUTHORIZATION: basic' "$TARGET/.sandcastle/trusted-pr-delivery.sh" \
  || { echo "GitHub read-token Basic auth missing" >&2; exit 1; }
grep -q 'if \[ -n "{{ISSUE_NUMBER}}" \]' "$TARGET/.sandcastle/review/prompt.md" \
  || { echo "review prompt does not handle unlinked PRs" >&2; exit 1; }
grep -q 'if \[ -n "{{ISSUE_NUMBER}}" \]' "$TARGET/.sandcastle/review/axis-prompt.md" \
  || { echo "review axis prompt does not handle unlinked PRs" >&2; exit 1; }
grep -q 'Buffer.from("x-access-token:"' "$TARGET/.sandcastle/update-branch/update-branch.ts" \
  || { echo "update-branch Basic auth missing" >&2; exit 1; }
if grep -R -n 'skills@latest\|GITHUB_TOKEN_FALLBACK' "$TARGET/.github/workflows"; then
  echo "runtime skill install or non-triggering delivery fallback remains" >&2
  exit 1
fi
for required in \
  '## Engineering economy' \
  'Trace the affected flow and every caller' \
  'already-installed dependency' \
  'deep module with a small interface' \
  'compatibility contracts' \
  'smallest end-to-end slice' \
  'high-switching-cost architecture choices durable' \
  "\`ponytail:\` comment"; do
  grep -Fq "$required" "$TARGET/.sandcastle/CODING_STANDARDS.md" \
    || { echo "engineering economy contract missing: $required" >&2; exit 1; }
done
for prompt in \
  .sandcastle/implement.md \
  .sandcastle/implement-prd/prompt.md \
  .sandcastle/implement-prompt.md \
  .sandcastle/implement/prompt.md \
  .sandcastle/implement-pr/prompt.md; do
  grep -q 'Economy ladder' "$TARGET/$prompt" \
    || { echo "implementation economy pointer missing: $prompt" >&2; exit 1; }
done
for prompt in \
  .sandcastle/review-prompt.md \
  .sandcastle/review/axis-prompt.md \
  .sandcastle/review/prompt.md; do
  grep -Eq 'Economy (audit|ladder)' "$TARGET/$prompt" \
    || { echo "review economy pointer missing: $prompt" >&2; exit 1; }
done
if find "$TARGET" -path '*/skills/ponytail/SKILL.md' -print -quit | grep -q .; then
  echo "provider-specific Ponytail skill was installed into the project" >&2
  exit 1
fi
node -e '
  const fs = require("fs");
  const metadata = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (metadata.templateVersion !== 1 || metadata.afk_template_version !== process.argv[4] || metadata.consensus_version !== "1.0.0" || metadata.consensus_compatibility !== ">=1.0.0 <2.0.0" || metadata.language !== process.argv[2] || metadata.repository !== process.argv[3]) process.exit(1);
  // The assigned schedule hour must be recorded, or the next project on this
  // host has nothing to consult and collides by default — the defect that
  // made every project architecture review run on the same minute.
  if (typeof metadata.cron_hour !== "number" || metadata.cron_hour < 0 || metadata.cron_hour > 23) process.exit(1);
' "$TARGET/.afk-bootstrap.json" "$LANGUAGE" "$REPO" "$(tr -d '[:space:]' < "$S/TEMPLATE_VERSION")" || { echo "template metadata invalid" >&2; exit 1; }

# The record and the workflow must agree. Bootstrap copies with --no-clobber, so
# a project that already has architecture-review.yml keeps it — and in that case
# --cron-hour cannot apply. Recording the hour anyway would make the next project
# read a free hour as taken, and rendering it would edit a file this run does not
# own. Asserted on the existing-target fixture below, which pre-dates this run.

# A fresh bootstrap that already carries the workflow: the hour must NOT be
# recorded, because the workflow's own schedule was not set by this run.
SKIP_HOUR="$TMP/skip-hour-$LANGUAGE"
mkdir -p "$SKIP_HOUR/.github/workflows"
git -C "$SKIP_HOUR" init -q -b main
printf '# existing\n' > "$SKIP_HOUR/README.md"
cp "$S/scaffold/.github/workflows/architecture-review.yml" "$SKIP_HOUR/.github/workflows/"
node -e '
  const fs=require("fs"); const p=process.argv[1];
  fs.writeFileSync(p, fs.readFileSync(p,"utf8").split("__AFK_CRON_HOUR__").join("9"));
' "$SKIP_HOUR/.github/workflows/architecture-review.yml"
cp "$SKIP_HOUR/.github/workflows/architecture-review.yml" "$TMP/skip-hour-before.yml"
"$S/bootstrap-afk.sh" "$SKIP_HOUR" --language "$LANGUAGE" --repo "$REPO" --no-build --cron-hour 17 >/dev/null 2>&1 || true
cmp -s "$TMP/skip-hour-before.yml" "$SKIP_HOUR/.github/workflows/architecture-review.yml" \
  || { echo "bootstrap rewrote a workflow it did not create" >&2; exit 1; }
if node -e '
  const fs=require("fs"); const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  process.exit(m.cron_hour === undefined ? 0 : 1);
' "$SKIP_HOUR/.afk-bootstrap.json"; then :; else
  echo "bootstrap recorded an hour for a workflow it did not set" >&2; exit 1
fi

# The scaffolded workflow must carry a rendered hour, never the placeholder:
# an unrendered placeholder is an invalid cron, which silently disables the
# workflow entirely rather than failing loudly.
if grep -q '__AFK_CRON_HOUR__' "$TARGET/.github/workflows/architecture-review.yml"; then
  echo "architecture-review cron placeholder was not rendered" >&2
  exit 1
fi
grep -qE 'cron: "0 ([0-9]|1[0-9]|2[0-3]) \* \* 1-5"' \
  "$TARGET/.github/workflows/architecture-review.yml" \
  || { echo "architecture-review cron is not a rendered hour" >&2; exit 1; }

AFK_ROOT="$TARGET" AFK_DEFAULT_BRANCH=main node "$TARGET/.sandcastle/policy-check.mjs" version
if AFK_ROOT="$TARGET" AFK_DEFAULT_BRANCH=main node "$TARGET/.sandcastle/policy-check.mjs" commit >/dev/null 2>&1; then
  echo "policy checker accepted the default branch" >&2
  exit 1
fi
git -C "$TARGET" checkout -q -b feat/policy-check
AFK_ROOT="$TARGET" AFK_DEFAULT_BRANCH=main node "$TARGET/.sandcastle/policy-check.mjs" all

REVIEW_WORKFLOW="$TARGET/.github/workflows/agent-review.yml"
cp "$REVIEW_WORKFLOW" "$TMP/agent-review.yml"
sed -i '/github.event.pull_request.user.login == github.repository_owner/d' "$REVIEW_WORKFLOW"
if AFK_ROOT="$TARGET" node "$TARGET/.sandcastle/policy-check.mjs" workflows >/dev/null 2>&1; then
  echo "policy checker accepted a PR workflow without the owner gate" >&2
  exit 1
fi
mv "$TMP/agent-review.yml" "$REVIEW_WORKFLOW"

cp "$REVIEW_WORKFLOW" "$TMP/agent-review.yml"
sed -i 's/^\( *\)github.event.pull_request.user.login == github.repository_owner/\1# github.event.pull_request.user.login == github.repository_owner/' "$REVIEW_WORKFLOW"
if AFK_ROOT="$TARGET" node "$TARGET/.sandcastle/policy-check.mjs" workflows >/dev/null 2>&1; then
  echo "policy checker accepted a commented PR owner gate" >&2
  exit 1
fi
mv "$TMP/agent-review.yml" "$REVIEW_WORKFLOW"

cp "$REVIEW_WORKFLOW" "$TMP/agent-review.yml"
sed -i 's/secrets.AGENT_PAT/secrets.GITHUB_TOKEN/' "$REVIEW_WORKFLOW"
if AFK_ROOT="$TARGET" node "$TARGET/.sandcastle/policy-check.mjs" workflows >/dev/null 2>&1; then
  echo "policy checker accepted GITHUB_TOKEN for the final PR push" >&2
  exit 1
fi
mv "$TMP/agent-review.yml" "$REVIEW_WORKFLOW"

cat > "$TARGET/.afk-exceptions.json" <<'JSON'
{"exceptions":[{"invariant":"runner-isolation","reason":"temporary upstream API mismatch","scope":"docs-only migration","compensating_control":"host runner and Ruleset remain enforced","owner":"owner@example.com","approved_at":"2026-08-01T00:00:00Z","expires_at":"2099-01-01T00:00:00Z"}]}
JSON
AFK_ROOT="$TARGET" AFK_DEFAULT_BRANCH=main node "$TARGET/.sandcastle/policy-check.mjs" exceptions
sed -i 's/runner-isolation/default-branch-protection/' "$TARGET/.afk-exceptions.json"
if AFK_ROOT="$TARGET" AFK_DEFAULT_BRANCH=main node "$TARGET/.sandcastle/policy-check.mjs" exceptions >/dev/null 2>&1; then
  echo "policy checker accepted a non-exceptionable invariant" >&2
  exit 1
fi

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
  grep -q 'npm run check' "$TARGET/.sandcastle/implement-prd/prompt.md" || { echo "PRD prompt not node" >&2; exit 1; }
  if grep -qE 'npm run typecheck|npm test' "$TARGET/.sandcastle/implement-prd/prompt.md"; then
    echo "PRD prompt requires nonstandard Node checks" >&2
    exit 1
  fi
  # The generated profile is exercised against a fake host settings file: it
  # must mount the endpoint rather than bake it, and must reject a profile the
  # scaffold no longer ships.
  PROFILE_HOME="$TMP/profile-home"
  mkdir -p "$PROFILE_HOME/cliproxyapi"
  printf '{"env":{"ANTHROPIC_BASE_URL":"https://example.invalid/step_plan","ANTHROPIC_AUTH_TOKEN":"fake-key"}}\n' \
    > "$PROFILE_HOME/cliproxyapi/settings.deepseek.json"
  (
    cd "$TARGET"
    npm install --silent
    HOME="$PROFILE_HOME" npm exec -- tsx -e '
      Promise.all([import("./.sandcastle/profile.ts"), import("./.sandcastle/planner.ts")]).then(([{ claudeProfile }, { extractClaimedIssues, parsePlanOutput, selectReadyIssues }]) => {
        if (parsePlanOutput("<plan>{\"issues\":[]}</plan>").length !== 0) process.exit(1);
        if (!extractClaimedIssues(["Closes #12\nFixes #34"]).has(34)) process.exit(1);
        const planned = parsePlanOutput("<plan>{\"issues\":[{\"number\":12,\"title\":\"ready\",\"branch\":\"agent/12-ready\"},{\"number\":34,\"title\":\"not ready\",\"branch\":\"agent/34-not-ready\"}]}</plan>");
        if (selectReadyIssues(planned, new Set([12]), new Set(), new Set([12])).length !== 1) process.exit(1);
        if (selectReadyIssues(planned, new Set([12, 34]), new Set(), new Set([12])).length !== 1) process.exit(1);
        // A retired profile must be rejected, not silently resolved.
        try { claudeProfile("aliyun-deepseek"); process.exit(1); }
        catch (error) { if (!String(error).includes("Unsupported profile")) throw error; }
        claudeProfile("claude-deepseek");
      });
    '
  ) || { echo "generated profile did not load" >&2; exit 1; }
  [ -e "$PROFILE_HOME/cliproxyapi/settings.deepseek.json" ] \
    || { echo "host deepseek settings fixture missing" >&2; exit 1; }
  grep -q 'home/agent/.afk-profile-settings.json' "$TARGET/.sandcastle/Dockerfile" \
    || { echo "Dockerfile does not use the mounted settings path" >&2; exit 1; }
  grep -q 'settings.deepseek.json' "$TARGET/.sandcastle/profile.ts" \
    || { echo "profile.ts does not resolve the deepseek host settings file" >&2; exit 1; }
fi

# ---- upgrade-afk: anchored migration of an already-scaffolded project --------
# The fixture is a verbatim 1.1.x project (five-profile map, old dispatch arm,
# psydo fallback), so the migration is exercised against real previous output
# rather than a reconstruction of it.
#
# The 1.3.2 step refuses to invent a schedule hour, because a default would put
# every migrated project on one hour — the defect that step removes. A 1.1.x
# project has no architecture-review workflow at all, so it has no schedule to
# carry over and must be told one, which is the `--cron-hour` operator path.
UPGRADE_TARGET="$TMP/upgrade-$LANGUAGE"
mkdir -p "$UPGRADE_TARGET/.github" "$UPGRADE_TARGET/docs"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$UPGRADE_TARGET/"
# The 1.5.2 prompts, so the map-pointer migration is exercised against real
# previous output. This matters more than it looks: the pointers are added by
# anchored replacement, the two sentences differ per prompt, and a missed anchor
# is *silent* (the loop reads it as "the author rewrote this line and left it
# alone"). Without a fixture that carries all five shapes, a step that migrates
# four of them passes green.
cp -R "$S/test/fixtures/legacy-1.5.2-prompts/.sandcastle" "$UPGRADE_TARGET/"
cp "$S/test/fixtures/legacy-1.5.2-prompts/implement.md" "$UPGRADE_TARGET/.sandcastle/implement.md"

# A project with no schedule to carry over and no --cron-hour must be refused,
# not silently defaulted: a default is what put every project on one hour.
NO_HOUR="$TMP/upgrade-no-hour-$LANGUAGE"
mkdir -p "$NO_HOUR/.github" "$NO_HOUR/docs"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$NO_HOUR/"
if "$S/upgrade-afk.sh" "$NO_HOUR" >/dev/null 2>&1; then
  echo "upgrade assigned a schedule hour instead of refusing to guess" >&2; exit 1
fi
grep -q -- '--cron-hour' <<<"$("$S/upgrade-afk.sh" "$NO_HOUR" 2>&1)" \
  || { echo "refusal did not name the --cron-hour fix" >&2; exit 1; }
rm -rf "$NO_HOUR"

# A dry run must name everything the real run would write, including the map —
# which is generated in the publish tail rather than staged with the other new
# files, so it is the one path a list-driven report can miss. The operator's
# reason to dry-run is exactly this list.
DRY_TARGET="$TMP/upgrade-dry-$LANGUAGE"
mkdir -p "$DRY_TARGET/.github" "$DRY_TARGET/docs"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$DRY_TARGET/"
DRY_OUT="$("$S/upgrade-afk.sh" "$DRY_TARGET" --cron-hour 13 --dry-run)"
grep -q 'REPO-MAP.md' <<<"$DRY_OUT" \
  || { echo "a dry run does not report the repository map it would create" >&2; exit 1; }
rm -rf "$DRY_TARGET"

# The 1.6.0 -> 1.6.1 step, on a project already at 1.6.0. It cannot be exercised
# by the cumulative migration above: that path runs the 1.6.0 step, which installs
# the current modules directly, so the 1.6.1 step finds nothing to do and would
# pass green even if it were broken. The fixture therefore pins the 1.6.0 modules
# from the reference copy, which is what the step compares against — a project
# that edited them must be reported, not overwritten.
P161="$TMP/upgrade-160-$LANGUAGE"
mkdir -p "$P161/.github" "$P161/docs" "$P161/.sandcastle"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P161/"
cp "$S/references/mcp-config.ts.1.6.0" "$P161/.sandcastle/mcp-config.ts"
cp "$S/references/mcp-config.check.ts.1.6.0" "$P161/.sandcastle/mcp-config.check.ts"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.6.0";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P161/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P161" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.6.0" >&2; exit 1; }
grep -q 'renameSync(tmp, path)' "$P161/.sandcastle/mcp-config.ts" \
  || { echo "1.6.1 left the config written in place" >&2; exit 1; }
grep -q 'canExecute' "$P161/.sandcastle/mcp-config.ts" \
  || { echo "1.6.1 left the binary test as a readability check" >&2; exit 1; }
# A project that edited the module keeps its edit and is told to port the fix by
# hand. Replacing it would delete whatever the project needed and record a clean
# migration over it.
P161EDITED="$TMP/upgrade-160-edited-$LANGUAGE"
mkdir -p "$P161EDITED/.github" "$P161EDITED/docs" "$P161EDITED/.sandcastle"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P161EDITED/"
sed 's|^    serena: {|    serena: { // project tweak|' \
  "$S/references/mcp-config.ts.1.6.0" > "$P161EDITED/.sandcastle/mcp-config.ts"
cp "$S/references/mcp-config.check.ts.1.6.0" "$P161EDITED/.sandcastle/mcp-config.check.ts"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.6.0";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P161EDITED/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P161EDITED" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project with an edited mcp-config.ts" >&2; exit 1; }
grep -q 'project tweak' "$P161EDITED/.sandcastle/mcp-config.ts" \
  || { echo "1.6.1 overwrote a project-edited mcp-config.ts" >&2; exit 1; }

# The generator grew a pyproject.toml parser, and a map that omits a project's
# console scripts is stale even though its file is current. So this step also
# restages repo-map.mjs and regenerates the map, and wires the parser's own
# self-check into CI — the one check a fresh scaffold cannot perform, because a
# fresh scaffold has no console scripts to omit.
P161MAP="$TMP/upgrade-160-map-$LANGUAGE"
mkdir -p "$P161MAP/.github/workflows" "$P161MAP/docs" "$P161MAP/.sandcastle"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P161MAP/"
cp "$S/references/repo-map.mjs.1.6.0" "$P161MAP/.sandcastle/repo-map.mjs"
cp "$S/scaffold/.sandcastle/repo-map.check.mjs" "$P161MAP/.sandcastle/repo-map.check.mjs"
cp "$S/scaffold/.github/workflows/afk-policy.yml" "$P161MAP/.github/workflows/"
# Strip the self-check step, so the migration has to add it back.
python3 - "$P161MAP/.github/workflows/afk-policy.yml" <<'STRIP'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
start = s.index("      # The generator's own parser")
end = s.index("node .sandcastle/repo-map.mjs --self-check") + len("node .sandcastle/repo-map.mjs --self-check\n")
p.write_text(s[:start] + s[end:])
STRIP
printf '[project.scripts]\napi = "pkg.api:main"\n' > "$P161MAP/pyproject.toml"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.6.0";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P161MAP/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P161MAP" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a 1.6.0 project carrying a map" >&2; exit 1; }
grep -q 'project.scripts' "$P161MAP/.sandcastle/repo-map.mjs" \
  || { echo "1.6.1 did not restage the map generator" >&2; exit 1; }
grep -q 'pkg.api:main' "$P161MAP/.sandcastle/REPO-MAP.md" \
  || { echo "the regenerated map omits the project's console script" >&2; exit 1; }
grep -q 'repo-map.mjs --self-check' "$P161MAP/.github/workflows/afk-policy.yml" \
  || { echo "1.6.1 did not wire the generator self-check into CI" >&2; exit 1; }
( cd "$P161MAP" && node .sandcastle/repo-map.mjs --self-check >/dev/null ) \
  || { echo "the migrated generator fails its own self-check" >&2; exit 1; }

# The 1.6.1 -> 1.6.2 step: the entry-point filter was an allowlist of five script
# names, so a project whose main CLI is called something else was told by the map
# that it does not exist. Pinned from the reference so a project that edited its
# generator is reported instead of overwritten.
P162="$TMP/upgrade-161-$LANGUAGE"
mkdir -p "$P162/.github/workflows" "$P162/docs" "$P162/.sandcastle"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P162/"
cp "$S/references/repo-map.mjs.1.6.1" "$P162/.sandcastle/repo-map.mjs"
cp "$S/scaffold/.sandcastle/repo-map.check.mjs" "$P162/.sandcastle/repo-map.check.mjs"
printf '{"scripts":{"easy":"tsx src/cli/easy.ts","test":"vitest run"}}\n' > "$P162/package.json"
mkdir -p "$P162/tests/unit"
: > "$P162/tests/unit/test_alpha.py"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.6.1";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P162/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P162" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.6.1" >&2; exit 1; }
grep -q 'script "easy"' "$P162/.sandcastle/REPO-MAP.md" \
  || { echo "the regenerated map still hides a non-allowlisted entry point" >&2; exit 1; }
grep -q 'test file(s, recursive)' "$P162/.sandcastle/REPO-MAP.md" \
  || { echo "the regenerated map does not count tests below the top level" >&2; exit 1; }
( cd "$P162" && node .sandcastle/repo-map.check.mjs >/dev/null ) \
  || { echo "the 1.6.2 map is stale on arrival" >&2; exit 1; }

# The 1.6.2 -> 1.6.3 step. The map reports the filesystem and an AFK run changes
# it, so a branch produced by a run was born failing the freshness check this
# scaffold wires — measured on health-flow #168, whose run added a service module
# and a test file. The step inserts a regeneration between the agent and the push.
# The workflows below are the real 1.6.2 shape taken from git, not a
# reconstruction: the anchor and its indentation are the whole insertion.
P163="$TMP/upgrade-162-$LANGUAGE"
mkdir -p "$P163/.github/workflows" "$P163/docs" "$P163/.sandcastle"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P163/"
# From the fixture, not from a ref: CI checks out a detached HEAD with no local
# `main`, so `git show main:...` fails there. Pinned output also means the step is
# exercised against what the template actually shipped rather than against
# whatever the working tree happens to hold.
cp "$S/test/fixtures/workflows-1.6.2/agent-implement.yml" "$P163/.github/workflows/agent-implement.yml"
cp "$S/test/fixtures/workflows-1.6.2/agent-implement-prd.yml" "$P163/.github/workflows/agent-implement-prd.yml"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.6.2";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P163/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P163" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.6.2" >&2; exit 1; }
for wf in agent-implement agent-implement-prd; do
  grep -q 'repo-map.mjs' "$P163/.github/workflows/$wf.yml" \
    || { echo "1.6.3 did not wire map regeneration into $wf.yml" >&2; exit 1; }
done

# The 1.6.3 -> 1.6.4 step: the map's file set moved from a filesystem walk to
# git's view of the repository. The fixture is a real git repository, because
# that is the whole point — the previous generator answered a different question
# here than it did in CI, and a non-repo fixture could not show it.
P164="$TMP/upgrade-163-repo-$LANGUAGE"
rm -rf "$P164"
mkdir -p "$P164/.github/workflows" "$P164/docs" "$P164/.sandcastle" "$P164/src" "$P164/build-output-xyz"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P164/"
cp "$S/references/repo-map.mjs.1.6.3" "$P164/.sandcastle/repo-map.mjs"
cp "$S/scaffold/.sandcastle/repo-map.check.mjs" "$P164/.sandcastle/repo-map.check.mjs"
printf 'build-output-xyz/\n' > "$P164/.gitignore"
printf 'export const x = 1;\n' > "$P164/src/app.ts"
printf 'artifact\n' > "$P164/build-output-xyz/built.bin"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.6.3";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P164/.afk-bootstrap.json"
# On a task branch, not the default one: the host's commit guard refuses a commit
# on a default branch, and this fixture is a real repository so the guard applies.
( cd "$P164" && git init -q -b main && git config user.email t@e.com && git config user.name t \
  && git checkout -q -b chore/fixture && git add -A && git commit -qm "chore: fixture at 1.6.3" )
"$S/upgrade-afk.sh" "$P164" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.6.3" >&2; exit 1; }
grep -q 'trackedPaths' "$P164/.sandcastle/repo-map.mjs" \
  || { echo "1.6.4 did not restage the map generator" >&2; exit 1; }
# The ignored directory must be absent and the tracked file present — that pair is
# the rule the step exists to install, and it is asserted on the *map*, not on the
# generator, so a generator that is right but unwired fails here.
if grep -q 'build-output-xyz' "$P164/.sandcastle/REPO-MAP.md" \
   && sed -n '/## Tree/,$p' "$P164/.sandcastle/REPO-MAP.md" | grep -q 'build-output-xyz'; then
  echo "the regenerated map lists an ignored directory" >&2; exit 1
fi
sed -n '/## Tree/,$p' "$P164/.sandcastle/REPO-MAP.md" | grep -q 'app.ts' \
  || { echo "the regenerated map omits a tracked file" >&2; exit 1; }
# And a file written but not yet committed is inside it: that is why the set is
# "tracked plus untracked-and-not-ignored" rather than "tracked".
printf 'export const y = 2;\n' > "$P164/src/just-written.ts"
( cd "$P164" && node .sandcastle/repo-map.mjs )
grep -q 'just-written.ts' "$P164/.sandcastle/REPO-MAP.md" \
  || { echo "an uncommitted new file is missing from the map" >&2; exit 1; }
( cd "$P164" && node .sandcastle/repo-map.check.mjs >/dev/null ) \
  || { echo "the 1.6.4 map is stale on arrival" >&2; exit 1; }

# The 1.6.4 -> 1.6.5 step: every agent runner logs the calls it actually made.
# Asserted on all three runners, because a fix applied to one and not the others
# is exactly the drift a single-file check misses — and the failure is silent
# (a log that shows fewer tools still looks like a complete log).
P165="$TMP/upgrade-164-runners-$LANGUAGE"
rm -rf "$P165"
mkdir -p "$P165/.github/workflows" "$P165/docs" "$P165/.sandcastle/implement" "$P165/.sandcastle/implement-pr" "$P165/.sandcastle/implement-prd"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P165/"
for rel in .sandcastle/implement/implement.ts .sandcastle/implement-prd/implement-prd.ts .sandcastle/implement-pr/implement-pr.ts; do
  printf 'const result = await sandcastle.run({\n  logging: { type: "stdout" },\n});\n' > "$P165/$rel"
done
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.6.4";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P165/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P165" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.6.4" >&2; exit 1; }
for rel in .sandcastle/implement/implement.ts .sandcastle/implement-prd/implement-prd.ts .sandcastle/implement-pr/implement-pr.ts; do
  grep -q 'verbose: true' "$P165/$rel" \
    || { echo "1.6.5 did not make $rel verbose" >&2; exit 1; }
done
# A runner the step cannot anchor on is reported, never half-rewritten: a file
# with `verbose: true` appended somewhere unexpected is worse than one left alone.
P165ODD="$TMP/upgrade-164-odd-$LANGUAGE"
rm -rf "$P165ODD"
mkdir -p "$P165ODD/.github/workflows" "$P165ODD/docs" "$P165ODD/.sandcastle/implement"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P165ODD/"
printf 'const result = await sandcastle.run({\n  logging: { type: "file", path: "/tmp/x.log" },\n});\n' > "$P165ODD/.sandcastle/implement/implement.ts"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.6.4";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P165ODD/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P165ODD" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project with a non-stdout logging runner" >&2; exit 1; }
grep -q 'type: "file"' "$P165ODD/.sandcastle/implement/implement.ts" \
  || { echo "1.6.5 rewrote a logging option it should have left alone" >&2; exit 1; }
if grep -q 'verbose' "$P165ODD/.sandcastle/implement/implement.ts"; then
  echo "1.6.5 added verbose to a runner it could not anchor on" >&2; exit 1
fi

# The 1.6.5 -> 1.7.0 step: a run's workspace is prepared before the agent starts.
# The fixture is a 1.6.5 project — the hook is absent, so the migration has to add
# both halves. A hook nobody registered is the failure this guards: the script
# would sit there and every run would quietly go back to the agent installing its
# own dependencies.
P170="$TMP/upgrade-165-prepare-$LANGUAGE"
rm -rf "$P170"
mkdir -p "$P170/.github/workflows" "$P170/docs" "$P170/.sandcastle"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P170/"
# From the fixture, not by stripping the feature out of the current template: a
# strip is a regex against text the migration is about to change, so it stops
# producing a 1.6.5 shape the moment the template is edited, and the test then
# passes while testing nothing. (The first version of this fixture did exactly
# that, and the two assertions below are what caught it.)
cp "$S/test/fixtures/profile-1.6.5/profile.ts" "$P170/.sandcastle/profile.ts"
cp "$S/test/fixtures/profile-1.6.5/afk-policy.yml" "$P170/.github/workflows/afk-policy.yml"
if grep -q 'sandbox-prepare' "$P170/.sandcastle/profile.ts"; then
  echo "fixture still carries the prepare hook — it is not a 1.6.5 shape" >&2; exit 1
fi
if grep -q 'sandbox-prepare' "$P170/.github/workflows/afk-policy.yml"; then
  echo "fixture still wires the prepare check — it is not a 1.6.5 shape" >&2; exit 1
fi
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.6.5";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P170/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P170" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.6.5" >&2; exit 1; }
[ -e "$P170/.sandcastle/sandbox-prepare.sh" ] \
  || { echo "1.7.0 did not add the prepare script" >&2; exit 1; }
grep -q 'sandbox-prepare.sh' "$P170/.sandcastle/profile.ts" \
  || { echo "1.7.0 left the prepare hook unwired — the script would never run" >&2; exit 1; }
grep -q 'sandbox-prepare.check.ts' "$P170/.github/workflows/afk-policy.yml" \
  || { echo "1.7.0 did not wire the prepare-hook check into CI" >&2; exit 1; }
# The injected hook must leave a parseable profile.ts and a valid workflow: a
# multi-line insertion into a TS object literal is exactly where a migration
# produces something that compiles nowhere and fails the project's next run.
( cd "$P170" && npx --yes tsx .sandcastle/sandbox-prepare.check.ts >/dev/null ) \
  || { echo "the migrated prepare hook does not pass its own check" >&2; exit 1; }
python3 - "$P170" <<'YAMLOK' || { echo "the injected CI step is not valid YAML" >&2; exit 1; }
import sys, pathlib, yaml
yaml.safe_load((pathlib.Path(sys.argv[1]) / ".github/workflows/afk-policy.yml").read_text())
YAMLOK
# A project that already wrote its own prepare script keeps it: the file is that
# project's own answer to "what does a run need", and overwriting it would
# overwrite the very answer this mechanism exists to collect.
P170OWN="$TMP/upgrade-165-prepare-own-$LANGUAGE"
rm -rf "$P170OWN"
cp -R "$P170" "$P170OWN"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.6.5";
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P170OWN/.afk-bootstrap.json"
printf '#!/usr/bin/env bash\nset -euo pipefail\necho "this project own setup"\n' > "$P170OWN/.sandcastle/sandbox-prepare.sh"
"$S/upgrade-afk.sh" "$P170OWN" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project with its own prepare script" >&2; exit 1; }
grep -q 'this project own setup' "$P170OWN/.sandcastle/sandbox-prepare.sh" \
  || { echo "1.7.0 overwrote a project's own sandbox-prepare.sh" >&2; exit 1; }

# The 1.7.0 -> 1.7.1 step: serena is started with an active project. Without it
# every symbol tool answers "No active project" on the first call, which is the
# call an agent uses to decide whether the tool is worth using.
P171="$TMP/upgrade-170-serena-$LANGUAGE"
rm -rf "$P171"
mkdir -p "$P171/.github/workflows" "$P171/.sandcastle"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P171/"
cp "$S/references/mcp-config.ts.1.7.0" "$P171/.sandcastle/mcp-config.ts"
cp "$S/scaffold/.sandcastle/mcp-config.check.ts" "$P171/.sandcastle/mcp-config.check.ts"
if grep -qF -- '"--project"' "$P171/.sandcastle/mcp-config.ts"; then
  echo "the 1.7.0 fixture already carries --project" >&2; exit 1
fi
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.7.0";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P171/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P171" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.7.0" >&2; exit 1; }
grep -qF -- '"--project"' "$P171/.sandcastle/mcp-config.ts" \
  || { echo "1.7.1 did not give serena an active project" >&2; exit 1; }
# The path must be the sandbox mount, not anything the host resolved: the config
# is read inside the container. Asserted through `mcpServers()` — the artefact the
# agent's session actually reads — rather than on the source text.
# The 1.7.1 -> 1.7.2 step: `hooks` moves out of `docker()` and onto the object
# `claudeProfile` returns, which callers spread into `run()`.
#
# This is the one defect in this series that no runtime evidence could have
# caught: a hook in the wrong object is silently ignored, and the symptom (an
# unprepared workspace) is identical to a hook that ran and did nothing. The
# first measurement that appeared to confirm 1.7.0's hook worked — a ready venv —
# was the agent installing dependencies itself. So the assertion is structural.
P172="$TMP/upgrade-171-hooks-$LANGUAGE"
rm -rf "$P172"
mkdir -p "$P172/.github/workflows" "$P172/.sandcastle"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P172/"
# From the fixture, not from a ref: CI checks out a detached HEAD with no local
# `main`, so `git show <sha>` fails there — which is how this fixture came to
# exist, the same way `profile-1.6.5/` did.
cp "$S/test/fixtures/profile-1.7.1/profile.ts" "$P172/.sandcastle/profile.ts"
cp "$S/scaffold/.sandcastle/mcp-config.ts" "$P172/.sandcastle/mcp-config.ts"
cp "$S/scaffold/.sandcastle/sandbox-prepare.sh" "$P172/.sandcastle/sandbox-prepare.sh"
cp "$S/scaffold/.sandcastle/sandbox-prepare.check.ts" "$P172/.sandcastle/sandbox-prepare.check.ts"
# The fixture is the 1.7.1 shape: hooks present, inside docker().
grep -qF "hooks: {" "$P172/.sandcastle/profile.ts" \
  || { echo "the 1.7.1 fixture carries no hooks block" >&2; exit 1; }
grep -qF "codebaseMemoryAvailable" "$P172/.sandcastle/profile.ts" \
  && { echo "the 1.7.1 fixture already has the fix" >&2; exit 1; }
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.7.1";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P172/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P172" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.7.1" >&2; exit 1; }
grep -qF "codebaseMemoryAvailable" "$P172/.sandcastle/profile.ts" \
  || { echo "1.7.2 did not move the hooks onto run()" >&2; exit 1; }
# The check is the only thing that can express this: it fails while the block
# sits in the wrong object, and the sandbox cannot be asked at build time
# whether a hook would run.
( cd "$P172" && npx --yes tsx .sandcastle/sandbox-prepare.check.ts >/dev/null ) \
  || { echo "the migrated profile still carries hooks where run() cannot read them" >&2; exit 1; }

# The same journey starting further back, which is where the gate matters: a 1.6.5
# project reaches 1.7.2 in ONE invocation, and that run's 1.7.0 step is what
# installs the hooks block. A step gated on `from_minor` would then skip the move
# — stamped 1.7.2 with hooks nothing reads. This is the mirror of the `to_patch`
# trap the 1.3.1 step carries a note about.
P172C="$TMP/upgrade-165-to-172-$LANGUAGE"
rm -rf "$P172C"
mkdir -p "$P172C/.github/workflows" "$P172C/.sandcastle"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P172C/"
cp "$S/test/fixtures/profile-1.6.5/profile.ts" "$P172C/.sandcastle/profile.ts"
cp "$S/test/fixtures/profile-1.6.5/afk-policy.yml" "$P172C/.github/workflows/afk-policy.yml"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.6.5";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P172C/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P172C" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a 1.6.5 project" >&2; exit 1; }
( cd "$P172C" && npx --yes tsx .sandcastle/sandbox-prepare.check.ts >/dev/null ) \
  || { echo "a 1.6.5 project reaching 1.7.2 in one run keeps hooks run() cannot read" >&2; exit 1; }

# 1.7.3: the index hook bounds itself. A sandbox hook that outlives its own
# timeoutMs raises HookTimeoutError, which kills the run — `|| true` cannot help,
# because there is no exit code to swallow. Measured: a run sat exactly the
# deadline inside "Setting up sandbox" and died, on a command that takes 1.2 s in
# every workspace shape reproducible locally.
( cd "$P172C" && grep -qF "timeout 120" .sandcastle/profile.ts ) \
  || { echo "the index hook has no self-imposed deadline — a hang can kill the run" >&2; exit 1; }

# 1.7.4: every agent runner works in its own worktree. The workflow checkout
# carries the review and update-branch workflows' residue, and everything reading
# the filesystem — the indexer, the agent — sees it as part of the repository.
# Measured: 6 283 nodes became 24 627, because serena's own .pkl caches under
# `candidate/` are parsed as source and time out.
# The three runner files come from `bootstrap-afk.sh`, not from a migration: the
# cumulative fixture above never had them, so this case plants them at their
# pre-1.7.4 shape. Without that the assertion passes vacuously — which is how the
# first version of it "passed" while checking nothing.
P174="$TMP/upgrade-173-worktrees-$LANGUAGE"
rm -rf "$P174"
mkdir -p "$P174/.github/workflows" "$P174/.sandcastle/implement" "$P174/.sandcastle/implement-prd" "$P174/.sandcastle/implement-pr"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P174/"
cp -R "$S/test/fixtures/runners-1.7.3/." "$P174/"
# The two workflows, from the same fixture release — the 1.7.5 step edits both,
# at two different indents, and a fixture that carried only one of them would
# leave the harder case untested.
cp -R "$S/test/fixtures/workflows-1.7.4/." "$P174/.github/workflows/"
# 1.7.5 edits the runners and 1.7.6 the workflows — two releases, one end state,
# so this fixture walks the whole chain in a single invocation.
printf 'node_modules/\n' > "$P174/.gitignore"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.7.3";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P174/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P174" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.7.3" >&2; exit 1; }
# Two runners get the isolated worktree, and the third must NOT have it.
#
# `implement-pr.ts` runs inside `candidate/`, which the workflow's own trusted
# delivery script has already checked the branch out in — a second checkout of
# the same branch is refused by git. 1.7.4 added it there by mistake and 1.7.5
# removes it, so this asserts the end state of the whole 1.7.x chain: an upgrade
# from 1.7.3 runs 1.7.4 and 1.7.5 in one invocation.
for runner in \
  .sandcastle/implement/implement.ts \
  .sandcastle/implement-prd/implement-prd.ts; do
  grep -qF 'branchStrategy: { type: "branch"' "$P174/$runner" \
    || { echo "the label-driven runners are not on an isolated worktree" >&2; exit 1; }
  # Parseable, not just textually present: the insertion is three lines into a
  # call's argument list, which is exactly where a migration produces something
  # that compiles nowhere.
  npx --yes esbuild --loader:.ts=ts "$P174/$runner" --outfile=/dev/null 2>/dev/null \
    || { echo "the migration produced a $runner that does not parse" >&2; exit 1; }
done
if grep -qF "branchStrategy:" "$P174/.sandcastle/implement-pr/implement-pr.ts"; then
  echo "the PR runner must keep its candidate/ checkout — a worktree on the same branch is refused" >&2
  exit 1
fi
npx --yes esbuild --loader:.ts=ts "$P174/.sandcastle/implement-pr/implement-pr.ts" --outfile=/dev/null 2>/dev/null \
  || { echo "the migration left implement-pr.ts unparseable" >&2; exit 1; }

# 1.7.7: the commit count names the branch, because both HEAD and
# `result.commits` are HEAD-relative and the host stays on the base branch —
# measured, that reported "no commits were made" for a run whose commit was on
# the branch, and deleted the worktree.
# 1.7.8: the branch rule checks the branch the run names, not this process's
# HEAD. Since 1.7.4 the policy job's checkout stays on the default branch by
# design (the task branch lives in a worktree), so reading HEAD rejected every
# correct run.
P178="$TMP/upgrade-177-branch-policy-$LANGUAGE"
rm -rf "$P178"
mkdir -p "$P178/.github/workflows" "$P178/.sandcastle"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P178/"
cp "$S/scaffold/.sandcastle/consensus-contract.json" "$P178/.sandcastle/consensus-contract.json"
cp "$S/test/fixtures/policy-check-1.7.7.mjs" "$P178/.sandcastle/policy-check.mjs"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.7.7";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P178/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P178" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.7.7" >&2; exit 1; }
grep -qF "process.env.BRANCH" "$P178/.sandcastle/policy-check.mjs" \
  || { echo "1.7.8 did not make the branch rule name the branch" >&2; exit 1; }
# And the rule must still refuse the case it was written for. Exercised here
# rather than only asserted textually, because "the check is now a no-op" is the
# way this fix goes wrong.
BRANCHCHECK="$TMP/branch-policy-$LANGUAGE"
rm -rf "$BRANCHCHECK"
mkdir -p "$BRANCHCHECK/.sandcastle"
cp "$P178/.sandcastle/policy-check.mjs" "$P178/.sandcastle/consensus-contract.json" "$BRANCHCHECK/.sandcastle/"
cp "$P178/.afk-bootstrap.json" "$BRANCHCHECK/.afk-bootstrap.json"
# The seed commit is made on a scratch branch and `main` is then moved to it:
# the host's commit guard refuses a commit *on* a default branch, and this
# fixture needs HEAD to be the default branch — that is the case under test.
( cd "$BRANCHCHECK" && git init -q -b main && git config user.email t@e.com && git config user.name t \
  && : > f && git add -A && git checkout -q -b chore/seed && git commit -qm "chore: seed" \
  && git branch -f main chore/seed && git checkout -q main )
if ( cd "$BRANCHCHECK" && AFK_ROOT="$PWD" AFK_DEFAULT_BRANCH=main node .sandcastle/policy-check.mjs commit ) >/dev/null 2>&1; then
  echo "the branch rule accepted HEAD on the default branch" >&2; exit 1
fi
( cd "$BRANCHCHECK" && AFK_ROOT="$PWD" AFK_DEFAULT_BRANCH=main BRANCH=agent/issue-1 node .sandcastle/policy-check.mjs commit ) >/dev/null 2>&1 \
  || { echo "the branch rule rejected a run that names a task branch" >&2; exit 1; }
if ( cd "$BRANCHCHECK" && AFK_ROOT="$PWD" AFK_DEFAULT_BRANCH=main BRANCH=main node .sandcastle/policy-check.mjs commit ) >/dev/null 2>&1; then
  echo "the branch rule accepted a run that names the default branch" >&2; exit 1
fi

# 1.7.9: a retry reclaims the worktree a failed run left. Sandcastle preserves it
# on failure by design, and the next run for the same issue finds its branch
# still checked out — `git branch --force` then refuses, so re-running a failed
# issue (the normal case) fails before the agent starts.
P179="$TMP/upgrade-178-worktree-reclaim-$LANGUAGE"
rm -rf "$P179"
mkdir -p "$P179/.github/workflows" "$P179/.sandcastle"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P179/"
cp -R "$S/test/fixtures/workflows-1.7.4/." "$P179/.github/workflows/"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.7.8";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P179/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P179" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.7.8" >&2; exit 1; }
for wf in agent-implement agent-implement-prd; do
  grep -qF "stale_worktree" "$P179/.github/workflows/$wf.yml" \
    || { echo "$wf.yml does not reclaim a stale worktree before creating the branch" >&2; exit 1; }
  python3 - "$P179/.github/workflows/$wf.yml" <<'WTFILE' || { echo "$wf.yml is not valid YAML after the insertion" >&2; exit 1; }
import sys, yaml
yaml.safe_load(open(sys.argv[1]).read())
WTFILE
done
# The reclamation is a real command, not prose: exercised on a throwaway repo,
# because "the branch is force-updated while a worktree still holds it" is the
# failure it exists to prevent and a textual assertion cannot see it.
WT="$TMP/stale-worktree-$LANGUAGE"
rm -rf "$WT"
mkdir -p "$WT"
( cd "$WT" && git init -q -b main && git config user.email t@e.com && git config user.name t \
  && : > f && git add -A && git checkout -q -b chore/seed && git commit -qm "chore: seed" \
  && git branch -f main chore/seed && git checkout -q main \
  && git branch agent/issue-1 && git worktree add -q .sandcastle/worktrees/w agent/issue-1 )
if ( cd "$WT" && git branch --force agent/issue-1 HEAD ) >/dev/null 2>&1; then
  echo "the fixture does not reproduce the conflict — a branch in a worktree was force-updated" >&2
  exit 1
fi
( cd "$WT" && stale="$(git worktree list --porcelain | awk -v b="refs/heads/agent/issue-1" '/^worktree /{ wt=$2 } $1 == "branch" && $2 == b { print wt }')" \
  && [ -n "$stale" ] && git worktree remove --force "$stale" && git branch --force agent/issue-1 HEAD ) \
  || { echo "reclaiming the stale worktree did not let the branch be force-updated" >&2; exit 1; }

# 1.7.10: the policy step is told which branch. 1.7.8 made the rule check BRANCH
# when set — and the step that runs it never set it, so the fix had no effect.
# Asserted on the **caller**, because the callee was already correct and a
# source-level assertion on it passes while every run still fails.
for wf in agent-implement agent-implement-prd; do
  python3 - "$P179/.github/workflows/$wf.yml" <<'BRANCHENV' || { echo "$wf.yml does not give the policy step the branch" >&2; exit 1; }
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]).read())
steps = [s for job in doc["jobs"].values() for s in job.get("steps", [])]
step = next((s for s in steps if s.get("name") == "Verify AFK policy before push"), None)
if step is None:
    sys.exit("no policy step")
env = step.get("env") or {}
if "BRANCH" not in env:
    sys.exit("the policy step has no BRANCH in its env")
BRANCHENV
done

# 1.7.11: the graph is named after the repository.
#
# Both halves are asserted, because either one alone leaves the failure in place:
# naming only the index leaves the agent guessing, and naming only the map leaves
# the map wrong. The names come from the same manifest field, so the third
# assertion is that they agree — a step that lowercased one side would produce a
# confidently-wrong instruction rather than a missing one.
P1711="$TMP/upgrade-1710-graph-name-$LANGUAGE"
rm -rf "$P1711"
mkdir -p "$P1711/.github/workflows" "$P1711/.sandcastle"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P1711/"
cp -R "$S/test/fixtures/workflows-1.7.4/." "$P1711/.github/workflows/"
# The 1.7.10 shapes of the two files this step restages, taken from references —
# the same place the step reads them, so the fixture cannot drift from the anchor.
cp "$S/references/repo-map.mjs.1.7.10" "$P1711/.sandcastle/repo-map.mjs"
cp "$S/references/repo-map.check.mjs.1.7.10" "$P1711/.sandcastle/repo-map.check.mjs"
# And the profile as 1.7.10 carried it: hooks present, no `--name`.
cp "$S/references/profile.ts.1.7.10" "$P1711/.sandcastle/profile.ts"
grep -qF "index_repository" "$P1711/.sandcastle/profile.ts" \
  || { echo "the 1.7.10 profile fixture carries no index hook" >&2; exit 1; }
grep -qF "## Code intelligence" "$P1711/.sandcastle/repo-map.mjs" \
  && { echo "the 1.7.10 map fixture already carries the section" >&2; exit 1; }
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.7.10";
  m.templateVersion = 1;
  m.repository = "kilbertert/AI-Ops";
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P1711/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P1711" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.7.10" >&2; exit 1; }
grep -qF -- "--name AI-Ops" "$P1711/.sandcastle/profile.ts" \
  || { echo "1.7.11 did not name the graph in the index hook" >&2; exit 1; }
grep -qF '## Code intelligence' "$P1711/.sandcastle/REPO-MAP.md" \
  || { echo "the regenerated map does not name the graph" >&2; exit 1; }
# The generator itself carries it, not just the map it happened to write: the
# policy job regenerates the map on every push, so a section present only in the
# committed file disappears on the next run.
grep -qF "## Code intelligence" "$P1711/.sandcastle/repo-map.mjs" \
  || { echo "the restaged generator does not emit the Code intelligence section" >&2; exit 1; }
( cd "$P1711" && node .sandcastle/repo-map.check.mjs >/dev/null ) \
  || { echo "the migrated map fails its own check" >&2; exit 1; }
# Negative control: a generator that prints a DIFFERENT name than the manifest
# must fail the check. Without this the assertion could be passing on the section
# merely existing rather than on it naming the right project.
python3 - "$P1711" <<'MAPNEG' || { echo "the map check accepted a name that is not the indexed project" >&2; exit 1; }
import pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
gen = root / ".sandcastle" / "repo-map.mjs"
gen.write_text(gen.read_text().replace('${projectName}', 'wrong-name', 1))
subprocess.run(["node", ".sandcastle/repo-map.mjs"], cwd=root, check=True, stdout=subprocess.DEVNULL)
if subprocess.run(["node", ".sandcastle/repo-map.check.mjs"], cwd=root,
                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
    sys.exit(1)
MAPNEG

# 1.7.12: decision records get a shape and a checker.
#
# The scaffold's prompts have said "read the ADRs" since 1.6.0 and nothing said
# "write one". This asserts both halves of the fix: the checker ships and is
# wired into the policy job, and — the part that decides whether adopting it is
# possible at all — the checker judges only the records a change touches, so a
# repository with a back catalogue can adopt it without editing that catalogue.
P1712="$TMP/upgrade-1711-adr-$LANGUAGE"
rm -rf "$P1712"
mkdir -p "$P1712/.github/workflows" "$P1712/.sandcastle/implement" \
         "$P1712/.sandcastle/implement-prd" "$P1712/docs/adr" "$P1712/docs/agents"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P1712/"
cp -R "$S/test/fixtures/workflows-1.7.4/." "$P1712/.github/workflows/"
# The policy workflow as 1.7.11 left it: the scaffold's steps, no decision-record
# step, and a SHALLOW checkout. Taken from references rather than assembled by
# stripping, because a strip that stops matching leaves the fixture fixed and the
# assertions below prove nothing — measured, twice.
cp "$S/references/afk-policy.yml.1.7.12" "$P1712/.github/workflows/afk-policy.yml"
grep -q 'adr.check.mjs' "$P1712/.github/workflows/afk-policy.yml" \
  && { echo "the 1.7.12 policy reference already carries the decision-record step — stale reference" >&2; exit 1; }
grep -q 'fetch-depth' "$P1712/.github/workflows/afk-policy.yml" \
  && { echo "the 1.7.12 policy reference already fetches full history — stale reference" >&2; exit 1; }
# The fixture must be the shape the live projects carry, not the pre-1.7.12 one:
# a 1.7.12–1.7.15 project has BOTH the decision-record step and the depth line,
# and an earlier version of the comparison missed exactly those. Built here rather
# than referenced, because two earlier attempts at stripping a fixture silently
# stopped matching and left it already-fixed.
python3 - "$P1712/.github/workflows/afk-policy.yml" <<'SHAPE1712'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
anchor = "      - name: Repository-map generator self-check"
assert anchor in t, "the 1.7.12 policy reference no longer has the generator step — stale reference"
t = t.replace(anchor, """      - name: Verify decision records
        env:
          AFK_ADR_BASE: ${{ github.event.pull_request.base.sha || github.event.before }}
        run: node .sandcastle/adr.check.mjs --base "$AFK_ADR_BASE"
""" + anchor, 1)
depth = "          persist-credentials: false"
assert depth in t, "the 1.7.12 policy reference no longer has the checkout — stale reference"
t = t.replace(depth, depth + "\n          fetch-depth: 0", 1)
p.write_text(t)
SHAPE1712
# A 1.7.x project carries the scaffold's own prompts — the other half this step edits.
mkdir -p "$P1712/.sandcastle/implement" "$P1712/.sandcastle/implement-prd"
cp "$S/scaffold/.sandcastle/implement/prompt.md" "$P1712/.sandcastle/implement/prompt.md"
cp "$S/templates/prompt.node.md" "$P1712/.sandcastle/implement-prd/prompt.md"
cp "$S/templates/implement.node.md" "$P1712/.sandcastle/implement.md"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$P1712/.sandcastle/repo-map.mjs"
cp "$S/scaffold/.sandcastle/repo-map.check.mjs" "$P1712/.sandcastle/repo-map.check.mjs"
# Strip the write duty, so the fixture is the version BEFORE it.
python3 - "$P1712" <<'STRIPDUTY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for rel in (".sandcastle/implement/prompt.md", ".sandcastle/implement-prd/prompt.md",
            ".sandcastle/implement.md"):
    p = root / rel
    t = p.read_text()
    i = t.find("If this change settles something")
    assert i != -1, f"{rel}: the scaffold prompt no longer carries the write duty — this test is stale"
    j = t.find("No-ADR: <why not>", i)
    assert j != -1, f"{rel}: could not bound the write duty"
    p.write_text(t[:i - 1] + t[j + len("    No-ADR: <why not>") + 1:])
STRIPDUTY
# A back-catalogue record: no status line, no alternatives. It predates the
# convention, which is the normal case in every repository on this host.
printf '# Legacy record\n\nSomething was decided once, in prose.\n' > "$P1712/docs/adr/0001-legacy.md"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.7.11";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P1712/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P1712" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.7.11" >&2; exit 1; }
[ -e "$P1712/.sandcastle/adr.check.mjs" ] \
  || { echo "1.7.12 did not ship the decision-record check" >&2; exit 1; }
[ -e "$P1712/docs/agents/architecture-decisions.md" ] \
  || { echo "1.7.12 did not ship the decision-record convention" >&2; exit 1; }
grep -q 'adr.check.mjs' "$P1712/.github/workflows/afk-policy.yml" \
  || { echo "the decision-record check is not wired into the policy job" >&2; exit 1; }
# ...and the checkout must carry the base commit that check resolves. Without it
# the run either reports that it cannot see the diff (harmless before 1.7.16) or
# FAILS (from 1.7.16), so the two changes land together.
# Parsed, not grepped: the scaffold's own comments contain `fetch-depth: 0`, so a
# textual assertion passes without an active setting. The claim is about the
# checkout the decision-record step runs under, so that is what is read.
grep -q 'github.event.pull_request.head.sha' "$P1712/.github/workflows/afk-policy.yml" \
  || { echo "the checkout does not name the pull request's own head" >&2; exit 1; }
python3 - "$P1712/.github/workflows/afk-policy.yml" <<'DEPTHCHK' \
  || { echo "the policy job's checkout cannot see the base commit" >&2; exit 1; }
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]).read())
for job in doc["jobs"].values():
    steps = [s for s in job.get("steps", []) if isinstance(s, dict)]
    at = next((n for n, s in enumerate(steps) if s.get("name") == "Verify decision records"), None)
    if at is None:
        continue
    for idx in range(at - 1, -1, -1):
        if str(steps[idx].get("uses", "")).startswith("actions/checkout@"):
            depth = (steps[idx].get("with") or {}).get("fetch-depth")
            sys.exit(0 if depth in (0, "0") else 1)
sys.exit(1)
DEPTHCHK
# The prompts must ask for a record, not only for one to be read.
for rel in \
  .sandcastle/implement/prompt.md .sandcastle/implement-prd/prompt.md .sandcastle/implement.md; do
  grep -qE 'No-ADR' "$P1712/$rel" \
    || { echo "$rel never asks for a decision record" >&2; exit 1; }
done

ADRC="$P1712/.sandcastle/adr.check.mjs"
# Captured, not piped into `grep -q`: this script runs under `pipefail`, and
# `grep -q` closes the pipe on its first match, so the producer dies of SIGPIPE
# and the pipeline reports 141 — a passing assertion read as a failure. The
# output is two lines; capturing it costs nothing.
BARE_OUT="$( cd "$P1712" && node "$ADRC" 2>&1 )" && BARE_RC=0 || BARE_RC=$?
# A bare run reports and does not block: this is what makes the migration
# adoptable — the project's back catalogue must not turn its first check red.
[ "$BARE_RC" = "0" ] \
  || { echo "the check blocked on a back-catalogue record with no diff to scope to" >&2; exit 1; }
case "$BARE_OUT" in
  *0001-legacy.md*) ;;
  *) echo "the bare report did not name the back-catalogue record" >&2; exit 1 ;;
esac
# ...but the back catalogue is still visible when someone asks for it, and the
# exit code is what makes `--all` a gate rather than a report.
ALL_OUT="$( cd "$P1712" && node "$ADRC" --all 2>&1 )" && ALL_RC=0 || ALL_RC=$?
[ "$ALL_RC" != "0" ] \
  || { echo "the check passed a record with no status and no alternatives under --all" >&2; exit 1; }
case "$ALL_OUT" in
  *0001-legacy.md*) ;;
  *) echo "the sweep did not name the offending record" >&2; exit 1 ;;
esac

# 1.7.13: the gate is scoped to commits, refuses a bare --base, and applies to
# itself. Three defects 1.7.12 shipped, each measured after it landed.
P1713="$TMP/upgrade-1712-gate-$LANGUAGE"
rm -rf "$P1713"
mkdir -p "$P1713/.github/workflows" "$P1713/.sandcastle/implement" \
         "$P1713/.sandcastle/implement-prd" "$P1713/docs/adr" "$P1713/docs/agents"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P1713/"
cp -R "$S/test/fixtures/workflows-1.7.4/." "$P1713/.github/workflows/"
cp "$S/scaffold/.github/workflows/afk-policy.yml" "$P1713/.github/workflows/afk-policy.yml"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$P1713/.sandcastle/repo-map.mjs"
cp "$S/scaffold/.sandcastle/repo-map.check.mjs" "$P1713/.sandcastle/repo-map.check.mjs"
# The 1.7.12 shapes, from references — the same place the step reads them, so the
# fixture cannot drift from the anchor it is supposed to reproduce.
cp "$S/references/adr.check.mjs.1.7.12" "$P1713/.sandcastle/adr.check.mjs"
cp "$S/references/architecture-decisions.md.1.7.12" "$P1713/docs/agents/architecture-decisions.md"
cp "$S/templates/implement.node.md" "$P1713/.sandcastle/implement.md"
cp "$S/templates/prompt.node.md" "$P1713/.sandcastle/implement-prd/prompt.md"
cp "$S/scaffold/.sandcastle/implement/prompt.md" "$P1713/.sandcastle/implement/prompt.md"
# Strip the SEARCH duty, so the fixture is the version before it — the write duty
# (No-ADR) is already present at 1.7.12 and is not what this step adds.
python3 - "$P1713" <<'STRIPSEARCH'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for rel in (".sandcastle/implement/prompt.md", ".sandcastle/implement-prd/prompt.md",
            ".sandcastle/implement.md"):
    p = root / rel
    t = p.read_text()
    i = t.find("Before you settle on an approach")
    assert i != -1, f"{rel}: the scaffold prompt carries no search duty — this test is stale"
    j = t.find("do not spend a human's time on them.")
    assert j != -1, f"{rel}: could not bound the search duty"
    p.write_text(t[:i - 1] + t[j + len("do not spend a human's time on them.") + 1:])
for rel in (".sandcastle/adr.check.mjs", "docs/agents/architecture-decisions.md"):
    p = root / rel
    assert "search what this repository has already decided" not in p.read_text(), \
        f"{rel}: the 1.7.12 reference already carries the fix — stale reference"
for rel in (".sandcastle/adr.check.mjs",):
    assert "refusing to report success" not in (root / rel).read_text(), \
        f"{rel}: the 1.7.12 reference already carries the fail-closed fix — stale reference"
STRIPSEARCH
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.7.12";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P1713/.afk-bootstrap.json"
# The project is at 1.7.12, so the 1.7.12 step has already run: give it the
# records and duties that version shipped, or the fixture is not that version.
printf '# Legacy\n\nprose only\n' > "$P1713/docs/adr/0001-legacy.md"
"$S/upgrade-afk.sh" "$P1713" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.7.12" >&2; exit 1; }
# 1. The fail-open is closed, and closed by SPECIFICATION not by value: both an
#    empty argument and an empty environment variable must fail.
( cd "$P1713" && node .sandcastle/adr.check.mjs --base "" >/dev/null 2>&1 ) \
  && { echo "an empty --base still reported success" >&2; exit 1; }
( cd "$P1713" && AFK_ADR_BASE="" node .sandcastle/adr.check.mjs >/dev/null 2>&1 ) \
  && { echo "an empty AFK_ADR_BASE still reported success" >&2; exit 1; }
# ...while a bare run stays a report, which is what makes the migration usable.
( cd "$P1713" && env -u AFK_ADR_BASE node .sandcastle/adr.check.mjs >/dev/null 2>&1 ) \
  || { echo "a bare run blocked; it must report and exit 0" >&2; exit 1; }
grep -qF 'cannot resolve' "$P1713/.sandcastle/adr.check.mjs" \
  || { echo "the checker cannot name an unresolvable base" >&2; exit 1; }
# 2. Coverage is judged per commit. The proof is a range holding two commits: one
#    that owes a record and carries none, and one that carries a record. A
#    diff-level check cannot tell them apart; a commit-level one can.
# Seeded on a scratch branch and fast-forwarded, because the host's commit guard
# refuses a commit ON a default branch — and the check needs HEAD to be one. Same
# shape as the policy-check fixture above.
( cd "$P1713" && git init -q -b main && git config user.email t@e.com && git config user.name t \
  && git add -A && git checkout -q -b chore/seed && git commit -qm "chore: seed" \
  && git branch -f main chore/seed && git checkout -q chore/seed )
BASE_NOW="$( cd "$P1713" && git rev-parse HEAD )"
# The commit that OWES a record, on its own: source only, no record in the same
# commit. Bundling the record in would satisfy `touchedAdr` and the fixture would
# prove nothing — measured, that is exactly how the first version of this block
# passed a broken checker.
mkdir -p "$P1713/src"
printf 'def f(): return 1\n' > "$P1713/src/owed.py"
( cd "$P1713" && git add -A && git commit -qm "feat: owes a record, carries none" )
( cd "$P1713" && node .sandcastle/adr.check.mjs --base "$BASE_NOW" >/dev/null 2>&1 ) \
  && { echo "a commit that owes a record and carries none was accepted" >&2; exit 1; }
# ...and the NEXT commit passes because it carries the record. Two commits, so the
# check has to tell them apart — which is the whole point of judging per commit.
printf '# Covered\n\nStatus: accepted\n\n## Alternatives considered\n\n- **B** — 否\n' > "$P1713/docs/adr/0002-covered.md"
( cd "$P1713" && git add -A && git commit -qm "feat: carries the record" )
# `if` rather than `A && B || C`: the checker exits non-zero by design here, and
# `|| C` would also run when `A` fails for an unrelated reason — shellcheck's
# SC2015, and a real difference between "it flagged a commit" and "it did not run".
if RANGE_OUT="$( cd "$P1713" && node .sandcastle/adr.check.mjs --base "$BASE_NOW" 2>&1 )"; then
  RANGE_RC=0
else
  RANGE_RC=$?
fi
[ "$RANGE_RC" != "0" ] \
  || { echo "the range with one owing commit exited 0" >&2; exit 1; }
case "$RANGE_OUT" in
  *'1 flagged'*) ;;
  *) echo "the range report does not say one of two commits was flagged:" >&2
     printf '%s\n' "$RANGE_OUT" >&2; exit 1 ;;
esac
# A diff-level check cannot express this: over the whole range, docs/adr/ IS
# touched, so the old implementation would have passed both commits.
grep -qF 'coverage judged' "$P1713/.sandcastle/adr.check.mjs" \
  || { echo "the checker does not report what it judged" >&2; exit 1; }
# 3. The rule owns itself: the step installs a record explaining the change, into
#    the project's own docs/adr/ — under the NEXT FREE number, not a fixed one.
#    Three of the four repositories on this host already have a 0002, so a shipped
#    serial collides in most of them, and the serial is how a record is cited.
SELF_RECORD=""
for f in "$P1713"/docs/adr/*-adr-check-scope-and-self-application.md; do
  [ -e "$f" ] && SELF_RECORD="$(basename "$f")"
done
[ -n "$SELF_RECORD" ] \
  || { echo "1.7.13 did not install its own decision record" >&2; exit 1; }
# At install time the fixture held exactly one record (0001-legacy), so the next
# free number is 0002. The point is that the step COUNTED rather than assumed: a
# shipped literal would be wrong in most repositories on this host, each of which
# already has a 0002.
[ "$SELF_RECORD" = "0002-adr-check-scope-and-self-application.md" ] \
  || { echo "the installed record did not take the next free number (got $SELF_RECORD)" >&2; exit 1; }
# 4. The search duty is now in all three live prompts.
for rel in .sandcastle/implement/prompt.md .sandcastle/implement-prd/prompt.md \
           .sandcastle/implement.md; do
  grep -q "search what this repository has already" "$P1713/$rel" \
    || { echo "$rel never asks to search the records before writing" >&2; exit 1; }
done

# 1.7.14: three more holes, all found by Devin Review on the 1.7.13 PRs after it
# had already been merged — which is the case for running the gate on the
# scaffolder itself rather than trusting the review of the tool that reviews.
P1714="$TMP/upgrade-1713-merge-$LANGUAGE"
rm -rf "$P1714"
mkdir -p "$P1714/.sandcastle" "$P1714/docs/adr" "$P1714/src"
cp "$S/scaffold/.sandcastle/adr.check.mjs" "$P1714/.sandcastle/adr.check.mjs"
printf '# M\n\nStatus: accepted\n\n## Alternatives considered\n\n- **B** — 否\n' > "$P1714/docs/adr/0002-m.md"
( cd "$P1714" && git init -q -b main && git config user.email t@e.com && git config user.name t \
  && git add -A && git checkout -q -b chore/seed && git commit -qm "chore: seed" \
  && git branch -f main chore/seed && git checkout -q chore/seed )
BASE_MERGE="$( cd "$P1714" && git rev-parse HEAD )"
# A side branch carrying a source change, merged in with `--no-ff`. The MERGE
# commit is the one under test: `git diff-tree` prints nothing for a two-parent
# commit without `-m`, so before the fix the merge was waived in silence.
( cd "$P1714" && git checkout -q -b side && printf 'x=1\n' > src/side.py \
  && git add -A && git commit -qm "feat: side change" \
  && git checkout -q chore/seed && git merge -q --no-ff side -m "chore: merge side" )
( cd "$P1714" && node .sandcastle/adr.check.mjs --base "$BASE_MERGE" >/dev/null 2>&1 ) \
  && { echo "a merge that brought in a record-worthy change was waived silently" >&2; exit 1; }
# The regression this guards: `git diff-tree` with no `-m` on that merge.
[ -z "$( cd "$P1714" && git diff-tree --no-commit-id --name-only -r --root "$(git rev-parse HEAD)" )" ] \
  || { echo "the fixture's merge is not the two-parent shape this guards" >&2; exit 1; }
[ -n "$( cd "$P1714" && git diff-tree --no-commit-id --name-only -r -m --first-parent --root "$(git rev-parse HEAD)" )" ] \
  || { echo "-m --first-parent does not reach the merge's paths" >&2; exit 1; }

# A duplicate serial is reported whatever the scope, and FAILS (a) always under
# --all, (b) under --base only when the change touches one of the pair — so a
# repository can adopt the rule before it retires a legacy collision.
cp "$P1714/docs/adr/0002-m.md" "$P1714/docs/adr/0002-m-second.md"
( cd "$P1714" && node .sandcastle/adr.check.mjs --all >/dev/null 2>&1 ) \
  && { echo "--all accepted two records sharing a serial" >&2; exit 1; }
( cd "$P1714" && env -u AFK_ADR_BASE node .sandcastle/adr.check.mjs >/dev/null 2>&1 ) \
  || { echo "a bare run failed on a collision instead of reporting it" >&2; exit 1; }
if COLLISION_OUT="$( cd "$P1714" && node .sandcastle/adr.check.mjs --all 2>&1 )"; then
  COLLISION_RC=0
else
  COLLISION_RC=$?
fi
# The exit code IS the assertion — the collision must fail under --all. Capturing
# it rather than discarding it is what makes "A && B || C" unnecessary here, and
# avoids SC2015 by construction rather than by suppression.
[ "$COLLISION_RC" != "0" ] \
  || { echo "--all exited 0 on two records sharing a serial" >&2; exit 1; }
case "$COLLISION_OUT" in
  *'used by 2 records'*) ;;
  *) echo "the collision report does not name both holders:" >&2
     printf '%s\n' "$COLLISION_OUT" >&2; exit 1 ;;
esac
rm -f "$P1714/docs/adr/0002-m-second.md"

# `--all` is a complete instruction and must not be blocked by an empty base ref.
( cd "$P1714" && AFK_ADR_BASE="" node .sandcastle/adr.check.mjs --all >/dev/null 2>&1 ) \
  || { echo "--all was blocked by an empty AFK_ADR_BASE; it needs no base" >&2; exit 1; }
# ...while a run that ASKED for a diff and supplied nothing still fails.
( cd "$P1714" && AFK_ADR_BASE="" node .sandcastle/adr.check.mjs >/dev/null 2>&1 ) \
  && { echo "an empty AFK_ADR_BASE with no --all still reported success" >&2; exit 1; }
# The combination is its own case, and the one that failed open: `--all` scopes
# the STRUCTURE rules, it does not license skipping the coverage half that `--base`
# was also asked for. Measured before this was fixed: `--all --base ""` exited 0
# with coverage silently unevaluated.
( cd "$P1714" && node .sandcastle/adr.check.mjs --all --base "" >/dev/null 2>&1 ) \
  && { echo "--all --base with no ref skipped the coverage half and reported success" >&2; exit 1; }
# ...and with a real ref, the combination judges BOTH halves.
( cd "$P1714" && node .sandcastle/adr.check.mjs --all --base "$BASE_MERGE" >/dev/null 2>&1 ) \
  && { echo "--all --base with a real ref did not judge the commits" >&2; exit 1; }
# A base that cannot be RESOLVED is fatal too. Judging nothing and saying so reads
# as honest and fails open: a shallow checkout (CI's default) or a typo leaves
# every commit on the branch unjudged while the log says "passed".
( cd "$P1714" && node .sandcastle/adr.check.mjs --base deadbeefdeadbeefdeadbeefdeadbeefdeadbeef >/dev/null 2>&1 ) \
  && { echo "an unresolvable --base judged nothing and reported success" >&2; exit 1; }
# `--base` with no value must not silently inherit AFK_ADR_BASE: a workflow that
# passes `--base "$UNSET"` would otherwise gate against whatever else is set.
( cd "$P1714" && AFK_ADR_BASE="$BASE_MERGE" node .sandcastle/adr.check.mjs --base >/dev/null 2>&1 ) \
  && { echo "--base with no value fell through to the environment instead of failing" >&2; exit 1; }
# ...while `--base <ref> --all` is a correctly configured pair and must run.
( cd "$P1714" && node .sandcastle/adr.check.mjs --base "$BASE_MERGE" --all >/dev/null 2>&1 ) \
  && { echo "--base <ref> --all was rejected; the ref is not a missing argument" >&2; exit 1; }

# 1.7.17: a project-owned policy workflow is wired ADDITIVELY.
#
# Two designs failed here before. Patching by text left a different hole each
# round; replacing the whole file cannot touch a workflow that has the project's
# own steps in it, and the fallback only mentioned the checkout depth — so a valid
# `No-ADR:` waiver kept failing on GitHub's synthetic merge commit. The wrier adds
# what is missing, in place, and asserts the result.
P1717="$TMP/upgrade-1716-policy-wire-$LANGUAGE"
rm -rf "$P1717"
mkdir -p "$P1717/.sandcastle" "$P1717/.github/workflows" "$P1717/docs/adr"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P1717/"
cp "$S/scaffold/.sandcastle/consensus-contract.json" "$P1717/.sandcastle/"
printf 'FROM node:24\n' > "$P1717/.sandcastle/Dockerfile"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$P1717/.sandcastle/repo-map.mjs"
cp "$S/scaffold/.sandcastle/repo-map.check.mjs" "$P1717/.sandcastle/repo-map.check.mjs"
cp "$S/references/afk-policy.yml.1.7.12" "$P1717/.github/workflows/afk-policy.yml"
# A step of the project's own, and no decision-record step: the shape that must be
# left alone apart from the two things it is missing.
python3 - "$P1717/.github/workflows/afk-policy.yml" <<'OWNSTEP'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
anchor = "      - name: Verify AFK workflow boundaries"
assert anchor in t, "the policy reference no longer has the workflow-boundary step — stale"
p.write_text(t.replace(anchor, "      - name: Local lint\n        run: make lint\n" + anchor, 1))
OWNSTEP
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.7.11";
  m.templateVersion = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P1717/.afk-bootstrap.json"
printf '# Legacy\n\nprose only\n' > "$P1717/docs/adr/0001-legacy.md"
"$S/upgrade-afk.sh" "$P1717" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.7.11" >&2; exit 1; }
python3 - "$P1717/.github/workflows/afk-policy.yml" <<'WIREDCHK' \
  || { echo "the policy workflow was not wired additively" >&2; exit 1; }
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]).read())
names = [s.get("name") for j in doc["jobs"].values() for s in j["steps"]]
if "Local lint" not in names:
    sys.exit("the project's own step was lost")
if "Verify decision records" not in names:
    sys.exit("the decision-record step was not added")
for job in doc["jobs"].values():
    steps = [s for s in job["steps"] if isinstance(s, dict)]
    at = next((n for n, s in enumerate(steps) if s.get("name") == "Verify decision records"), None)
    if at is None:
        continue
    for idx in range(at - 1, -1, -1):
        if str(steps[idx].get("uses", "")).startswith("actions/checkout@"):
            have = steps[idx].get("with") or {}
            if have.get("fetch-depth") != 0:
                sys.exit("the checkout still cannot see the base commit")
            if "github.event.pull_request.head.sha" not in str(have.get("ref", "")):
                sys.exit("the checkout still lands on GitHub's merge ref")
            sys.exit(0)
sys.exit("no checkout found under the decision-record step")
WIREDCHK

for runner in .sandcastle/implement/implement.ts .sandcastle/implement-prd/implement-prd.ts; do
  grep -qF 'origin/main..' "$P174/$runner" \
    || { echo "$runner does not count commits on the branch" >&2; exit 1; }
  # The explanatory comment names `result.commits` on purpose, so this looks for
  # a *use* — the identifier outside a comment line.
  if grep -vE '^\s*(//|/\*|\*)' "$P174/$runner" | grep -qE 'result\.commits\b'; then
    echo "$runner still reads result.commits, which is HEAD-relative" >&2; exit 1
  fi
  npx --yes esbuild --loader:.ts=ts "$P174/$runner" --outfile=/dev/null 2>/dev/null \
    || { echo "the migration left $runner unparseable" >&2; exit 1; }
done

# And the workflows must stop checking the task branch out for the same reason:
# sandcastle's `branch` strategy checks it out inside a worktree, and git refuses
# to check one branch out twice. The branch is created without moving HEAD.
# The patterns are built so the literal `"$BRANCH"` is not read as an expansion
# (shellcheck SC2016) — the text being matched is workflow source.
DQ='"'
CO_OLD="git checkout -b ${DQ}\$BRANCH${DQ}"
CO_OLD_CAP="git checkout -B ${DQ}\$BRANCH${DQ}"
BR_NEW="git branch --force ${DQ}\$BRANCH${DQ}"
for wf in agent-implement agent-implement-prd; do
  if grep -qF -e "$CO_OLD" -e "$CO_OLD_CAP" "$P174/.github/workflows/$wf.yml"; then
    echo "$wf.yml still checks out the task branch — the worktree would be refused" >&2
    exit 1
  fi
  grep -qF "$BR_NEW" "$P174/.github/workflows/$wf.yml" \
    || { echo "$wf.yml does not create the task branch without checking it out" >&2; exit 1; }
done
# Both indents are exercised above (10 spaces and 12), which is the point: an
# exact-anchor substitution on the wrong indent fails loudly rather than missing.
python3 - "$P174" <<'YAMLOK' || { echo "the migrated workflows are not valid YAML" >&2; exit 1; }
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1]) / ".github" / "workflows"
for n in ("agent-implement", "agent-implement-prd"):
    yaml.safe_load((root / f"{n}.yml").read_text())
YAMLOK
# And the worktree it creates must be ignored, or the next run indexes the
# previous run's worktree — the same defect one level in.
grep -qE '^\.sandcastle/worktrees/?' "$P174/.gitignore" \
  || { echo "1.7.4 did not ignore the sandbox worktree directory" >&2; exit 1; }


( cd "$P171" && npx --yes tsx -e '
import { mcpServers } from "./.sandcastle/mcp-config.ts";
const args = mcpServers().serena.args;
const i = args.indexOf("--project");
if (i < 0) { console.error("serena has no --project"); process.exit(1); }
if (args[i + 1] !== "/home/agent/workspace") {
  console.error("serena --project is not the sandbox path: " + args[i + 1]);
  process.exit(1);
}
' ) || { echo "the migrated serena config is not usable" >&2; exit 1; }
# It has to be valid YAML at a step boundary. An insertion that lands a level too
# deep parses the `-` as a continuation key and the workflow fails to load — the
# run never starts, which is the silent outcome this whole step exists to remove.
python3 - "$P163" <<'YAMLCHECK' || { echo "the inserted step does not parse as a workflow step" >&2; exit 1; }
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1]) / ".github" / "workflows"
for name in ("agent-implement", "agent-implement-prd"):
    doc = yaml.safe_load((root / f"{name}.yml").read_text())
    for job in doc["jobs"].values():
        names = [s.get("name", "") for s in job.get("steps", [])]
        if "Regenerate the repository map" in names:
            break
    else:
        sys.exit(f"{name}.yml: the regeneration step is not a step")
YAMLCHECK

UPGRADE_OUT="$("$S/upgrade-afk.sh" "$UPGRADE_TARGET" --cron-hour 13)"
printf '%s\n' "$UPGRADE_OUT"
grep -q 'claude-deepseek)' "$UPGRADE_TARGET/.sandcastle/Dockerfile" \
  || { echo "upgrade did not install the deepseek dispatch arm" >&2; exit 1; }
if grep -qE 'claude-ark\|agentrouter\|psydo' "$UPGRADE_TARGET/.sandcastle/Dockerfile"; then
  echo "upgrade left the retired dispatch arm in place" >&2; exit 1
fi
grep -q 'vars.AFK_PROFILE || .claude-deepseek.' "$UPGRADE_TARGET/.github/workflows/agent-implement.yml" \
  || { echo "upgrade did not update the workflow fallback" >&2; exit 1; }
grep -q 'claude-deepseek' "$UPGRADE_TARGET/.sandcastle/main.ts" \
  || { echo "upgrade did not update the CLI usage string" >&2; exit 1; }
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (m.afk_template_version !== process.argv[2]) process.exit(1);
  // Cumulative migration: a 1.1.x project must come out of ONE run with both
  // the 1.2.0 provider migration and the 1.3.2 schedule migration applied, and
  // the assigned hour recorded. A step gated on from_minor alone would leave a
  // 1.1.x project at 1.2.0 output while the metadata claimed 1.3.2.
  if (typeof m.cron_hour !== "number" || m.cron_hour < 0 || m.cron_hour > 23) process.exit(1);
' "$UPGRADE_TARGET/.afk-bootstrap.json" "$(tr -d '[:space:]' < "$S/TEMPLATE_VERSION")" || { echo "upgrade did not record the new version and hour" >&2; exit 1; }
# The schedule must come out rendered, and the job budget raised: leaving either
# behind reproduces the two defects this step exists to remove — an invalid cron
# that silently disables the workflow, or a 20m budget that cancels a 19m review
# inside its own success path.
if grep -q '__AFK_CRON_HOUR__' "$UPGRADE_TARGET/.github/workflows/architecture-review.yml"; then
  echo "upgrade left the cron placeholder unrendered" >&2; exit 1
fi
grep -qE 'cron: "0 ([0-9]|1[0-9]|2[0-3]) \* \* 1-5"' \
  "$UPGRADE_TARGET/.github/workflows/architecture-review.yml" \
  || { echo "upgrade did not render a valid cron hour" >&2; exit 1; }
grep -qE '^\s*timeout-minutes: 75\s*$' "$UPGRADE_TARGET/.github/workflows/architecture-review.yml" \
  || { echo "upgrade did not raise the architecture-review job budget" >&2; exit 1; }
# The 1.6.0 files are staged into a copy, and a staged file is not a delivered
# one: `profile.ts` gains `import ... from "./mcp-config.js"` in the same step, so
# a run that stamps 1.6.0 without publishing them leaves a project whose `pnpm afk`
# dies on a module that cannot be resolved. Asserted on the migrated project, not
# on the template, because the template was never the problem.
for f in \
  .sandcastle/mcp-config.ts .sandcastle/mcp-config.check.ts \
  .sandcastle/repo-map.mjs .sandcastle/repo-map.check.mjs \
  .sandcastle/REPO-MAP.md; do
  [ -e "$UPGRADE_TARGET/$f" ] || { echo "upgrade did not publish $f" >&2; exit 1; }
done
# The modules shipped must be the current revision, not whatever the template
# had when the step was written. Both defects were silent — the agent loses
# servers and nothing goes red — so the shape is asserted rather than assumed:
# the config is written by rename, and the binary must be executable.
grep -q 'renameSync(tmp, path)' "$UPGRADE_TARGET/.sandcastle/mcp-config.ts" \
  || { echo "migrated mcp-config.ts does not write the config atomically" >&2; exit 1; }
grep -q 'canExecute' "$UPGRADE_TARGET/.sandcastle/mcp-config.ts" \
  || { echo "migrated mcp-config.ts does not require the binary to be executable" >&2; exit 1; }
grep -q 'mcp-config.js' "$UPGRADE_TARGET/.sandcastle/profile.ts" \
  || { echo "migrated profile.ts lost its MCP import" >&2; exit 1; }
grep -qF -- '--mcp-config /home/agent/.afk-mcp.json' "$UPGRADE_TARGET/.sandcastle/Dockerfile" \
  || { echo "upgrade did not wire the sandbox MCP config into the wrapper" >&2; exit 1; }
grep -q 'serena-agent' "$UPGRADE_TARGET/.sandcastle/Dockerfile" \
  || { echo "upgrade did not add the serena layer" >&2; exit 1; }
# npm 11 skips an unnamed postinstall, and claude-code fetches its native binary
# from one. A migrated project that rebuilds without this gets a green build
# around a claude that cannot start.
grep -qF 'npm install --global --allow-scripts=@anthropic-ai/claude-code' \
  "$UPGRADE_TARGET/.sandcastle/Dockerfile" \
  || { echo "upgrade left the npm postinstall unapproved" >&2; exit 1; }
# The freshness check the 1.6.0 CI step wires must pass against what the migration
# wrote. The map is generated after publication, from the finished project, so it
# is run here — the migration's own output is what is under test.
( cd "$UPGRADE_TARGET" && node .sandcastle/repo-map.check.mjs >/dev/null ) \
  || { echo "upgrade wrote a repository map that is already stale" >&2; exit 1; }
# The same, on the path that renames a root document. A pre-1.4 project holds
# CONTEXT.md; the map must come out describing GLOSSARY.md, because that is what
# the tree will hold. Generating before the rename publishes leaves the map
# naming a root file that no longer exists.
RENAME_TARGET="$TMP/upgrade-rename-$LANGUAGE"
mkdir -p "$RENAME_TARGET/.github" "$RENAME_TARGET/docs"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$RENAME_TARGET/"
printf '# project glossary\n\nterms\n' > "$RENAME_TARGET/CONTEXT.md"
"$S/upgrade-afk.sh" "$RENAME_TARGET" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project holding CONTEXT.md" >&2; exit 1; }
[ ! -e "$RENAME_TARGET/CONTEXT.md" ] || { echo "upgrade left CONTEXT.md in place" >&2; exit 1; }
grep -q 'GLOSSARY.md' "$RENAME_TARGET/.sandcastle/REPO-MAP.md" \
  || { echo "repository map does not name the renamed glossary" >&2; exit 1; }
if grep -q 'CONTEXT.md' "$RENAME_TARGET/.sandcastle/REPO-MAP.md"; then
  echo "repository map still names CONTEXT.md after the rename" >&2; exit 1
fi
( cd "$RENAME_TARGET" && node .sandcastle/repo-map.check.mjs >/dev/null ) \
  || { echo "the rename path writes a stale repository map" >&2; exit 1; }
# All five implementation prompts gain the pointer, including the two whose
# read list starts somewhere other than `Read `GLOSSARY` — the PRD prompt lists
# docs first. A single anchor migrates four and reports success for five.
for prompt in \
  .sandcastle/implement.md \
  .sandcastle/implement-prompt.md \
  .sandcastle/implement/prompt.md \
  .sandcastle/implement-pr/prompt.md \
  .sandcastle/implement-prd/prompt.md; do
  grep -q 'REPO-MAP.md' "$UPGRADE_TARGET/$prompt" \
    || { echo "upgrade left $prompt without the map pointer" >&2; exit 1; }
done
# The `claude` dispatch arm is the only one with no --settings flag, so the
# substitution anchored on that flag cannot reach it — and that arm is paired
# with the mounts that are no longer conditional. A mount the wrapper does not
# read is a server the agent does not get.
grep -qF 'claude) exec /usr/local/bin/claude-real --mcp-config /home/agent/.afk-mcp.json' \
  "$UPGRADE_TARGET/.sandcastle/Dockerfile" \
  || { echo "upgrade left the claude arm without --mcp-config" >&2; exit 1; }
grep -qF '...mcpConfigMounts(),' "$UPGRADE_TARGET/.sandcastle/profile.ts" \
  || { echo "upgrade left the MCP mounts out of profile.ts" >&2; exit 1; }
if grep -q '? { mounts: \[{ hostPath: settingsPath' "$UPGRADE_TARGET/.sandcastle/profile.ts"; then
  echo "migrated profile.ts still gates the mounts on settingsPath" >&2; exit 1
fi
# A project document is its own source of truth: the migration reports it, never rewrites it.
grep -q 'afk-workflow.md' <<<"$UPGRADE_OUT" \
  || { echo "upgrade silently ignored project prose naming a retired profile" >&2; exit 1; }
grep -q 'claude-ark' "$UPGRADE_TARGET/docs/afk-workflow.md" \
  || { echo "upgrade rewrote a project-owned document" >&2; exit 1; }
# Idempotent on a second run.
"$S/upgrade-afk.sh" "$UPGRADE_TARGET" | grep -q 'already at' \
  || { echo "upgrade is not idempotent" >&2; exit 1; }
# Refuses a target without scaffold provenance.
NO_PROVENANCE="$TMP/no-provenance-$LANGUAGE"
mkdir -p "$NO_PROVENANCE/.sandcastle"
cp "$UPGRADE_TARGET/.sandcastle/Dockerfile" "$NO_PROVENANCE/.sandcastle/"
if "$S/upgrade-afk.sh" "$NO_PROVENANCE" >/dev/null 2>&1; then
  echo "upgrade accepted a project with no .afk-bootstrap.json" >&2; exit 1
fi
# The hand-port shape (a project that applied a provider profile by hand, with
# the endpoint baked in) converges onto the same mounted result, and its baked
# secret block is removed rather than left as a dead arm.
HANDPORT="$TMP/handport-$LANGUAGE"
mkdir -p "$HANDPORT/.github/workflows"
cp -R "$S/test/fixtures/handport-1.1.x/." "$HANDPORT/"
"$S/upgrade-afk.sh" "$HANDPORT" --cron-hour 11 >/dev/null \
  || { echo "upgrade refused the hand-port shape" >&2; exit 1; }
[ "$(grep -c 'claude-deepseek)' "$HANDPORT/.sandcastle/Dockerfile")" = 1 ] \
  || { echo "hand-port did not converge to a single dispatch arm" >&2; exit 1; }
if grep -qE 'STEPFUN_BASE_URL|api_key|afk-stepfun-settings\.json' "$HANDPORT/.sandcastle/Dockerfile"; then
  echo "hand-port kept the baked endpoint instead of mounting it" >&2; exit 1
fi
grep -q 'settings.deepseek.json' "$HANDPORT/.sandcastle/profile.ts" \
  || { echo "hand-port did not resolve the mounted settings path" >&2; exit 1; }

# An *added provider* is the case a presence test misses: it needs no change
# outside the profile table, so the rest of the file stays byte-identical to a
# generated one. The comparison must still refuse it — replacing the file would
# delete the provider while recording a successful migration.
ADDED_PROVIDER="$TMP/added-provider-$LANGUAGE"
mkdir -p "$ADDED_PROVIDER"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$ADDED_PROVIDER/"
node -e '
  const fs = require("fs"), p = process.argv[1] + "/.sandcastle/profile.ts";
  fs.writeFileSync(p, fs.readFileSync(p, "utf8").replace(
    "  psydo: undefined,",
    "  psydo: undefined,\n  \"company-claude\": join(homedir(), \"company/settings.json\"),"));
' "$ADDED_PROVIDER"
ADDED_TREE="$(cd "$ADDED_PROVIDER" && find . -type f | sort | xargs md5sum)"
if "$S/upgrade-afk.sh" "$ADDED_PROVIDER" >/dev/null 2>&1; then
  echo "upgrade overwrote a profile.ts with an added provider" >&2; exit 1
fi
[ "$ADDED_TREE" = "$(cd "$ADDED_PROVIDER" && find . -type f | sort | xargs md5sum)" ] \
  || { echo "refusing an added provider still modified the project" >&2; exit 1; }

# A profile.ts carrying a project edit must be refused, not replaced: the file is
# the only one the migration discards rather than edits.
EDITED_PROFILE="$TMP/edited-profile-$LANGUAGE"
mkdir -p "$EDITED_PROFILE"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$EDITED_PROFILE/"
node -e '
  const fs = require("fs"), p = process.argv[1] + "/.sandcastle/profile.ts";
  fs.writeFileSync(p, fs.readFileSync(p, "utf8").replace("        ...(agentToken", "        projectExtra: 1,\n        ...(agentToken"));
' "$EDITED_PROFILE"
EDITED_TREE="$(cd "$EDITED_PROFILE" && find . -type f | sort | xargs md5sum)"
if "$S/upgrade-afk.sh" "$EDITED_PROFILE" >/dev/null 2>&1; then
  echo "upgrade overwrote a profile.ts carrying a project edit" >&2; exit 1
fi
[ "$EDITED_TREE" = "$(cd "$EDITED_PROFILE" && find . -type f | sort | xargs md5sum)" ] \
  || { echo "refusing an edited profile.ts still modified the project" >&2; exit 1; }

# A project already newer than this template must not be pulled backwards.
NEWER="$TMP/newer-$LANGUAGE"
mkdir -p "$NEWER"; cp -R "$S/test/fixtures/legacy-1.1.x/." "$NEWER/"
node -e '
  const fs = require("fs"), p = process.argv[1];
  const m = JSON.parse(fs.readFileSync(p, "utf8"));
  m.afk_template_version = "1.9.0";
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");
' "$NEWER/.afk-bootstrap.json"
if "$S/upgrade-afk.sh" "$NEWER" >/dev/null 2>&1; then
  echo "upgrade downgraded a newer project" >&2; exit 1
fi
grep -q '1.9.0' "$NEWER/.afk-bootstrap.json" \
  || { echo "downgrade refusal still rewrote the version" >&2; exit 1; }

# Every retired fallback is rewritten, and an unrecognised one is refused:
# a workflow that still names a profile the new map rejects cannot start its
# agent, so recording the migration would be a false success.
for retired in psydo claude-ark agentrouter aliyun-deepseek; do
  FB="$TMP/fallback-$retired-$LANGUAGE"
  mkdir -p "$FB/.github/workflows"
  cp -R "$S/test/fixtures/legacy-1.1.x/.sandcastle" "$FB/"
  cp "$S/test/fixtures/legacy-1.1.x/.afk-bootstrap.json" "$FB/"
    node -e '
    const fs = require("fs"), dir = process.argv[1], provider = process.argv[2];
    const src = process.argv[3];
    const moved = fs.readFileSync(src, "utf8")
      .split("vars.AFK_PROFILE || '"'"'psydo'"'"'").join("vars.AFK_PROFILE || '"'"'" + provider + "'"'"'");
    fs.writeFileSync(dir + "/.github/workflows/agent-implement.yml", moved);
  ' "$FB" "$retired" "$S/test/fixtures/legacy-1.1.x/.github/workflows/agent-implement.yml"
  "$S/upgrade-afk.sh" "$FB" --cron-hour 13 >/dev/null \
    || { echo "upgrade refused the retired fallback $retired" >&2; exit 1; }
  if grep -qF -e "$retired" "$FB/.github/workflows/agent-implement.yml"; then
    echo "upgrade left the retired fallback $retired in place" >&2; exit 1
  fi
  grep -qF -e "vars.AFK_PROFILE || 'claude-deepseek'" "$FB/.github/workflows/agent-implement.yml" \
    || { echo "upgrade did not write the new fallback for $retired" >&2; exit 1; }
done

# GitHub reads .yaml as well as .yml, so a workflow named with the other
# extension must be migrated too — otherwise it keeps a fallback the new profile
# map rejects and its next run stops before the agent starts.
YAML_FB="$TMP/fallback-yaml-$LANGUAGE"
mkdir -p "$YAML_FB/.github/workflows"
cp -R "$S/test/fixtures/legacy-1.1.x/.sandcastle" "$YAML_FB/"
cp "$S/test/fixtures/legacy-1.1.x/.afk-bootstrap.json" "$YAML_FB/"
cp "$S/test/fixtures/legacy-1.1.x/.github/workflows/agent-implement.yml" \
   "$YAML_FB/.github/workflows/custom-agent.yaml"
"$S/upgrade-afk.sh" "$YAML_FB" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a .yaml workflow" >&2; exit 1; }
if grep -qF -e "vars.AFK_PROFILE || 'psydo'" "$YAML_FB/.github/workflows/custom-agent.yaml"; then
  echo "upgrade left a retired fallback in a .yaml workflow" >&2; exit 1
fi
grep -qF -e "vars.AFK_PROFILE || 'claude-deepseek'" "$YAML_FB/.github/workflows/custom-agent.yaml" \
  || { echo "upgrade did not rewrite the .yaml workflow fallback" >&2; exit 1; }

# A checkout path containing a space must not split the reference list.
SPACED_TOOL="$TMP/with space"
mkdir -p "$SPACED_TOOL"
cp "$S/upgrade-afk.sh" "$SPACED_TOOL/"
cp -R "$S/references" "$SPACED_TOOL/"
cp -R "$S/scaffold" "$SPACED_TOOL/"
cp "$S/TEMPLATE_VERSION" "$SPACED_TOOL/"
SPACED_PROJECT="$TMP/spaced project"
mkdir -p "$SPACED_PROJECT/.github/workflows"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$SPACED_PROJECT/"
"$SPACED_TOOL/upgrade-afk.sh" "$SPACED_PROJECT" --cron-hour 13 >/dev/null \
  || { echo "upgrade failed when its own path contains a space" >&2; exit 1; }

UNKNOWN_FB="$TMP/fallback-unknown-$LANGUAGE"
mkdir -p "$UNKNOWN_FB/.github/workflows"
cp -R "$S/test/fixtures/legacy-1.1.x/.sandcastle" "$UNKNOWN_FB/"
cp "$S/test/fixtures/legacy-1.1.x/.afk-bootstrap.json" "$UNKNOWN_FB/"
node -e '
  const fs = require("fs"), dir = process.argv[1], src = process.argv[2];
  fs.writeFileSync(dir + "/.github/workflows/agent-implement.yml",
    fs.readFileSync(src, "utf8")
      .split("vars.AFK_PROFILE || '"'"'psydo'"'"'").join("vars.AFK_PROFILE || '"'"'custom-provider'"'"'"));
' "$UNKNOWN_FB" "$S/test/fixtures/legacy-1.1.x/.github/workflows/agent-implement.yml"
UNKNOWN_TREE="$(cd "$UNKNOWN_FB" && find . -type f | sort | xargs md5sum)"
if "$S/upgrade-afk.sh" "$UNKNOWN_FB" >/dev/null 2>&1; then
  echo "upgrade accepted an unrecognised AFK_PROFILE fallback" >&2; exit 1
fi
[ "$UNKNOWN_TREE" = "$(cd "$UNKNOWN_FB" && find . -type f | sort | xargs md5sum)" ] \
  || { echo "refusing an unrecognised fallback still modified the project" >&2; exit 1; }

# The bootstrap report is the operational handoff for a new project, so the
# profile it tells the operator to set must be one the scaffold accepts.
if "$S/bootstrap-afk.sh" "$TMP/report-$LANGUAGE" --language "$LANGUAGE" --repo "$REPO" --no-build 2>/dev/null \
   | grep -qE 'AFK_PROFILE --body (claude-ark|agentrouter|psydo|aliyun-deepseek)'; then
  echo "bootstrap still recommends a retired profile" >&2; exit 1
fi

# A refused migration must leave the project untouched. Each case mutates one
# file into a shape the step cannot anchor, then asserts every file is
# byte-identical afterwards — a step that failed after an earlier write would
# otherwise strand a migrated Dockerfile under old metadata.
assert_refused_untouched() {
  label=$1
  mutate=$2
  CASE="$TMP/refuse-$label-$LANGUAGE"
  mkdir -p "$CASE"
  cp -R "$S/test/fixtures/legacy-1.1.x/." "$CASE/"
  node -e "$mutate" "$CASE"
  BEFORE_TREE="$(cd "$CASE" && find . -type f | sort | xargs md5sum)"
  if "$S/upgrade-afk.sh" "$CASE" >/dev/null 2>&1; then
    echo "upgrade accepted a target it cannot migrate: $label" >&2; exit 1
  fi
  [ "$BEFORE_TREE" = "$(cd "$CASE" && find . -type f | sort | xargs md5sum)" ] \
    || { echo "refused upgrade ($label) modified the project" >&2; exit 1; }
}

assert_refused_untouched 'unknown-arm' '
  const fs = require("fs"), p = process.argv[1];
  const f = p + "/.sandcastle/Dockerfile";
  fs.writeFileSync(f, fs.readFileSync(f, "utf8")
    .split("\n").map((l) => l.includes("claude-ark|agentrouter|psydo) args=()")
      ? "    '"'"'  custom-provider) args=(); exit 9 ;;'"'"' \\" : l).join("\n"));
'
assert_refused_untouched 'custom-main-usage' '
  const fs = require("fs"), p = process.argv[1];
  const f = p + "/.sandcastle/main.ts";
  fs.writeFileSync(f, fs.readFileSync(f, "utf8")
    .replace("--profile claude|claude-ark|agentrouter|psydo|aliyun-deepseek", "--profile custom-provider"));
'
assert_refused_untouched 'missing-profile' '
  const fs = require("fs"), p = process.argv[1];
  fs.rmSync(p + "/.sandcastle/profile.ts");
'

# Refuses a target without scaffold provenance.
NO_PROVENANCE="$TMP/no-provenance-$LANGUAGE"
mkdir -p "$NO_PROVENANCE/.sandcastle"
cp "$UPGRADE_TARGET/.sandcastle/Dockerfile" "$NO_PROVENANCE/.sandcastle/"
if "$S/upgrade-afk.sh" "$NO_PROVENANCE" >/dev/null 2>&1; then
  echo "upgrade accepted a project with no .afk-bootstrap.json" >&2; exit 1
fi

# A project already at 1.2.0 takes the schedule-only path: the provider step
# must NOT re-run (it would refuse a legitimately customised profile.ts and
# block an unrelated upgrade), and the run must reach publication rather than
# dying on an unset variable after printing its change report. Both were real
# defects on this path, and neither is reachable from the 1.1.x fixture above.
MID="$TMP/mid-$LANGUAGE"
mkdir -p "$MID/.github/workflows"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$MID/"
# Make it a 1.2.0 project: provider migration already applied.
node -e '
  const fs = require("fs"), p = process.argv[1];
  const f = p + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8"));
  m.afk_template_version = "1.2.0";
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$MID"
cp "$S/scaffold/.sandcastle/profile.ts" "$MID/.sandcastle/profile.ts"
cp "$S/scaffold/.github/workflows/architecture-review.yml" "$MID/.github/workflows/"
MID_BEFORE="$(cd "$MID" && find . -type f | sort | xargs md5sum)"
"$S/upgrade-afk.sh" "$MID" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a 1.2.0 project taking the schedule-only path" >&2; exit 1; }
# The change must actually LAND: a run that prints its report and then aborts
# leaves the rollback trap to restore the original, which is how an unset
# variable silently made this path a no-op.
grep -qE '^\s*timeout-minutes: 75\s*$' "$MID/.github/workflows/architecture-review.yml" \
  || { echo "1.2.0 path did not land the job budget change" >&2; exit 1; }
if grep -q '__AFK_CRON_HOUR__' "$MID/.github/workflows/architecture-review.yml"; then
  echo "1.2.0 path left the cron placeholder unrendered" >&2; exit 1
fi
grep -qE 'cron: "0 13 \* \* 1-5"' "$MID/.github/workflows/architecture-review.yml" \
  || { echo "1.2.0 path did not render the assigned hour" >&2; exit 1; }
[ "$MID_BEFORE" != "$(cd "$MID" && find . -type f | sort | xargs md5sum)" ] \
  || { echo "1.2.0 path reported changes but wrote nothing" >&2; exit 1; }

# A 1.1.x project has no architecture-review workflow AND no runner for it. The
# migration must add both: adding the workflow alone leaves it invoking
# `.sandcastle/architecture-review/architecture-review.ts`, which does not exist
# there — it would fail on its first run, replacing a missing feature with a
# broken one. Asserted on the runner, not just the workflow file.
grep -q '.sandcastle/architecture-review/architecture-review.ts' \
  "$UPGRADE_TARGET/.github/workflows/architecture-review.yml" \
  || { echo "migrated workflow does not reference the runner" >&2; exit 1; }
for f in architecture-review.ts extraction.md prompt.md; do
  [ -f "$UPGRADE_TARGET/.sandcastle/architecture-review/$f" ] \
    || { echo "migration did not add .sandcastle/architecture-review/$f" >&2; exit 1; }
done
# The surrounding .sandcastle files are project-owned and must survive.
for f in Dockerfile main.ts profile.ts; do
  [ -f "$UPGRADE_TARGET/.sandcastle/$f" ] \
    || { echo "migration discarded .sandcastle/$f" >&2; exit 1; }
done

# A commented-out `# - cron:` line is not the schedule. A whole-file search finds
# the comment first and records the hour it names, so the record describes a
# schedule the project does not run and the genuinely-occupied hour looks free to
# the next project. Asserted with BOTH present: the comment says 9, the live line
# says 16, and 16 is what must be recorded.
COMMENTED_CRON="$TMP/commented-cron-$LANGUAGE"
mkdir -p "$COMMENTED_CRON/.github/workflows"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$COMMENTED_CRON/"
node -e '
  const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8")); m.afk_template_version = "1.2.0";
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$COMMENTED_CRON"
cp "$S/scaffold/.sandcastle/profile.ts" "$COMMENTED_CRON/.sandcastle/profile.ts"
cp "$S/scaffold/.github/workflows/architecture-review.yml" "$COMMENTED_CRON/.github/workflows/"
# shellcheck disable=SC2016  # JS regex wants literal `$1`; none is shell here.
node -e '
  const fs = require("fs"), p = process.argv[1] + "/.github/workflows/architecture-review.yml";
  fs.writeFileSync(p, fs.readFileSync(p, "utf8")
    .split("__AFK_CRON_HOUR__").join("9")
    .replace(/^(    - cron: .*)$/m, "    # $1\n    - cron: \"0 16 * * 1-5\""));
' "$COMMENTED_CRON"
"$S/upgrade-afk.sh" "$COMMENTED_CRON" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a workflow carrying a commented cron" >&2; exit 1; }
node -e '
  const fs=require("fs"); const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  if (m.cron_hour !== 16) { console.error("recorded the commented hour, not the live one: " + m.cron_hour); process.exit(1); }
' "$COMMENTED_CRON/.afk-bootstrap.json" \
  || { echo "a commented cron line was mistaken for the schedule" >&2; exit 1; }
# The live schedule is the project's and must be left alone; the comment stays too.
grep -qE '^[[:space:]]*- cron: "0 16 \* \* 1-5"' "$COMMENTED_CRON/.github/workflows/architecture-review.yml" \
  || { echo "upgrade rewrote the live schedule" >&2; exit 1; }

# The 1.1.x path ADDS the workflow from the current scaffold, so no stale comment
# exists there. What must hold is that the render consumed the placeholder: the
# token is a sed target, so any copy of it left in prose would be overwritten
# with the hour and the comment would read nonsense.
if grep -q '__AFK_CRON_HOUR__' "$UPGRADE_TARGET/.github/workflows/architecture-review.yml"; then
  echo "the cron placeholder was left unrendered" >&2; exit 1
fi
grep -qE '^[[:space:]]*- cron: "0 13 \* \* 1-5"' \
  "$UPGRADE_TARGET/.github/workflows/architecture-review.yml" \
  || { echo "migration did not set the cron hour" >&2; exit 1; }
# And no prose was rewritten by the render: the comment must not name the hour.
if grep -qE '^\s*#.*\b13\b.*placeholder' "$UPGRADE_TARGET/.github/workflows/architecture-review.yml"; then
  echo "the render rewrote prose because the token appeared more than once" >&2; exit 1
fi

# A single-digit hour must keep its leading zero. The hour is read as a NUMBER
# and written back into prose, so a naive format produced `# 9:00 UTC` — a
# correct sync that looks like a typo. Bash also reads a leading zero as octal,
# so formatting `09` needs an explicit base.
for pair in "9:09" "8:08"; do
  want=${pair##*:}; cron_h=${pair%%:*}
  PAD="$TMP/pad-$cron_h-$LANGUAGE"
  mkdir -p "$PAD/.github/workflows"
  cp -R "$S/test/fixtures/legacy-1.1.x/." "$PAD/"
  node -e '
    const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
    const m = JSON.parse(fs.readFileSync(f, "utf8")); m.afk_template_version = "1.3.1";
    fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
  ' "$PAD"
  cp "$S/scaffold/.sandcastle/profile.ts" "$PAD/.sandcastle/profile.ts"
  printf '%s\n' \
    'name: Architecture Review' 'on:' '  schedule:' \
    '    # 12:00 UTC, Monday–Friday. GitHub may delay' \
    "    - cron: \"0 $cron_h * * 1-5\"" '  workflow_dispatch:' 'jobs:' \
    '  architecture-review:' '    runs-on: self-hosted' \
    '    timeout-minutes: 75' '    steps:' '      - run: echo hi' \
    > "$PAD/.github/workflows/architecture-review.yml"
  "$S/upgrade-afk.sh" "$PAD" >/dev/null \
    || { echo "upgrade failed for a single-digit hour ($cron_h)" >&2; exit 1; }
  grep -q "# $want:00 UTC" "$PAD/.github/workflows/architecture-review.yml" \
    || { echo "single-digit hour lost its leading zero (wanted $want:00)" >&2; exit 1; }
done

# A workflow whose cron and comment disagree is corrected to the cron. 1.3.0 only
# rewrote the comment on the branch that moved the cron itself, so a project that
# had already moved it (or moved it by hand) kept a comment naming a different
# hour — worse than no comment, because the next reader schedules against it.
DRIFTED="$TMP/comment-drift-$LANGUAGE"
mkdir -p "$DRIFTED/.github/workflows"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$DRIFTED/"
node -e '
  const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8")); m.afk_template_version = "1.3.1";
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$DRIFTED"
cp "$S/scaffold/.sandcastle/profile.ts" "$DRIFTED/.sandcastle/profile.ts"
printf '%s\n' \
  'name: Architecture Review' 'on:' '  schedule:' \
  '    # 09:00 UTC, Monday–Friday. GitHub may delay scheduled runs under load.' \
  '    - cron: "0 16 * * 1-5"' '  workflow_dispatch:' 'jobs:' \
  '  architecture-review:' '    runs-on: self-hosted' \
  '    timeout-minutes: 75' '    steps:' '      - run: echo hi' \
  > "$DRIFTED/.github/workflows/architecture-review.yml"
"$S/upgrade-afk.sh" "$DRIFTED" >/dev/null \
  || { echo "upgrade refused a workflow with a drifted comment" >&2; exit 1; }
grep -q '# 16:00 UTC' "$DRIFTED/.github/workflows/architecture-review.yml" \
  || { echo "the schedule comment was not synced to the active cron" >&2; exit 1; }
# The cron itself is the project's; it must not move.
grep -qE '^\s*- cron: "0 16 \* \* 1-5"' "$DRIFTED/.github/workflows/architecture-review.yml" \
  || { echo "comment sync moved the cron" >&2; exit 1; }

# The 1.2.0 -> 1.3.x path moves a MIGRATED file whose comment hardcoded 09:00.
# Moving the cron alone leaves the file describing a schedule it no longer runs.
COMMENT_MOVE="$TMP/comment-move-$LANGUAGE"
mkdir -p "$COMMENT_MOVE/.github/workflows"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$COMMENT_MOVE/"
node -e '
  const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8")); m.afk_template_version = "1.2.0";
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$COMMENT_MOVE"
cp "$S/scaffold/.sandcastle/profile.ts" "$COMMENT_MOVE/.sandcastle/profile.ts"
# A real-shaped workflow: the 1.3.2 step locates the job by name, so a fixture
# without the job would fail for a reason unrelated to what this asserts.
printf '%s\n' \
  'name: Architecture Review' 'on:' '  schedule:' \
  '    # 09:00 UTC, Monday–Friday. GitHub may delay scheduled runs under load.' \
  '    - cron: "0 9 * * 1-5"' '  workflow_dispatch:' 'jobs:' \
  '  architecture-review:' '    runs-on: self-hosted' \
  '    timeout-minutes: 45' '    steps:' '      - run: echo hi' \
  > "$COMMENT_MOVE/.github/workflows/architecture-review.yml"
"$S/upgrade-afk.sh" "$COMMENT_MOVE" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a 1.2.0 workflow" >&2; exit 1; }
grep -q '# 13:00 UTC' "$COMMENT_MOVE/.github/workflows/architecture-review.yml" \
  || { echo "migration moved the cron but left the comment naming the old hour" >&2; exit 1; }

# A project already at 1.3.0 takes the 1.3.2 budget step ONLY. The 1.3.0 step must
# not re-run on it — re-running the schedule migration on an already-migrated
# workflow is the over-broad gating that once made a 1.2.0 project redo the
# provider migration.
PATCH_TARGET="$TMP/patch-$LANGUAGE"
mkdir -p "$PATCH_TARGET/.github/workflows"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$PATCH_TARGET/"
node -e '
  const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8"));
  m.afk_template_version = "1.3.0"; m.cron_hour = 13;
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$PATCH_TARGET"
cp "$S/scaffold/.sandcastle/profile.ts" "$PATCH_TARGET/.sandcastle/profile.ts"
cp "$S/scaffold/.github/workflows/architecture-review.yml" "$PATCH_TARGET/.github/workflows/"
node -e '
  const fs = require("fs"), p = process.argv[1] + "/.github/workflows/architecture-review.yml";
  let s = fs.readFileSync(p, "utf8").split("__AFK_CRON_HOUR__").join("13")
    .replace("timeout-minutes: 75", "timeout-minutes: 45");
  fs.writeFileSync(p, s);
' "$PATCH_TARGET"
PATCH_OUT="$("$S/upgrade-afk.sh" "$PATCH_TARGET" 2>&1)" \
  || { echo "upgrade refused a 1.3.0 project needing the budget step" >&2; exit 1; }
grep -qE '^\s*timeout-minutes: 75\s*$' "$PATCH_TARGET/.github/workflows/architecture-review.yml" \
  || { echo "the 45m -> 75m budget step did not run" >&2; exit 1; }
if grep -q 'schedule and budget' <<<"$PATCH_OUT"; then
  echo "the 1.3.0 step re-ran on an already-migrated project" >&2; exit 1
fi

# A project that already hand-ported the runner keeps it: the migration follows
# the scaffold's own --no-clobber rule. Overwriting would discard project work
# while reporting success, which is the failure the scaffold copy avoids for
# every other file. Missing files are still added.
HAND_PORTED="$TMP/hand-ported-$LANGUAGE"
mkdir -p "$HAND_PORTED/.github" "$HAND_PORTED/docs" \
         "$HAND_PORTED/.sandcastle/architecture-review"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$HAND_PORTED/"
printf '// hand-ported by the project\n' \
  > "$HAND_PORTED/.sandcastle/architecture-review/architecture-review.ts"
"$S/upgrade-afk.sh" "$HAND_PORTED" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project with a hand-ported runner" >&2; exit 1; }
grep -q 'hand-ported by the project' \
  "$HAND_PORTED/.sandcastle/architecture-review/architecture-review.ts" \
  || { echo "migration overwrote a hand-ported runner file" >&2; exit 1; }
for f in extraction.md prompt.md; do
  [ -f "$HAND_PORTED/.sandcastle/architecture-review/$f" ] \
    || { echo "migration did not add the missing $f alongside a hand-ported one" >&2; exit 1; }
done

# ---- architecture review proposes; the workflow publishes -------------------
# Every architecture-review run past the oldest template opened TWO issues: the
# shipped prompt told the agent to publish via `/to-prd-project` and apply the
# provenance label, while the workflow's own *Publish PRD issue* step built an
# issue from the same `<output>`. Two writers, one run. The agent's copy is also
# the unlabelled one — the skill does not exist in the sandbox, so it falls back
# to `gh issue create` with an `issues=read` token, and the label write 403s.
#
# The fixture reproduces that exact prompt, so the migration is exercised against
# real shipped output rather than a reconstruction of it.
ARCHPROMPT="$TMP/archprompt-$LANGUAGE"
mkdir -p "$ARCHPROMPT/.github/workflows" "$ARCHPROMPT/.sandcastle/architecture-review"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$ARCHPROMPT/"
node -e '
  const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8"));
  // 1.5.0 post-dates the 1.5.1 network-check step, so this run exercises the
  // prompt step alone and not a stack of unrelated migrations.
  m.afk_template_version = "1.5.0"; m.cron_hour = 13;
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$ARCHPROMPT"
cp "$S/scaffold/.sandcastle/profile.ts" "$ARCHPROMPT/.sandcastle/profile.ts"
cp "$S/scaffold/.github/workflows/architecture-review.yml" "$ARCHPROMPT/.github/workflows/"
node -e '
  const fs = require("fs"), p = process.argv[1] + "/.github/workflows/architecture-review.yml";
  fs.writeFileSync(p, fs.readFileSync(p, "utf8")
    .split("__AFK_CRON_HOUR__").join("13")
    .replace("timeout-minutes: 75", "timeout-minutes: 45"));
' "$ARCHPROMPT"
# The fixture is the prompt this template actually SHIPPED (captured before the
# fix), not a hand-written approximation of it. An approximation drifts from the
# real text and then tests an anchor the migration would never match — the
# false-green that makes a migration look verified when it is not.
cp "$S/test/fixtures/architecture-review-buggy/prompt.md" \
   "$ARCHPROMPT/.sandcastle/architecture-review/prompt.md"
# The second half of the same defect: the extract pass asked the agent to report
# the issue it had created. Fixing only the prompt leaves the extract pass asking
# about an issue that no longer exists, and `skipped` is a legal answer.
cp "$S/test/fixtures/architecture-review-buggy/extraction.md" \
   "$ARCHPROMPT/.sandcastle/architecture-review/extraction.md"
# The scaffold must no longer ship that text, or this step has nothing to fix.
# shellcheck disable=SC2016  # the pattern is prompt text; backticks are literal.
if grep -qF -e '4. Publish it via `/to-prd-project`.' \
   "$S/scaffold/.sandcastle/architecture-review/prompt.md"; then
  echo "the scaffold still ships the double-publication prompt" >&2; exit 1
fi
if grep -qF -e 'the issue you created' \
   "$S/scaffold/.sandcastle/architecture-review/extraction.md"; then
  echo "the scaffold's extract pass still asks for the issue the agent created" >&2; exit 1
fi
# And the produce prompt must not ask for `<output>` either: sandcastle's
# `runWithExtraction` runs that phase with no output definition, and its own docs
# say the produce prompt "should contain no JSON-emission instructions". Asking
# for both blocks is the duplication the wrapper exists to remove.
# shellcheck disable=SC2016  # the pattern is prompt text; backticks are literal.
if grep -qF -e 'in your `<output>` block' \
   "$S/scaffold/.sandcastle/architecture-review/prompt.md"; then
  echo "the scaffold's produce prompt still asks for an <output> block" >&2; exit 1
fi
ARCHPROMPT_OUT="$("$S/upgrade-afk.sh" "$ARCHPROMPT" 2>&1)" \
  || { echo "upgrade refused a project needing the prompt step" >&2; exit 1; }
if grep -qF -e '/to-prd-project' "$ARCHPROMPT/.sandcastle/architecture-review/prompt.md"; then
  echo "the migration left the agent publishing its own issue" >&2; exit 1
fi
grep -qF 'Do NOT create the issue yourself' \
  "$ARCHPROMPT/.sandcastle/architecture-review/prompt.md" \
  || { echo "the migrated prompt does not hand publication back to the workflow" >&2; exit 1; }
grep -qF 'report it as a PRD' "$ARCHPROMPT/.sandcastle/architecture-review/prompt.md" \
  || { echo "the migrated prompt still says the agent publishes" >&2; exit 1; }
# shellcheck disable=SC2016  # the pattern is prompt text; backticks are literal.
if grep -qF -e 'emit a `skipped` output and' \
   "$ARCHPROMPT/.sandcastle/architecture-review/prompt.md"; then
  echo "the migrated prompt still asks the produce pass for structured output" >&2; exit 1
fi
# The tail paragraph is the other half of the same instruction: step 4 can be
# converged while the paragraph below still sends the produce pass to the exact
# schema. #57 rewrote step 4 and left this, which is why it is asserted here.
# shellcheck disable=SC2016
if grep -qF -e 'and the exact `<output>` schema' \
   "$ARCHPROMPT/.sandcastle/architecture-review/prompt.md"; then
  echo "the migrated prompt still sends the produce pass to the output schema" >&2; exit 1
fi
grep -qF 'The extraction' "$ARCHPROMPT/.sandcastle/architecture-review/prompt.md" \
  || { echo "the migrated prompt does not hand the schema to the extraction pass" >&2; exit 1; }
grep -qF 'changed: .sandcastle/architecture-review/prompt.md' <<<"$ARCHPROMPT_OUT" \
  || { echo "the migration edited the prompt without reporting it" >&2; exit 1; }
if grep -qF -e 'the issue you created' \
   "$ARCHPROMPT/.sandcastle/architecture-review/extraction.md"; then
  echo "the extract pass still asks for the issue the agent was told not to create" >&2; exit 1
fi
grep -qF 'this becomes the issue title' \
  "$ARCHPROMPT/.sandcastle/architecture-review/extraction.md" \
  || { echo "the extract pass does not describe the workflow as the publisher" >&2; exit 1; }
grep -qF 'changed: .sandcastle/architecture-review/extraction.md' <<<"$ARCHPROMPT_OUT" \
  || { echo "the migration edited the extract prompt without reporting it" >&2; exit 1; }
grep -qE '^\s*timeout-minutes: 75\s*$' "$ARCHPROMPT/.github/workflows/architecture-review.yml" \
  || { echo "the prompt step did not carry the earlier budget step with it" >&2; exit 1; }

# A project that fixed the prompt BY HAND keeps its own wording. AI-Ops and
# genesis-evidence both did, in their own commits with their own rationale.
# Rewriting them would discard that repair and, worse, would re-import this
# scaffold's wording over a prompt already carrying the fix.
HANDFIX="$TMP/handfix-$LANGUAGE"
mkdir -p "$HANDFIX/.github/workflows" "$HANDFIX/.sandcastle/architecture-review"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$HANDFIX/"
node -e '
  const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8"));
  m.afk_template_version = "1.5.0"; m.cron_hour = 13;
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$HANDFIX"
cp "$S/scaffold/.sandcastle/profile.ts" "$HANDFIX/.sandcastle/profile.ts"
cp "$S/scaffold/.github/workflows/architecture-review.yml" "$HANDFIX/.github/workflows/"
node -e '
  const fs = require("fs"), p = process.argv[1] + "/.github/workflows/architecture-review.yml";
  fs.writeFileSync(p, fs.readFileSync(p, "utf8").split("__AFK_CRON_HOUR__").join("13"));
' "$HANDFIX"
printf '# TASK\n\nReport it as structured output — you do not create the issue.\n' \
  > "$HANDFIX/.sandcastle/architecture-review/prompt.md"
printf '# EMIT\n\n"title": "PRD title (the workflow creates the issue from this)"\n' \
  > "$HANDFIX/.sandcastle/architecture-review/extraction.md"
"$S/upgrade-afk.sh" "$HANDFIX" >/dev/null \
  || { echo "upgrade refused a project whose prompt was repaired by hand" >&2; exit 1; }
grep -qF 'Report it as structured output' \
  "$HANDFIX/.sandcastle/architecture-review/prompt.md" \
  || { echo "the migration overwrote a hand-repaired prompt" >&2; exit 1; }
grep -qF 'the workflow creates the issue from this' \
  "$HANDFIX/.sandcastle/architecture-review/extraction.md" \
  || { echo "the migration overwrote a hand-repaired extract prompt" >&2; exit 1; }

# A project that reworded ONE of the two examples and left the other. Gating the
# whole file on a single anchor would call this repaired and skip it, leaving the
# surviving "matches the issue you created" in place — Devin Review's example on
# #57. Each anchor migrates on its own.
PARTIAL="$TMP/partial-extract-$LANGUAGE"
mkdir -p "$PARTIAL/.github/workflows" "$PARTIAL/.sandcastle/architecture-review"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$PARTIAL/"
node -e '
  const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8"));
  m.afk_template_version = "1.5.0"; m.cron_hour = 13;
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$PARTIAL"
cp "$S/scaffold/.sandcastle/profile.ts" "$PARTIAL/.sandcastle/profile.ts"
cp "$S/scaffold/.github/workflows/architecture-review.yml" "$PARTIAL/.github/workflows/"
node -e '
  const fs = require("fs"), p = process.argv[1] + "/.github/workflows/architecture-review.yml";
  fs.writeFileSync(p, fs.readFileSync(p, "utf8").split("__AFK_CRON_HOUR__").join("13"));
' "$PARTIAL"
# Prompt already repair-free, so only the extraction half of the step is under
# test here.
printf '# TASK\n\nReport it as structured output — you do not create the issue.\n' \
  > "$PARTIAL/.sandcastle/architecture-review/prompt.md"
sed 's/"body": "The PRD body you published.",/"body": "The PRD body for the workflow to publish.",/' \
  "$S/test/fixtures/architecture-review-buggy/extraction.md" \
  > "$PARTIAL/.sandcastle/architecture-review/extraction.md"
grep -qF '"title": "PRD title (matches the issue you created)"' \
  "$PARTIAL/.sandcastle/architecture-review/extraction.md" \
  || { echo "the partial fixture lost the legacy title example" >&2; exit 1; }
"$S/upgrade-afk.sh" "$PARTIAL" >/dev/null \
  || { echo "upgrade refused the partial fixture" >&2; exit 1; }
if grep -qF 'the issue you created' \
   "$PARTIAL/.sandcastle/architecture-review/extraction.md"; then
  echo "a reworded body example hid the legacy title instruction" >&2; exit 1
fi
grep -qF 'The PRD body for the workflow to publish.' \
  "$PARTIAL/.sandcastle/architecture-review/extraction.md" \
  || { echo "the migration overwrote the project's reworded body example" >&2; exit 1; }

# An example reworded into words the exact anchors do not match, still naming an
# issue the agent created. Neither anchor fires, both halves read as "already
# migrated", and the file would be stamped with the new version — unreachable by
# any later run. The step must refuse instead of recording a repair it did not do.
RESIDUAL="$TMP/residual-extract-$LANGUAGE"
mkdir -p "$RESIDUAL/.github/workflows" "$RESIDUAL/.sandcastle/architecture-review"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$RESIDUAL/"
node -e '
  const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8"));
  m.afk_template_version = "1.5.0"; m.cron_hour = 13;
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$RESIDUAL"
cp "$S/scaffold/.sandcastle/profile.ts" "$RESIDUAL/.sandcastle/profile.ts"
cp "$S/scaffold/.github/workflows/architecture-review.yml" "$RESIDUAL/.github/workflows/"
node -e '
  const fs = require("fs"), p = process.argv[1] + "/.github/workflows/architecture-review.yml";
  fs.writeFileSync(p, fs.readFileSync(p, "utf8").split("__AFK_CRON_HOUR__").join("13"));
' "$RESIDUAL"
printf '# TASK\n\nReport it as structured output — you do not create the issue.\n' \
  > "$RESIDUAL/.sandcastle/architecture-review/prompt.md"
sed -e 's/"title": "PRD title (matches the issue you created)"/"title": "Title of the issue you created"/' \
    -e 's/"body": "The PRD body you published.",/"body": "The PRD body for the workflow to publish.",/' \
  "$S/test/fixtures/architecture-review-buggy/extraction.md" \
  > "$RESIDUAL/.sandcastle/architecture-review/extraction.md"
if "$S/upgrade-afk.sh" "$RESIDUAL" >/dev/null 2>&1; then
  echo "the migration stamped a project whose extract pass still names the agent's issue" >&2; exit 1
fi

# A project that ran the PREVIOUS revision of the 1.5.2 step. It records 1.5.2 —
# the version that revision stamped — and its prompt already hands publication to
# the workflow (the `/to-prd-project` marker is gone) while step 4 and the tail
# still ask the produce pass for `<output>`. That is the gap #57 left, and the
# version it records is why a wider 1.5.2 step can never reach it: the script
# returns early once the recorded version equals the template version, so the
# 1.5.3 step is the only carrier.
HALFFIX="$TMP/halffix-$LANGUAGE"
mkdir -p "$HALFFIX/.github/workflows" "$HALFFIX/.sandcastle/architecture-review"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$HALFFIX/"
node -e '
  const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8"));
  m.afk_template_version = "1.5.2"; m.cron_hour = 13;
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$HALFFIX"
cp "$S/scaffold/.sandcastle/profile.ts" "$HALFFIX/.sandcastle/profile.ts"
cp "$S/scaffold/.github/workflows/architecture-review.yml" "$HALFFIX/.github/workflows/"
node -e '
  const fs = require("fs"), p = process.argv[1] + "/.github/workflows/architecture-review.yml";
  fs.writeFileSync(p, fs.readFileSync(p, "utf8").split("__AFK_CRON_HOUR__").join("13"));
' "$HALFFIX"
# The text that revision actually shipped, kept as a fixture captured from git
# rather than retyped. A hand-written approximation is the false green this
# fixture exists to avoid.
cp "$S/test/fixtures/architecture-review-1.5.2-prev/prompt.md" \
   "$HALFFIX/.sandcastle/architecture-review/prompt.md"
cp "$S/test/fixtures/architecture-review-1.5.2-prev/extraction.md" \
   "$HALFFIX/.sandcastle/architecture-review/extraction.md"
# shellcheck disable=SC2016  # the pattern is prompt text; backticks are literal.
grep -qF -e 'in your `<output>` block' "$HALFFIX/.sandcastle/architecture-review/prompt.md" \
  || { echo "the half-fixed fixture does not carry the produce-pass output request" >&2; exit 1; }
"$S/upgrade-afk.sh" "$HALFFIX" >/dev/null \
  || { echo "upgrade refused a project holding the previous revision of this step" >&2; exit 1; }
# shellcheck disable=SC2016
if grep -qF -e 'in your `<output>` block' \
   "$HALFFIX/.sandcastle/architecture-review/prompt.md"; then
  echo "a project already stamped 1.5.2 kept the produce-pass output request" >&2; exit 1
fi
# shellcheck disable=SC2016
if grep -qF -e 'and the exact `<output>` schema' \
   "$HALFFIX/.sandcastle/architecture-review/prompt.md"; then
  echo "a project already stamped 1.5.2 kept the schema paragraph" >&2; exit 1
fi
grep -qF 'in prose' "$HALFFIX/.sandcastle/architecture-review/prompt.md" \
  || { echo "the produce-pass prose edit did not reach an already-1.5.2 project" >&2; exit 1; }

# A project still BELOW 1.5. Its run applies the publication step (which inserts
# this scaffold's step 4, asking the produce pass for `<output>`) and the prose
# step in the SAME invocation. Gating the prose step on the version being
# upgraded FROM would strand exactly this project: stamped 1.5.3, with the prompt
# the publication step just installed still requesting structured output, and
# never revisited because the recorded version then equals the template version.
# The gate is therefore on the version being upgraded TO, and this fixture is the
# one that fails if it ever narrows again.
PRE15="$TMP/pre15-$LANGUAGE"
mkdir -p "$PRE15/.github/workflows" "$PRE15/.sandcastle/architecture-review"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$PRE15/"
node -e '
  const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8"));
  // 1.4.0: below the publication step, below the prose step, and old enough that
  // several unrelated migrations run first — the shape a real project arrives in.
  m.afk_template_version = "1.4.0"; m.cron_hour = 13;
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$PRE15"
cp "$S/scaffold/.sandcastle/profile.ts" "$PRE15/.sandcastle/profile.ts"
cp "$S/scaffold/.github/workflows/architecture-review.yml" "$PRE15/.github/workflows/"
node -e '
  const fs = require("fs"), p = process.argv[1] + "/.github/workflows/architecture-review.yml";
  fs.writeFileSync(p, fs.readFileSync(p, "utf8").split("__AFK_CRON_HOUR__").join("13"));
' "$PRE15"
# The prompt this template actually shipped before the fix — the one the
# publication step's anchors were written against.
cp "$S/test/fixtures/architecture-review-buggy/prompt.md" \
   "$PRE15/.sandcastle/architecture-review/prompt.md"
cp "$S/test/fixtures/architecture-review-buggy/extraction.md" \
   "$PRE15/.sandcastle/architecture-review/extraction.md"
"$S/upgrade-afk.sh" "$PRE15" >/dev/null \
  || { echo "upgrade refused a project below 1.5" >&2; exit 1; }
# Asserted against TEMPLATE_VERSION rather than a literal. A literal is a trap
# that fires on the next bump, not on the change that broke anything: this step's
# job is "the run records the version it actually produced", and the version it
# produced is whatever the run was for.
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (m.afk_template_version !== process.argv[2]) {
    console.error("a pre-1.5 project did not reach the template version: " + m.afk_template_version);
    process.exit(1);
  }
' "$PRE15/.afk-bootstrap.json" "$(tr -d '[:space:]' < "$S/TEMPLATE_VERSION")" \
  || { echo "a pre-1.5 project was not stamped with the template version" >&2; exit 1; }
# shellcheck disable=SC2016  # the patterns are prompt text; backticks are literal.
if grep -qF -e 'in your `<output>` block' -e 'and the exact `<output>`' \
   "$PRE15/.sandcastle/architecture-review/prompt.md"; then
  echo "a pre-1.5 project was stamped current with a produce prompt still asking for structured output" >&2; exit 1
fi
grep -qF 'in prose' "$PRE15/.sandcastle/architecture-review/prompt.md" \
  || { echo "the prose step did not reach a project upgraded from below 1.5" >&2; exit 1; }

# A project whose cron this template did NOT write keeps its own schedule, but
# the hour it already occupies must still be recorded. Without that the record
# says the project holds no hour, and the next project on this host reads that
# hour as free and collides with it — provenance is the record's whole purpose.
CUSTOM_CRON="$TMP/custom-cron-$LANGUAGE"
mkdir -p "$CUSTOM_CRON/.github/workflows"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$CUSTOM_CRON/"
node -e '
  const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8")); m.afk_template_version = "1.2.0";
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$CUSTOM_CRON"
cp "$S/scaffold/.sandcastle/profile.ts" "$CUSTOM_CRON/.sandcastle/profile.ts"
cp "$S/scaffold/.github/workflows/architecture-review.yml" "$CUSTOM_CRON/.github/workflows/"
node -e '
  const fs = require("fs"), p = process.argv[1] + "/.github/workflows/architecture-review.yml";
  fs.writeFileSync(p, fs.readFileSync(p, "utf8")
    .split("__AFK_CRON_HOUR__").join("4")            // a readable custom hour
    .replace(/cron: "0 4 /, "cron: \"30 4 "));
' "$CUSTOM_CRON"
"$S/upgrade-afk.sh" "$CUSTOM_CRON" >/dev/null \
  || { echo "upgrade refused a project with its own schedule" >&2; exit 1; }
node -e '
  const fs=require("fs"); const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  if (m.cron_hour !== 4) { console.error("occupied hour was not recorded: " + m.cron_hour); process.exit(1); }
' "$CUSTOM_CRON/.afk-bootstrap.json" \
  || { echo "custom-schedule project did not record its occupied hour" >&2; exit 1; }
grep -qF 'cron: "30 4 ' "$CUSTOM_CRON/.github/workflows/architecture-review.yml" \
  || { echo "upgrade rewrote a schedule the project set" >&2; exit 1; }

# An unreadable schedule shape must be reported, not silently recorded as absent.
UNREADABLE="$TMP/unreadable-cron-$LANGUAGE"
mkdir -p "$UNREADABLE/.github/workflows"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$UNREADABLE/"
node -e '
  const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8")); m.afk_template_version = "1.2.0";
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$UNREADABLE"
cp "$S/scaffold/.sandcastle/profile.ts" "$UNREADABLE/.sandcastle/profile.ts"
cp "$S/scaffold/.github/workflows/architecture-review.yml" "$UNREADABLE/.github/workflows/"
node -e '
  const fs = require("fs"), p = process.argv[1] + "/.github/workflows/architecture-review.yml";
  fs.writeFileSync(p, fs.readFileSync(p, "utf8").split("__AFK_CRON_HOUR__").join("4")
    .replace(/cron: "0 4 /, "cron: \"*/30 4 "));
' "$UNREADABLE"
grep -q 'cannot read an hour from' <<<"$("$S/upgrade-afk.sh" "$UNREADABLE" 2>&1)" \
  || { echo "an unreadable schedule was not reported" >&2; exit 1; }
rm -rf "$UNREADABLE"

# A 1.2.0 project whose profile.ts carries a legitimate project edit must still
# be able to take the schedule upgrade. Re-running the provider step on it would
# refuse the unrecognised shape and block an unrelated change — so the provider
# step must be gated on the project being BELOW 1.2, not merely at-or-below.
CUSTOM="$TMP/custom-profile-$LANGUAGE"
mkdir -p "$CUSTOM/.github/workflows"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$CUSTOM/"
node -e '
  const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8")); m.afk_template_version = "1.2.0";
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$CUSTOM"
cp "$S/scaffold/.sandcastle/profile.ts" "$CUSTOM/.sandcastle/profile.ts"
cp "$S/scaffold/.github/workflows/architecture-review.yml" "$CUSTOM/.github/workflows/"
# A project edit the provider migration does not recognise.
node -e '
  const fs = require("fs"), p = process.argv[1];
  fs.writeFileSync(p, fs.readFileSync(p, "utf8").replace("imageName:", "projectExtra: 1,\n      imageName:"));
' "$CUSTOM/.sandcastle/profile.ts"
"$S/upgrade-afk.sh" "$CUSTOM" --cron-hour 13 >/dev/null \
  || { echo "a customised 1.2.0 profile blocked an unrelated schedule upgrade" >&2; exit 1; }
grep -qE '^\s*timeout-minutes: 75\s*$' "$CUSTOM/.github/workflows/architecture-review.yml" \
  || { echo "customised 1.2.0 project did not receive the budget change" >&2; exit 1; }

# An invalid recorded hour must be refused, not interpolated into the cron: a
# non-integer or out-of-range value would produce an invalid schedule, which
# disables the workflow silently instead of failing.
BAD_HOUR="$TMP/bad-hour-$LANGUAGE"
mkdir -p "$BAD_HOUR/.github/workflows"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$BAD_HOUR/"
node -e '
  const fs = require("fs"), f = process.argv[1] + "/.afk-bootstrap.json";
  const m = JSON.parse(fs.readFileSync(f, "utf8"));
  m.afk_template_version = "1.2.0";   // so the schedule step is the one that runs
  m.cron_hour = 99;
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
' "$BAD_HOUR"
cp "$S/scaffold/.sandcastle/profile.ts" "$BAD_HOUR/.sandcastle/profile.ts"
cp "$S/scaffold/.github/workflows/architecture-review.yml" "$BAD_HOUR/.github/workflows/"
# The fixture carries the placeholder; a bad recorded hour must be refused
# before it is interpolated into the cron.
subst_hour() { node -e '
  const fs=require("fs"); const p=process.argv[1]; const h=process.argv[2];
  fs.writeFileSync(p, fs.readFileSync(p,"utf8").split("__AFK_CRON_HOUR__").join(h));
' "$1" "$2"; }
subst_hour "$BAD_HOUR/.github/workflows/architecture-review.yml" 9
if "$S/upgrade-afk.sh" "$BAD_HOUR" >/dev/null 2>&1; then
  echo "upgrade accepted an out-of-range cron_hour" >&2; exit 1
fi
rm -rf "$BAD_HOUR"

# A 1.1.1 project predates the range's lower bound only by coincidence of
# fixtures; the step applies unchanged, so it must be accepted rather than
# refused for being outside an enumerated list.
OLDEST="$TMP/oldest-$LANGUAGE"
mkdir -p "$OLDEST"; cp -R "$S/test/fixtures/legacy-1.1.x/." "$OLDEST/"
node -e '
  const fs = require("fs"), p = process.argv[1];
  const m = JSON.parse(fs.readFileSync(p, "utf8"));
  m.afk_template_version = "1.1.1";
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");
' "$OLDEST/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$OLDEST" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a 1.1.1 project" >&2; exit 1; }
grep -q 'claude-deepseek)' "$OLDEST/.sandcastle/Dockerfile" \
  || { echo "1.1.1 upgrade did not install the deepseek dispatch arm" >&2; exit 1; }
# Dry run writes nothing.
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const m = JSON.parse(fs.readFileSync(p, "utf8"));
  m.afk_template_version = "1.1.5";
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");
' "$UPGRADE_TARGET/.afk-bootstrap.json"
BEFORE="$(cat "$UPGRADE_TARGET/.sandcastle/Dockerfile")"
"$S/upgrade-afk.sh" "$UPGRADE_TARGET" --dry-run >/dev/null
[ "$BEFORE" = "$(cat "$UPGRADE_TARGET/.sandcastle/Dockerfile")" ] \
  || { echo "dry run wrote to a template file" >&2; exit 1; }
[ "$(node -e 'process.stdout.write(String(require(process.argv[1]).afk_template_version))' "$UPGRADE_TARGET/.afk-bootstrap.json")" = "1.1.5" ] \
  || { echo "dry run wrote the recorded version" >&2; exit 1; }

# A publish that fails after some files are already written must restore every
# one of them. The whole publish phase is otherwise the one place a failure can
# still leave a half-migrated tree, which is what the staging step exists to
# prevent.
PUBLISH_SHIM="$TMP/publish-shim-$LANGUAGE"
mkdir -p "$PUBLISH_SHIM/bin"
cat > "$PUBLISH_SHIM/bin/cp" <<'SHIM'
#!/usr/bin/env bash
# Fail only the metadata publish: it is the copy whose source is the staged
# project and whose name is .afk-bootstrap.json. Backups copy the other way, and
# staging creation copies from the real project, so neither matches.
case "$1" in
  */project/.afk-bootstrap.json) exit 1 ;;
esac
exec /usr/bin/cp "$@"
SHIM
chmod 755 "$PUBLISH_SHIM/bin/cp"

# A rollback must REMOVE a file the migration added, not try to restore a backup
# that never existed — an added file has none.
ADDED_ROLLBACK="$TMP/added-rollback-$LANGUAGE"
mkdir -p "$ADDED_ROLLBACK/.github" "$ADDED_ROLLBACK/docs"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$ADDED_ROLLBACK/"
if PATH="$PUBLISH_SHIM/bin:$PATH" "$S/upgrade-afk.sh" "$ADDED_ROLLBACK" --cron-hour 13 >/dev/null 2>&1; then
  echo "a failing publish was not reported" >&2; exit 1
fi
[ ! -e "$ADDED_ROLLBACK/.sandcastle/architecture-review" ] \
  || { echo "rollback left a file the migration had added" >&2; exit 1; }
ROLLBACK="$TMP/rollback-$LANGUAGE"
mkdir -p "$ROLLBACK/.github/workflows"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$ROLLBACK/"
printf 'name: extra\non: push\n' > "$ROLLBACK/.github/workflows/extra.yml"
ROLLBACK_TREE="$(cd "$ROLLBACK" && find . -type f | sort | xargs md5sum)"
# --cron-hour so the run reaches the publish step: without it the hour refusal
# would fail the run first, and this test would pass for the wrong reason.
if PATH="$PUBLISH_SHIM/bin:$PATH" "$S/upgrade-afk.sh" "$ROLLBACK" --cron-hour 13 >/dev/null 2>&1; then
  echo "publish failure was not reported" >&2; exit 1
fi
[ "$ROLLBACK_TREE" = "$(cd "$ROLLBACK" && find . -type f | sort | xargs md5sum)" ] \
  || { echo "a failed publish did not restore the project" >&2; exit 1; }
[ -d "$ROLLBACK/.github/workflows/workflows" ] \
  && { echo "restoring the workflow directory nested it instead of replacing it" >&2; exit 1; }

# ---- 1.4.0: the domain doc is renamed, not just re-pointed -------------------
# The scaffold prompts this run rewrites now name GLOSSARY.md. Renaming only the
# prompts would point every agent at a file that does not exist, so the project's
# own doc must move with them.
GLOSSARY_TARGET="$TMP/glossary-rename-$LANGUAGE"
mkdir -p "$GLOSSARY_TARGET/.github" "$GLOSSARY_TARGET/docs" "$GLOSSARY_TARGET/.sandcastle"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$GLOSSARY_TARGET/"
printf '# Project glossary\n\n- **Order**: a request to buy.\n' > "$GLOSSARY_TARGET/CONTEXT.md"
# A lookalike name must survive untouched: `\bCONTEXT\.md\b` also matches after a
# hyphen, which would rewrite this reference while the file keeps its own name,
# leaving a pointer to a file that does not exist.
printf 'Read DEPLOYMENT-CONTEXT.md for release terminology.\n' \
  > "$GLOSSARY_TARGET/docs/deploy-notes.md"
# Backticks as the real templates emit them. Built from an octal escape rather
# than written literally, so shellcheck does not read them as command
# substitution. A fixture without them would pass without exercising the anchor.
BT="$(printf '\140')"
printf '# CONTEXT\n\nRead %sCONTEXT.md%s for glossary terms.\n' "$BT" "$BT" \
  > "$GLOSSARY_TARGET/.sandcastle/implement-prompt.md"
GLOSSARY_OUT="$("$S/upgrade-afk.sh" "$GLOSSARY_TARGET" --cron-hour 13)"
[ -e "$GLOSSARY_TARGET/GLOSSARY.md" ] \
  || { echo "upgrade did not rename the domain doc to GLOSSARY.md" >&2; exit 1; }
[ ! -e "$GLOSSARY_TARGET/CONTEXT.md" ] \
  || { echo "upgrade left CONTEXT.md in place after renaming" >&2; exit 1; }
# The glossary is project-owned: renamed, never regenerated from the template.
grep -q 'a request to buy' "$GLOSSARY_TARGET/GLOSSARY.md" \
  || { echo "rename replaced the project's glossary content" >&2; exit 1; }
grep -q 'GLOSSARY\.md' "$GLOSSARY_TARGET/.sandcastle/implement-prompt.md" \
  || { echo "a generated prompt still names the retired filename" >&2; exit 1; }
if grep -q 'CONTEXT\.md' "$GLOSSARY_TARGET/.sandcastle/implement-prompt.md"; then
  echo "a generated prompt still names CONTEXT.md" >&2; exit 1
fi
# The lookalike must be left exactly as written.
grep -q 'DEPLOYMENT-CONTEXT\.md' "$GLOSSARY_TARGET/docs/deploy-notes.md" \
  || { echo "migration rewrote a lookalike filename (DEPLOYMENT-CONTEXT.md)" >&2; exit 1; }
# And the file that still references the old name must be REPORTED, not silently
# left for an agent to trip over. It is project prose, so it is never rewritten.
grep -q 'deploy-notes.md' <<<"$GLOSSARY_OUT" \
  || { echo "migration did not report a project doc still naming CONTEXT.md" >&2; exit 1; }
# Idempotent: a second run has nothing left to rename.
"$S/upgrade-afk.sh" "$GLOSSARY_TARGET" | grep -q 'already at' \
  || { echo "glossary rename broke idempotence" >&2; exit 1; }

# When both names are present the migration must not guess which is current.
# Overwriting either would destroy project content, so it leaves both and says so.
BOTH="$TMP/glossary-both-$LANGUAGE"
mkdir -p "$BOTH/.github" "$BOTH/docs"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$BOTH/"
printf '# old\n' > "$BOTH/CONTEXT.md"
printf '# new\n' > "$BOTH/GLOSSARY.md"
"$S/upgrade-afk.sh" "$BOTH" --cron-hour 13 >/dev/null
if [ ! -e "$BOTH/CONTEXT.md" ] || [ ! -e "$BOTH/GLOSSARY.md" ]; then
  echo "upgrade destroyed one of two competing domain docs" >&2; exit 1
fi
grep -q '# old' "$BOTH/CONTEXT.md" \
  || { echo "upgrade overwrote the original CONTEXT.md" >&2; exit 1; }
grep -q '# new' "$BOTH/GLOSSARY.md" \
  || { echo "upgrade overwrote the existing GLOSSARY.md" >&2; exit 1; }

# A project that predates the rename carries its terms in CONTEXT.md. Bootstrap
# must MOVE that file, not generate a blank template beside it: the generated
# prompts name GLOSSARY.md, so a fresh template would leave every agent reading an
# empty glossary while the real terms sat unused under the old name.
OLD_GLOSSARY_TARGET="$TMP/old-glossary-bootstrap-$LANGUAGE"
mkdir "$OLD_GLOSSARY_TARGET"
git -C "$OLD_GLOSSARY_TARGET" init -q -b main
git -C "$OLD_GLOSSARY_TARGET" remote add origin \
  "https://github.com/kilbertert/fake-old-glossary-$LANGUAGE.git"
printf '# Existing domain terms\n\n- **Order**: a request to buy.\n' \
  > "$OLD_GLOSSARY_TARGET/CONTEXT.md"
"$S/bootstrap-afk.sh" "$OLD_GLOSSARY_TARGET" --language "$LANGUAGE" --no-build >/dev/null
[ -e "$OLD_GLOSSARY_TARGET/GLOSSARY.md" ] \
  || { echo "bootstrap did not produce GLOSSARY.md for a pre-rename project" >&2; exit 1; }
[ ! -e "$OLD_GLOSSARY_TARGET/CONTEXT.md" ] \
  || { echo "bootstrap left CONTEXT.md beside the new GLOSSARY.md" >&2; exit 1; }
grep -q 'a request to buy' "$OLD_GLOSSARY_TARGET/GLOSSARY.md" \
  || { echo "bootstrap replaced the project's existing glossary with a blank template" >&2; exit 1; }

# A project already using the new name must NOT be reported as changed. The
# change report was derived from an unconditional append, so every prompt landed
# in it whether or not the substitution matched — a false "changed" on every run
# and in every dry run.
ALREADY="$TMP/glossary-already-$LANGUAGE"
mkdir -p "$ALREADY/.github" "$ALREADY/docs"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$ALREADY/"
printf '# terms\n' > "$ALREADY/GLOSSARY.md"
printf '# CONTEXT\n\nRead GLOSSARY.md for glossary terms.\n' \
  > "$ALREADY/.sandcastle/implement-prompt.md"
ALREADY_OUT="$("$S/upgrade-afk.sh" "$ALREADY" --cron-hour 13 --dry-run)"
if grep -q 'changed: .sandcastle/implement-prompt.md' <<<"$ALREADY_OUT"; then
  echo "a prompt already naming GLOSSARY.md was reported as changed" >&2; exit 1
fi

# A target path or document name containing a space must still be reported
# correctly. Word-splitting a grep result fragments the path into pieces that
# match no file, so the report named garbage instead of the document to fix.
SPACED_PROSE="$TMP/glossary spaced $LANGUAGE"
mkdir -p "$SPACED_PROSE/.github" "$SPACED_PROSE/docs/old notes"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$SPACED_PROSE/"
printf 'See CONTEXT.md for terms.\n' > "$SPACED_PROSE/docs/old notes/team terms.md"
printf '# t\n' > "$SPACED_PROSE/GLOSSARY.md"
SPACED_OUT="$("$S/upgrade-afk.sh" "$SPACED_PROSE" --cron-hour 13 2>&1)"
grep -qF 'old notes/team terms.md' <<<"$SPACED_OUT" \
  || { echo "a spaced document path was not reported intact" >&2; exit 1; }

echo "$LANGUAGE smoke test passed"

# 1.7.18: the ticket-eligibility pre-flight.
#
# The shape gate refuses a ticket by its POSITION — a leaf, unblocked, not a
# PRD. Nothing ever judged the ticket ITSELF: whether it says what to build and
# what "done" looks like. So `agent:implement` opened a door whose other side
# nobody checked, and — measured across the four consumer repositories — of
# twelve tickets carrying `ready-for-agent`, ONE had acceptance criteria.
#
# Built from the CURRENT scaffold with the added parts removed, not from
# `legacy-1.1.x`: that snapshot predates `implement-prd/`, so a tree built from
# it would exercise the "file absent" path and never the insert itself.
P1718="$TMP/upgrade-1717-ticket-gate-$LANGUAGE"
rm -rf "$P1718"
mkdir -p "$P1718/.sandcastle/implement-prd" "$P1718/.github/workflows" "$P1718/docs/adr"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P1718/"
cp "$S/scaffold/.sandcastle/consensus-contract.json" "$P1718/.sandcastle/"
printf 'FROM node:24\n' > "$P1718/.sandcastle/Dockerfile"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$S/scaffold/.sandcastle/repo-map.check.mjs" "$P1718/.sandcastle/"
python3 - "$S" "$P1718" <<'PREMIG' || { echo "could not build the pre-1.7.18 fixture" >&2; exit 1; }
import pathlib, sys
S, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

prd = (S / "scaffold/.sandcastle/implement-prd/prompt.md").read_text()
lines = prd.split("\n")
at = next(i for i, l in enumerate(lines) if "Do not touch work that belongs" in l)
end = at
while end + 1 < len(lines) and not lines[end + 1].startswith("# "):
    end += 1
out = "\n".join(lines[: at + 1] + lines[end + 1 :])
assert "Source ticket:" not in out, "the strip left the write-back paragraph behind"
(dst / ".sandcastle/implement-prd/prompt.md").write_text(out)

node_md = (S / "templates/implement.node.md").read_text()
out = "\n".join(node_md.split("\n")[:-9])
assert "Source ticket:" not in out, "the strip left the write-back paragraph behind"
(dst / ".sandcastle/implement.md").write_text(out)
PREMIG
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const m = JSON.parse(fs.readFileSync(p, "utf8"));
  m.afk_template_version = "1.7.17";
  m.templateVersion = 1;
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");
' "$P1718/.afk-bootstrap.json"

"$S/upgrade-afk.sh" "$P1718" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.7.17" >&2; exit 1; }

for f in .sandcastle/ticket-check.mjs docs/agents/ticket-contract.md; do
  [ -f "$P1718/$f" ] || { echo "1.7.18 did not add $f" >&2; exit 1; }
done
grep -qF 'Source ticket:' "$P1718/.sandcastle/implement-prd/prompt.md" \
  || { echo "the PRD prompt does not ask for the write-back" >&2; exit 1; }
grep -qF 'Source ticket:' "$P1718/.sandcastle/implement.md" \
  || { echo "the local implement prompt does not ask for the write-back" >&2; exit 1; }

# The insert must land the SAME bytes the scaffold carries. A freshly
# bootstrapped project and an upgraded one have to agree about this rule, or the
# two drift and the divergence is invisible until the next upgrade.
python3 - "$P1718" "$S" <<'IDENT' || { echo "the migrated paragraph differs from the scaffold's" >&2; exit 1; }
import pathlib, sys
def block(p):
    lines = pathlib.Path(p).read_text().split("\n")
    at = next(i for i, l in enumerate(lines) if "came from an outside ticket" in l)
    # Ends on the paragraph's last line. That line changed in 1.7.21 (the
    # handoff was rewritten), so the marker is the closing phrase both versions
    # share rather than a leading word of one of them — the assertion is about
    # the two files agreeing, not about which version they carry.
    end = next(i for i in range(at, len(lines)) if lines[i].endswith("has to rediscover."))
    return lines[at : end + 1]
dst, src = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
if block(dst / ".sandcastle/implement-prd/prompt.md") != block(
    src / "scaffold/.sandcastle/implement-prd/prompt.md"
):
    sys.exit(1)
IDENT

# The published checker, run where it was published.
node "$P1718/.sandcastle/ticket-check.mjs" --self-check >/dev/null \
  || { echo "the published ticket-check fails its own self-check" >&2; exit 1; }

# The workflow pre-flight, asserted on the PARSE rather than on the bytes.
python3 - "$P1718/.github/workflows/agent-implement.yml" <<'WIRED' \
  || { echo "the single-issue workflow was not wired" >&2; exit 1; }
import sys, yaml
steps = list(yaml.safe_load(open(sys.argv[1]))["jobs"].values())[0]["steps"]
names = [s.get("name") for s in steps]
check = "Pre-flight — refuse if the ticket is not implementable"
openpr = "Pre-flight — refuse if an open PR already exists for this issue"
if check not in names or names.index(check) > names.index(openpr):
    sys.exit("the check is missing, or landed after the open-PR pre-flight")
if "ticket-check.mjs --json --strict" not in steps[names.index(check)]["run"]:
    sys.exit("the check step does not run the checker")
if "steps.ticket.outputs.implementable" in str(steps[names.index(openpr)]["if"]):
    sys.exit("the open-PR step is gated on the ticket check, so a refused ticket skips it")
if "steps.ticket.outputs.implementable" not in str(steps[names.index(openpr)]["run"]):
    sys.exit("the open-PR step does not carry the refusal into `refused`")
transition = "Transition labels — remove implement/blocked, add in-progress"
if "preflight.outputs.refused" not in str(steps[names.index(transition)]["if"]):
    sys.exit("the transition step does not gate on the refusal signal")
WIRED

# Negative control: strip the pre-flight and the same predicate must stop
# holding. Without this the block only proves the YAML parses.
# The PRD loop carries the same judgement for each of its leaves, and it must
# SKIP the leaf rather than refuse the PRD: one vaguely-written sub-issue must
# not stop every sibling behind it.
python3 - "$P1718/.github/workflows/agent-implement-prd.yml" <<'PRDWIRED' \
  || { echo "the PRD workflow was not wired" >&2; exit 1; }
import sys, yaml
steps = list(yaml.safe_load(open(sys.argv[1]))["jobs"].values())[0]["steps"]
names = [s.get("name") for s in steps]
skip = "Skip — the selected sub-issue is not implementable"
if skip not in names:
    sys.exit("the skip step is missing")
shape = next(s["run"] for s in steps if str(s.get("name", "")).startswith("Detect"))
for needle in ("ticket-check.mjs --json --strict", 'mode="skip-unimplementable"',
               "ticket_report<<AFK_TICKET_REPORT"):
    if needle not in shape:
        sys.exit(f"the shape step does not carry {needle}")
always = next(s for s in steps if str(s.get("name", "")).startswith("Always remove in-progress"))
if "skip-unimplementable" not in str(always.get("if")):
    sys.exit("a skipped leaf would leave the PRD labelled agent:in-progress forever")
PRDWIRED

NEGW="$TMP/ticket-wire-negative-$LANGUAGE.yml"
cp "$P1718/.github/workflows/agent-implement.yml" "$NEGW"
python3 - "$NEGW" <<'STRIP'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1])
doc = yaml.safe_load(p.read_text())
job = list(doc["jobs"].values())[0]
job["steps"] = [s for s in job["steps"] if not str(s.get("name", "")).startswith("Pre-flight — refuse if the ticket")]
p.write_text(yaml.safe_dump(doc, allow_unicode=True, sort_keys=False))
STRIP
if python3 - "$NEGW" <<'NEGCHK' >/dev/null 2>&1; then
import sys, yaml
names = [
    s.get("name")
    for s in list(yaml.safe_load(open(sys.argv[1]))["jobs"].values())[0]["steps"]
]
sys.exit(0 if "Pre-flight — refuse if the ticket is not implementable" in names else 1)
NEGCHK
  echo "negative control: the pre-flight survived being stripped" >&2; exit 1
fi

# The 1.7.13 step's record is named by a number it recomputes on every run, so
# its guard could never hit: measured, all four consumer repositories carry
# exactly THREE copies, one per upgrade since 1.7.13, and `--all` reports each
# extra as a shared serial. The guard keys on the slug now, and a fourth copy is
# never written.
DUP="$TMP/adr-record-duplicate-$LANGUAGE"
rm -rf "$DUP"
mkdir -p "$DUP/.sandcastle" "$DUP/.github/workflows" "$DUP/docs/adr"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$DUP/"
cp "$S/scaffold/.sandcastle/consensus-contract.json" "$DUP/.sandcastle/"
printf 'FROM node:24\n' > "$DUP/.sandcastle/Dockerfile"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$S/scaffold/.sandcastle/repo-map.check.mjs" "$DUP/.sandcastle/"
for n in 0007 0008 0009; do
  cp "$S/references/adr-self-application.md" "$DUP/docs/adr/$n-adr-check-scope-and-self-application.md"
done
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const m = JSON.parse(fs.readFileSync(p, "utf8"));
  m.afk_template_version = "1.7.12";
  m.templateVersion = 1;
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");
' "$DUP/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$DUP" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project already carrying the record" >&2; exit 1; }
count_records() {
  n=0
  for f in "$DUP"/docs/adr/*adr-check-scope-and-self-application.md; do
    [ -e "$f" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}
[ "$(count_records)" = "3" ] \
  || { echo "the step wrote a fourth copy of the self-application record" >&2; exit 1; }
# Negative control: with no copy present, one is still written — otherwise the
# guard above proves only that the step does nothing at all.
rm -f "$DUP"/docs/adr/*adr-check-scope*
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const m = JSON.parse(fs.readFileSync(p, "utf8"));
  m.afk_template_version = "1.7.12";
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");
' "$DUP/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$DUP" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project with no record" >&2; exit 1; }
[ "$(count_records)" = "1" ] \
  || { echo "the step did not write the record it still owes a project" >&2; exit 1; }

# 1.7.19: both duties reach every live prompt, and the search insert stops
# stacking copies.
#
# Three defects in what 1.7.18 shipped, all measured on the four consumer
# repositories. The fixture is built from the CURRENT scaffold and then broken
# in exactly the ways those repositories were broken: the search duty
# quadrupled in the three prompts 1.7.13 reached, absent from the two it did
# not; the write-back duty present only in the two 1.7.18 named.
P1719="$TMP/upgrade-1718-all-prompts-$LANGUAGE"
rm -rf "$P1719"
mkdir -p "$P1719/.sandcastle/implement-prd" "$P1719/.sandcastle/implement" \
         "$P1719/.sandcastle/implement-pr" "$P1719/.github/workflows" "$P1719/docs/adr"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P1719/"
cp "$S/scaffold/.sandcastle/consensus-contract.json" "$P1719/.sandcastle/"
printf 'FROM node:24\n' > "$P1719/.sandcastle/Dockerfile"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$S/scaffold/.sandcastle/repo-map.check.mjs" "$P1719/.sandcastle/"
python3 - "$S" "$P1719" "$LANGUAGE" <<'BREAK1718' || { echo "could not build the 1.7.18-state fixture" >&2; exit 1; }
import pathlib, sys
S, dst, lang = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]

SEARCH_HEAD = "Before you settle on an approach, search what this repository has already"
SEARCH_TAIL = "yourself — do not spend a human's time on them."
WRITE_MID = " came from an outside ticket"
# The paragraph's closing phrase, shared by every version of it — the 1.7.21
# rewrite changed the lines above it, not that one.
WRITE_TAIL = "has to rediscover."

# `.sandcastle/implement.md` is the per-language render of
# `templates/implement.<lang>.md` (bootstrap copies it there); the other four
# ship from `scaffold/`. Reading each from where it actually comes from is the
# point of the test — a fixture built from the wrong source exercises the wrong
# insert.
SCAFFOLD = S / "scaffold/.sandcastle"
SOURCE = {
    "implement.md": S / f"templates/implement.{lang}.md",
    "implement-prompt.md": SCAFFOLD / "implement-prompt.md",
    "implement/prompt.md": SCAFFOLD / "implement/prompt.md",
    "implement-pr/prompt.md": SCAFFOLD / "implement-pr/prompt.md",
    # Rendered from the template, like implement.md above: `bootstrap-afk.sh:130`
    # copies `templates/prompt.<lang>.md` here. The scaffold's own copy of this
    # path is NOT what a project carries — it has no `policy-check.mjs commit`
    # line at all, so a fixture built from it exercises the "no anchor" path
    # while the real repository has the anchor and gets the paragraph. Measured:
    # this is the difference that made the smoke fail on all four real repos'
    # shape while passing on the wrong one.
    "implement-prd/prompt.md": S / f"templates/prompt.{lang}.md",
}


def span(t, head, tail):
    """(start, end) of the paragraph from `head` through `tail`, blank line first."""
    i = t.index(head)
    if t[i - 1] == "\n" and t[i - 2] == "\n":
        i -= 1
    return i, t.index(tail, i) + len(tail)


def drop(t, head, tail):
    while head in t:
        i, j = span(t, head, tail)
        if t[j : j + 1] == "\n":
            j += 1
        t = t[:i] + t[j:]
    return t


def drop_write(t):
    # The paragraph opens with "If " — but so does the sentence before it in
    # some prompts, so the start is found from the phrase that identifies it
    # and then walked back to the paragraph break.
    while WRITE_MID in t:
        k = t.index(WRITE_MID)
        i = t.rindex("\n\n", 0, k) + 2
        j = t.index(WRITE_TAIL, k) + len(WRITE_TAIL)
        if t[j : j + 1] == "\n":
            j += 1
        t = t[:i] + t[j:]
    return t


for rel, src in SOURCE.items():
    p = dst / ".sandcastle" / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    t = src.read_text()

    if rel in ("implement.md", "implement/prompt.md", "implement-prd/prompt.md"):
        # 1.7.13 reached these: keep the duty, add the duplicates it left. The
        # count is what the four consumer repositories actually carry.
        i, j = span(t, SEARCH_HEAD, SEARCH_TAIL)
        block = t[i:j]
        t = t[:j] + "\n\n" + block + "\n\n" + block + "\n\n" + block + t[j:]
    else:
        t = drop(t, SEARCH_HEAD, SEARCH_TAIL)

    if rel not in ("implement.md", "implement-prd/prompt.md"):
        t = drop_write(t)

    p.write_text(t)

for rel, n_search, n_write in (
    ("implement.md", 4, 1),
    ("implement/prompt.md", 4, 0),
    ("implement-prd/prompt.md", 4, 1),
    ("implement-prompt.md", 0, 0),
    ("implement-pr/prompt.md", 0, 0),
):
    t = (dst / ".sandcastle" / rel).read_text()
    assert t.count("do not spend a human's time on them.") == n_search, (rel, t.count("do not spend"))
    # Counts PARAGRAPHS, not occurrences of `Source ticket:`. The 1.7.21 rewrite
    # names that line twice inside one paragraph (the commit body, and the
    # top-level comment for a reply-only run), so a token count would read 2 for
    # a file that carries the duty once. Measured; this assertion is what caught
    # the difference between "the duty is present" and "the string occurs".
    assert t.count("came from an outside ticket") == n_write, (rel, t.count("came from an outside ticket"))
BREAK1718
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const m = JSON.parse(fs.readFileSync(p, "utf8"));
  m.afk_template_version = "1.7.18";
  m.templateVersion = 1;
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");
' "$P1719/.afk-bootstrap.json"

"$S/upgrade-afk.sh" "$P1719" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.7.18" >&2; exit 1; }

# Every live prompt carries both duties exactly once. `exactly once` is the
# assertion, not `at least once`: the defect being fixed is the duplicate, and
# an `at least` test would have passed on all four damaged repositories.
python3 - "$P1719" <<'BOTH' || { echo "1.7.19 did not give every prompt both duties" >&2; exit 1; }
import pathlib, sys
root = pathlib.Path(sys.argv[1]) / ".sandcastle"
# The five promptFiles an AFK run actually loads, and who loads each.
LIVE = {
    "implement.md": "main.ts — local `npm run afk`",
    "implement-prompt.md": "planner.ts",
    "implement/prompt.md": "implement.ts — the labelled issue (Actions)",
    "implement-pr/prompt.md": "implement-pr.ts — PR feedback",
    "implement-prd/prompt.md": "implement-prd.ts — PRD loop (Actions)",
}
for rel, who in LIVE.items():
    t = (root / rel).read_text()
    assert t.count("do not spend a human's time on them.") == 1, (
        f"{rel} ({who}): search duty appears {t.count('do not spend a human' + chr(39) + 's time on them.')} times, not once"
    )
    # Paragraphs, not tokens: the 1.7.21 text names `Source ticket:` twice inside
    # one paragraph. Counting the token made this assertion read 2 on a correct
    # file, which is why it is the OPENER that is counted.
    assert t.count("came from an outside ticket") == 1, (
        f"{rel} ({who}): write-back duty appears {t.count('came from an outside ticket')} times, not once"
    )
BOTH

# The paragraph the migration inserts must be the SAME BYTES the bootstrap
# renders, or a freshly bootstrapped project and an upgraded one disagree about
# the rule. Compared against the template, which is what bootstrap copies.
python3 - "$P1719" "$S" <<'SAME' || { echo "the migrated duties differ from the scaffold's" >&2; exit 1; }
import pathlib, sys
dst, src = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

def para(path, head, tail):
    t = path.read_text()
    i = t.index(head)
    j = t.index(tail, i) + len(tail)
    return t[i:j]

for rel in ("implement-prompt.md", "implement/prompt.md", "implement-pr/prompt.md"):
    for head, tail in (
        ("Before you settle on an approach", "do not spend a human's time on them."),
        ("came from an outside ticket", "has to rediscover."),
    ):
        got = para(dst / ".sandcastle" / rel, head, tail)
        want = para(src / "scaffold/.sandcastle" / rel, head, tail)
        assert got == want, f"{rel}: {head[:30]}… differs from the scaffold"
SAME

# Negative control: with the duties already in place and correct, a second run
# is a no-op — it must not add a second copy. Without this the block above
# proves only that one run inserts something.
cp -R "$P1719" "$P1719-again"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.7.18";
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P1719-again/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P1719-again" --cron-hour 13 >/dev/null \
  || { echo "the re-run refused a project it had just migrated" >&2; exit 1; }
python3 - "$P1719-again" <<'IDEM' || { echo "a second run stacked a duplicate duty" >&2; exit 1; }
import pathlib, sys
root = pathlib.Path(sys.argv[1]) / ".sandcastle"
for rel in ("implement.md", "implement-prompt.md", "implement/prompt.md",
            "implement-pr/prompt.md", "implement-prd/prompt.md"):
    t = (root / rel).read_text()
    assert t.count("do not spend a human's time on them.") == 1, rel
    assert t.count("came from an outside ticket") == 1, rel
IDEM

echo "1.7.19 smoke checks passed"

# 1.7.19 negative control on the markdown tool itself: a project that reworded
# the paragraph keeps its wording and does NOT get the template's copy added on
# top. The first version of `add-search-duty.mjs` keyed its presence test on the
# paragraph's CLOSING line; against a copy whose last line had been replaced it
# did not match, and the tool appended a second paragraph beside the project's
# own. Measured, not hypothesised — which is why the assertion is here.
PWORD="$TMP/search-duty-reworded-$LANGUAGE"
rm -rf "$PWORD"
mkdir -p "$PWORD"
git -C "$S" show HEAD:scaffold/.sandcastle/implement/prompt.md > "$PWORD/prompt.md" \
  || { echo "could not read the scaffold prompt from HEAD" >&2; exit 1; }
# Give it the duty the way an upgrade would, then let the project reword it.
# `|| true` because this script runs under `set -e` and this tool exits 4 —
# "already present" — which is a SUCCESS here, not a failure to abort on.
node "$S/tools/add-search-duty.mjs" "$PWORD/prompt.md" \
  "node .sandcastle/policy-check.mjs commit" >/dev/null 2>&1 || true
python3 - "$PWORD/prompt.md" <<'REWORD' || { echo "could not reword the fixture" >&2; exit 1; }
import pathlib, sys
p = pathlib.Path(sys.argv[1])
# The OPENING line, which is the case that defeats a single nominated marker:
# the first version of this test reworded the CLOSING line, and the tool's
# replacement marker was the OPENING — so the test passed while the defect it
# was meant to catch (reword one line, get a second copy) still reproduced.
old = "Before you settle on an approach, search what this repository has already"
t = p.read_text()
assert t.count(old) == 1, "the fixture did not carry the duty exactly once"
p.write_text(t.replace(old, "Before choosing an approach, review the repository's ADRs"))
REWORD
node "$S/tools/add-search-duty.mjs" "$PWORD/prompt.md" \
  "node .sandcastle/policy-check.mjs commit" >/dev/null 2>&1 || true
# rc is 4 (already there); the assertion is on the CONTENT, because rc alone
# would also be 4 for a file the tool wrongly recognised as untouched.
python3 - "$PWORD/prompt.md" <<'KEPT' || { echo "a reworded prompt was given a second copy of the duty" >&2; exit 1; }
import pathlib, sys
t = pathlib.Path(sys.argv[1]).read_text()
assert t.count("Before choosing an approach, review the repository's ADRs") == 1, (
    "the project's wording was moved or duplicated"
)
# The template's own opening must NOT be present: its absence is what proves no
# second paragraph was inserted beside the project's.
assert "Before you settle on an approach, search what this repository has already" not in t, (
    "the template's copy was added beside the project's reworded one"
)
KEPT

echo "1.7.19 markdown-tool checks passed"

# 1.7.20: the search duty goes after the list item, not inside it.
#
# 1.7.19 inserted at `anchor + 1`. In `.sandcastle/implement-pr/prompt.md` the
# anchor is step 3 of a numbered list and step 3 continues for four indented
# lines, so the paragraph landed BETWEEN the item and its own continuation —
# the verification instruction orphaned from the step it belongs to. Measured on
# health-flow after the rollout; Devin Review reported it on that PR.
#
# The fixture is the shape the four consumer repositories actually carry: one
# copy, in the wrong place.
PIN="$TMP/upgrade-1719-pr-item-$LANGUAGE"
rm -rf "$PIN"
mkdir -p "$PIN/.sandcastle/implement-pr"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$PIN/"
cp "$S/scaffold/.sandcastle/consensus-contract.json" "$PIN/.sandcastle/"
printf 'FROM node:24\n' > "$PIN/.sandcastle/Dockerfile"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$S/scaffold/.sandcastle/repo-map.check.mjs" "$PIN/.sandcastle/"
# The 1.7.19 state of this prompt, reproduced by inserting the paragraph after
# the anchor line — which is exactly the defect, and reproduces BOTH of its
# halves: the paragraph lands between step 3 and step 3's continuation, and it
# lands with no blank line before whatever follows.
python3 - "$S" "$PIN" <<'MISPLACED' || { echo "could not build the 1.7.19-state fixture" >&2; exit 1; }
import pathlib, sys
S, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
BLOCK = [
    "Before you settle on an approach, search what this repository has already",
    'decided: `rg -i "<机制名或关键词>" docs/adr/`, and read the two or three records',
    "whose titles touch the area. Facts the code or those records can answer, answer",
    "yourself — do not spend a human's time on them.",
]
t = (S / "scaffold/.sandcastle/implement-pr/prompt.md").read_text()
assert t.count(BLOCK[0]) == 1, "the scaffold prompt no longer carries the duty once"
assert "   If the repo has a project verification skill" in t, (
    "the scaffold prompt no longer has step 3's continuation — this test is stale"
)
# Strip the paragraph and the blank line the scaffold now puts in front of it,
# then re-insert it the way 1.7.19 did: straight after the anchor line, no blank
# on either side.
i = t.index(BLOCK[0])
j = t.index(BLOCK[-1], i) + len(BLOCK[-1])
stripped = t[:i].rstrip("\n") + "\n" + t[j:].lstrip("\n")
at = stripped.index("3. Make the code changes")
end = stripped.index("\n", at) + 1
out = stripped[:end] + "\n".join(BLOCK) + "\n" + stripped[end:]
assert out.index("3. Make the code changes") < out.index(BLOCK[0]), "fixture is not misplaced"
assert out.index(BLOCK[0]) < out.index("   If the repo has"), "continuation must follow the paragraph"
# The continuation directly follows the paragraph with no blank — that IS the
# tail-blank case. Without the fix, step 3's own continuation is swallowed into
# the paragraph and stops being part of step 3.
assert BLOCK[-1] + "\n   If the repo has" in out, (
    "fixture must put the continuation directly after the paragraph"
)
(dst / ".sandcastle/implement-pr/prompt.md").write_text(out)
MISPLACED
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const m = JSON.parse(fs.readFileSync(p, "utf8"));
  m.afk_template_version = "1.7.19";
  m.templateVersion = 1;
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");
' "$PIN/.afk-bootstrap.json"

"$S/upgrade-afk.sh" "$PIN" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.7.19" >&2; exit 1; }

python3 - "$PIN" <<'ITEMEND' || { echo "1.7.20 left the duty inside step 3" >&2; exit 1; }
import pathlib, sys
t = (pathlib.Path(sys.argv[1]) / ".sandcastle/implement-pr/prompt.md").read_text()
assert t.count("do not spend a human's time on them.") == 1, "the duty is not there exactly once"
item = t.index("3. Make the code changes")
cont = t.index("   If the repo has a project verification skill")
duty = t.index("Before you settle on an approach")
nxt = t.index("4. If you made no changes")
assert item < cont < duty < nxt, (
    f"order is item@{item} continuation@{cont} duty@{duty} next@{nxt} — "
    "the continuation must stay with the item, before the paragraph"
)
# The paragraph must be followed by a BLANK line, or step 4 is swallowed into it
# and stops being a list item. Text order alone does not catch that: the first
# version of this assertion passed while `4.` rendered as body text.
lines = t.split("\n")
end = next(i for i, l in enumerate(lines) if l.startswith("yourself — do not spend"))
assert lines[end + 1] == "", (
    f"line after the paragraph is {lines[end + 1]!r} — step 4 needs a blank line"
)
ITEMEND

# Re-run: repairing a misplaced paragraph must be idempotent. The negative
# control above mutates a string in memory, which says nothing about a second
# upgrade pass over the same tree.
cp "$PIN/.sandcastle/implement-pr/prompt.md" "$PIN/before-rerun.md"
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const m = JSON.parse(fs.readFileSync(p, "utf8"));
  m.afk_template_version = "1.7.19";
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");
' "$PIN/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$PIN" --cron-hour 13 >/dev/null \
  || { echo "the re-run refused a project it had just migrated" >&2; exit 1; }
cmp -s "$PIN/before-rerun.md" "$PIN/.sandcastle/implement-pr/prompt.md" \
  || { echo "a second upgrade changed a correctly-placed paragraph" >&2; exit 1; }

# Negative control: put the duty back inside the item and the predicate above
# must stop holding. Written as a reusable predicate so the control and the
# assertion cannot disagree about what "correct" means.
python3 - "$PIN/.sandcastle/implement-pr/prompt.md" <<'REBREAK'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); t = p.read_text()
d = t.index("Before you settle on an approach")
e = t.index("do not spend a human's time on them.", d) + len("do not spend a human's time on them.")
block = t[d:e]
t = t[: d - 1] + t[e:]
at = t.index("3. Make the code changes")
end = t.index("\n", at) + 1
t = t[:end] + "\n" + block + "\n" + t[end:]
# The same order test the assertion uses. It MUST be False now.
ok = (t.index("3. Make the code changes") < t.index("   If the repo has a project verification skill")
      < t.index("Before you settle on an approach") < t.index("4. If you made no changes"))
sys.exit(1 if ok else 0)
REBREAK

# A missing anchor must leave the paragraph ALONE. The tool used to delete the
# copies and exit 3, on the reasoning that the upgrade only warns — but the
# upgrade then publishes, so an instruction disappeared from a project-owned
# prompt and the version was stamped anyway. Measured: rc=3, paragraph 1 -> 0.
NANCHOR="$TMP/search-duty-no-anchor-$LANGUAGE"
rm -rf "$NANCHOR"; mkdir -p "$NANCHOR"
cp "$S/scaffold/.sandcastle/implement-pr/prompt.md" "$NANCHOR/prompt.md"
# The project renamed the policy-check command, so the anchor is gone while the
# search paragraph it already has is untouched.
python3 - "$NANCHOR/prompt.md" <<'RENAME' || { echo "could not reword the anchor" >&2; exit 1; }
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
assert t.count("node .sandcastle/policy-check.mjs commit") == 1
p.write_text(t.replace("node .sandcastle/policy-check.mjs commit", "node .sandcastle/policy-check.mjs verify-then-commit"))
RENAME
cp "$NANCHOR/prompt.md" "$NANCHOR/before.md"
node "$S/tools/add-search-duty.mjs" "$NANCHOR/prompt.md" "node .sandcastle/policy-check.mjs commit" >/dev/null 2>&1 || true
cmp -s "$NANCHOR/before.md" "$NANCHOR/prompt.md" \
  || { echo "a missing anchor let the tool edit the file anyway" >&2; exit 1; }
grep -q "do not spend a human's time on them." "$NANCHOR/prompt.md" \
  || { echo "the search duty was removed by a run that could not place it" >&2; exit 1; }

echo "1.7.20 item-placement checks passed"

# 1.7.21: the handoff names something that exists, and the host keeps its side.
#
# The paragraph 1.7.18 introduced asked the agent for "the branch, the pull
# request, and which acceptance criteria this change satisfies" — and the pull
# request does not exist when the commit is made. The host opens it afterwards.
# Its second hole: the commit body was the only carrier, and `implement-pr`
# accepts a run with replies and zero commits.
P1721="$TMP/upgrade-1720-handoff-$LANGUAGE"
rm -rf "$P1721"
mkdir -p "$P1721/.sandcastle/implement-pr" "$P1721/.sandcastle/implement-prd" \
         "$P1721/.sandcastle/implement" "$P1721/.github/workflows" "$P1721/docs/agents"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$P1721/"
cp "$S/scaffold/.sandcastle/consensus-contract.json" "$P1721/.sandcastle/"
printf 'FROM node:24\n' > "$P1721/.sandcastle/Dockerfile"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$S/scaffold/.sandcastle/repo-map.check.mjs" "$P1721/.sandcastle/"
cp "$S/references/ticket-contract.1.7.18.md" "$P1721/docs/agents/ticket-contract.md"
# The 1.7.20-state workflow, from the REFERENCE the step's own restage compares
# against — not from HEAD. Measured in CI: `git show HEAD:` reads the MERGE commit
# of this PR, which already carries the change, so a fixture built that way has
# nothing to strip and the assertions pass on a tree that was never in the state
# they claim to test. That is the "a reference that tracks HEAD anchors nothing"
# failure in this repository's own record of the 1.7.12 migration.
cp "$S/references/agent-implement.1.7.20.yml" "$P1721/.github/workflows/agent-implement.yml"
python3 - "$P1721" "$S" "$LANGUAGE" <<'PRE1721' || { echo "could not build the 1.7.20-state fixture" >&2; exit 1; }
import pathlib, sys, yaml
dst, S, lang = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]

# The prompts as 1.7.20 shipped them: the OLD handoff paragraph. Taken from the
# reference the old text is preserved in, not assembled by hand.
OLD = (
    "If {sub} came from an outside ticket — a requirements platform, a chat\n"
    "thread, a support queue — that ticket is where someone is waiting. When the work\n"
    "is done, write back to it: the branch, the pull request, and which acceptance\n"
    "criteria this change satisfies. You cannot post to a system this sandbox does not\n"
    "reach; record the text in the commit body under `Source ticket:` and the host\n"
    "runner or the human who owns that ticket posts it. A result that stays in this\n"
    "repository is one the next person to open that ticket has to rediscover."
)
NEW_MARK = "Record its identifier and the acceptance criteria"

SOURCES = {
    "implement.md": S / f"templates/implement.{lang}.md",
    "implement-prompt.md": S / "scaffold/.sandcastle/implement-prompt.md",
    "implement/prompt.md": S / "scaffold/.sandcastle/implement/prompt.md",
    "implement-pr/prompt.md": S / "scaffold/.sandcastle/implement-pr/prompt.md",
    "implement-prd/prompt.md": S / f"templates/prompt.{lang}.md",
}
SUBJECTS = {
    "implement.md": "this work",
    "implement-prompt.md": "this work",
    "implement/prompt.md": "this work",
    "implement-pr/prompt.md": "this change",
    "implement-prd/prompt.md": "this sub-issue",
}
for rel, src in SOURCES.items():
    p = dst / ".sandcastle" / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    t = src.read_text()
    assert NEW_MARK in t, f"{rel}: the scaffold no longer carries the corrected handoff"
    # Replace the NEW paragraph with the OLD one, by lines, so the fixture is the
    # pre-1.7.21 text exactly.
    new = t[t.index("If " + SUBJECTS[rel] + " came from an outside ticket"):
            t.index("has to rediscover.", t.index("came from an outside ticket"))
            + len("has to rediscover.")]
    assert NEW_MARK in new, f"{rel}: the new paragraph was not found"
    t = t.replace(new, OLD.format(sub=SUBJECTS[rel]), 1)
    assert "the branch, the pull request" in t, f"{rel}: the old text was not restored"
    p.write_text(t)

# The reference IS the pre-1.7.21 state. Assert that rather than assuming it: a
# reference that has drifted to the post-change shape would make every assertion
# below vacuous, and that is exactly the failure mode this file's own history
# warns about.
wf = dst / ".github/workflows/agent-implement.yml"
text = wf.read_text()
assert "ticket-writeback.sh" not in text, "the reference already calls the write-back — stale"
assert 'echo "pr_url=' not in text, "the reference already exports pr_url — stale"
steps = [str(s.get("name", ""))
         for s in list(yaml.safe_load(text)["jobs"].values())[0]["steps"]]
assert "Write the delivery link back to the issue" not in steps, "the reference already has the step"
PRE1721
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const m = JSON.parse(fs.readFileSync(p, "utf8"));
  m.afk_template_version = "1.7.20";
  m.templateVersion = 1;
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");
' "$P1721/.afk-bootstrap.json"

"$S/upgrade-afk.sh" "$P1721" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project at 1.7.20" >&2; exit 1; }

python3 - "$P1721" <<'HANDOFF1721' || { echo "1.7.21 did not fix the handoff" >&2; exit 1; }
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for rel in ("implement.md", "implement-prompt.md", "implement/prompt.md",
            "implement-pr/prompt.md", "implement-prd/prompt.md"):
    t = (root / ".sandcastle" / rel).read_text()
    # The thing the agent cannot know is gone.
    assert "the branch, the pull request, and which acceptance" not in t, (
        f"{rel}: still asks for the pull request the agent cannot know"
    )
    # And the replacement is there, once.
    assert t.count("Record its identifier and the acceptance criteria") == 1, rel
    # The reply-only path has a carrier.
    assert "top-level PR comment" in t, f"{rel}: no carrier for a reply-only run"
handoff = (root / "docs/agents/ticket-contract.md").read_text()
assert "Do not try to name the pull request" in handoff, "the convention doc was not restaged"
HANDOFF1721

# The host's half is present, and the workflow calls it AFTER the PR exists.
python3 - "$P1721" <<'WIRED1721' || { echo "1.7.21 did not wire the host's half" >&2; exit 1; }
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
script = root / ".sandcastle/ticket-writeback.sh"
assert script.is_file(), "the write-back script was not added"
assert script.stat().st_mode & 0o100, "the write-back script is not executable by its owner"
steps = list(yaml.safe_load((root / ".github/workflows/agent-implement.yml").read_text())["jobs"].values())[0]["steps"]
names = [str(s.get("name", "")) for s in steps]
wb = "Write the delivery link back to the issue"
assert wb in names, "the write-back step was not added"
openpr = next(i for i, s in enumerate(steps) if s.get("id") == "open_pr")
assert openpr < names.index(wb), "the write-back runs before the pull request exists"
step = steps[names.index(wb)]
assert "PR_URL" in (step.get("env") or {}), "the step does not receive the PR URL"
WIRED1721

# Negative control: strip the write-back step and the same predicate must stop
# holding, or the block proves only that the file parses.
NEGWB="$TMP/handoff-negative-$LANGUAGE.yml"
cp "$P1721/.github/workflows/agent-implement.yml" "$NEGWB"
python3 - "$NEGWB" <<'STRIPWB'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1])
doc = yaml.safe_load(p.read_text())
job = list(doc["jobs"].values())[0]
job["steps"] = [s for s in job["steps"] if s.get("name") != "Write the delivery link back to the issue"]
p.write_text(yaml.safe_dump(doc, allow_unicode=True, sort_keys=False))
STRIPWB
if python3 - "$NEGWB" <<'NEGWB' >/dev/null 2>&1; then
import sys, yaml
names = [str(s.get("name", "")) for s in list(yaml.safe_load(open(sys.argv[1]))["jobs"].values())[0]["steps"]]
sys.exit(0 if "Write the delivery link back to the issue" in names else 1)
NEGWB
  echo "negative control: the write-back step survived being stripped" >&2; exit 1
fi

echo "1.7.21 handoff checks passed"

# 1.7.22: the alternatives detector accepts an inline carrier, and the sweep
# stops demanding the one fix its own convention forbids.
#
# Two defects, both measured:
#
#   1. `ALTERNATIVES_RE` required a HEADING. AI-Ops 0006 line 15 carries
#      "- 被否掉的替代形态：(a) …；(b) …；(c) …" — the exact phrase the regex hunts
#      for, with three rejected options and their reasons — and the check reported
#      "no alternatives section … a record of what was chosen and not what was
#      rejected". The message was false about that record. 3 records on this host
#      are in that shape; the other 11 genuinely have no weighing.
#
#   2. `--all` FAILED on a record whose alternatives section is absent, while the
#      convention says those records "are not worth a mechanical rewrite, and
#      nobody should invent alternatives a record never weighed just to turn a
#      check green". A gate whose only honest exits are fabrication or deletion is
#      enforcing the opposite of the rule.
P1722="$TMP/adr-tiers-$LANGUAGE"
rm -rf "$P1722"
mkdir -p "$P1722/docs/adr"
cp "$S/scaffold/.sandcastle/adr.check.mjs" "$P1722/adr.check.mjs"
git -C "$P1722" init -q -b work
git -C "$P1722" config user.email t@e.x
git -C "$P1722" config user.name t
cat > "$P1722/docs/adr/0001-baseline.md" <<'ADR'
# Baseline

Status: Accepted

## Decision
x

## Alternatives Considered
- Option B: its strongest case is …, and it lost because …
ADR
git -C "$P1722" add -A
git -C "$P1722" -c commit.gpgsign=false commit -qm "chore: baseline"
git -C "$P1722" branch -q main

adr_run() { ( cd "$P1722" && node adr.check.mjs "$@" ) >/tmp/adr-out 2>&1; echo $?; }

# (a) An inline carrier counts. No heading; the phrase rides a list item.
cat > "$P1722/docs/adr/0002-inline.md" <<'ADR'
# Inline carrier

Status: Accepted

## Decision
x

## Consequences
- 被否掉的替代形态：(a) 由入口中介——多一次往返；(b) 维护白名单——需要一份不在我们手里的清单。
ADR
[ "$(adr_run --all)" = "0" ] \
  || { echo "an inline alternatives carrier was not recognised" >&2; cat /tmp/adr-out >&2; exit 1; }
grep -q "0002-inline" /tmp/adr-out \
  && { echo "a record with an inline carrier was still reported" >&2; cat /tmp/adr-out >&2; exit 1; }
rm "$P1722/docs/adr/0002-inline.md"

# (b) A record with `Status:` and NO weighing: advisory under the sweep, failure
#     when the diff touches it. One fixture, two modes — that IS the tier.
cat > "$P1722/docs/adr/0003-nostatus-alt.md" <<'ADR'
# No weighing at all

Status: Accepted

## Decision
x
ADR
[ "$(adr_run --all)" = "0" ] \
  || { echo "the sweep failed on a record it may not honestly ask anyone to finish" >&2; cat /tmp/adr-out >&2; exit 1; }
grep -q "advisory: 0003-nostatus-alt" /tmp/adr-out \
  || { echo "the sweep dropped the finding instead of reporting it" >&2; cat /tmp/adr-out >&2; exit 1; }
git -C "$P1722" add -A
git -C "$P1722" -c commit.gpgsign=false commit -qm "chore: record"
[ "$(adr_run --base main)" != "0" ] \
  || { echo "a touched record with no weighing passed the diff gate" >&2; cat /tmp/adr-out >&2; exit 1; }

# (c) A heading over nothing claims a weighing — that fails in BOTH modes, and
#     needs no memory to see or to fix.
cat > "$P1722/docs/adr/0004-empty-heading.md" <<'ADR'
# Claimed weighing

Status: Accepted

## Decision
x

## Alternatives Considered

ADR
[ "$(adr_run --all)" != "0" ] \
  || { echo "an empty alternatives heading passed the sweep" >&2; exit 1; }
[ "$(adr_run --base main)" != "0" ] \
  || { echo "an empty alternatives heading passed the diff gate" >&2; exit 1; }
rm "$P1722/docs/adr/0004-empty-heading.md"

# (d) No `Status:` is a FACT, not a memory — it fails in both modes so the sweep
#     cannot be used to drift away from it. Asserted, because it was demoted in
#     an earlier draft of this change and a later reader deserves the reason.
cat > "$P1722/docs/adr/0005-nostatus.md" <<'ADR'
# No status

## Decision
x

## Alternatives Considered
- Option B: …, lost because …
ADR
[ "$(adr_run --all)" != "0" ] \
  || { echo "a record with no Status passed the sweep" >&2; exit 1; }
[ "$(adr_run --base main)" != "0" ] \
  || { echo "a record with no Status passed the diff gate" >&2; exit 1; }

# Negative control: put the inline carrier back under a heading and the same
# predicate must stop holding — otherwise (a) would pass on a detector that
# simply accepts everything.
cat > "$P1722/docs/adr/0006-fake.md" <<'ADR'
# Fake

Status: Accepted

## Decision
x

## Consequences
- nothing about rejected options is written here
ADR
if grep -qE '^(?:[-*+]\s+|\*\*|__)?\s*(?:alternatives\b|rejected\b|备选方案|替代方案|被否)' \
   "$P1722/docs/adr/0006-fake.md"; then
  echo "negative control: an unrelated bullet matched the inline-carrier pattern" >&2; exit 1
fi

echo "1.7.22 alternatives-detector checks passed"

# 1.7.22 also fixes a latent bug it found on the way: the 1.7.12 step replaced
# `.sandcastle/adr.check.mjs` UNCONDITIONALLY.
#
# Its gate is `to_patch -ge 12`, which is true on every later upgrade too, so it
# re-runs for a project already at 1.7.21 — and an unconditional `cp` then
# overwrites a checker the project had edited, before any later step can read it.
# Measured: a project-edited checker came out of a 1.7.21 -> 1.7.22 run
# byte-identical to the template, and the 1.7.22 step then reported "already
# reads more than a heading" about a file whose edit that `cp` had destroyed.
# The comment said "a project that never had this file"; the code did not say it.
#
# The four live repositories all carry an unedited copy, so this never bit in
# production — it is a defect that only fires for a project that edits its own
# checker, which is exactly the case the surrounding machinery exists to protect.
PGUARD="$TMP/adr-guard-edit-$LANGUAGE"
rm -rf "$PGUARD"
mkdir -p "$PGUARD/.sandcastle" "$PGUARD/.github/workflows"
git -C "$PGUARD" init -q -b work
git -C "$PGUARD" config user.email t@e.x
git -C "$PGUARD" config user.name t
cp "$S/references/adr.check.mjs.1.7.21" "$PGUARD/.sandcastle/adr.check.mjs"
printf '\n// PROJECT-EDIT-MARKER\n' >> "$PGUARD/.sandcastle/adr.check.mjs"
printf '{"afk_template_version":"1.7.21","templateVersion":1,"repository":"kilbertert/guard","cron_hour":13}\n' > "$PGUARD/.afk-bootstrap.json"
printf 'FROM node:24\n' > "$PGUARD/.sandcastle/Dockerfile"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$S/scaffold/.sandcastle/repo-map.check.mjs" \
   "$S/scaffold/.sandcastle/consensus-contract.json" "$PGUARD/.sandcastle/"
"$S/upgrade-afk.sh" "$PGUARD" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project with an edited checker" >&2; exit 1; }
grep -q 'PROJECT-EDIT-MARKER' "$PGUARD/.sandcastle/adr.check.mjs" \
  || { echo "an upgrade destroyed a project's own edit to its checker" >&2; exit 1; }
if grep -q 'INLINE_ALTERNATIVES_RE' "$PGUARD/.sandcastle/adr.check.mjs"; then
  echo "the template overwrote a project-edited checker instead of reporting it" >&2; exit 1
fi

# Negative control: an UNEDITED checker still gets restaged. Without this the
# guard above proves only that the migration skips the file for every project.
PCLEAN="$TMP/adr-guard-clean-$LANGUAGE"
rm -rf "$PCLEAN"
mkdir -p "$PCLEAN/.sandcastle" "$PCLEAN/.github/workflows" "$PCLEAN/docs/agents"
git -C "$PCLEAN" init -q -b work
git -C "$PCLEAN" config user.email t@e.x
git -C "$PCLEAN" config user.name t
cp "$S/references/adr.check.mjs.1.7.21" "$PCLEAN/.sandcastle/adr.check.mjs"
cp "$S/references/architecture-decisions.md.1.7.21" "$PCLEAN/docs/agents/architecture-decisions.md"
printf '{"afk_template_version":"1.7.21","templateVersion":1,"repository":"kilbertert/clean","cron_hour":13}\n' > "$PCLEAN/.afk-bootstrap.json"
printf 'FROM node:24\n' > "$PCLEAN/.sandcastle/Dockerfile"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$S/scaffold/.sandcastle/repo-map.check.mjs" \
   "$S/scaffold/.sandcastle/consensus-contract.json" "$PCLEAN/.sandcastle/"
"$S/upgrade-afk.sh" "$PCLEAN" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project with an unedited checker" >&2; exit 1; }
grep -q 'INLINE_ALTERNATIVES_RE' "$PCLEAN/.sandcastle/adr.check.mjs" \
  || { echo "an unedited checker was not restaged" >&2; exit 1; }
grep -q 'needs its' "$PCLEAN/docs/agents/architecture-decisions.md" \
  || { echo "an unedited convention document was not restaged" >&2; exit 1; }

echo "1.7.22 project-edit guard checks passed"

# ---- 1.7.23: verification is risk-shaped, and the full gate runs once --------
#
# The fixture is built to carry the divergences the REAL consumer repositories
# carry, because that is the only fixture that tests the decision this step makes.
# A fixture whose prompts still matched the scaffold byte-for-byte would pass
# while every live repository silently no-opped — the failure mode ADR 0003
# records, and the reason this step edits anchors instead of restaging whole
# files. Two divergences are injected below:
#
#   * the language substitution that bootstrap applies to a python project, which
#     no upgrade step re-applies (`upgrade-afk.sh` has no substitution logic);
#   * a hand-written verification paragraph of the kind all three live python
#     repositories carry, naming a credential red line. It must survive untouched.
#
# The three properties asserted, in the order they matter:
#   1. the red-green LOOP is gone — it is the loop, not the tests, that costs;
#   2. the project's own gate command is byte-unchanged — the step must not
#      rewrite what a repository chose to verify with;
#   3. the project's hand-written paragraph is still there.
# A reference that tracks HEAD anchors nothing. This repository has shipped that
# bug once already (the 1.7.12 note: "a reference that tracks HEAD anchors
# nothing"), and it fails in the direction that is hardest to see — the fixture
# takes a file that is ALREADY migrated, "restores" the old shape from it, gets
# nothing, and then every assertion below holds on a tree that was never in the
# pre-migration state. Green locally, and green in CI for the wrong reason.
# So the snapshots are asserted to carry the old shape before anything uses them,
# and the drift turns red here rather than silently disarming the section.
python3 - "$S" <<'REFS' || { echo "a 1.7.22 reference no longer carries the pre-migration shape" >&2; exit 1; }
import pathlib, sys
refs = pathlib.Path(sys.argv[1]) / "references"
for name in ("implement-prompt.1.7.22.md", "implement-prompt-actions.1.7.22.md",
             "implement-prd-prompt.1.7.22.md"):
    t = (refs / name).read_text()
    assert "RED: write one failing test" in t, f"{name}: the ritual is gone — this reference tracks HEAD"
    assert "Do not manufacture a test to satisfy a quota." not in t, f"{name}: carries the NEW text"
REFS

P1723="$TMP/verify-doctrine-$LANGUAGE"
rm -rf "$P1723"
mkdir -p "$P1723/.sandcastle/implement" "$P1723/.sandcastle/implement-prd" \
         "$P1723/.github/workflows"
git -C "$P1723" init -q -b work
for REL in implement-prompt.md implement/prompt.md implement-prd/prompt.md; do
  cp "$S/references/$(case $REL in
       implement-prompt.md) echo implement-prompt.1.7.22.md ;;
       implement/prompt.md) echo implement-prompt-actions.1.7.22.md ;;
       *) echo implement-prd-prompt.1.7.22.md ;;
     esac)" "$P1723/.sandcastle/$REL"
done
cp "$S/references/CODING_STANDARDS.md.1.7.22" "$P1723/.sandcastle/CODING_STANDARDS.md"
printf 'FROM node:24\n' > "$P1723/.sandcastle/Dockerfile"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$S/scaffold/.sandcastle/repo-map.check.mjs" \
   "$S/scaffold/.sandcastle/consensus-contract.json" "$P1723/.sandcastle/"

# Inject the divergence the real repositories have. The python substitution is
# applied to every markdown file, exactly as `bootstrap-afk.sh` applies it.
if [ "$LANGUAGE" = "python" ]; then
  node -e '
    const fs = require("fs"), path = require("path");
    const check = "uv sync --extra dev && uv run pytest && uv run ruff check";
    (function walk(d) {
      for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const p = path.join(d, e.name);
        if (e.isDirectory()) walk(p);
        else if (e.name.endsWith(".md")) {
          const s = fs.readFileSync(p, "utf8");
          if (s.includes("npm run check")) fs.writeFileSync(p, s.replace(/npm run check/g, check));
        }
      }
    })(process.argv[1]);
  ' "$P1723/.sandcastle"
fi
# A project-authored verification paragraph, of the shape AI-Ops and health-flow
# both wrote for themselves.
cat >> "$P1723/.sandcastle/implement-prompt.md" <<'VERIFY'

This repo HAS a project verification skill, `.claude/skills/verify-smoke`.
Never record a device token in evidence or a commit.
VERIFY

printf '{"afk_template_version":"1.7.22","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1723/.afk-bootstrap.json"

"$S/upgrade-afk.sh" "$P1723" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project whose prompts have diverged" >&2; exit 1; }

python3 - "$P1723" <<'RIGHTSIZE' || { echo "1.7.23 did not right-size the prompts" >&2; exit 1; }
import pathlib, sys
root = pathlib.Path(sys.argv[1]) / ".sandcastle"
# The three promptFiles that carry the loop, and who loads each.
LOOPED = {
    "implement-prompt.md": "planner.ts — `pnpm ralph`",
    "implement/prompt.md": "implement.ts — the labelled issue (Actions)",
    "implement-prd/prompt.md": "implement-prd.ts — PRD loop (Actions)",
}
GUIDANCE = "Do not manufacture a test to satisfy a quota."
CADENCE = "run it once, when the change is complete"
for rel, who in LOOPED.items():
    t = (root / rel).read_text()
    # The loop is gone. This is the assertion the old text cannot survive.
    assert "RED: write one failing test" not in t, f"{rel} ({who}): the red-green loop survives"
    assert "Use red-green-refactor" not in t, f"{rel} ({who}): the ritual heading survives"
    # Present exactly once. `exactly once` and not `at least once`: the defect
    # class this repo has already shipped twice is a per-upgrade duplicate, and
    # an `at least` assertion passes on every damaged tree.
    assert t.count(GUIDANCE) == 1, f"{rel} ({who}): guidance appears {t.count(GUIDANCE)} times, not once"
    assert t.count(CADENCE) == 1, f"{rel} ({who}): cadence appears {t.count(CADENCE)} times, not once"
RIGHTSIZE

# The project's own gate command must be byte-unchanged. This is the guard that
# keeps the step from rewriting what a repository chose to verify with: a python
# project still runs uv, and no `npm run check` may have leaked into it.
if [ "$LANGUAGE" = "python" ]; then
  grep -q 'uv run pytest' "$P1723/.sandcastle/implement-prompt.md" \
    || { echo "the step destroyed a python project's gate command" >&2; exit 1; }
  if grep -R -q --include='*.md' 'npm run check' "$P1723/.sandcastle"; then
    echo "the step leaked a node gate into a python project" >&2; exit 1
  fi
else
  grep -q 'npm run check' "$P1723/.sandcastle/implement-prompt.md" \
    || { echo "the step destroyed a node project's gate command" >&2; exit 1; }
fi

# The project's hand-written verification paragraph survives untouched.
grep -q 'verify-smoke' "$P1723/.sandcastle/implement-prompt.md" \
  || { echo "the step destroyed a project's own verification paragraph" >&2; exit 1; }
grep -q 'Never record a device token' "$P1723/.sandcastle/implement-prompt.md" \
  || { echo "the step destroyed a project's credential red line" >&2; exit 1; }

# CODING_STANDARDS.md is byte-clean in every consumer, so it is restaged from the
# template rather than edited in place.
grep -q 'not a loop you spin after every edit' "$P1723/.sandcastle/CODING_STANDARDS.md" \
  || { echo "the coding standards were not restaged" >&2; exit 1; }

# Negative control: the step is reachable, and the tool's own exit-3 path is the
# only reason it could be skipped. Proven by defeating the TOOL rather than the
# version gate: the gate is `from_patch -lt 23`, and a fixture parked below that
# is legitimately in scope, so moving the version cannot make this control fail.
# What can make it fail is the tool declining to recognise the block — so the
# anchor is destroyed here, and the ritual must then survive with a warning.
P1723OFF="$TMP/verify-doctrine-off-$LANGUAGE"
rm -rf "$P1723OFF"
cp -R "$P1723" "$P1723OFF"
for REL in implement-prompt.md implement/prompt.md implement-prd/prompt.md; do
  cp "$S/references/$(case $REL in
       implement-prompt.md) echo implement-prompt.1.7.22.md ;;
       implement/prompt.md) echo implement-prompt-actions.1.7.22.md ;;
       *) echo implement-prd-prompt.1.7.22.md ;;
     esac)" "$P1723OFF/.sandcastle/$REL"
  # Reword the block's heading so every anchor this tool matches is gone.
  sed -i 's/^Use red-green-refactor where applicable[:.]\?$/Take a failing test first, where that helps./' \
    "$P1723OFF/.sandcastle/$REL"
done
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.7.22";
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P1723OFF/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P1723OFF" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project whose block was reworded" >&2; exit 1; }
grep -q 'Take a failing test first' "$P1723OFF/.sandcastle/implement-prompt.md" \
  || { echo "a reworded block was overwritten — the tool guessed" >&2; exit 1; }
if grep -q 'Do not manufacture a test to satisfy a quota' "$P1723OFF/.sandcastle/implement-prompt.md"; then
  echo "a reworded block got the template's guidance inserted beside it" >&2; exit 1
fi

# Idempotency: a re-run must not add a second copy. This is the defect class that
# bit 1.7.13 (a presence test that could never match its own insert) and 1.7.19
# (four stacked copies). A re-run that stacks is invisible to a single run.
cp -R "$P1723" "$P1723-again"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.7.22";
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P1723-again/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P1723-again" --cron-hour 13 >/dev/null \
  || { echo "the re-run refused a project it had just migrated" >&2; exit 1; }
python3 - "$P1723-again" <<'IDEM' || { echo "a second run stacked a duplicate" >&2; exit 1; }
import pathlib, sys
root = pathlib.Path(sys.argv[1]) / ".sandcastle"
for rel in ("implement-prompt.md", "implement/prompt.md", "implement-prd/prompt.md"):
    t = (root / rel).read_text()
    assert t.count("Do not manufacture a test to satisfy a quota.") == 1, rel
    assert t.count("run it once, when the change is complete") == 1, rel
    assert "Use red-green-refactor" not in t, rel
IDEM

# The tool's own duplication behaviour, exercised directly. The re-run above
# cannot fail this way — once the tool has rewritten the block its anchor is gone,
# so a second run exits 3 before it could write anything, and the "no stacking"
# property holds for a reason that has nothing to do with the tool's marker check.
# Measured: disabling that check (`if (lines.some((l) => l.includes(MARK)))
# process.exit(4)`) leaves the smoke test fully green. So the marker is defence in
# depth, not the thing under test, and the assertion that actually catches a
# stacked copy is the `== 1` count. Proven against a hand-injected duplicate,
# because a guard nobody has watched fail is a guard nobody knows works.
python3 - "$S/scaffold/.sandcastle/implement-prompt.md" <<'DUP' || { echo "the duplicate guard does not bite" >&2; exit 1; }
import pathlib, sys
t = pathlib.Path(sys.argv[1]).read_text()
g = "Do not manufacture a test to satisfy a quota."
assert t.count(g) == 1, "scaffold no longer carries exactly one copy"
stacked = t.replace(g, g + "\n" + g, 1)
try:
    assert stacked.count(g) == 1, f"guidance appears {stacked.count(g)} times, not once"
except AssertionError:
    sys.exit(0)
sys.exit(1)
DUP

echo "1.7.23 risk-based verification checks passed"

# ---- 1.7.24: the review prompt's duty reaches existing repositories ---------
#
# 1.7.23 wrote the adversary section into `scaffold/.sandcastle/review-prompt.md`
# and stopped there, so it reached every project created AFTER it and none
# created before. Measured on the three live consumers right after that rollout:
# present in the scaffold, 0 of 3 in their own copies. This is the ADR 0003
# defect a second time (1.7.18 did it to the write-back duty), and nothing failed
# because no check compares a scaffold file against the consumer copies of it.
#
# The fixture therefore has to look like a CONSUMER, not like the scaffold: a
# review prompt WITHOUT the section. Building it from the current scaffold would
# make it a file that already carries the section, and the assertions would pass
# while the step did nothing for the repositories this exists to fix.
P1724="$TMP/review-duty-$LANGUAGE"
rm -rf "$P1724"
mkdir -p "$P1724/.sandcastle/implement" "$P1724/.github/workflows"
git -C "$P1724" init -q -b work
cp "$S/references/review-prompt.1.7.23.md" "$P1724/.sandcastle/review-prompt.md"
# The prompt already carries the 1.7.23 work (the language's gate command), so
# the fixture is a 1.7.23 consumer rather than a pre-1.7.23 one.
if [ "$LANGUAGE" = "python" ]; then
  node -e '
    const fs = require("fs"), path = require("path");
    const check = "uv sync --extra dev && uv run pytest && uv run ruff check";
    (function walk(d) {
      for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const p = path.join(d, e.name);
        if (e.isDirectory()) walk(p);
        else if (e.name.endsWith(".md")) {
          const s = fs.readFileSync(p, "utf8");
          if (s.includes("npm run check")) fs.writeFileSync(p, s.replace(/npm run check/g, check));
        }
      }
    })(process.argv[1]);
  ' "$P1724/.sandcastle"
fi
printf 'FROM node:24\n' > "$P1724/.sandcastle/Dockerfile"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$S/scaffold/.sandcastle/repo-map.check.mjs" \
   "$S/scaffold/.sandcastle/consensus-contract.json" "$P1724/.sandcastle/"
printf '{"afk_template_version":"1.7.23","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1724/.afk-bootstrap.json"

# The fixture must NOT start with the duty, or the section below proves nothing.
grep -q 'adversary, not the author' "$P1724/.sandcastle/review-prompt.md" \
  && { echo "the 1.7.24 fixture already carries the duty — it is not a pre-1.7.24 consumer" >&2; exit 1; }

"$S/upgrade-afk.sh" "$P1724" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a 1.7.23 consumer" >&2; exit 1; }

python3 - "$P1724" "$S" <<'REVIEWDUTY' || { echo "1.7.24 did not deliver the review duty" >&2; exit 1; }
import pathlib, sys
dst, src = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
rel = ".sandcastle/review-prompt.md"
t = (dst / rel).read_text()

# Present exactly once. `exactly once`, not `at least once`: this repository's
# recorded defect class is a per-upgrade duplicate (1.7.13 stacked four copies).
assert t.count("You are the adversary, not the author") == 1, (
    f"{rel}: the adversary duty appears {t.count('You are the adversary, not the author')} times, not once"
)
# The section is placed where a reviewer reads it, before the numbered process.
assert t.index("## 0. You are the adversary") < t.index("## 1. Read the diff"), (
    f"{rel}: the adversary duty is not the first step of the review process"
)
# The project's own gate command survives: this step must not rewrite what a
# repository verifies with.
assert "run " in t and ("uv run pytest" in t or "npm run check" in t), (
    f"{rel}: the step destroyed the project's gate command"
)

# Byte-equality with the scaffold. A freshly bootstrapped project and an upgraded
# one must carry the SAME text for the same rule, or the two disagree about it.
def section(p):
    s = p.read_text()
    a = s.index("## 0. You are the adversary")
    b = s.index("## 1. Read the diff")
    return s[a:b]

want = section(src / "scaffold" / rel)
got = section(dst / rel)
assert got == want, f"{rel}: the migrated section differs from the scaffold's bytes"
REVIEWDUTY

# Negative control: a project that reworded the review heading keeps its wording
# and does NOT get the template's paragraph inserted beside it. Guards against a
# tool that falls back to "insert near any known anchor" once the match fails.
P1724OFF="$TMP/review-duty-off-$LANGUAGE"
rm -rf "$P1724OFF"
mkdir -p "$P1724OFF/.sandcastle" "$P1724OFF/.github/workflows"
cp "$S/references/review-prompt.1.7.23.md" "$P1724OFF/.sandcastle/review-prompt.md"
python3 - "$P1724OFF/.sandcastle/review-prompt.md" <<'REWORD'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); t = p.read_text()
assert t.count("## 1. Read the diff and look for anything dodgy") == 1
p.write_text(t.replace("## 1. Read the diff and look for anything dodgy",
                       "## 1. Work through the diff carefully"))
REWORD
printf 'FROM node:24\n' > "$P1724OFF/.sandcastle/Dockerfile"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$S/scaffold/.sandcastle/repo-map.check.mjs" \
   "$S/scaffold/.sandcastle/consensus-contract.json" "$P1724OFF/.sandcastle/"
printf '{"afk_template_version":"1.7.23","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1724OFF/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P1724OFF" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project whose review heading was reworded" >&2; exit 1; }
grep -q 'Work through the diff carefully' "$P1724OFF/.sandcastle/review-prompt.md" \
  || { echo "a reworded review heading was overwritten — the tool guessed" >&2; exit 1; }
if grep -q 'You are the adversary, not the author' "$P1724OFF/.sandcastle/review-prompt.md"; then
  echo "a reworded review prompt got the template's duty inserted beside its own wording" >&2; exit 1
fi

# Idempotency: a re-run must not add a second copy.
cp -R "$P1724" "$P1724-again"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.7.23";
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P1724-again/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P1724-again" --cron-hour 13 >/dev/null \
  || { echo "the re-run refused a project it had just migrated" >&2; exit 1; }
python3 - "$P1724-again" <<'IDEM' || { echo "a second run stacked a duplicate review duty" >&2; exit 1; }
import pathlib, sys
t = (pathlib.Path(sys.argv[1]) / ".sandcastle/review-prompt.md").read_text()
assert t.count("You are the adversary, not the author") == 1, t.count("You are the adversary, not the author")
IDEM

# The tool's anchor discipline, exercised directly. Both of these misfired in the
# first version of the review mode, which used a SUBSTRING match where the loop
# mode next door correctly matches whole lines. They are asserted here rather
# than left to the migration-level checks because the migration fixture uses an
# unmodified heading, so neither case can be reached through it.
#
#   A. a heading at a different level still CONTAINS the expected text, so the
#      section was inserted above a level-three heading and the run reported
#      success — instead of reporting that the anchor it knows is gone;
#   B. a prose MENTION of the duty's name satisfied the presence check, so the
#      step reported "already delivered" and stamped the version while adding
#      nothing — the silent-skip failure this whole step exists to fix.
python3 - "$S" <<'ANCHORS' || { echo "the review mode's anchor discipline is broken" >&2; exit 1; }
import pathlib, re, subprocess, sys, tempfile
src = pathlib.Path(sys.argv[1])
tool = src / "tools" / "right-size-tests.mjs"
base = (src / "references" / "review-prompt.1.7.23.md").read_text()
tree = pathlib.Path(tempfile.mkdtemp())

def run(text):
    p = tree / "p.md"
    p.write_text(text)
    rc = subprocess.run(["node", str(tool), str(p), "review"],
                        capture_output=True).returncode
    return rc, p.read_text()

# A. demoted heading: report, do not edit.
demoted = base.replace("## 1. Read the diff and look for anything dodgy",
                       "### 1. Read the diff and look for anything dodgy")
rc, out = run(demoted)
assert rc == 3, f"a level-three heading was accepted as the anchor (rc={rc})"
assert "You are the adversary" not in out, "the duty was inserted at a guessed location"

# B. a prose mention is not the section.
mentioned = base.replace(
    "# REVIEW PROCESS",
    "# REVIEW PROCESS\n\nThe phrase You are the adversary, not the author describes our goal.")
rc, out = run(mentioned)
assert rc == 0, f"a prose mention was taken as the delivered section (rc={rc})"
assert out.count("## 0. You are the adversary, not the author") == 1, "the section was not added"

# C. and the real shape still works, exactly once.
rc, out = run(base)
assert rc == 0 and out.count("## 0. You are the adversary, not the author") == 1
ANCHORS

echo "1.7.24 review-duty checks passed"

# ---- 1.7.25: the OTHER reviewer gets the adversary duty --------------------
#
# 1.7.24 delivered the duty to `.sandcastle/review-prompt.md` and wrote an ADR
# that considered and correctly rejected `.sandcastle/review/prompt.md` (the fixer
# after the two axes). What that reasoning missed is that the SAME DIRECTORY holds
# `review/axis-prompt.md` — the first-pass reviewer on the other path
# (`review/review.ts:178`, the `agent:review` label). Third occurrence of the ADR
# 0003 defect; found by Devin Review on a consumer PR.
#
# Delivered by `cmp`-guarded restage rather than an anchored edit, because the two
# files differ in exactly this respect: `review-prompt.md` diverges from the
# scaffold by 17 lines in every consumer, while `review/axis-prompt.md` was
# measured BYTE-IDENTICAL in all three. The fixture builds from the 1.7.24
# reference, which is that byte-clean pre-migration shape.
P1725="$TMP/axis-review-duty-$LANGUAGE"
rm -rf "$P1725"
mkdir -p "$P1725/.sandcastle/review" "$P1725/.github/workflows"
git -C "$P1725" init -q -b work
cp "$S/references/review-axis-prompt.1.7.24.md" "$P1725/.sandcastle/review/axis-prompt.md"
printf 'FROM node:24\n' > "$P1725/.sandcastle/Dockerfile"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$S/scaffold/.sandcastle/repo-map.check.mjs" \
   "$S/scaffold/.sandcastle/consensus-contract.json" "$P1725/.sandcastle/"
printf '{"afk_template_version":"1.7.24","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1725/.afk-bootstrap.json"

# The fixture must NOT start with the duty, or this section proves nothing.
grep -q 'YOUR JOB' "$P1725/.sandcastle/review/axis-prompt.md" \
  && { echo "the 1.7.25 fixture already carries the duty — it is not a pre-1.7.25 shape" >&2; exit 1; }

"$S/upgrade-afk.sh" "$P1725" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a 1.7.24 consumer" >&2; exit 1; }

python3 - "$P1725" "$S" <<'AXISDUTY' || { echo "1.7.25 did not deliver the axis reviewer's duty" >&2; exit 1; }
import pathlib, sys
dst, src = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
rel = ".sandcastle/review/axis-prompt.md"
t = (dst / rel).read_text()

# Present exactly once — this repository's recorded defect class is a per-upgrade
# duplicate (1.7.13 stacked four copies of its paragraph).
n = t.count("# YOUR JOB")
assert n == 1, f"{rel}: the adversary duty appears {n} times, not once"

# Byte-equality with the scaffold: a freshly bootstrapped project and an upgraded
# one must carry the same text for the same rule.
assert t == (src / "scaffold" / rel).read_text(), f"{rel}: differs from the scaffold"

# The read-only reviewer MAY run things — it gets a sandbox, and the ban covers
# editing/committing/pushing, not executing. The first draft of this section said
# "You cannot run the code", which was an UNVERIFIED claim about the sandbox and
# would have told the reviewer not to reproduce a failure it is able to reproduce.
# Devin Review caught it. So the assertion is the opposite direction now.
assert "described rather than demonstrated" not in t, (
    f"{rel}: tells the reviewer its counterexample cannot be demonstrated — but this "
    "pass gets a sandbox and may run things; only editing/committing/pushing is banned"
)
assert "a demonstrated failure beats a described one" in t, (
    f"{rel}: does not invite the reviewer to demonstrate a failure it can reproduce"
)
# The ban is exactly the three things the read-only line names, and stays.
assert "Do not edit files, commit, push" in t, f"{rel}: the read-only constraint was lost"
# And where it cannot demonstrate, the finding must still be checkable.
assert "names no input, so nobody can check it" in t, (
    f"{rel}: missing the criterion that keeps a described finding checkable"
)
AXISDUTY

# Negative control: a project-edited axis prompt keeps its own text and does NOT
# get the template's copy written over it. This is what the `cmp` guard buys, and
# without this control the section proves only that the file changed.
P1725EDIT="$TMP/axis-review-edited-$LANGUAGE"
rm -rf "$P1725EDIT"
mkdir -p "$P1725EDIT/.sandcastle/review" "$P1725EDIT/.github/workflows"
cp "$S/references/review-axis-prompt.1.7.24.md" "$P1725EDIT/.sandcastle/review/axis-prompt.md"
printf '\nProject own note: our review adds a security checklist.\n' \
  >> "$P1725EDIT/.sandcastle/review/axis-prompt.md"
printf 'FROM node:24\n' > "$P1725EDIT/.sandcastle/Dockerfile"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$S/scaffold/.sandcastle/repo-map.check.mjs" \
   "$S/scaffold/.sandcastle/consensus-contract.json" "$P1725EDIT/.sandcastle/"
printf '{"afk_template_version":"1.7.24","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1725EDIT/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P1725EDIT" --cron-hour 13 >/dev/null \
  || { echo "upgrade refused a project whose axis prompt was edited" >&2; exit 1; }
grep -q 'Project own note' "$P1725EDIT/.sandcastle/review/axis-prompt.md" \
  || { echo "an upgrade destroyed a project's own edit to its axis prompt" >&2; exit 1; }
if grep -q '# YOUR JOB' "$P1725EDIT/.sandcastle/review/axis-prompt.md"; then
  echo "the template overwrote a project-edited axis prompt instead of reporting it" >&2; exit 1
fi

# Idempotency: a re-run must not add a second copy.
cp -R "$P1725" "$P1725-again"
node -e '
  const fs = require("fs");
  const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  m.afk_template_version = "1.7.24";
  fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
' "$P1725-again/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P1725-again" --cron-hour 13 >/dev/null \
  || { echo "the re-run refused a project it had just migrated" >&2; exit 1; }
python3 - "$P1725-again" <<'IDEM' || { echo "a second run stacked a duplicate axis duty" >&2; exit 1; }
import pathlib, sys
t = (pathlib.Path(sys.argv[1]) / ".sandcastle/review/axis-prompt.md").read_text()
assert t.count("# YOUR JOB") == 1, t.count("# YOUR JOB")
IDEM

# The step's own guard must not skip on a MENTION of the heading. The first
# version tested `grep -qF "# YOUR JOB"`, so a project whose prompt merely quoted
# it in prose satisfied the test: the upgrade reported "already carries the
# adversary duty", left the old reviewer text in place, and stamped 1.7.25 —
# this step's own failure mode (a silent skip) reproduced inside its guard, and
# the same substring-vs-structure mistake the 1.7.24 review mode made.
#
# Asserted at the migration level because that is where the guard lives.
P1725MENTION="$TMP/axis-review-mention-$LANGUAGE"
rm -rf "$P1725MENTION"
mkdir -p "$P1725MENTION/.sandcastle/review" "$P1725MENTION/.github/workflows"
cp "$S/references/review-axis-prompt.1.7.24.md" "$P1725MENTION/.sandcastle/review/axis-prompt.md"
printf '\nOur checklist quotes # YOUR JOB from the planner prompt.\n' \
  >> "$P1725MENTION/.sandcastle/review/axis-prompt.md"
printf 'FROM node:24\n' > "$P1725MENTION/.sandcastle/Dockerfile"
cp "$S/scaffold/.sandcastle/repo-map.mjs" "$S/scaffold/.sandcastle/repo-map.check.mjs" \
   "$S/scaffold/.sandcastle/consensus-contract.json" "$P1725MENTION/.sandcastle/"
printf '{"afk_template_version":"1.7.24","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1725MENTION/.afk-bootstrap.json"
# The report is asserted on THIS run. A second invocation on the same tree cannot
# serve: the first one already stamped 1.7.25, so the second takes the "already at
# 1.7.25" early exit and never reaches this step — measured, and it made the first
# version of this control vacuous while looking like it exercised the guard.
MENTION_OUT="$("$S/upgrade-afk.sh" "$P1725MENTION" --cron-hour 13 2>&1)" \
  || { echo "upgrade refused a project that merely mentions the heading" >&2; exit 1; }
if grep -q "a demonstrated failure beats a described one" "$P1725MENTION/.sandcastle/review/axis-prompt.md"; then
  echo "a mere mention of the heading made the step write over a project's own text" >&2; exit 1
fi
grep -q 'Our checklist quotes' "$P1725MENTION/.sandcastle/review/axis-prompt.md" \
  || { echo "the project's own text was destroyed" >&2; exit 1; }
# And it must SAY so rather than pass silently — this is the half that catches the
# substring guard. Without it the control above passes for a step that skipped the
# file for the wrong reason.
grep -q 'differs from what this template shipped' <<<"$MENTION_OUT" \
  || { echo "a mention of the heading was reported as already-migrated" >&2; exit 1; }

echo "1.7.25 axis-reviewer checks passed"

# ---- 1.7.26: the two prompts with NO per-language render -------------------
# The scaffold ships every prompt saying `npm run check`. Five of them have a
# per-language render, so bootstrap and every upgrade step so far translated
# those. `merge-prompt.md` and `update-branch/prompt.md` have NONE — nothing in
# either is about Node — and so were on no list, in the two prompts whose whole
# job is "resolve the conflict, then verify".
echo "1.7.26 language-agnostic-prompt checks..."

P1726="$TMP/fake-$LANGUAGE-1726"
# Built by bootstrapping a throwaway target, then REGRESSING the two files to the
# pre-1.7.26 shape. A hand-built fixture missing `.sandcastle/Dockerfile` (or any
# other file every real project has) makes the upgrade refuse before it reaches
# this step — measured: "missing .sandcastle/Dockerfile", which reads as a broken
# step rather than a thin fixture.
mkdir -p "$P1726"
git -C "$P1726" init -q -b main
git -C "$P1726" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1726" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
# Restore the NODE text in exactly the two language-agnostic prompts, which is
# what a project created before this step actually holds.
cp "$S/scaffold/.sandcastle/merge-prompt.md"         "$P1726/.sandcastle/merge-prompt.md"
cp "$S/scaffold/.sandcastle/update-branch/prompt.md" "$P1726/.sandcastle/update-branch/prompt.md"
printf '{"afk_template_version":"1.7.25","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1726/.afk-bootstrap.json"

# The fixture must still carry the NODE command, or this section proves nothing:
# if the scaffold ever ships these pre-translated, the assertions below pass for
# a reason unrelated to this step.
grep -q 'npm run check' "$P1726/.sandcastle/merge-prompt.md" \
  || { echo "the 1.7.26 fixture starts without \`npm run check\` — it is not a pre-1.7.26 shape" >&2; exit 1; }

OUT1726="$("$S/upgrade-afk.sh" "$P1726" --cron-hour 13 2>&1)" \
  || { echo "upgrade refused a 1.7.25 consumer" >&2; exit 1; }

# (a) For a PYTHON project the node command is GONE from both files. Not asserted
#     for node: there the command is already `npm run check`, so its survival is
#     the correct outcome, and asserting its absence would demand the step change
#     a file it has no reason to touch.
if [ "$LANGUAGE" = "python" ]; then
  if grep -q 'npm run check' "$P1726/.sandcastle/merge-prompt.md" "$P1726/.sandcastle/update-branch/prompt.md"; then
    echo "1.7.26 left \`npm run check\` in a language-agnostic prompt" >&2; exit 1
  fi
fi
# (b) The substitution is the TEMPLATE's command, not a plausible invention.
# `awk -F'\`'` rather than grep+sed: shellcheck reads the backticks inside a
# single-quoted grep pattern as command substitution (SC2016) and fails the job.
PROJECT_CHECK="$(awk -F'`' '/^3\. Run `/ { print $2; exit }' "$S/templates/implement.$LANGUAGE.md")"
[ -n "$PROJECT_CHECK" ] || { echo "could not read the template's check command" >&2; exit 1; }
if [ "$LANGUAGE" = "python" ]; then
  grep -qF "$PROJECT_CHECK" "$P1726/.sandcastle/merge-prompt.md" \
    || { echo "merge-prompt.md did not receive \`$PROJECT_CHECK\`" >&2; exit 1; }
  grep -qF "$PROJECT_CHECK" "$P1726/.sandcastle/update-branch/prompt.md" \
    || { echo "update-branch/prompt.md did not receive \`$PROJECT_CHECK\`" >&2; exit 1; }
fi
# (c) And it is PUBLISHED, not merely staged. Measured with the registration
#     removed: the tool printed both `adapted` lines, the file kept
#     `npm run check`, and the publish tail never named it.
if [ "$LANGUAGE" = "python" ]; then
  grep -q 'changed: .sandcastle/merge-prompt.md' <<<"$OUT1726" \
    || { echo "the step adapted merge-prompt.md but never published it" >&2; exit 1; }
  grep -q 'changed: .sandcastle/update-branch/prompt.md' <<<"$OUT1726" \
    || { echo "the step adapted update-branch/prompt.md but never published it" >&2; exit 1; }
else
  # ⚠️ The other direction, and the one that bit hardest: for a node project the
  # step writes nothing, so it must PUBLISH nothing either. Registering the file
  # in NEW_FILES restages the scaffold's copy over the project's own — measured:
  # a node consumer's two prompts were silently reverted while the run reported
  # success. A project that had edited either prompt would lose the edit.
  grep -q 'changed: .sandcastle/merge-prompt.md' <<<"$OUT1726" \
    && { echo "a node project's merge-prompt.md was overwritten by the scaffold copy" >&2; exit 1; }
  grep -q 'changed: .sandcastle/update-branch/prompt.md' <<<"$OUT1726" \
    && { echo "a node project's update-branch/prompt.md was overwritten by the scaffold copy" >&2; exit 1; }
  :
fi
# (d) A node project is a no-op, and SAYS so rather than reporting a rewrite.
if [ "$LANGUAGE" = "node" ]; then
  grep -qi 'nothing to adapt\|nothing to do' <<<"$OUT1726" \
    || { echo "a node project was reported as adapted" >&2; exit 1; }
  grep -q 'npm run check' "$P1726/.sandcastle/merge-prompt.md" \
    || { echo "a node project lost its own check command" >&2; exit 1; }
fi

# NEGATIVE CONTROL: a project's OWN edit to one of these prompts must survive.
# The first version registered both files in NEW_FILES unconditionally, so a node
# project's prompts were silently reverted to the scaffold copy — and these two
# files are the ones a project most often edits, because nothing in them is
# language-specific. The fixture above cannot catch that: it holds unmodified
# scaffold text, so reverting it changes nothing. This one carries an edit.
P1726EDIT="$TMP/fake-$LANGUAGE-1726-edited"
mkdir -p "$P1726EDIT"
git -C "$P1726EDIT" init -q -b main
git -C "$P1726EDIT" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1726EDIT" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
cp "$S/scaffold/.sandcastle/merge-prompt.md"         "$P1726EDIT/.sandcastle/merge-prompt.md"
cp "$S/scaffold/.sandcastle/update-branch/prompt.md" "$P1726EDIT/.sandcastle/update-branch/prompt.md"
printf '\n# PROJECT RULE\nOur merge agent must also update CHANGELOG.md.\n' \
  >> "$P1726EDIT/.sandcastle/merge-prompt.md"
printf '{"afk_template_version":"1.7.25","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1726EDIT/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P1726EDIT" --cron-hour 13 >/dev/null 2>&1 || true
grep -q 'PROJECT RULE' "$P1726EDIT/.sandcastle/merge-prompt.md" \
  || { echo "the upgrade reverted a project's own edit to merge-prompt.md" >&2; exit 1; }
# And the doc it names must not have been left dangling: a pre-1.4 project's
# `update-branch/prompt.md` names CONTEXT.md, which this same run renames.
P1726GLOSS="$TMP/fake-$LANGUAGE-1726-glossary"
mkdir -p "$P1726GLOSS"
git -C "$P1726GLOSS" init -q -b main
git -C "$P1726GLOSS" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1726GLOSS" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
rm -f "$P1726GLOSS/GLOSSARY.md"
printf '# project glossary\n' > "$P1726GLOSS/CONTEXT.md"
sed -i 's/GLOSSARY\.md/CONTEXT.md/g' "$P1726GLOSS/.sandcastle/update-branch/prompt.md"
printf '{"afk_template_version":"1.3.0","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1726GLOSS/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P1726GLOSS" --cron-hour 13 >/dev/null 2>&1 || true
if grep -q 'CONTEXT\.md' "$P1726GLOSS/.sandcastle/update-branch/prompt.md" \
   && [ -e "$P1726GLOSS/GLOSSARY.md" ]; then
  echo "a pre-1.4 upgrade left the prompt naming CONTEXT.md after renaming the doc" >&2; exit 1
fi


# NEGATIVE CONTROL: an unreadable language must leave the prompts ALONE and say
# so. A step that guessed here would write a wrong command into two prompts with
# a straight face, and the agent reading them cannot tell it was a guess.
P1726REF="$TMP/fake-$LANGUAGE-1726-refused"
mkdir -p "$P1726REF"
git -C "$P1726REF" init -q -b main
git -C "$P1726REF" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1726REF" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
cp "$S/scaffold/.sandcastle/merge-prompt.md"         "$P1726REF/.sandcastle/merge-prompt.md"
cp "$S/scaffold/.sandcastle/update-branch/prompt.md" "$P1726REF/.sandcastle/update-branch/prompt.md"
printf '{"afk_template_version":"1.7.25","templateVersion":1,"language":"cobol","repository":"kilbertert/smoke","cron_hour":13}\n' \
  > "$P1726REF/.afk-bootstrap.json"
# The run may fail for any reason and that is fine — what is asserted is that the
# prompts were not rewritten to a guessed command.
"$S/upgrade-afk.sh" "$P1726REF" --cron-hour 13 >/dev/null 2>&1 || true
grep -q 'npm run check' "$P1726REF/.sandcastle/merge-prompt.md" \
  || { echo "an unknown language was given a guessed check command" >&2; exit 1; }

echo "1.7.26 language-agnostic-prompt checks passed"

# ---- 1.7.27: the reviewers learn where green tests lie ----------------------
echo "1.7.27 test-double-criterion checks..."

P1727="$TMP/fake-$LANGUAGE-1727"
mkdir -p "$P1727"
git -C "$P1727" init -q -b main
git -C "$P1727" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1727" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
cp "$S/references/review-prompt.1.7.26.md"        "$P1727/.sandcastle/review-prompt.md"
cp "$S/references/review-prompt-fixer.1.7.26.md"  "$P1727/.sandcastle/review/prompt.md"
cp "$S/references/review-axis-prompt.1.7.26.md"   "$P1727/.sandcastle/review/axis-prompt.md"
# A PYTHON fixture must carry the language substitution, or the cmp guard is tested
# against a shape no Python consumer has. That normalisation IS the mechanism.
if [ "$LANGUAGE" = "python" ]; then
  node "$S/tools/adapt-check-command.mjs" --root "$P1727" --scaffold "$S" >/dev/null
fi
printf '{"afk_template_version":"1.7.26","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1727/.afk-bootstrap.json"

grep -q 'more forgiving than the real thing' "$P1727/.sandcastle/review/axis-prompt.md" \
  && { echo "the 1.7.27 fixture already carries the criterion" >&2; exit 1; }

OUT1727="$("$S/upgrade-afk.sh" "$P1727" --cron-hour 13 2>&1)" \
  || { echo "upgrade refused a 1.7.26 consumer" >&2; exit 1; }

# (a) The criterion reaches ALL THREE review files.
grep -q 'more forgiving than the real thing' "$P1727/.sandcastle/review/axis-prompt.md" \
  || { echo "the axis reviewer did not get the double criterion" >&2; exit 1; }
grep -q 'check the double' "$P1727/.sandcastle/review-prompt.md" \
  || { echo "the planner reviewer did not get the double criterion" >&2; exit 1; }
grep -q 'keep the' "$P1727/.sandcastle/review/prompt.md" \
  || { echo "the fixer did not get the double criterion" >&2; exit 1; }
# (b) Published, not merely staged.
for f in .sandcastle/review-prompt.md .sandcastle/review/prompt.md .sandcastle/review/axis-prompt.md; do
  grep -q "changed: $f" <<<"$OUT1727" \
    || { echo "the step restaged $f but never published it" >&2; exit 1; }
done
# (c) A python consumer must NOT be left with the node command.
if [ "$LANGUAGE" = "python" ]; then
  if grep -q 'npm run check' "$P1727/.sandcastle/review-prompt.md" "$P1727/.sandcastle/review/prompt.md"; then
    echo "1.7.27 reverted a python consumer's check command to npm" >&2; exit 1
  fi
  grep -q 'uv sync --extra dev' "$P1727/.sandcastle/review-prompt.md" \
    || { echo "review-prompt.md lost the project's own check command" >&2; exit 1; }
fi

# NEGATIVE CONTROL: a project that hand-edited one of these files keeps its text.
P1727EDIT="$TMP/fake-$LANGUAGE-1727-edited"
mkdir -p "$P1727EDIT"
git -C "$P1727EDIT" init -q -b main
git -C "$P1727EDIT" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1727EDIT" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
cp "$S/references/review-axis-prompt.1.7.26.md" "$P1727EDIT/.sandcastle/review/axis-prompt.md"
printf '\n# PROJECT RULE\nOur axis reviewer also checks the audit log shape.\n' \
  >> "$P1727EDIT/.sandcastle/review/axis-prompt.md"
printf '{"afk_template_version":"1.7.26","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1727EDIT/.afk-bootstrap.json"
EDIT_OUT="$("$S/upgrade-afk.sh" "$P1727EDIT" --cron-hour 13 2>&1)" || true
grep -q 'PROJECT RULE' "$P1727EDIT/.sandcastle/review/axis-prompt.md" \
  || { echo "the upgrade destroyed a project's own text in axis-prompt.md" >&2; exit 1; }
grep -q 'differs from what this template shipped' <<<"$EDIT_OUT" \
  || { echo "a hand-edited review prompt was restaged silently" >&2; exit 1; }

echo "1.7.27 test-double-criterion checks passed"

# ---- 1.7.28: the check command runs the suite in parallel --------------------
# Measured on a real consumer (AI-Ops, 2026-10-22): 249.7 s serially vs 46.4 s
# in parallel, identical tests. The agent runs this command on EVERY iteration,
# so the difference compounds per issue.
#
# ⚠️ The assertions below read `-n 4`, not `-n auto`: 1.7.29 narrowed the count
# (see that section). The property this section owns is "a new project's check
# command runs the suite in parallel at all" — the exact number is 1.7.29's.
echo "1.7.28 parallel-check-command checks..."

P1728="$TMP/fake-$LANGUAGE-1728"
mkdir -p "$P1728"
git -C "$P1728" init -q -b main
git -C "$P1728" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1728" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null

# (a) A NEW project gets a parallel command from the template, and the command is
#     still parseable by the 1.7.26 tool (its anchor is `Run \`…\` before`).
if [ "$LANGUAGE" = "python" ]; then
  grep -q 'uv run pytest -n 4' "$P1728/.sandcastle/implement.md" \
    || { echo "a new python project's check command lost the worker count" >&2; exit 1; }
  # The 1.7.26 tool exits 3 = "nothing to substitute", which is the correct outcome
  # here (a fresh bootstrap already carries the translated command). `|| true` keeps
  # `set -e` from reading that as a failure — the assertion below is the real check.
  node "$S/tools/adapt-check-command.mjs" --root "$P1728" --scaffold "$S" >/dev/null 2>&1 || true
  grep -q 'uv run pytest -n 4' "$P1728/.sandcastle/review-prompt.md" \
    || { echo "the 1.7.26 substitution did not carry the worker count into review-prompt.md" >&2; exit 1; }
fi

# (b) A consumer upgrading ACROSS the change keeps working: its files still say the
#     old (serial) command, and the 1.7.27 guard must not read that as a hand-edit.
#     Measured before the fix: the step refused both files, the criterion never
#     landed, and nothing failed loudly.
P1728OLD="$TMP/fake-$LANGUAGE-1728-across"
mkdir -p "$P1728OLD"
git -C "$P1728OLD" init -q -b main
git -C "$P1728OLD" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1728OLD" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
cp "$S/references/review-prompt.1.7.26.md"       "$P1728OLD/.sandcastle/review-prompt.md"
cp "$S/references/review-prompt-fixer.1.7.26.md" "$P1728OLD/.sandcastle/review/prompt.md"
cp "$S/references/review-axis-prompt.1.7.26.md"  "$P1728OLD/.sandcastle/review/axis-prompt.md"
if [ "$LANGUAGE" = "python" ]; then
  # The pre-1.7.28 spelling, which is what such a consumer actually holds.
  # The fixture must hold the NEW spelling while the 1.7.26 snapshot holds the OLD
  # one — that is the only combination where the guard's normalisation matters.
  # Measured (2026-10-22): consumer=old matches either way; consumer=new matches
  # ONLY when both spellings are normalised. Getting this backwards makes the
  # control silently vacuous, which is what the first version of this section did.
  # Translate the snapshot's node command the way a 1.7.27 consumer's file already
  # reads, using the SAME tool the upgrade uses. Hand-rolled sed here drifted from
  # the tool and produced a file holding both spellings at once — which the guard
  # then (correctly) read as a hand-edit.
  node "$S/tools/adapt-check-command.mjs" --root "$P1728OLD" --scaffold "$S" \
    --file .sandcastle/review-prompt.md --file .sandcastle/review/prompt.md >/dev/null 2>&1 || true
fi
printf '{"afk_template_version":"1.7.26","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1728OLD/.afk-bootstrap.json"
OLD_OUT="$("$S/upgrade-afk.sh" "$P1728OLD" --cron-hour 13 2>&1)" \
  || { echo "upgrade refused a consumer from before the parallel command" >&2; exit 1; }
# It must SAY it restaged the file rather than passing quietly.
grep -q 'restaged: .sandcastle/review-prompt.md' <<<"$OLD_OUT" \
  || { echo "the 1.7.27 step skipped review-prompt.md without saying so" >&2; exit 1; }
grep -q 'check the double' "$P1728OLD/.sandcastle/review-prompt.md" \
  || { echo "a pre-1.7.28 consumer never got the 1.7.27 criterion (the guard mis-read the old command as an edit)" >&2; exit 1; }
if [ "$LANGUAGE" = "python" ]; then
  grep -q 'uv run pytest -n 4' "$P1728OLD/.sandcastle/review-prompt.md" \
    || { echo "a pre-1.7.28 consumer was not moved onto the worker-counted command" >&2; exit 1; }
fi

echo "1.7.28 parallel-check-command checks passed"

# ---- 1.7.29: half the cores per lap, not all of them ------------------------
# Measured on the shared host 2026-10-23: seven concurrent `-n auto` laps on 8 cores
# drove load average 5.28 → 79; sshd starved, the tailnet dropped, and the machine
# became unreachable. `auto` is the whole box, and the box is not this run's.
echo "1.7.29 bounded-worker-count checks..."

P1729="$TMP/fake-$LANGUAGE-1729"
mkdir -p "$P1729"
git -C "$P1729" init -q -b main
git -C "$P1729" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1729" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
# A consumer that was last touched under 1.7.28: `-n auto` wherever that step had
# put a worker count. Two shapes exist and both are realistic —
#   * `uv run pytest -n auto`  (implement*.md, review*), and
#   * a bare `uv run pytest`   (`implement-prd/prompt.md`, whose command is written
#     as a list and which the 1.7.28 step only reaches on the upgrade path).
# The second is checked separately below: the 1.7.29 step must leave it alone
# rather than invent a count for a file that never had one.
if [ "$LANGUAGE" = "python" ]; then
  perl -pi -e 's/uv run pytest -n 4(?!\d)/uv run pytest -n auto/g' "$P1729/.sandcastle/"*.md
  perl -pi -e 's/uv run pytest -n 4(?!\d)/uv run pytest -n auto/g' "$P1729/.sandcastle/"*/prompt.md
  for f in .sandcastle/implement.md .sandcastle/implement-prompt.md .sandcastle/implement/prompt.md \
           .sandcastle/implement-pr/prompt.md .sandcastle/review-prompt.md \
           .sandcastle/review/prompt.md; do
    grep -q 'uv run pytest -n auto' "$P1729/$f" \
      || { echo "fixture: $f did not carry -n auto into the 1.7.29 case" >&2; exit 1; }
  done
fi
printf '{"afk_template_version":"1.7.28","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1729/.afk-bootstrap.json"

OUT1729="$("$S/upgrade-afk.sh" "$P1729" --cron-hour 13 2>&1)" \
  || { echo "upgrade refused a 1.7.28 consumer" >&2; exit 1; }

if [ "$LANGUAGE" = "python" ]; then
  # (a) Every prompt that HAD `auto` moved off it.
  for f in .sandcastle/implement.md .sandcastle/implement-prompt.md .sandcastle/implement/prompt.md \
           .sandcastle/implement-pr/prompt.md .sandcastle/review-prompt.md \
           .sandcastle/review/prompt.md; do
    grep -q 'uv run pytest -n auto' "$P1729/$f" \
      && { echo "1.7.29 left -n auto in $f" >&2; exit 1; }
    grep -q 'uv run pytest -n 4' "$P1729/$f" \
      || { echo "1.7.29 did not give $f a worker count" >&2; exit 1; }
  done
  # (a2) A prompt that never carried a count keeps not carrying one. Substitution
  #      on the flag cannot fire here, and that is the correct outcome — inventing
  #      `-n 4` for a file the project wrote without it would be this step editing
  #      a command it was not asked to change.
  grep -q 'uv run pytest -n 4' "$P1729/.sandcastle/implement-prd/prompt.md" \
    && { echo "1.7.29 invented a worker count for implement-prd/prompt.md" >&2; exit 1; }

  # (b) NEGATIVE CONTROL for the lookahead: re-running the step against a tree that
  #     ALREADY says `-n 4` must not produce `-n 4 -n 4`. pytest accepts a repeated
  #     `-n` and runs, so this defect is invisible without asserting the shape.
  #     Measured before the fix: exactly `uv run pytest -n 4 -n 4`.
  printf '{"afk_template_version":"1.7.28","templateVersion":1,"language":"python","repository":"kilbertert/smoke","cron_hour":13}\n' \
    > "$P1729/.afk-bootstrap.json"
  "$S/upgrade-afk.sh" "$P1729" --cron-hour 13 >/dev/null 2>&1 || true
  grep -q 'uv run pytest -n 4 -n\|uv run pytest -n auto -n' "$P1729/.sandcastle/implement.md" \
    && { echo "1.7.29 doubled the worker flag on a re-run (-n 4 -n 4)" >&2; exit 1; }
fi

# (c) The step must SAY that the per-run width is all it can set. The number of
#     concurrent runs is what actually took the host down, and it lives in the
#     consumer's own conftest — an upgrade that silently implies "fixed" is worse
#     than one that names the remaining half.
grep -q 'how many runs may exist at once' <<<"$OUT1729" \
  || { echo "1.7.29 did not say that concurrent-run count is out of its reach" >&2; exit 1; }

# (d) NEGATIVE CONTROL for the gate: a consumer already at 1.7.29 must not re-run
#     the step. Rewriting the version by hand is the only way in, so it also proves
#     the gate reads the patch level rather than the presence of the substitution.
printf '{"afk_template_version":"1.7.29","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1729/.afk-bootstrap.json"
OUT1729B="$("$S/upgrade-afk.sh" "$P1729" --cron-hour 13 2>&1)" \
  || { echo "upgrade refused a consumer already at the current version" >&2; exit 1; }
grep -q 'half the cores per lap' <<<"$OUT1729B" \
  && { echo "the 1.7.29 step ran again for a consumer already at 1.7.29" >&2; exit 1; }

echo "1.7.29 bounded-worker-count checks passed"


# REGRESSION (review): a consumer coming from BEFORE 1.7.24 must still receive the
# criterion. The 1.7.24 step adds the adversary section to `review-prompt.md` in
# `$WORK`, so a guard that compared `$TARGET` would refuse — and the file would
# still be published and stamped 1.7.27 with the criterion silently absent.
P1727OLD="$TMP/fake-$LANGUAGE-1727-pre1724"
mkdir -p "$P1727OLD"
git -C "$P1727OLD" init -q -b main
git -C "$P1727OLD" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1727OLD" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
# Strip the adversary section to make it a pre-1.7.24 shape.
cp "$S/references/review-prompt.1.7.23.md" "$P1727OLD/.sandcastle/review-prompt.md"
cp "$S/references/review-prompt-fixer.1.7.26.md" "$P1727OLD/.sandcastle/review/prompt.md"
cp "$S/references/review-axis-prompt.1.7.26.md" "$P1727OLD/.sandcastle/review/axis-prompt.md"
if [ "$LANGUAGE" = "python" ]; then
  node "$S/tools/adapt-check-command.mjs" --root "$P1727OLD" --scaffold "$S" >/dev/null
fi
printf '{"afk_template_version":"1.7.22","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1727OLD/.afk-bootstrap.json"
"$S/upgrade-afk.sh" "$P1727OLD" --cron-hour 13 >/dev/null 2>&1 \
  || { echo "upgrade refused a pre-1.7.24 consumer" >&2; exit 1; }
# BOTH sections must reach the published file: the 1.7.24 adversary duty AND the
# 1.7.27 criterion. Getting one without the other is the defect this checks.
grep -q 'You are the adversary, not the author' "$P1727OLD/.sandcastle/review-prompt.md" \
  || { echo "a pre-1.7.24 consumer lost the adversary duty" >&2; exit 1; }
grep -q 'check the double' "$P1727OLD/.sandcastle/review-prompt.md" \
  || { echo "a pre-1.7.24 consumer never got the double criterion" >&2; exit 1; }

# ---- 1.7.30: thinking-token heartbeats are kept out of the console ----------
# Measured 2026-10-27 (Claude Code 2.1.311, one real prompt): 227-342 frames of
# `{"type":"system","subtype":"thinking_tokens",…}` per run, 58% of every byte.
# The filter's own check is run here too: it is wired into afk-policy.yml, and a
# check nobody runs is the failure mode this repository keeps closing.
echo "1.7.30 heartbeat-filter checks..."

# (a) A NEW project gets the filter installed and the check wired.
for f in .sandcastle/quiet-heartbeats.ts .sandcastle/quiet-heartbeats.check.ts; do
  [ -e "$TARGET/$f" ] || { echo "a new scaffold has no $f" >&2; exit 1; }
done
grep -q 'quietThinkingHeartbeats()' "$TARGET/.sandcastle/profile.ts" \
  || { echo "a new scaffold never installs the heartbeat filter" >&2; exit 1; }
grep -q 'quiet-heartbeats.check.ts' "$TARGET/.github/workflows/afk-policy.yml" \
  || { echo "a new scaffold never runs the heartbeat check" >&2; exit 1; }

# (b) The filter's check itself, against the real frame shapes.
( cd "$TARGET" && npx --yes tsx .sandcastle/quiet-heartbeats.check.ts >/dev/null 2>&1 ) \
  || { echo "the heartbeat check fails on a fresh scaffold" >&2; exit 1; }

# (c) A consumer at 1.7.29 is upgraded: files copied, profile.ts gains the call,
#     CI gains the step. Deliberately a consumer that ALREADY ran the earlier
#     steps — the gate is the patch level, not the presence of anything else.
P1730="$TMP/fake-$LANGUAGE-1730"
mkdir -p "$P1730"
git -C "$P1730" init -q -b main
git -C "$P1730" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1730" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
# Strip what 1.7.30 adds, so the fixture is a real 1.7.29 tree.
rm -f "$P1730/.sandcastle/quiet-heartbeats.ts" "$P1730/.sandcastle/quiet-heartbeats.check.ts"
perl -0pi -e 's/^import \{ quietThinkingHeartbeats \} from "\.\/quiet-heartbeats\.js";\n//m' "$P1730/.sandcastle/profile.ts"
# Strip the comment block and the call, leaving the newline after
# `writeMcpConfig();` intact — the same shape a real pre-1.7.30 tree has. A
# pattern that also eats that newline glues the replacement to the next line and
# blames the migration for a fixture defect (measured: it did).
perl -0pi -e 's/  \/\/ Scan the console stream for the CLI.*?\n  quietThinkingHeartbeats\(\);\n//s' "$P1730/.sandcastle/profile.ts"
perl -0pi -e 's/      # The heartbeat filter.*?\n      - name: Verify the console heartbeat filter\n        run: npx --yes tsx \.sandcastle\/quiet-heartbeats\.check\.ts\n//s' "$P1730/.github/workflows/afk-policy.yml"
grep -q 'quiet' "$P1730/.sandcastle/profile.ts" \
  && { echo "fixture: the 1.7.29 shape still carries the filter" >&2; exit 1; }
printf '{"afk_template_version":"1.7.29","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1730/.afk-bootstrap.json"

OUT1730="$("$S/upgrade-afk.sh" "$P1730" --cron-hour 13 2>&1)" \
  || { echo "upgrade refused a 1.7.29 consumer" >&2; exit 1; }
grep -q 'heartbeats out of the log' <<<"$OUT1730" \
  || { echo "1.7.30 did not announce its own step" >&2; exit 1; }
for f in .sandcastle/quiet-heartbeats.ts .sandcastle/quiet-heartbeats.check.ts; do
  [ -e "$P1730/$f" ] || { echo "1.7.30 did not add $f" >&2; exit 1; }
done
grep -q 'quietThinkingHeartbeats();' "$P1730/.sandcastle/profile.ts" \
  || { echo "1.7.30 did not install the filter in profile.ts" >&2; exit 1; }
grep -q 'quiet-heartbeats.check.ts' "$P1730/.github/workflows/afk-policy.yml" \
  || { echo "1.7.30 did not wire the check into CI" >&2; exit 1; }
( cd "$P1730" && npx --yes tsx .sandcastle/quiet-heartbeats.check.ts >/dev/null 2>&1 ) \
  || { echo "the heartbeat check fails on an upgraded consumer" >&2; exit 1; }

# (d) NEGATIVE CONTROL: a consumer already at 1.7.30 must not run the step again
#     — and the install must stay a single call, not accumulate one per upgrade.
printf '{"afk_template_version":"1.7.29","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1730/.afk-bootstrap.json"
OUT1730B="$("$S/upgrade-afk.sh" "$P1730" --cron-hour 13 2>&1)" \
  || { echo "upgrade refused an already-upgraded consumer" >&2; exit 1; }
[ "$(grep -c 'quietThinkingHeartbeats();' "$P1730/.sandcastle/profile.ts")" = "1" ] \
  || { echo "a second upgrade installed the heartbeat filter twice" >&2; exit 1; }
[ "$(grep -c 'quiet-heartbeats.check.ts' "$P1730/.github/workflows/afk-policy.yml")" = "1" ] \
  || { echo "a second upgrade wired the heartbeat check twice" >&2; exit 1; }
grep -q 'already installed' <<<"$OUT1730B" \
  || { echo "a second upgrade did not report the filter as already installed" >&2; exit 1; }

# (e) A consumer that restructured claudeProfile (no anchor) is TOLD, not
#     half-edited. The import must not land without the call.
P1730ODD="$TMP/fake-$LANGUAGE-1730-odd"
mkdir -p "$P1730ODD"
git -C "$P1730ODD" init -q -b main
git -C "$P1730ODD" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1730ODD" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
rm -f "$P1730ODD/.sandcastle/quiet-heartbeats.ts" "$P1730ODD/.sandcastle/quiet-heartbeats.check.ts"
perl -0pi -e 's/^import \{ quietThinkingHeartbeats \} from "\.\/quiet-heartbeats\.js";\n//m' "$P1730ODD/.sandcastle/profile.ts"
# Same newline-preserving strip as above; this fixture already removes the
# surrounding anchors separately.
perl -0pi -e 's/  \/\/ Scan the console stream for the CLI.*?\n  quietThinkingHeartbeats\(\);\n//s' "$P1730ODD/.sandcastle/profile.ts"
# Remove BOTH anchors: the network import and the MCP materialisation call.
perl -0pi -e 's/^import \{ sandboxNetworkOptions \} from "\.\/profile-network\.js";\n//m' "$P1730ODD/.sandcastle/profile.ts"
perl -0pi -e 's/^  writeMcpConfig\(\);\n//m' "$P1730ODD/.sandcastle/profile.ts"
printf '{"afk_template_version":"1.7.29","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1730ODD/.afk-bootstrap.json"
OUT1730ODD="$("$S/upgrade-afk.sh" "$P1730ODD" --cron-hour 13 2>&1)" \
  || { echo "upgrade refused an unanchored consumer instead of reporting it" >&2; exit 1; }
grep -q 'Install it by hand' <<<"$OUT1730ODD" \
  || { echo "1.7.30 silently skipped an unanchored profile.ts" >&2; exit 1; }
grep -q 'quiet-heartbeats.js' "$P1730ODD/.sandcastle/profile.ts" \
  && { echo "1.7.30 wrote a dangling import into an unanchored profile.ts" >&2; exit 1; }

echo "1.7.30 heartbeat-filter checks passed"

# ---- 1.7.31: the filter honours the writable-stream contract -----------------
# 1.7.30 shipped two defects that a passing run never shows: a suppressed write
# never called its completion callback, and the exit summary went through an
# async write that termination can discard. The check catches both — verified by
# reverting each fix and watching it fail — so this section's job is that the
# upgrade DELIVERS the fixed copy to a consumer that already took 1.7.30.
echo "1.7.31 heartbeat write-contract checks..."

# (a) The shipped copy is the fixed one: it writes the summary synchronously and
#     calls the callback. Asserted on the source because that is what the
#     mutation test showed is reliable.
grep -q 'writeSync(' "$TARGET/.sandcastle/quiet-heartbeats.ts" \
  || { echo "the shipped filter does not write its exit summary synchronously" >&2; exit 1; }
grep -q 'nextTick(callback' "$TARGET/.sandcastle/quiet-heartbeats.ts" \
  || { echo "the shipped filter never calls a suppressed write's callback" >&2; exit 1; }

# (b) MUTATION GUARD: both defects must fail the check. Without this, a check
#     that passes for the broken code certifies the bug it was written for.
MUT="$TMP/mut-$LANGUAGE"
mkdir -p "$MUT"
cp "$TARGET/.sandcastle/quiet-heartbeats.check.ts" "$MUT/"
# Drop the callback, keep everything else.
sed 's/process\.nextTick(callback as () => void);//' "$TARGET/.sandcastle/quiet-heartbeats.ts" > "$MUT/quiet-heartbeats.ts"
( cd "$MUT" && npx --yes tsx quiet-heartbeats.check.ts >/dev/null 2>&1 ) \
  && { echo "the check passes when a suppressed write never calls its callback" >&2; exit 1; }
# Make the exit summary an async write again, keep the callback.
sed 's/writeSync(/write(/' "$TARGET/.sandcastle/quiet-heartbeats.ts" > "$MUT/quiet-heartbeats.ts"
( cd "$MUT" && npx --yes tsx quiet-heartbeats.check.ts >/dev/null 2>&1 ) \
  && { echo "the check passes when the exit summary is an async write" >&2; exit 1; }

# (c) A consumer already carrying 1.7.30's copy is REPAIRED, not told
#     "already present".
P1731="$TMP/fake-$LANGUAGE-1731"
mkdir -p "$P1731"
git -C "$P1731" init -q -b main
git -C "$P1731" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1731" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
cp "$S/references/quiet-heartbeats-1.7.30/quiet-heartbeats.ts" "$P1731/.sandcastle/quiet-heartbeats.ts"
cp "$S/references/quiet-heartbeats-1.7.30/quiet-heartbeats.check.ts" "$P1731/.sandcastle/quiet-heartbeats.check.ts"
printf '{"afk_template_version":"1.7.30","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1731/.afk-bootstrap.json"
OUT1731="$("$S/upgrade-afk.sh" "$P1731" --cron-hour 13 2>&1)" \
  || { echo "upgrade refused a 1.7.30 consumer" >&2; exit 1; }
grep -q 'replaced quiet-heartbeats-1.7.30' <<<"$OUT1731" \
  || { echo "1.7.31 did not report replacing 1.7.30's defective copy" >&2; exit 1; }
grep -q 'writeSync(' "$P1731/.sandcastle/quiet-heartbeats.ts" \
  || { echo "a 1.7.30 consumer's filter was not repaired" >&2; exit 1; }
( cd "$P1731" && npx --yes tsx .sandcastle/quiet-heartbeats.check.ts >/dev/null 2>&1 ) \
  || { echo "the repaired filter fails its own check" >&2; exit 1; }

# (d) A consumer that edited the filter keeps its version and is TOLD.
P1731E="$TMP/fake-$LANGUAGE-1731-edited"
mkdir -p "$P1731E"
git -C "$P1731E" init -q -b main
git -C "$P1731E" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1731E" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
cp "$S/references/quiet-heartbeats-1.7.30/quiet-heartbeats.ts" "$P1731E/.sandcastle/quiet-heartbeats.ts"
cp "$S/references/quiet-heartbeats-1.7.30/quiet-heartbeats.check.ts" "$P1731E/.sandcastle/quiet-heartbeats.check.ts"
printf '\n// a project edit this script must not discard\n' >> "$P1731E/.sandcastle/quiet-heartbeats.ts"
printf '{"afk_template_version":"1.7.30","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1731E/.afk-bootstrap.json"
OUT1731E="$("$S/upgrade-afk.sh" "$P1731E" --cron-hour 13 2>&1)" \
  || { echo "upgrade refused a consumer with an edited filter" >&2; exit 1; }
grep -q 'project edits this script will not overwrite' <<<"$OUT1731E" \
  || { echo "1.7.31 overwrote or silently skipped an edited filter" >&2; exit 1; }
grep -q 'a project edit this script must not discard' "$P1731E/.sandcastle/quiet-heartbeats.ts" \
  || { echo "1.7.31 discarded a project edit to the filter" >&2; exit 1; }

echo "1.7.31 heartbeat write-contract checks passed"

# ---- 1.7.32: the check proves a run USES the filter -------------------------
# The gap review found in 1.7.31: the check called the module directly, so
# deleting the call from claudeProfile() left it — and CI — green while every
# runner printed heartbeats again. That is the "helper correct, wiring gone"
# shape profile-network.check.ts exists for, and it is now closed the same way.
echo "1.7.32 heartbeat wiring checks..."

# (a) The wiring assertion exists and is real: removing the install must fail.
WIRE="$TMP/wire-$LANGUAGE"
mkdir -p "$WIRE"
cp "$TARGET/.sandcastle/quiet-heartbeats.ts" "$TARGET/.sandcastle/quiet-heartbeats.check.ts" "$WIRE/"
cp "$TARGET/.sandcastle/profile.ts" "$WIRE/profile.ts"
( cd "$WIRE" && npx --yes tsx quiet-heartbeats.check.ts >/dev/null 2>&1 ) \
  || { echo "the wiring check fails on an intact scaffold" >&2; exit 1; }
perl -0pi -e 's/^  quietThinkingHeartbeats\(\);\n//m' "$WIRE/profile.ts"
grep -q 'quietThinkingHeartbeats();' "$WIRE/profile.ts" \
  && { echo "mutation fixture: the install was not removed" >&2; exit 1; }
( cd "$WIRE" && npx --yes tsx quiet-heartbeats.check.ts >/dev/null 2>&1 ) \
  && { echo "the check passes when profile.ts stops installing the filter" >&2; exit 1; }
# Commented out is the subtler spelling of the same regression.
cp "$TARGET/.sandcastle/profile.ts" "$WIRE/profile.ts"
perl -0pi -e 's/^  quietThinkingHeartbeats\(\);/  \/\/ quietThinkingHeartbeats();/m' "$WIRE/profile.ts"
( cd "$WIRE" && npx --yes tsx quiet-heartbeats.check.ts >/dev/null 2>&1 ) \
  && { echo "the check passes when profile.ts only *mentions* the filter" >&2; exit 1; }

# (b) The exit summary falls back to stderr, so a full pipe does not eat it.
grep -q 'writeSync(2,' "$TARGET/.sandcastle/quiet-heartbeats.ts" \
  || { echo "the exit summary has no stderr fallback" >&2; exit 1; }

# (c) A consumer carrying 1.7.31's copy is upgraded to 1.7.32, not left behind.
P1732="$TMP/fake-$LANGUAGE-1732"
mkdir -p "$P1732"
git -C "$P1732" init -q -b main
git -C "$P1732" remote add origin "https://github.com/$REPO.git"
"$S/bootstrap-afk.sh" "$P1732" --language "$LANGUAGE" --repo "$REPO" --no-build >/dev/null
cp "$S/references/quiet-heartbeats-1.7.31/quiet-heartbeats.ts" "$P1732/.sandcastle/quiet-heartbeats.ts"
cp "$S/references/quiet-heartbeats-1.7.31/quiet-heartbeats.check.ts" "$P1732/.sandcastle/quiet-heartbeats.check.ts"
printf '{"afk_template_version":"1.7.31","templateVersion":1,"language":"%s","repository":"kilbertert/smoke","cron_hour":13}\n' \
  "$LANGUAGE" > "$P1732/.afk-bootstrap.json"
OUT1732="$("$S/upgrade-afk.sh" "$P1732" --cron-hour 13 2>&1)" \
  || { echo "upgrade refused a 1.7.31 consumer" >&2; exit 1; }
grep -q 'replaced quiet-heartbeats-1.7.31' <<<"$OUT1732" \
  || { echo "1.7.32 left a 1.7.31 consumer on the copy without the wiring check" >&2; exit 1; }
( cd "$P1732" && npx --yes tsx .sandcastle/quiet-heartbeats.check.ts >/dev/null 2>&1 ) \
  || { echo "the upgraded 1.7.31 consumer fails its own check" >&2; exit 1; }

echo "1.7.32 heartbeat wiring checks passed"

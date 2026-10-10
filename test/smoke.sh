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
  .sandcastle/sandbox-prepare.sh \
  docs/agents/issue-tracker.md docs/agents/triage-labels.md docs/agents/domain.md \
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

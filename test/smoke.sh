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
printf '# Existing glossary\n' > "$TARGET/CONTEXT.md"
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
  .sandcastle/CODING_STANDARDS.md CONTEXT.md CLAUDE.md docs/afk-workflow.md \
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
grep -q 'claude-stepfun' "$TARGET/.sandcastle/profile.ts" || { echo "claude-stepfun profile missing" >&2; exit 1; }
grep -q 'claude-stepfun' "$TARGET/.sandcastle/main.ts" || { echo "claude-stepfun CLI option missing" >&2; exit 1; }
grep -q 'claude-stepfun)' "$TARGET/.sandcastle/Dockerfile" || { echo "claude-stepfun Docker dispatch missing" >&2; exit 1; }
# The generated workflow doc is project-owned once it lands (the fixture above
# pre-creates one), so the provider documentation is asserted on the template.
grep -q 'claude-stepfun' "$S/templates/afk-workflow.md" || { echo "claude-stepfun workflow documentation missing" >&2; exit 1; }
if grep -qE 'claude-ark|agentrouter|psydo|aliyun-deepseek' "$TARGET/.sandcastle/profile.ts" "$TARGET/.sandcastle/main.ts" "$TARGET/.sandcastle/Dockerfile" "$S/templates/afk-workflow.md"; then
  echo "a retired provider profile is still scaffolded" >&2
  exit 1
fi
grep -q 'vars.AFK_PROFILE || .claude-stepfun.' "$TARGET/.github/workflows/agent-implement.yml" \
  || { echo "workflow does not fall back to claude-stepfun" >&2; exit 1; }
grep -q '# Existing glossary' "$TARGET/CONTEXT.md" || { echo "existing glossary was overwritten" >&2; exit 1; }
if grep -q '{{PROJECT_NAME}}' "$WORKTREE_TARGET/CONTEXT.md"; then
  echo "generated glossary contains an unrendered project name" >&2
  exit 1
fi
grep -q "# fake-$LANGUAGE-project" "$WORKTREE_TARGET/CONTEXT.md" \
  || { echo "generated glossary project name is incorrect" >&2; exit 1; }
grep -q '# Existing workflow' "$TARGET/docs/afk-workflow.md" || { echo "existing workflow was overwritten" >&2; exit 1; }
grep -q '# Existing domain docs' "$TARGET/docs/agents/domain.md" || { echo "existing domain docs were overwritten" >&2; exit 1; }
grep -q '# Existing ADR' "$TARGET/docs/adr/0001-existing.md" || { echo "existing ADR was overwritten" >&2; exit 1; }
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
  const metadata = require(process.argv[1]);
  if (metadata.templateVersion !== 1 || metadata.afk_template_version !== "1.2.0" || metadata.consensus_version !== "1.0.0" || metadata.consensus_compatibility !== ">=1.0.0 <2.0.0" || metadata.language !== process.argv[2] || metadata.repository !== process.argv[3]) process.exit(1);
' "$TARGET/.afk-bootstrap.json" "$LANGUAGE" "$REPO" || { echo "template metadata invalid" >&2; exit 1; }

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
    > "$PROFILE_HOME/cliproxyapi/settings.stepfun.json"
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
        claudeProfile("claude-stepfun");
      });
    '
  ) || { echo "generated profile did not load" >&2; exit 1; }
  [ -e "$PROFILE_HOME/cliproxyapi/settings.stepfun.json" ] \
    || { echo "host stepfun settings fixture missing" >&2; exit 1; }
  grep -q 'home/agent/.afk-profile-settings.json' "$TARGET/.sandcastle/Dockerfile" \
    || { echo "Dockerfile does not use the mounted settings path" >&2; exit 1; }
  grep -q 'settings.stepfun.json' "$TARGET/.sandcastle/profile.ts" \
    || { echo "profile.ts does not resolve the stepfun host settings file" >&2; exit 1; }
fi

# ---- upgrade-afk: anchored migration of an already-scaffolded project --------
# The fixture is a verbatim 1.1.x project (five-profile map, old dispatch arm,
# psydo fallback), so the migration is exercised against real previous output
# rather than a reconstruction of it.
UPGRADE_TARGET="$TMP/upgrade-$LANGUAGE"
mkdir -p "$UPGRADE_TARGET/.github" "$UPGRADE_TARGET/docs"
cp -R "$S/test/fixtures/legacy-1.1.x/." "$UPGRADE_TARGET/"

UPGRADE_OUT="$("$S/upgrade-afk.sh" "$UPGRADE_TARGET")"
printf '%s\n' "$UPGRADE_OUT"
grep -q 'claude-stepfun)' "$UPGRADE_TARGET/.sandcastle/Dockerfile" \
  || { echo "upgrade did not install the stepfun dispatch arm" >&2; exit 1; }
if grep -qE 'claude-ark\|agentrouter\|psydo' "$UPGRADE_TARGET/.sandcastle/Dockerfile"; then
  echo "upgrade left the retired dispatch arm in place" >&2; exit 1
fi
grep -q 'vars.AFK_PROFILE || .claude-stepfun.' "$UPGRADE_TARGET/.github/workflows/agent-implement.yml" \
  || { echo "upgrade did not update the workflow fallback" >&2; exit 1; }
grep -q 'claude-stepfun' "$UPGRADE_TARGET/.sandcastle/main.ts" \
  || { echo "upgrade did not update the CLI usage string" >&2; exit 1; }
node -e '
  const m = require(process.argv[1]);
  if (m.afk_template_version !== "1.2.0") process.exit(1);
' "$UPGRADE_TARGET/.afk-bootstrap.json" || { echo "upgrade did not record the new version" >&2; exit 1; }
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
# The hand-port shape (a project that applied the stepfun profile by hand, with
# the endpoint baked in) converges onto the same mounted result, and its baked
# secret block is removed rather than left as a dead arm.
HANDPORT="$TMP/handport-$LANGUAGE"
mkdir -p "$HANDPORT/.github/workflows"
cp -R "$S/test/fixtures/handport-1.1.x/." "$HANDPORT/"
"$S/upgrade-afk.sh" "$HANDPORT" >/dev/null \
  || { echo "upgrade refused the hand-port shape" >&2; exit 1; }
[ "$(grep -c 'claude-stepfun)' "$HANDPORT/.sandcastle/Dockerfile")" = 1 ] \
  || { echo "hand-port did not converge to a single dispatch arm" >&2; exit 1; }
if grep -qE 'STEPFUN_BASE_URL|api_key|afk-stepfun-settings\.json' "$HANDPORT/.sandcastle/Dockerfile"; then
  echo "hand-port kept the baked endpoint instead of mounting it" >&2; exit 1
fi
grep -q 'settings.stepfun.json' "$HANDPORT/.sandcastle/profile.ts" \
  || { echo "hand-port did not resolve the mounted settings path" >&2; exit 1; }

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
  "$S/upgrade-afk.sh" "$FB" >/dev/null \
    || { echo "upgrade refused the retired fallback $retired" >&2; exit 1; }
  if grep -qF -e "$retired" "$FB/.github/workflows/agent-implement.yml"; then
    echo "upgrade left the retired fallback $retired in place" >&2; exit 1
  fi
  grep -qF -e "vars.AFK_PROFILE || 'claude-stepfun'" "$FB/.github/workflows/agent-implement.yml" \
    || { echo "upgrade did not write the new fallback for $retired" >&2; exit 1; }
done

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
"$S/upgrade-afk.sh" "$OLDEST" >/dev/null \
  || { echo "upgrade refused a 1.1.1 project" >&2; exit 1; }
grep -q 'claude-stepfun)' "$OLDEST/.sandcastle/Dockerfile" \
  || { echo "1.1.1 upgrade did not install the stepfun dispatch arm" >&2; exit 1; }
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

echo "$LANGUAGE smoke test passed"

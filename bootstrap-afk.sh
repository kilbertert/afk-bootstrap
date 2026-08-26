#!/usr/bin/env bash
#
# bootstrap-afk — scaffold the AFK development workflow
# (idea -> grill -> PRD -> native sub-issues -> AFK/Sandcastle -> draft PR ->
#  QA feedback) into a project, using Auto-Test's battle-tested implementation
# as the copy-verbatim baseline and generating the per-language parts.
#
# USAGE:
#   bootstrap-afk <target-repo> [--language node|python] [--repo owner/name]
#                 [--baseline <path>] [--no-build]
#
#   <target-repo>  path to the project (a git repo on its default branch).
#   --language     project toolchain: node | python  (default: node).
#   --repo         GitHub slug used to fix the to-prd-project skill
#                  (default: derived from `git remote get-url origin`).
#   --baseline     source of the copy-verbatim files
#                  (default: /home/claude/Projects/Auto-Test).
#   --no-build     skip building the sandcastle: docker image.
#
# It only creates files; it never commits or pushes. The host runner owns
# delivery (branch -> PR -> CI -> merge).
set -euo pipefail

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

TARGET="${1:-}"; shift || true
[ -n "$TARGET" ] || { usage; exit 1; }

LANGUAGE="node"; BASELINE="/home/claude/Projects/Auto-Test"; REPO=""; DO_BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --language) LANGUAGE="${2:?}"; shift 2;;
    --repo)     REPO="${2:?}"; shift 2;;
    --baseline) BASELINE="${2:?}"; shift 2;;
    --no-build) DO_BUILD=0; shift;;
    -h|--help)  usage; exit 0;;
    *) echo "unknown arg: $1" >&2; usage; exit 1;;
  esac
done

case "$LANGUAGE" in node|python) ;; *) echo "unsupported --language: $LANGUAGE" >&2; exit 1;; esac

# ---- validations -----------------------------------------------------------
[ -d "$TARGET/.git" ]          || { echo "not a git repo: $TARGET" >&2; exit 1; }
[ -e "$TARGET/.sandcastle" ]   && { echo "already scaffolded (.sandcastle exists): $TARGET" >&2; exit 1; }
[ -d "$BASELINE/.sandcastle" ] || { echo "baseline .sandcastle missing: $BASELINE" >&2; exit 1; }
if [ -z "$REPO" ]; then
  REPO=$(git -C "$TARGET" remote get-url origin 2>/dev/null \
    | sed -E 's#.*github.com[:/]([^/]+/[^/]+)(\.git)?$#\1#')
fi
[ -n "$REPO" ] || { echo "cannot determine GitHub repo; pass --repo owner/name" >&2; exit 1; }

SLUG="$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_.-]/-/g')"

S="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$TARGET/.sandcastle" "$TARGET/.claude/skills" "$TARGET/.github/workflows"

# ---- copy-verbatim from the baseline --------------------------------------
for f in main.ts profile.ts run-with-retry.ts retry-feedback.ts run-with-extraction.ts planner.ts .env.example .gitignore; do
  cp "$BASELINE/.sandcastle/$f" "$TARGET/.sandcastle/$f"
done
# planner + label-Actions prompts are copied verbatim (node: `npm run check`);
# a python project swaps the check command in the prompt-substitution step below.
for p in plan-prompt.md implement-prompt.md review-prompt.md merge-prompt.md; do
  cp "$BASELINE/.sandcastle/$p" "$TARGET/.sandcastle/$p"
done
for d in to-issues-prd write-prd-pr implement-prd implement write-pr review implement-pr update-branch architecture-review skills; do
  cp -R "$BASELINE/.sandcastle/$d" "$TARGET/.sandcastle/$d"
done
for d in to-prd-project to-issues-project; do
  cp -R "$BASELINE/.claude/skills/$d" "$TARGET/.claude/skills/$d"
done
for w in agent-to-issues-prd.yml agent-implement-prd.yml agent-implement.yml agent-review.yml agent-implement-pr.yml agent-update-branch.yml agent-promote-queued.yml architecture-review.yml; do
  cp "$BASELINE/.github/workflows/$w" "$TARGET/.github/workflows/$w"
done

# ---- point the copied profile.ts at THIS project's image -------------------
# The baseline bakes in its own tag (e.g. "sandcastle:auto-test"); the runner
# would otherwise keep using that instead of the image built below. Override
# the AFK_IMAGE default with sandcastle:<slug>.
sed -i 's#\(imageName: process.env.AFK_IMAGE ?? \)"[^"]*"#\1"sandcastle:'"$SLUG"'"#' "$TARGET/.sandcastle/profile.ts"

# ---- per-language generated files -----------------------------------------
cp "$S/templates/implement.$LANGUAGE.md"      "$TARGET/.sandcastle/implement.md"
cp "$S/templates/prompt.$LANGUAGE.md"         "$TARGET/.sandcastle/implement-prd/prompt.md"
cp "$S/templates/Dockerfile.$LANGUAGE"        "$TARGET/.sandcastle/Dockerfile"
cp "$S/templates/CODING_STANDARDS.md"         "$TARGET/.sandcastle/CODING_STANDARDS.md"

# ---- python: swap `npm run check` in the copied planner/action prompts -----
# The baseline prompts are node (`npm run check`); a python project's in-container
# agents must verify with uv instead.
if [ "$LANGUAGE" = "python" ]; then
  node -e '
    const fs = require("fs"), path = require("path");
    const check = "uv sync --extra dev && uv run pytest && uv run ruff check";
    (function walk(dir) {
      for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p);
        else if (e.name.endsWith(".md")) {
          const s = fs.readFileSync(p, "utf8");
          if (s.includes("npm run check")) {
            fs.writeFileSync(p, s.replace(/npm run check/g, check));
          }
        }
      }
    })(process.argv[1]);
  ' "$TARGET/.sandcastle"
fi

# ---- fix the repo slug baked into the to-prd-project skill ----------------
sed -i "s#kilbertert/Auto_Test#$REPO#g" "$TARGET/.claude/skills/to-prd-project/SKILL.md"

# ---- node_modules: the scaffold adds Node deps; keep them out of git ------
if [ -f "$TARGET/.gitignore" ] && ! grep -qx 'node_modules' "$TARGET/.gitignore"; then
  printf '\n# AFK runner (package.json) dependencies\nnode_modules/\n' >> "$TARGET/.gitignore"
fi

# ---- package.json: merge or create ----------------------------------------
if [ -f "$TARGET/package.json" ]; then
  node -e '
    const fs = require("fs"); const p = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    p.scripts = { ...(p.scripts || {}), "afk": "tsx .sandcastle/main.ts", "ralph": "tsx .sandcastle/planner.ts", "prd:to-issues": "tsx .sandcastle/to-issues-prd/to-issues-prd.ts" };
    p.dependencies = { ...(p.dependencies || {}), "tsx": "^4.20.0", "zod": "^4.4.3" };
    p.devDependencies = { ...(p.devDependencies || {}), "@ai-hero/sandcastle": "^0.12.0", "@types/node": "^24.0.0" };
    fs.writeFileSync(process.argv[2], JSON.stringify(p, null, 2) + "\n");
  ' "$TARGET/package.json"
else
  NAME="$(basename "$TARGET")"
  cp "$S/templates/package.json" "$TARGET/package.json"
  node -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));p.name=process.argv[2];fs.writeFileSync(process.argv[1],JSON.stringify(p,null,2)+"\n")' \
    "$TARGET/package.json" "$NAME"
  echo "== generating package-lock.json for \`npm ci\` in the workflows =="
  (cd "$TARGET" && npm install --package-lock-only --silent)
fi

# ---- pnpm-workspace.yaml: allow esbuild build script (pnpm 11 blocks it) --
# pnpm 11 fails `pnpm install` on unreviewed build scripts (strictDepBuilds);
# the AFK runner auto-runs `pnpm install`, so esbuild must be approved or
# every `pnpm afk` dies before the agent starts.
if [ -f "$TARGET/pnpm-workspace.yaml" ]; then
  if grep -q '^allowBuilds:' "$TARGET/pnpm-workspace.yaml"; then
    if grep -qE '^[[:space:]]*esbuild:' "$TARGET/pnpm-workspace.yaml"; then
      sed -i 's/^\([[:space:]]*\)esbuild:.*/\1esbuild: true/' "$TARGET/pnpm-workspace.yaml"
    else
      sed -i '/^allowBuilds:/a\  esbuild: true' "$TARGET/pnpm-workspace.yaml"
    fi
  else
    printf '\nallowBuilds:\n  esbuild: true\n' >> "$TARGET/pnpm-workspace.yaml"
  fi
else
  cp "$S/templates/pnpm-workspace.yaml" "$TARGET/pnpm-workspace.yaml"
fi

# ---- build the sandbox image ----------------------------------------------
if [ "$DO_BUILD" = "1" ]; then
  IMG="sandcastle:$SLUG"
  echo "== building $IMG =="
  (cd "$TARGET" && docker build --build-arg AGENT_UID="$(id -u)" --build-arg AGENT_GID="$(id -g)" -t "$IMG" .sandcastle)
fi

# ---- report ----------------------------------------------------------------
cat <<EOF

== scaffolded $TARGET (language: $LANGUAGE, repo: $REPO) ==
Next steps (host runner owns delivery — this script commits nothing):

1. Commit the scaffold on a task branch, push, open a PR, and merge it.
2. Pick the model provider for Actions:
     gh variable set AFK_PROFILE --repo $REPO --body claude-ark
   (or psydo / aliyun-deepseek; profiles are server-global, no new credentials)
3. Create the AFK labels once:
     gh label create agent:to-issues  --repo $REPO --color ffffff --force
     gh label create agent:implement  --repo $REPO --color 000000 --force
     gh label create agent:in-progress --repo $REPO --color 0e8a16 --force
     gh label create agent:blocked     --repo $REPO --color d93f0b --force
4. For Actions to run you need a self-hosted runner registered for $REPO
   (repo-level; personal accounts cannot share runners). Set the AGENT_PAT
   secret so one sub-issue chains to the next. Until then, drive it locally:
     cd $TARGET
     AFK_PROFILE=claude-ark pnpm afk -- <issue-number>     # single issue
     AFK_PROFILE=claude-ark pnpm ralph                     # planner loop
5. Create the PRD parent issue (via /to-prd-project), label it agent:to-issues
   to split sub-issues, then agent:implement to start the chain.
   The label-driven Actions (implement/review/update-branch/promote-queued/
   architecture-review) also fire off the same labels.
EOF

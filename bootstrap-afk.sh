#!/usr/bin/env bash
#
# bootstrap-afk — scaffold the AFK development workflow
# (idea -> grill -> PRD -> native sub-issues -> AFK/Sandcastle -> draft PR ->
#  QA feedback) into a project from this repository's versioned scaffold.
#
# USAGE:
#   bootstrap-afk <target-repo> [--language node|python] [--repo owner/name]
#                 [--no-build]
#
#   <target-repo>  path to the project (a git repo on its default branch).
#   --language     project toolchain: node | python  (default: node).
#   --repo         GitHub slug used by the generated issue-tracker docs
#                  (default: derived from `git remote get-url origin`).
#   --no-build     skip building the sandcastle: docker image.
#
# It only creates files; it never commits or pushes. The host runner owns
# delivery (branch -> PR -> CI -> merge).
set -euo pipefail
umask 027

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

TARGET="${1:-}"; shift || true
[ -n "$TARGET" ] || { usage; exit 1; }

LANGUAGE="node"; REPO=""; DO_BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --language) LANGUAGE="${2:?}"; shift 2;;
    --repo)     REPO="${2:?}"; shift 2;;
    --no-build) DO_BUILD=0; shift;;
    -h|--help)  usage; exit 0;;
    *) echo "unknown arg: $1" >&2; usage; exit 1;;
  esac
done

case "$LANGUAGE" in node|python) ;; *) echo "unsupported --language: $LANGUAGE" >&2; exit 1;; esac

# ---- validations -----------------------------------------------------------
S="$(cd "$(dirname "$0")" && pwd)"
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "not a git repo: $TARGET" >&2; exit 1; }
[ -e "$TARGET/.sandcastle" ] && { echo "already scaffolded (.sandcastle exists): $TARGET" >&2; exit 1; }
[ -d "$S/scaffold/.sandcastle" ] || { echo "bundled scaffold missing: $S/scaffold" >&2; exit 1; }
TEMPLATE_VERSION="$(tr -d '[:space:]' < "$S/TEMPLATE_VERSION")"
[[ "$TEMPLATE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$ ]] \
  || { echo "invalid TEMPLATE_VERSION" >&2; exit 1; }
if [ -z "$REPO" ]; then
  REPO=$(git -C "$TARGET" remote get-url origin 2>/dev/null \
    | sed -E 's#.*github.com[:/]##; s#\.git$##')
fi
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || { echo "cannot determine GitHub repo; pass --repo owner/name" >&2; exit 1; }

SLUG="$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_.-]/-/g')"

mkdir -p "$TARGET"

# ---- copy the versioned scaffold without clobbering project files ----------
# Bootstrap adds missing files; an existing project document remains its own
# source of truth and is updated deliberately in a later migration.
cp -R --no-clobber "$S/scaffold/." "$TARGET/"

# ---- point the copied profile.ts at THIS project's image -------------------
# Render the AFK_IMAGE default with the image built below.
sed -i "s#__AFK_IMAGE__#sandcastle:$SLUG#g" "$TARGET/.sandcastle/profile.ts"

# ---- per-language generated files -----------------------------------------
cp "$S/templates/implement.$LANGUAGE.md"      "$TARGET/.sandcastle/implement.md"
cp "$S/templates/prompt.$LANGUAGE.md"         "$TARGET/.sandcastle/implement-prd/prompt.md"
cp "$S/templates/Dockerfile.$LANGUAGE"        "$TARGET/.sandcastle/Dockerfile"
cp "$S/templates/CODING_STANDARDS.md"         "$TARGET/.sandcastle/CODING_STANDARDS.md"
if [ ! -e "$TARGET/CONTEXT.md" ]; then
  cp "$S/templates/CONTEXT.md" "$TARGET/CONTEXT.md"
fi
mkdir -p "$TARGET/docs"
if [ ! -e "$TARGET/docs/afk-workflow.md" ]; then
  cp "$S/templates/afk-workflow.md" "$TARGET/docs/afk-workflow.md"
fi

# ---- append the managed instruction block without masking project rules ----
AFK_MANAGED_BLOCK="$S/templates/AFK-MANAGED-BLOCK.md"
append_managed_block() {
  local path="$1"
  if [ -e "$path" ]; then
    grep -q '<!-- afk-bootstrap:managed:start -->' "$path" && return 0
    printf '\n%s\n' "$(cat "$AFK_MANAGED_BLOCK")" >> "$path"
  else
    cp "$AFK_MANAGED_BLOCK" "$path"
  fi
}

# Codex loads AGENTS.override.md in preference to AGENTS.md. If a project
# already has one, update it as well so the gate is present in the file Codex
# will actually read; never create a new override file.
if [ -e "$TARGET/AGENTS.md" ]; then
  append_managed_block "$TARGET/AGENTS.md"
elif [ -e "$TARGET/AGENTS.override.md" ]; then
  append_managed_block "$TARGET/AGENTS.override.md"
else
  append_managed_block "$TARGET/AGENTS.md"
fi
if [ -e "$TARGET/AGENTS.md" ] && [ -e "$TARGET/AGENTS.override.md" ]; then
  append_managed_block "$TARGET/AGENTS.override.md"
fi
append_managed_block "$TARGET/CLAUDE.md"

# ---- python: swap `npm run check` in the copied planner/action prompts -----
# The bundled prompts are node (`npm run check`); a python project's in-container
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

# ---- record scaffold provenance -------------------------------------------
node -e '
  const fs = require("fs");
  const [path, version, language, repository, contractPath] = process.argv.slice(1);
  const contract = JSON.parse(fs.readFileSync(contractPath, "utf8"));
  fs.writeFileSync(path, JSON.stringify({
    templateVersion: Number(version.split(".")[0]),
    afk_template_version: version,
    consensus_version: contract.consensus_version,
    consensus_compatibility: contract.afk_template_compatibility,
    language,
    repository,
  }, null, 2) + "\n");
' "$TARGET/.afk-bootstrap.json" "$TEMPLATE_VERSION" "$LANGUAGE" "$REPO" "$TARGET/.sandcastle/consensus-contract.json"

# ---- node_modules: the scaffold adds Node deps; keep them out of git ------
if [ -f "$TARGET/.gitignore" ] && ! grep -qx 'node_modules' "$TARGET/.gitignore"; then
  printf '\n# AFK runner (package.json) dependencies\nnode_modules/\n' >> "$TARGET/.gitignore"
fi

# ---- package.json: merge or create ----------------------------------------
if [ -f "$TARGET/package.json" ]; then
  node -e '
    const fs = require("fs"); const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const scripts = { ...(p.scripts || {}) };
    delete scripts["prd:to-issues"];
    p.scripts = { ...scripts, "afk": "tsx .sandcastle/main.ts", "ralph": "tsx .sandcastle/planner.ts", "afk:policy": "node .sandcastle/policy-check.mjs all" };
    p.dependencies = { ...(p.dependencies || {}), "tsx": "^4.20.0", "zod": "^4.4.3" };
    p.devDependencies = { ...(p.devDependencies || {}), "@ai-hero/sandcastle": "^0.12.0", "@types/node": "^24.0.0" };
    fs.writeFileSync(process.argv[1], JSON.stringify(p, null, 2) + "\n");
  ' "$TARGET/package.json"
  echo "== updating package-lock.json for \`npm ci\` in the workflows =="
  (cd "$TARGET" && npm install --package-lock-only --silent)
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
   (or agentrouter / psydo / aliyun-deepseek; profiles are server-global, no new credentials)
3. Create the AFK labels once:
  gh label create agent:implement  --repo $REPO --color 000000 --force
     gh label create agent:in-progress --repo $REPO --color 0e8a16 --force
     gh label create agent:blocked     --repo $REPO --color d93f0b --force
4. For Actions to run you need a self-hosted runner registered for $REPO
   (repo-level; personal accounts cannot share runners). Set the AGENT_PAT
   secret for host-side label chaining and the read-only AFK_AGENT_READ_TOKEN
   secret for Docker agents. Until then, drive it locally:
     cd $TARGET
     AFK_PROFILE=claude-ark pnpm afk -- <issue-number>     # single issue
     AFK_PROFILE=claude-ark pnpm ralph                     # planner loop
5. Use the installed official skills in order: /to-spec, then /to-tickets.
   Label the approved PRD agent:implement to run the retained PRD executor.
   The label-driven Actions (implement/review/update-branch/promote-queued/
   architecture-review) use the native issue shape and labels.
EOF

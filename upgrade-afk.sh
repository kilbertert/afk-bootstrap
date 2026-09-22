#!/usr/bin/env bash
#
# upgrade-afk — bring an already-scaffolded project up to the current
# afk-bootstrap template version.
#
# USAGE:
#   upgrade-afk <target-repo> [--dry-run]
#
#   <target-repo>  path to an AFK-scaffolded project (has .sandcastle/).
#   --dry-run      print what would change; write nothing.
#
# Why this exists: `bootstrap-afk.sh` refuses a target that already has
# `.sandcastle/`, so it can only create. This script performs the *upgrade*
# half: it applies each step of a version range to an existing project and
# records the new version in `.afk-bootstrap.json`.
#
# Why it is anchored rather than a template re-render: a scaffolded Dockerfile
# is project-owned after it lands. README tells projects to enable the
# Playwright block by uncommenting it, so re-rendering from `templates/` would
# silently revert that. Each step below therefore matches the exact lines the
# previous template generated and rewrites only those. A step whose anchor does
# not match is refused, never guessed at — a half-migrated file is worse than
# an unmigrated one.
#
# It only edits files; it never commits, pushes, or rebuilds the image. The
# host runner owns delivery, and the sandbox image must be rebuilt from the
# upgraded Dockerfile before AFK_PROFILE is switched to the new profile —
# changing the variable first makes the wrapper exit 2.
set -euo pipefail
umask 027

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

TARGET="${1:-}"; shift || true
[ -n "$TARGET" ] || { usage; exit 1; }

DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $1" >&2; usage; exit 1;;
  esac
done

S="$(cd "$(dirname "$0")" && pwd)"
[ -d "$TARGET/.sandcastle" ] || { echo "not an AFK-scaffolded project (no .sandcastle): $TARGET" >&2; exit 1; }
[ -f "$TARGET/.afk-bootstrap.json" ] || { echo "missing .afk-bootstrap.json: $TARGET" >&2; exit 1; }
[ -f "$TARGET/.sandcastle/Dockerfile" ] || { echo "missing .sandcastle/Dockerfile: $TARGET" >&2; exit 1; }

TEMPLATE_VERSION="$(tr -d '[:space:]' < "$S/TEMPLATE_VERSION")"
FROM="$(node -e 'process.stdout.write(String(require(process.argv[1]).afk_template_version ?? ""))' "$TARGET/.afk-bootstrap.json")"
[ -n "$FROM" ] || { echo ".afk-bootstrap.json has no afk_template_version" >&2; exit 1; }

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# Literal string replacement. The anchors below contain `|`, `(`, `)` and `.`
# — both sed delimiters and regex metacharacters — so `sed s///` either breaks
# on the delimiter or matches an alternation instead of the literal arm.
subst() {
  local file="$1" from="$2" to="$3"
  node -e '
    const fs = require("fs");
    const [path, from, to] = process.argv.slice(1);
    const source = fs.readFileSync(path, "utf8");
    if (!source.includes(from)) {
      console.error("anchor not found in " + path + ": " + from);
      process.exit(1);
    }
    fs.writeFileSync(path, source.split(from).join(to));
  ' "$file" "$from" "$to"
}

# Major bumps change structure this script will not guess at.
old_major="${FROM%%.*}"
new_major="${TEMPLATE_VERSION%%.*}"
if [ "$old_major" != "$new_major" ]; then
  echo "refusing a major template jump ($FROM -> $TEMPLATE_VERSION); migrate by hand" >&2
  exit 1
fi
if [ "$FROM" = "$TEMPLATE_VERSION" ]; then
  say "already at $TEMPLATE_VERSION; nothing to do"
  exit 0
fi

CHANGED=0
changed() { CHANGED=1; note "$*"; }

# ---- step: 1.1.x -> 1.2.0 — mount-based single provider ---------------------
# Old templates shipped five profiles: three resolved to host settings files
# under cliproxyapi/ whose upstream quota is exhausted, and aliyun-deepseek was
# the only Codex-provider profile. A run selecting any of them failed before the
# agent started. They are replaced by claude + claude-stepfun, both Claude Code
# profiles driven by a mounted host settings file.
if [ "$FROM" = "1.1.2" ] || [ "$FROM" = "1.1.3" ] || [ "$FROM" = "1.1.4" ] || [ "$FROM" = "1.1.5" ]; then
  say "== 1.1.x -> 1.2.0: single mount-based provider =="

  # 1. Dockerfile dispatch arm. Anchor is the exact arm the old templates wrote,
  #    plus the baked-secret variant a project may have hand-ported (AI-Ops
  #    #322 / Auto-Test #216 shape), which this step converges onto the mount.
  DOCKER="$TARGET/.sandcastle/Dockerfile"
  OLD_ARM="'  claude-ark|agentrouter|psydo) args=();"
  NEW_ARM="'  claude-stepfun) args=();"
  if grep -qF -e "$OLD_ARM" "$DOCKER"; then
    if [ "$DRY_RUN" = "1" ]; then
      changed "Dockerfile: dispatch arm claude-ark|agentrouter|psydo -> claude-stepfun"
    else
      subst "$DOCKER" "$OLD_ARM" "$NEW_ARM"
      changed "Dockerfile: dispatch arm claude-ark|agentrouter|psydo -> claude-stepfun"
    fi
  elif grep -qF -e "$NEW_ARM" "$DOCKER"; then
    note "Dockerfile: dispatch arm already names claude-stepfun"
  else
    echo "Dockerfile: no dispatch arm anchor found — refusing to guess" >&2
    exit 1
  fi

  # 2. A hand-ported image bakes the endpoint with a BuildKit secret and adds
  #    its own dispatch arm ahead of the settings arm. Both belong to the same
  #    hand-port and are removed together — the mount replaces them. Step 1
  #    above already rewrote the settings arm, so leaving this one would produce
  #    a second `claude-stepfun)` arm: the first matches, which makes it dead
  #    code pointing at a settings file the image no longer carries.
  BAKED_ARM='/home/agent/.afk-stepfun-settings.json'
  if grep -qE '^ARG STEPFUN_BASE_URL=' "$DOCKER" || grep -qF -e "$BAKED_ARM" "$DOCKER"; then
    if [ "$DRY_RUN" = "1" ]; then
      changed "Dockerfile: would drop the baked StepFun arm + secret block (key leaves the image layer)"
    else
      node -e '
        const fs = require("fs");
        const [path] = process.argv.slice(1);
        let lines = fs.readFileSync(path, "utf8").split("\n");

        // The baked dispatch arm, identified by the settings path only it uses.
        const arm = lines.findIndex((l) => l.includes("/home/agent/.afk-stepfun-settings.json"));
        if (arm >= 0) lines.splice(arm, 1);

        // The baked settings block: its ARG line through the chmod that ends
        // its RUN, plus the comment header directly above the ARG.
        const start = lines.findIndex((l) => l.startsWith("ARG STEPFUN_BASE_URL="));
        if (start >= 0) {
          let end = start;
          while (end < lines.length && !/^\s*&& chmod 600 \/home\/agent\/\.afk-stepfun-settings\.json\s*$/.test(lines[end])) end += 1;
          if (end >= lines.length) {
            console.error("could not find the end of the baked StepFun block");
            process.exit(1);
          }
          while (end + 1 < lines.length && lines[end + 1].trim() === "") end += 1;
          let from = start;
          while (from > 0 && lines[from - 1].startsWith("#")) from -= 1;
          lines.splice(from, end - from + 1);
        }

        // Collapse any blank-line run the removals left behind.
        lines = lines.filter((l, i) => !(l.trim() === "" && lines[i - 1]?.trim() === ""));
        fs.writeFileSync(path, lines.join("\n"));
      ' "$DOCKER"
      changed "Dockerfile: dropped the baked StepFun arm + secret block (key leaves the image layer)"
    fi
  else
    note "Dockerfile: no baked StepFun arm or secret block to remove"
  fi

  # 3. profile.ts. A hand-ported file has a single-entry map plus a large
  #    wholesale rewrite; an untouched 1.1.x file has the five-entry map. Either
  #    way the target file is the scaffold's own profile.ts, so it is copied
  #    verbatim — everything project-specific lives in the image-name line,
  #    which is preserved by re-rendering it.
  PROF="$TARGET/.sandcastle/profile.ts"
  IMAGE_NAME="$(grep -oE 'AFK_IMAGE \?\? "[^"]*"' "$PROF" | sed -E 's/.*"([^"]*)"/\1/')"
  [ -n "$IMAGE_NAME" ] || { echo "profile.ts: cannot read the AFK_IMAGE default" >&2; exit 1; }
  if cmp -s "$PROF" "$S/scaffold/.sandcastle/profile.ts"; then
    note "profile.ts: already current"
  elif [ "$DRY_RUN" = "1" ]; then
    changed "profile.ts: would render the current scaffold (keeping image $IMAGE_NAME)"
  else
    sed "s|__AFK_IMAGE__|${IMAGE_NAME}|" "$S/scaffold/.sandcastle/profile.ts" > "$PROF"
    changed "profile.ts: rendered the current scaffold (keeping image $IMAGE_NAME)"
  fi

  # 4. main.ts usage string, when the file is otherwise the scaffold's.
  MAIN="$TARGET/.sandcastle/main.ts"
  OLD_USAGE="--profile claude|claude-ark|agentrouter|psydo|aliyun-deepseek"
  NEW_USAGE="--profile claude|claude-stepfun"
  if grep -qF -e "$OLD_USAGE" "$MAIN"; then
    if [ "$DRY_RUN" = "1" ]; then
      changed "main.ts: would update the usage string"
    else
      subst "$MAIN" "$OLD_USAGE" "$NEW_USAGE"
      changed "main.ts: updated the usage string"
    fi
  else
    note "main.ts: usage string already current"
  fi

  # 5. Workflows: fallback default only. Templates pin `vars.AFK_PROFILE ||
  #    'psydo'`; the variable itself is a host-side setting, not a file.
  OLD_FALLBACK="vars.AFK_PROFILE || 'psydo'"
  NEW_FALLBACK="vars.AFK_PROFILE || 'claude-stepfun'"
  WF_CHANGED=0
  for wf in "$TARGET"/.github/workflows/*.yml; do
    [ -e "$wf" ] || continue
    grep -qF -e "$OLD_FALLBACK" "$wf" || continue
    if [ "$DRY_RUN" = "1" ]; then
      WF_CHANGED=1
    else
      subst "$wf" "$OLD_FALLBACK" "$NEW_FALLBACK"
      WF_CHANGED=1
    fi
  done
  if [ "$WF_CHANGED" = "1" ]; then
    changed "workflows: fallback AFK_PROFILE psydo -> claude-stepfun"
  else
    note "workflows: fallback already current"
  fi

  # 6. Report, never rewrite, the project's own prose. The generated
  #    docs/afk-workflow.md belongs to the project once it lands (README says
  #    a project document is its own source of truth), so a provider change in
  #    it is the project's edit to make. Naming the files makes that actionable
  #    instead of silent.
  PROSE=""
  for f in "$TARGET/docs/afk-workflow.md" "$TARGET/docs/afk-development.md" "$TARGET/README.md"; do
    [ -e "$f" ] || continue
    if grep -qE 'claude-ark|agentrouter|psydo|aliyun-deepseek' "$f"; then
      PROSE="$PROSE ${f#"$TARGET"/}"
    fi
  done
  if [ -n "$PROSE" ]; then
    say ""
    say "Project prose still names a retired profile (this script does not edit it):"
    for f in $PROSE; do say "  - $f"; done
  fi
else
  echo "no upgrade step defined from $FROM to $TEMPLATE_VERSION" >&2
  exit 1
fi

# ---- record the new version ------------------------------------------------
if [ "$CHANGED" = "0" ]; then
  say "template files already current for $TEMPLATE_VERSION"
fi
if [ "$DRY_RUN" = "1" ]; then
  say "== dry run: nothing written; would record afk_template_version $FROM -> $TEMPLATE_VERSION =="
  exit 0
fi

node -e '
  const fs = require("fs");
  const [path, version] = process.argv.slice(1);
  const metadata = JSON.parse(fs.readFileSync(path, "utf8"));
  metadata.templateVersion = Number(String(version).split(".")[0]);
  metadata.afk_template_version = version;
  fs.writeFileSync(path, JSON.stringify(metadata, null, 2) + "\n");
' "$TARGET/.afk-bootstrap.json" "$TEMPLATE_VERSION"
say ""
say "== upgraded $TARGET: $FROM -> $TEMPLATE_VERSION =="
cat <<EOF
Still to do (host runner owns delivery — this script commits nothing):

1. Rebuild the sandbox image from the upgraded Dockerfile:
     docker build --build-arg AGENT_UID="\$(id -u)" --build-arg AGENT_GID="\$(id -g)" -t <image> .sandcastle
2. Then switch the repository variable, in that order:
     gh variable set AFK_PROFILE --repo <owner/name> --body claude-stepfun
   Changing it before the rebuild makes the image's claude wrapper exit 2,
   because the old image has no claude-stepfun dispatch arm.
3. Update any project prose still naming a retired profile (listed above).
EOF

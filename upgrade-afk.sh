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
# Every step runs against a staging copy and the result is published only after
# the last step succeeds, so a refused migration leaves the project untouched.
# A step that fails after an earlier step already wrote would otherwise leave a
# Dockerfile migrated under metadata that still claims the old version.
#
# It only edits files; it never commits, pushes, or rebuilds the image. The
# host runner owns delivery, and the sandbox image must be rebuilt from the
# upgraded Dockerfile before AFK_PROFILE is switched to the new profile —
# changing the variable first makes the wrapper exit 2.
set -euo pipefail
umask 027

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
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

# Is this file a shape a template generated, or one a project has edited?
#
# Replacing profile.ts is the only step that discards a file rather than editing
# a line, so this decides what may be discarded. A presence test is not enough: a
# project that *added* a mount or an env var keeps every marker the scaffold has,
# so the file is compared to the two shapes that actually exist in the field —
# the pristine 1.1.x output and the `claude-stepfun` hand-port — with the two
# things a project legitimately varies normalised away: the profile table, which
# a hand-port trimmed, and the image name, which is per-project. Anything else is
# a project edit and is refused rather than overwritten.
profile_is_generated_shape() {
  local candidate="$1"
  local refs="$S/test/fixtures/legacy-1.1.x/.sandcastle/profile.ts $S/test/fixtures/handport-1.1.x/.sandcastle/profile.ts"
  local reference
  for reference in $refs; do
    [ -f "$reference" ] || { echo "profile.ts: migration reference missing: $reference" >&2; return 1; }
  done
  # shellcheck disable=SC2086
  profile_matches "$candidate" $refs
}

# Compare a profile.ts to reference shape(s) with the two project-variable
# values normalised away, so its exact bytes are never the question.
profile_matches() {
  node -e '
    const fs = require("fs");
    const [candidate, ...references] = process.argv.slice(1);
    const normalise = (source) => source
      .replace(/const profiles = \{[\s\S]*?\} as const;/, "const profiles = TABLE;")
      .replace(/(imageName: process\.env\.AFK_IMAGE \?\? ")[^"]*(")/, "IMAGE_NAME");
    let actual;
    try {
      actual = normalise(fs.readFileSync(candidate, "utf8"));
    } catch {
      process.exit(1);
    }
    const match = references.some((reference) => {
      try {
        return normalise(fs.readFileSync(reference, "utf8")) === actual;
      } catch {
        return false;
      }
    });
    process.exit(match ? 0 : 1);
  ' "$@"
}

# A migration only ever moves forward within one major version. Comparing the
# majors alone is not enough: a project already at 1.3.0 must not be pulled
# back to this script's 1.2.0, so the full versions are compared.
parse_semver() {
  node -e '
    const raw = process.argv[1];
    const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(raw);
    if (!match) {
      console.error("invalid SemVer: " + raw);
      process.exit(1);
    }
    process.stdout.write(match.slice(1).join(" "));
  ' "$1"
}
if ! FROM_PARTS="$(parse_semver "$FROM")"; then
  echo ".afk-bootstrap.json has an invalid afk_template_version: $FROM" >&2
  exit 1
fi
# shellcheck disable=SC2086
set -- $FROM_PARTS
from_major=$1 from_minor=$2 from_patch=$3
if ! TO_PARTS="$(parse_semver "$TEMPLATE_VERSION")"; then
  echo "TEMPLATE_VERSION is not valid SemVer: $TEMPLATE_VERSION" >&2
  exit 1
fi
# shellcheck disable=SC2086
set -- $TO_PARTS
to_major=$1 to_minor=$2 to_patch=$3

if [ "$from_major" != "$to_major" ]; then
  echo "refusing a major template jump ($FROM -> $TEMPLATE_VERSION); migrate by hand" >&2
  exit 1
fi
if [ "$from_minor" -gt "$to_minor" ] ||
   { [ "$from_minor" -eq "$to_minor" ] && [ "$from_patch" -gt "$to_patch" ]; }; then
  echo "refusing to downgrade ($FROM -> $TEMPLATE_VERSION)" >&2
  exit 1
fi
if [ "$FROM" = "$TEMPLATE_VERSION" ]; then
  say "already at $TEMPLATE_VERSION; nothing to do"
  exit 0
fi

# Every write below targets the staging copy; the originals are read-only
# inputs. Publishing happens once, at the end, and only for a run that reached
# it.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
WORK="$STAGE/project"
mkdir -p "$WORK/.github"
cp -R "$TARGET/.sandcastle" "$WORK/.sandcastle"
cp -R "$TARGET/.github/workflows" "$WORK/.github/workflows"
cp "$TARGET/.afk-bootstrap.json" "$WORK/.afk-bootstrap.json"

# ---- step: 1.1.x -> 1.2.0 — mount-based single provider ---------------------
# Old templates shipped five profiles: three resolved to host settings files
# under cliproxyapi/ whose upstream quota is exhausted, and aliyun-deepseek was
# the only Codex-provider profile. A run selecting any of them failed before the
# agent started. They are replaced by claude + claude-stepfun, both Claude Code
# profiles driven by a mounted host settings file.
if [ "$from_minor" -eq 1 ] && [ "$to_minor" -eq 2 ]; then
  say "== $FROM -> $TEMPLATE_VERSION: single mount-based provider =="

  # 1. Dockerfile dispatch arm. Anchor is the exact arm the old templates wrote.
  #    A hand-port that added its own arm is handled by step 2.
  DOCKER="$WORK/.sandcastle/Dockerfile"
  OLD_ARM="'  claude-ark|agentrouter|psydo) args=();"
  NEW_ARM="'  claude-stepfun) args=();"
  if grep -qF -e "$OLD_ARM" "$DOCKER"; then
    subst "$DOCKER" "$OLD_ARM" "$NEW_ARM"
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
    node -e '
      const fs = require("fs");
      const [path] = process.argv.slice(1);
      let lines = fs.readFileSync(path, "utf8").split("\n");

      // The baked dispatch arm, identified by the settings path only it uses.
      const arm = lines.findIndex((l) => l.includes("/home/agent/.afk-stepfun-settings.json"));
      if (arm >= 0) lines.splice(arm, 1);

      // The hand-port also documented the secret build invocation at the top of
      // the file. Once the endpoint is mounted that instruction tells a reader to
      // build an image the migration just removed, so it goes with it.
      const doc = lines.findIndex((l) => l.includes("--secret id=stepfun_api_key"));
      if (doc >= 0) {
        let from = doc;
        while (from > 0 && lines[from - 1].trimStart().startsWith("#")) from -= 1;
        let to = doc;
        while (to + 1 < lines.length && lines[to + 1].trimStart().startsWith("#")) to += 1;
        lines.splice(from, to - from + 1);
      }

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
  else
    note "Dockerfile: no baked StepFun arm or secret block to remove"
  fi

  # 3. profile.ts. This is the one step that replaces a file rather than editing
  #    a line, so it verifies what it is about to discard. A project may have
  #    added a mount, an env var, or a provider of its own to claudeProfile;
  #    replacing that wholesale would delete the change and record success.
  #    Only the two generated shapes are migrated — the 1.1.x five-profile map,
  #    and the single-provider map a project may have hand-ported — identified by
  #    their profile table and the scaffold body they kept. Anything else is
  #    reported as a project edit this script will not overwrite.
  PROF="$WORK/.sandcastle/profile.ts"
  IMAGE_NAME="$(grep -oE 'AFK_IMAGE \?\? "[^"]*"' "$PROF" | sed -E 's/.*"([^"]*)"/\1/')"
  [ -n "$IMAGE_NAME" ] || { echo "profile.ts: cannot read the AFK_IMAGE default" >&2; exit 1; }
  if profile_matches "$PROF" "$S/scaffold/.sandcastle/profile.ts"; then
    note "profile.ts: already current"
  elif profile_is_generated_shape "$PROF"; then
    sed "s|__AFK_IMAGE__|${IMAGE_NAME}|" "$S/scaffold/.sandcastle/profile.ts" > "$PROF"
  else
    say ""
    say "profile.ts is not a generated shape — it has project edits this script"
    say "will not overwrite. Migrate .sandcastle/profile.ts by hand: it must keep"
    say "only the claude and claude-stepfun profiles, with the endpoint supplied"
    say "by the mounted settings file (see .sandcastle/Dockerfile)."
    exit 1
  fi

  # 4. main.ts usage string. Both anchors are checked, so a file whose entry
  #    was customised to some third value is refused rather than recorded as
  #    migrated while still advertising a profile the image does not dispatch.
  MAIN="$WORK/.sandcastle/main.ts"
  OLD_USAGE="--profile claude|claude-ark|agentrouter|psydo|aliyun-deepseek"
  NEW_USAGE="--profile claude|claude-stepfun"
  if grep -qF -e "$OLD_USAGE" "$MAIN"; then
    subst "$MAIN" "$OLD_USAGE" "$NEW_USAGE"
  elif grep -qF -e "$NEW_USAGE" "$MAIN"; then
    note "main.ts: usage string already current"
  else
    echo "main.ts: no usage string anchor found — refusing to guess" >&2
    exit 1
  fi

  # 5. Workflows: fallback default only. Templates pin `vars.AFK_PROFILE ||
  #    'psydo'`; the variable itself is a host-side setting, not a file.
  OLD_FALLBACK="vars.AFK_PROFILE || 'psydo'"
  NEW_FALLBACK="vars.AFK_PROFILE || 'claude-stepfun'"
  for wf in "$WORK"/.github/workflows/*.yml; do
    [ -e "$wf" ] || continue
    grep -qF -e "$OLD_FALLBACK" "$wf" || continue
    subst "$wf" "$OLD_FALLBACK" "$NEW_FALLBACK"
  done

  # 6. Report, never rewrite, the project's own prose. The generated
  #    docs/afk-workflow.md belongs to the project once it lands (README says
  #    a project document is its own source of truth), so a provider change in
  #    it is the project's edit to make. Naming the files makes that actionable
  #    instead of silent. Read from the target: the staging copy only holds the
  #    files this step can write.
  PROSE=""
  for f in "$TARGET/docs/afk-workflow.md" "$TARGET/docs/afk-development.md" "$TARGET/README.md"; do
    [ -e "$f" ] || continue
    if grep -qE 'claude-ark|agentrouter|psydo|aliyun-deepseek' "$f"; then
      PROSE="$PROSE ${f#"$TARGET"/}"
    fi
  done
else
  echo "no upgrade step defined from $FROM to $TEMPLATE_VERSION" >&2
  exit 1
fi

# The staged metadata is rewritten here, before the change report, so a dry run
# lists .afk-bootstrap.json like every other file it would touch.
node -e '
  const fs = require("fs");
  const [path, version] = process.argv.slice(1);
  const metadata = JSON.parse(fs.readFileSync(path, "utf8"));
  metadata.templateVersion = Number(String(version).split(".")[0]);
  metadata.afk_template_version = version;
  fs.writeFileSync(path, JSON.stringify(metadata, null, 2) + "\n");
' "$WORK/.afk-bootstrap.json" "$TEMPLATE_VERSION"

# ---- report and publish ----------------------------------------------------
# What changed is derived by comparing staged against original, so it cannot
# drift from what the steps actually did.
CHANGED=0
for rel in .sandcastle/Dockerfile .sandcastle/profile.ts .sandcastle/main.ts .afk-bootstrap.json; do
  cmp -s "$TARGET/$rel" "$WORK/$rel" && continue
  CHANGED=1
  note "changed: $rel"
done
if ! diff -rq "$TARGET/.github/workflows" "$WORK/.github/workflows" >/dev/null 2>&1; then
  CHANGED=1
  note "changed: .github/workflows/"
fi

if [ -n "$PROSE" ]; then
  say ""
  say "Project prose still names a retired profile (this script does not edit it):"
  for f in $PROSE; do say "  - $f"; done
fi

if [ "$DRY_RUN" = "1" ]; then
  # The staged copy is discarded by the trap; nothing under $TARGET was opened
  # for writing at any point above.
  say ""
  say "== dry run: nothing written; would record afk_template_version $FROM -> $TEMPLATE_VERSION =="
  exit 0
fi

if [ "$CHANGED" = "0" ]; then
  say "template files already current for $TEMPLATE_VERSION"
fi

# Staging protects the transform phase, but publishing still mutates the target
# one file at a time. Back every destination up first and restore all of them if
# any write fails, so an interrupted or failing publish cannot leave a migrated
# Dockerfile next to metadata that still claims the old version.
PUBLISHED=""
restore_published() {
  local status=$?
  if [ -n "$PUBLISHED" ]; then
    say "publish failed; restoring the project" >&2
    for rel in $PUBLISHED; do
      cp "$STAGE/backup/$rel" "$TARGET/$rel" || say "could not restore $rel" >&2
    done
  fi
  rm -rf "$STAGE"
  exit "$status"
}
mkdir -p "$STAGE/backup/.sandcastle" "$STAGE/backup/.github"
trap restore_published EXIT

publish_file() {
  local rel="$1"
  mkdir -p "$(dirname "$TARGET/$rel")"
  cp "$TARGET/$rel" "$STAGE/backup/$rel"
  cp "$WORK/$rel" "$TARGET/$rel" || return 1
  PUBLISHED="$rel $PUBLISHED"
  return 0
}

# Metadata goes last: until every content file is in place it should keep
# describing the version the tree actually is.
for rel in .sandcastle/Dockerfile .sandcastle/profile.ts .sandcastle/main.ts; do
  publish_file "$rel" || { say "could not publish $rel" >&2; exit 1; }
done
if ! diff -rq "$TARGET/.github/workflows" "$WORK/.github/workflows" >/dev/null 2>&1; then
  # Back up the whole directory, then copy it across, so a partial copy is undone
  # by restoring the directory rather than by re-copying per file.
  cp -R "$TARGET/.github/workflows" "$STAGE/backup/.github/workflows"
  PUBLISHED=".github/workflows $PUBLISHED"
  rm -rf "$TARGET/.github/workflows"
  cp -R "$WORK/.github/workflows" "$TARGET/.github/workflows" \
    || { say "could not publish .github/workflows" >&2; exit 1; }
fi
publish_file ".afk-bootstrap.json" || { say "could not publish .afk-bootstrap.json" >&2; exit 1; }

# Every write is done; disarm the rollback rather than restoring over it.
PUBLISHED=""
trap 'rm -rf "$STAGE"' EXIT

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

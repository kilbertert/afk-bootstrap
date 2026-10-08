#!/usr/bin/env bash
#
# upgrade-afk — bring an already-scaffolded project up to the current
# afk-bootstrap template version.
#
# USAGE:
#   upgrade-afk <target-repo> [--dry-run] [--cron-hour 0-23]
#
#   <target-repo>  path to an AFK-scaffolded project (has .sandcastle/).
#   --dry-run      print what would change; write nothing.
#   --cron-hour    schedule hour for architecture-review, recorded in
#                  .afk-bootstrap.json. Required only when the project has no
#                  hour recorded yet and still runs at the shared 09:00: every
#                  project on a host shares one upstream credential and one
#                  concurrency limit, and a review runs 20-68 minutes, so two
#                  projects on one hour fail with 429. There is no safe
#                  default, so this is refused rather than guessed.
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
  sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'
}

TARGET="${1:-}"; shift || true
[ -n "$TARGET" ] || { usage; exit 1; }

DRY_RUN=0; CRON_HOUR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift;;
    --cron-hour) CRON_HOUR="${2:?}"; shift 2;;
    -h|--help)   usage; exit 0;;
    *) echo "unknown arg: $1" >&2; usage; exit 1;;
  esac
done
if [ -n "$CRON_HOUR" ] && ! [[ "$CRON_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
  echo "--cron-hour must be 0-23, got: $CRON_HOUR" >&2; exit 1
fi

S="$(cd "$(dirname "$0")" && pwd)"
[ -d "$TARGET/.sandcastle" ] || { echo "not an AFK-scaffolded project (no .sandcastle): $TARGET" >&2; exit 1; }
[ -f "$TARGET/.afk-bootstrap.json" ] || { echo "missing .afk-bootstrap.json: $TARGET" >&2; exit 1; }
[ -f "$TARGET/.sandcastle/Dockerfile" ] || { echo "missing .sandcastle/Dockerfile: $TARGET" >&2; exit 1; }

TEMPLATE_VERSION="$(tr -d '[:space:]' < "$S/TEMPLATE_VERSION")"
FROM="$(node -e 'process.stdout.write(String(require(process.argv[1]).afk_template_version ?? ""))' "$TARGET/.afk-bootstrap.json")"
[ -n "$FROM" ] || { echo ".afk-bootstrap.json has no afk_template_version" >&2; exit 1; }

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# The schedule hour for this project.
#
# An explicitly recorded hour wins; otherwise `--cron-hour` is REQUIRED. Carrying
# the old value over looks tempting — a project at `0 9 * * 1-5` is already on
# hour 9 — but it is wrong for the case this exists for: five projects on this
# host all run at hour 9, so "preserve" reproduces the collision exactly. Which
# hours are free is fleet-level information (it depends on which projects share
# one upstream credential), and this script sees one project, so it cannot
# derive it. An operator can.
#

# The hour a project's own cron line already occupies.
#
# This is not a default and not a choice: the hour is already in use by this
# project, so recording it asserts a fact rather than inventing one. Empty when
# the shape is something else — a schedule this script cannot read an hour from
# is reported, never guessed at.
#
# A constant minute is required (`30 4 ...` or `0 4 ...`, not `*/30 4 ...`): an
# hour field only identifies an occupied hour when the minute is fixed, since a
# 20-68 minute review starting at `*/30 4` spills across the whole hour anyway.
existing_cron_hour() {
  # Scans LINE BY LINE for an uncommented `- cron:` entry. `String.match` finds
  # the first occurrence anywhere, which for a workflow that keeps its old
  # schedule commented out is the COMMENT — and the hour it names is not the one
  # the project runs. A leading `-` is the test: `# - cron:` does not match.
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
    for (const line of lines) {
      if (!/^[ \t]*-[ \t]*cron:/.test(line)) continue;
      const m = line.match(/"(\d{1,2}) +(\d{1,2}) +\* +\* +[^"]*"/);
      if (m) { process.stdout.write(String(Number(m[2]))); process.exit(0); }
    }
    process.stdout.write("");
  ' "$ARCH"
}

# Empty means the caller must be told; the caller refuses rather than default.
#
# A recorded value is validated here, not trusted: it lands directly in the cron
# expression, so a hand-edited or corrupted `cron_hour` would otherwise produce
# an invalid schedule — which disables the workflow silently rather than failing.
resolve_hour() {
  local hour
  if [ -n "$CRON_HOUR" ]; then hour="$CRON_HOUR"; else
    hour="$(node -e '
      const fs = require("fs");
      const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      process.stdout.write(m.cron_hour == null ? "" : String(m.cron_hour));
    ' "$TARGET/.afk-bootstrap.json")"
  fi
  [ -z "$hour" ] && return 0
  case "$hour" in
    ''|*[!0-9]*) echo "cron_hour is not an integer: $hour" >&2; exit 1;;
  esac
  if [ "$hour" -gt 23 ]; then
    echo "cron_hour is outside 0-23: $hour" >&2; exit 1
  fi
  printf '%s' "$hour"
}

# Every project on a host shares one upstream credential and one concurrency
# limit, and a review runs 20-68 minutes, so two projects on one hour fail with
# 429. This script cannot see the fleet, so it asks rather than guesses.
refuse_hour() {
  echo "architecture-review: this project needs a schedule hour and none was given." >&2
  echo "   Every project on this host shares one upstream credential and one concurrency limit," >&2
  echo "   and a review runs 20-68 minutes — so give it an hour no sibling project uses." >&2
  echo "   (Carrying the current value over is not enough: a project already at 09:00" >&2
  echo "   keeps colliding with every sibling that is also at 09:00.)" >&2
  echo "     $S/upgrade-afk.sh $TARGET --cron-hour <0-23>" >&2
  exit 1
}

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
# project that *added* a mount, an env var, or a provider keeps every marker the
# scaffold has, so the file is compared to the two shapes that actually exist in
# the field — the pristine 1.1.x output and the `claude-stepfun` hand-port — with
# only the per-project image name normalised away. Anything else is a project
# edit and is refused rather than overwritten.
profile_is_generated_shape() {
  local candidate="$1"
  local refs=("$S/references/profile-1.1.x.ts" "$S/references/profile-handport.ts")
  local reference
  for reference in "${refs[@]}"; do
    [ -f "$reference" ] || { echo "profile.ts: migration reference missing: $reference" >&2; return 1; }
  done
  profile_matches "$candidate" "${refs[@]}"
}

# Like `subst`, but replaces every occurrence. A workflow may carry the same
# fallback in more than one step, and `subst` refuses an anchor it cannot find —
# which it would be, on the second pass, once the first pass rewrote it.
subst_all() {
  local file="$1" from="$2" to="$3"
  grep -qF -e "$from" "$file" || return 0
  node -e '
    const fs = require("fs");
    const [path, from, to] = process.argv.slice(1);
    fs.writeFileSync(path, fs.readFileSync(path, "utf8").split(from).join(to));
  ' "$file" "$from" "$to"
}

# Compare a profile.ts to reference shape(s). Only the rendered image name is
# normalised: it is the one value that legitimately differs per project.
#
# The profile table is compared verbatim rather than normalised away. Normalising
# it looks tempting — a hand-port trimmed the table, so the two references differ
# there — but it would also accept a table a project extended. A settings-driven
# provider needs no change outside the table, so such a file would otherwise match
# a reference byte for byte and be replaced, silently deleting that provider.
# Comparing the tables against the known historical ones keeps that refused.
profile_matches() {
  node -e '
    const fs = require("fs");
    const [candidate, ...references] = process.argv.slice(1);
    const normalise = (source) =>
      source.replace(/(imageName: process\.env\.AFK_IMAGE \?\? ")[^"]*(")/, "IMAGE_NAME");
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
# Steps are cumulative: a project older than the target runs every step between
# its recorded version and the target, in order, in one invocation. Gating a
# step on `from_minor` alone would strand a 1.1.x project at 1.2.0's output
# while the metadata claimed 1.3.0 — the exact "claims a version whose changes
# it never received" failure this script refuses elsewhere.
# Declared before the steps, not inside one: the report below reads it for every
# path, and `set -u` aborts on an unset variable — which would kill the run
# AFTER the change report printed but BEFORE the publish, so the rollback trap
# would silently restore the original files. Each step that finds prose appends.
PROSE=""

# Set by the 1.6.0 step when the project has no repository map. The map is
# generated after publication, not during the transform phase — see the note at
# that step for why the finished tree is the only correct input.
MAP_NEEDED=0

# Paths a step added or replaced that are not on the fixed lists the report and
# the publish loop walk. Declared here, not inside a step: 1.6.0 and 1.6.1 both
# contribute, and a run that enters at 1.6.0 executes only the second — an
# unset variable under `set -u` would abort it after the transform phase and
# before the publish, so the rollback trap would silently restore the originals.
NEW_FILES=""

STEP_RAN=0
# `-lt 2`: a project already at 1.2.0 has had the provider migration. Re-running
# it is not merely wasted — the step refuses a profile.ts it cannot recognise as
# generated, so a project that legitimately customised its profile would be
# blocked from an unrelated schedule upgrade. Only a project still BELOW 1.2.0
# needs this step.
if [ "$from_minor" -lt 2 ] && [ "$to_minor" -ge 2 ]; then
  STEP_RAN=1
  say "== $FROM -> $TEMPLATE_VERSION: single mount-based provider =="

  # 1. Dockerfile dispatch arm. Anchor is the exact arm the old templates wrote.
  #    A hand-port that added its own arm is handled by step 2.
  DOCKER="$WORK/.sandcastle/Dockerfile"
  OLD_ARM="'  claude-ark|agentrouter|psydo) args=();"
  NEW_ARM="'  claude-stepfun) args=();"
  # `claude-deepseek` is the arm a LATER step installs. It reaches here when a
  # project's recorded version is rewound below this step's gate while its tree
  # is already current — the whole step is a no-op on such a tree, and refusing
  # it would block a later step from running. Recognise it and leave it.
  DEEPSEEK_ARM="'  claude-deepseek) args=();"
  if grep -qF -e "$OLD_ARM" "$DOCKER"; then
    subst "$DOCKER" "$OLD_ARM" "$NEW_ARM"
  elif grep -qF -e "$NEW_ARM" "$DOCKER"; then
    note "Dockerfile: dispatch arm already names claude-stepfun"
  elif grep -qF -e "$DEEPSEEK_ARM" "$DOCKER"; then
    note "Dockerfile: dispatch arm already names claude-deepseek (a later step's output)"
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
    say "only the claude and claude-deepseek profiles, with the endpoint supplied"
    say "by the mounted settings file (see .sandcastle/Dockerfile)."
    exit 1
  fi

  # 4. main.ts usage string. Both anchors are checked, so a file whose entry
  #    was customised to some third value is refused rather than recorded as
  #    migrated while still advertising a profile the image does not dispatch.
  MAIN="$WORK/.sandcastle/main.ts"
  OLD_USAGE="--profile claude|claude-ark|agentrouter|psydo|aliyun-deepseek"
  NEW_USAGE="--profile claude|claude-stepfun"
  # As with the dispatch arm: a rewound project whose tree already carries the
  # later step's usage string is a no-op here, not an error.
  DEEPSEEK_USAGE="--profile claude|claude-deepseek"
  if grep -qF -e "$OLD_USAGE" "$MAIN"; then
    subst "$MAIN" "$OLD_USAGE" "$NEW_USAGE"
  elif grep -qF -e "$NEW_USAGE" "$MAIN"; then
    note "main.ts: usage string already current"
  elif grep -qF -e "$DEEPSEEK_USAGE" "$MAIN"; then
    note "main.ts: usage string already names claude-deepseek (a later step's output)"
  else
    echo "main.ts: no usage string anchor found — refusing to guess" >&2
    exit 1
  fi

  # 5. Workflows: the fallback default only — the variable itself is a host-side
  #    setting, not a file. Every retired profile must be rewritten, not just the
  #    `psydo` the templates shipped: a project may have set the fallback to any
  #    provider 1.2.0 removes, and leaving it would make the workflow hand
  #    `claudeProfile` a value it rejects before the agent starts. A fallback
  #    that is neither retired nor the new default is a project edit, and is
  #    refused rather than recorded as a completed migration.
  # GitHub reads both extensions, so a project that named its workflow .yaml
  # must be migrated too — otherwise it keeps a fallback the new profile map
  # rejects and its next run stops before the agent starts.
  for wf in "$WORK"/.github/workflows/*.yml "$WORK"/.github/workflows/*.yaml; do
    [ -e "$wf" ] || continue
    # Collect the distinct fallbacks before rewriting anything: the file is
    # rewritten in place, so re-reading it mid-loop would see an already-rewritten
    # value and then look for it a second time.
    fallbacks="$(grep -oE "vars\.AFK_PROFILE \|\| '[^']*'" "$wf" | sort -u || true)"
    [ -n "$fallbacks" ] || continue
    while IFS= read -r fallback; do
      case $fallback in
        ''|"vars.AFK_PROFILE || 'claude-stepfun'"|"vars.AFK_PROFILE || 'claude'")
          # Already what this version ships. Leave it.
          continue ;;
        "vars.AFK_PROFILE || 'claude-deepseek'")
          # What a LATER step ships. It reaches here on a project whose recorded
          # version was rewound below this step's gate while its tree is already
          # current — a no-op, not an unrecognised value.
          continue ;;
        "vars.AFK_PROFILE || 'psydo'"|"vars.AFK_PROFILE || 'claude-ark'"|\
        "vars.AFK_PROFILE || 'agentrouter'"|"vars.AFK_PROFILE || 'aliyun-deepseek'")
          continue ;;
      esac
      # Neither retained nor a profile this version retires. Refuse rather than
      # record a migration that leaves the workflow handing an unsupported value
      # to claudeProfile once the profile map stops accepting it.
      echo "$wf: unrecognised AFK_PROFILE fallback — refusing to guess:" >&2
      echo "  $fallback" >&2
      exit 1
    done <<<"$fallbacks"
    # Every surviving fallback is either retained or retired, so replace the
    # retired ones wholesale.
    for retired in psydo claude-ark agentrouter aliyun-deepseek; do
      grep -qF -e "vars.AFK_PROFILE || '$retired'" "$wf" || continue
      subst_all "$wf" "vars.AFK_PROFILE || '$retired'" "vars.AFK_PROFILE || 'claude-stepfun'"
    done
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
      PROSE="$PROSE
${f#"$TARGET"/}"
    fi
  done
fi

# ---- step: 1.2.x -> 1.3.0 — architecture-review schedule and budget ---------
# Two defects in what 1.2.0 shipped, both observed on real runs:
#
# 1. Every project got `cron: "0 9 * * 1-5"` — the same minute. A review run
#    lasts 20-68 minutes (measured) and every project on a host resolves the
#    same upstream settings file, so the fleet contended for one concurrency
#    limit and failed with `429 concurrency reached, current: 6, limit: 5`.
#    This renders a per-project hour and records it, so the next project can
#    pick a free one deliberately.
# 2. The job budget was 20 minutes against a review that measured 19m13s, so
#    runs were cancelled inside their own success path and read as failures.
#
# The hour is NOT derived from the slug: hashing collides (two of this fleet's
# five slugs land in the same hour), and a silent collision is the same defect.
# It is read from the project's own record, or assigned here and written back.
# `from_minor -lt 3`: a project already at 1.3.x has run this step. Re-running it
# re-does the schedule migration on a workflow it already migrated — the same
# over-broad gating that once made a 1.2.0 project redo the provider step.
if [ "$from_minor" -lt 3 ] && [ "$to_minor" -ge 3 ]; then
  STEP_RAN=1
  say "== $FROM -> $TEMPLATE_VERSION: architecture-review schedule and budget =="

  ARCH="$WORK/.github/workflows/architecture-review.yml"
  META="$WORK/.afk-bootstrap.json"

  if [ ! -e "$ARCH" ]; then
    # A 1.1.x project never had this workflow — it arrived in 1.2.0. There is
    # nothing to migrate, so it is added from the current scaffold, which
    # already carries the corrected budget and the hour placeholder.
    #
    # Adding the WORKFLOW ALONE IS NOT ENOUGH. It invokes
    # `.sandcastle/architecture-review/architecture-review.ts`, which a 1.1.x
    # project does not have — the workflow would fail on its first run, and the
    # migration would have swapped a missing feature for a broken one. The whole
    # runner ships with it, from the same scaffold, so the two cannot diverge.
    if [ ! -e "$S/scaffold/.sandcastle/architecture-review/architecture-review.ts" ]; then
      echo "scaffold is missing the architecture-review runner; cannot add the workflow safely" >&2
      exit 1
    fi
    mkdir -p "$WORK/.github/workflows" "$WORK/.sandcastle/architecture-review"
    cp "$S/scaffold/.github/workflows/architecture-review.yml" "$ARCH"
    # --no-clobber, matching the scaffold's own rule: a project that already
    # hand-ported the runner keeps it. Overwriting would discard project work
    # and the migration would report success — the same failure the scaffold
    # copy avoids for every other file. A file the template ADDS (the usual
    # case here) is written normally.
    cp -R --no-clobber "$S/scaffold/.sandcastle/architecture-review/." \
          "$WORK/.sandcastle/architecture-review/"
    note "architecture-review added (workflow + runner; new in 1.2.0)"
    HOUR="$(resolve_hour)"
    if [ -z "$HOUR" ]; then
      refuse_hour
    fi
    subst "$ARCH" "__AFK_CRON_HOUR__" "$HOUR"
    note "architecture-review: schedule hour set to $HOUR UTC (assigned)"
  else
    # 1. Timeout, scoped to the architecture-review job. A bare search-and-
    #    replace on `timeout-minutes: 20` would raise EVERY job carrying that
    #    budget — the file has a second job, and a project may have added more —
    #    silently granting unrelated jobs a 45-minute budget. So the edit is
    #    located by the job it belongs to, and only its own line is rewritten.
    rc=0
    # shellcheck disable=SC2016  # the JS wants a literal `$`; the trailing `$?`
    #                             # is shell, and is not inside the quotes.
    node -e '
      const fs = require("fs");
      const [path, from, to] = process.argv.slice(1);
      const source = fs.readFileSync(path, "utf8");
      const lines = source.split("\n");
      const jobKey = (l) => /^  [A-Za-z0-9_-]+: */.test(l) && l.trim().endsWith(":");
      // Find the job whose key is `architecture-review:`, then the first
      // `timeout-minutes:` inside it (before the next top-level job key).
      const start = lines.findIndex((l) => l.trim() === "architecture-review:");
      if (start < 0) { console.error("architecture-review job not found"); process.exit(2); }
      let end = lines.length;
      for (let i = start + 1; i < lines.length; i++) {
        if (jobKey(lines[i])) { end = i; break; }
      }
      for (let i = start + 1; i < end; i++) {
        if (lines[i].trim() === "timeout-minutes: " + from) {
          lines[i] = lines[i].replace(from, to);
          fs.writeFileSync(path, lines.join("\n"));
          process.exit(0);
        }
      }
      process.exit(3);   // present but already customised
    ' "$ARCH" 20 45 || rc=$?
    case $rc in
      0) note "architecture-review: job budget 20m -> 45m (a review measured 19m13s)";;
      3) note "architecture-review: job budget already customised; left alone";;
      *) echo "architecture-review.yml: could not locate the job timeout" >&2; exit 1;;
    esac

    # 2. Schedule hour. Accept the exact cron the old template wrote, or one
    #    already carrying the placeholder. Anything else is a project edit and
    #    is refused rather than overwritten.
    #
    #    The hour is NOT defaulted when absent. Defaulting it to 9 would
    #    reproduce, in the migration itself, the exact defect the migration
    #    exists to remove: every project landing on the same hour. This script
    #    has no fleet view — it cannot know which hours its siblings hold — so
    #    it refuses and names the one-line fix rather than guessing silently.
    OLD_CRON='cron: "0 9 * * 1-5"'
    NEW_CRON='cron: "0 __AFK_CRON_HOUR__ * * 1-5"'
    HOUR="$(resolve_hour)"
    # A commented-out `# - cron: ...` is not the schedule. A plain grep matches it
    # too, and then the migration rewrites a comment (harmless) while recording
    # the hour the COMMENT names — so the record describes a schedule the project
    # does not run, and the next project reads the genuinely-occupied hour as
    # free. Every test below is therefore "is this an ACTIVE cron line", which is
    # a leading character test rather than a substring one.
    active_cron() { grep -E '^[[:space:]]*-[[:space:]]*cron:' "$1" 2>/dev/null; }
    if active_cron "$ARCH" | grep -qF -e "$NEW_CRON"; then
      [ -n "$HOUR" ] || { echo "$META: cron_hour is unset while the workflow already carries the placeholder; pass --cron-hour" >&2; exit 1; }
      # The workflow may carry the placeholder from a scaffold, which renders it
      # only at bootstrap. Leaving it here would ship `cron: "0 __AFK_CRON_HOUR__
      # * * 1-5"` — an invalid cron, which disables the schedule silently.
      subst "$ARCH" "__AFK_CRON_HOUR__" "$HOUR"
      note "architecture-review: placeholder rendered (hour $HOUR)"
    elif active_cron "$ARCH" | grep -qF -e "$OLD_CRON"; then
      if [ -z "$HOUR" ]; then
        refuse_hour
      fi
      # Rewrite the ACTIVE line only. `subst` is a global string replace, so a
      # commented copy of the same line would be rewritten too — turning a
      # record of what the project used to run into a claim about what it runs.
      active_cron "$ARCH" | grep -qF -e "$OLD_CRON" || {
        echo "$ARCH: active cron line vanished mid-migration" >&2; exit 1; }
      # shellcheck disable=SC2016  # the JS pattern wants a literal `$`; none is shell here.
      node -e '
        const fs = require("fs");
        const [path, from, to] = process.argv.slice(1);
        const lines = fs.readFileSync(path, "utf8").split("\n");
        let done = false;
        for (let i = 0; i < lines.length; i++) {
          // Only an uncommented `- cron:` line is the schedule.
          if (!/^[ \t]*-[ \t]*cron:/.test(lines[i])) continue;
          if (!lines[i].includes(from)) continue;
          lines[i] = lines[i].replace(from, to);
          done = true;
          break;
        }
        if (!done) { console.error("no active cron line matched"); process.exit(1); }
        fs.writeFileSync(path, lines.join("\n"));
      ' "$ARCH" "$OLD_CRON" "$NEW_CRON"
      subst "$ARCH" "__AFK_CRON_HOUR__" "$HOUR"
      # The 1.2.0 file hardcoded the comment as well as the cron. Moving one
      # without the other leaves the file describing a schedule it no longer
      # runs, and the next reader schedules against the wrong hour.
      subst "$ARCH" "# 09:00 UTC, Monday" "# $HOUR:00 UTC, Monday" || true
      note "architecture-review: schedule hour set to $HOUR UTC (was the shared 09:00)"
    else
      # A schedule neither this template nor the placeholder wrote: the project
      # set it. The schedule is left alone — it is the project's — but the hour
      # it already occupies MUST be recorded. Without that, the record says the
      # project holds no hour, and the next project on this host reads this
      # hour as free and collides with it. Provenance is what the record is for.
      HOUR="$(existing_cron_hour)"
      if [ -n "$HOUR" ]; then
        note "architecture-review: schedule left as the project set it; hour $HOUR recorded so siblings do not reuse it"
      else
        # A schedule shape this script cannot read an hour out of. Recording
        # nothing is the honest outcome, but it must be said out loud: this
        # project occupies an hour and the fleet cannot tell which.
        say "WARNING: architecture-review schedule is in a shape this script cannot read an hour from:" >&2
        say "         $(grep -m1 'cron:' "$ARCH" || echo '(no cron line)')" >&2
        say "         No hour is recorded, so a sibling project may be assigned the same one." >&2
      fi
    fi
  fi

  # Record the hour so the next project can pick a free one. Absent unless this
  # step assigned it above, in which case the value is already known.
  if [ -n "${HOUR:-}" ]; then
    node -e '
      const fs=require("fs"); const [p,h]=process.argv.slice(1);
      const m=JSON.parse(fs.readFileSync(p,"utf8")); m.cron_hour=Number(h);
      fs.writeFileSync(p, JSON.stringify(m,null,2)+"\n");
    ' "$META" "$HOUR"
  fi
fi

# ---- step: 1.3.x -> 1.3.1 — raise the job budget against a longer observation --
# 1.3.0 set the budget to 45 minutes from a single 19m13s run. The fleet has since
# produced a COMPLETED review at 54.8 minutes (AI-Ops), which that budget would
# have killed in its own success path — the same defect the 20-minute budget
# caused, one size up. 75m is ~1.37x the longest observed successful run.
#
# Only a run that COMPLETED counts as evidence: a cancelled run's duration is the
# budget it hit, not the work it did. That is the distinction the 45m sizing got
# wrong, so it is stated here rather than left implicit.
# Gated on the minor version, not `to_patch -ge 1`. The patch term made this step
# disappear the moment the template moved past 1.3.1 — a project coming from 1.3.x
# would then silently keep its 45m budget, which is the defect this step removes.
# "At or above the version that introduced it" is the condition; a patch level is
# not a proxy for it.
if [ "$to_minor" -ge 3 ]; then
  STEP_RAN=1
  ARCH="$WORK/.github/workflows/architecture-review.yml"
  if [ ! -e "$ARCH" ]; then
    note "architecture-review.yml absent; no budget to raise"
  elif grep -qE '^\s*timeout-minutes: 45\s*$' "$ARCH"; then
    say "== $FROM -> $TEMPLATE_VERSION: architecture-review job budget =="
    # shellcheck disable=SC2016  # the JS pattern wants a literal `$`; none is shell here.
    node -e '
      const fs = require("fs");
      const [path] = process.argv.slice(1);
      const lines = fs.readFileSync(path, "utf8").split("\n");
      const jobKey = (l) => /^  [A-Za-z0-9_-]+: */.test(l) && l.trim().endsWith(":");
      const start = lines.findIndex((l) => l.trim() === "architecture-review:");
      if (start < 0) { console.error("architecture-review job not found"); process.exit(2); }
      let end = lines.length;
      for (let i = start + 1; i < lines.length; i++) {
        if (jobKey(lines[i])) { end = i; break; }
      }
      for (let i = start + 1; i < end; i++) {
        if (lines[i].trim() === "timeout-minutes: 45") {
          lines[i] = lines[i].replace("45", "75");
          fs.writeFileSync(path, lines.join("\n"));
          process.exit(0);
        }
      }
      process.exit(3);
    ' "$ARCH" || rc=$?
    case ${rc:-0} in
      0) note "architecture-review: job budget 45m -> 75m (a review completed at 54.8m)" ;;
      3) note "architecture-review: job budget already customised; left alone" ;;
      *) echo "architecture-review.yml: could not locate the job timeout" >&2; exit 1 ;;
    esac
  elif grep -qE '^\s*timeout-minutes: [0-9]+\s*$' "$ARCH"; then
    note "architecture-review: job budget is not the 1.3.0 value; left alone"
  else
    echo "architecture-review.yml: no job timeout found" >&2; exit 1
  fi

  # Sync the schedule comment to the cron it describes.
  #
  # 1.3.0 rewrote `# 09:00 UTC` only on the branch that migrated the cron itself,
  # so a project that had already moved its cron — or moved it by hand — kept a
  # comment naming a different hour. A comment that disagrees with the line below
  # it is worse than no comment: the next person schedules against the wrong hour.
  # This reads the ACTIVE cron hour and rewrites any `HH:00 UTC` comment to match.
  if [ -e "$ARCH" ]; then
    ACTIVE_HOUR="$(existing_cron_hour)"
    if [ -n "$ACTIVE_HOUR" ]; then
      COMMENT_MISMATCH="$(node -e '
        const fs = require("fs");
        const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
        const hour = process.argv[2];
        for (const line of lines) {
          const m = line.match(/^\s*#\s*(\d{1,2}):00 UTC/);
          if (m && m[1] !== hour) { process.stdout.write(m[1]); process.exit(0); }
        }
        process.stdout.write("");
      ' "$ARCH" "$ACTIVE_HOUR")"
      if [ -n "$COMMENT_MISMATCH" ]; then
        # Two-digit hours, so 9 becomes 09. The hour is read as a NUMBER
        # (`Number(m[2])`), which drops the leading zero — writing that back
        # produced `# 9:00 UTC` and made a correct sync look like a typo.
        # `10#$h` forces base 10: bash reads a leading zero as octal, so a bare
        # `09` is an invalid octal number rather than the number nine.
        printf -v PADDED '%02d' "$((10#$ACTIVE_HOUR))"
        printf -v PADDED_OLD '%02d' "$((10#$COMMENT_MISMATCH))"
        subst "$ARCH" "# $PADDED_OLD:00 UTC" "# $PADDED:00 UTC"
        note "architecture-review: schedule comment $PADDED_OLD:00 -> $PADDED:00 UTC (matched to the active cron)"
      fi
    fi
  fi
fi

# A version pair no step handles must fail rather than publish a copy that only
# has its metadata rewritten — the project would then claim a version whose
# changes it never received.
# `to_minor -ge 4`: there is no from-version gate because the rename has to reach
# every older project. A 1.1.x project runs the 1.2.0 and 1.3.0 steps above in the
# same invocation, so gating on `from_minor` would strand it on the old filename.
if [ "$to_minor" -ge 4 ]; then
  STEP_RAN=1
  GLOSSARY_FILES=""
  GLOSSARY_RENAME=0
  say "== $FROM -> $TEMPLATE_VERSION: domain doc CONTEXT.md -> GLOSSARY.md =="

  # $WORK stages only .sandcastle/ and .github/workflows/; the domain doc lives
  # under docs/. Stage it here so publish_file has a source to copy.
  if [ -e "$TARGET/docs/agents/domain.md" ]; then
    mkdir -p "$WORK/docs/agents"
    cp "$TARGET/docs/agents/domain.md" "$WORK/docs/agents/domain.md"
  fi

  # `.sandcastle/implement.md` is the per-language render of
  # `templates/implement.<lang>.md` (bootstrap-afk.sh copies it there), so it
  # carries the same reference and must move with the rest. Missing it would
  # leave the implement job pointing at a filename that no longer exists.
  for rel in \
    .sandcastle/implement.md \
    .sandcastle/implement-prompt.md \
    .sandcastle/implement-prd/prompt.md \
    .sandcastle/review-prompt.md \
    .sandcastle/review/axis-prompt.md \
    .sandcastle/review/prompt.md \
    .sandcastle/implement/prompt.md \
    .sandcastle/implement-pr/prompt.md \
    .sandcastle/update-branch/prompt.md \
    .sandcastle/architecture-review/prompt.md \
    .sandcastle/write-pr/prompt.md \
    .sandcastle/write-prd-pr/prompt.md \
    docs/agents/domain.md ; do
    [ -e "$WORK/$rel" ] || continue
    # A bare word boundary is the WRONG anchor: `\b` also matches after a hyphen,
    # so `DEPLOYMENT-CONTEXT.md` would be rewritten to `DEPLOYMENT-GLOSSARY.md`
    # while that file keeps its own name — a pointer to nothing. Require that the
    # match is not preceded or followed by a word character or a hyphen, which is
    # exactly the standalone filename the previous templates emitted.
    mkdir -p "$STAGE/before/$(dirname "$rel")"
    cp "$WORK/$rel" "$STAGE/before/$rel"
    perl -pi -e 's/(?<![\w-])CONTEXT\.md(?![\w-])/GLOSSARY.md/g' "$WORK/$rel"
    # Derive "did this change" from the file itself rather than a separate grep,
    # so the pattern above is the single source of truth for the anchor.
    cmp -s "$STAGE/before/$rel" "$WORK/$rel" || GLOSSARY_FILES="$GLOSSARY_FILES $rel"
  done

  # The prompts now name GLOSSARY.md, so a project still holding CONTEXT.md would
  # point every agent at a file that does not exist. The project's own copy is
  # renamed, not overwritten: the glossary content is project-owned.
  GLOSSARY_RENAME=0
  if [ -e "$TARGET/CONTEXT.md" ] && [ ! -e "$TARGET/GLOSSARY.md" ]; then
    GLOSSARY_RENAME=1
    # Staged under the NEW name: publish_file copies from $WORK, so the rename is
    # a write of GLOSSARY.md followed by a delete of CONTEXT.md.
    cp "$TARGET/CONTEXT.md" "$WORK/GLOSSARY.md"
    say "renaming CONTEXT.md -> GLOSSARY.md (project glossary content preserved)"
  elif [ -e "$TARGET/CONTEXT.md" ] && [ -e "$TARGET/GLOSSARY.md" ]; then
    # Both present: refuse to guess which one is current. Overwriting either
    # would destroy project content, so report and leave both in place.
    PROSE="$PROSE
CONTEXT.md"
    say "note: both CONTEXT.md and GLOSSARY.md exist; left both, merge them by hand"
  fi

  # Project-owned prose is reported, never rewritten — the same policy the
  # retired-profile step applies. The file list is discovered rather than fixed:
  # every root document and anything under docs/ can carry the old name, and a
  # hardcoded list silently under-reports. `.sandcastle/` is excluded because
  # those files were rewritten above; `.git`/`node_modules` are noise.
  # Read line by line, not word-split: a project path containing a space would
  # otherwise fragment each hit into pieces that match no file, and the report
  # would silently name garbage instead of the documents to fix. A spaced target
  # is a supported shape (see the spaced-tool-directory smoke case).
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$TARGET"/}"
    # Skip the files this step already rewrote in $WORK. They still hold the old
    # name in $TARGET — that is the input, not a leftover — so reporting them
    # would tell the operator to fix something that is already fixed.
    case " $GLOSSARY_FILES " in
      *" $rel "*) continue ;;
    esac
    PROSE="$PROSE
$rel"
  done <<EOF
$(grep -rl --exclude-dir=.git --exclude-dir=node_modules \
    -e 'CONTEXT\.md' "$TARGET/docs" "$TARGET"/*.md 2>/dev/null || true)
EOF
fi

# ---- step: 1.4.x -> 1.5.0 — provider moves to the local relay ----------------
# Every remote provider the 1.2.0 step installed is now dead: stepfun and
# tokenrouter both report an exhausted quota, airouter answers "unauthorized
# client detected". `claude-stepfun` therefore selects a profile that can no
# longer serve a request, and a run that picks it dies before the agent starts.
# The only endpoint still answering is the host-local relay (`cli-proxy-api` on
# 127.0.0.1:8317), which genesis-evidence already proved out as
# `claude-deepseek`.
#
# Distinct from the 1.2.0 step on purpose: that one changes WHICH provider, this
# one changes HOW the sandbox reaches it. The relay is bound to the host's
# loopback, so the sandbox must share the host network namespace — a
# default-bridge container cannot reach the host's 127.0.0.1. That is a real
# cost: the sandbox loses Docker's bridge isolation. It is confined to the
# profiles whose endpoint is host-loopback, and `profile-network.check.ts`
# asserts that confinement rather than trusting it.
if [ "$from_minor" -lt 5 ] && [ "$to_minor" -ge 5 ]; then
  STEP_RAN=1
  say "== $FROM -> $TEMPLATE_VERSION: provider -> host-loopback relay =="

  DOCKER="$WORK/.sandcastle/Dockerfile"
  NEW_ARM="'  claude-deepseek) args=();"
  # Two older arms reach this version: the 1.2.0 one, and the 1.1.x one. A
  # project can be recorded at 1.2.0 (so the provider step does not re-run) while
  # its Dockerfile still carries the 1.1.x arm — the metadata moved without the
  # Dockerfile. Accepting only the newer arm refused that shape, which is a real
  # path a fixture already covers.
  OLD_ARM_120="'  claude-stepfun) args=();"
  OLD_ARM_110="'  claude-ark|agentrouter|psydo) args=();"
  # A project that hand-added the relay profile before this version exists keeps
  # both names in ONE arm. Narrow it to the single live profile: leaving the
  # retired name in a dispatch arm advertises a profile whose settings file no
  # longer exists.
  OLD_ARM_COMBINED="'  claude-stepfun|claude-deepseek) args=();"
  if grep -qF -e "$OLD_ARM_120" "$DOCKER"; then
    subst "$DOCKER" "$OLD_ARM_120" "$NEW_ARM"
  elif grep -qF -e "$OLD_ARM_110" "$DOCKER"; then
    subst "$DOCKER" "$OLD_ARM_110" "$NEW_ARM"
  elif grep -qF -e "$OLD_ARM_COMBINED" "$DOCKER"; then
    subst "$DOCKER" "$OLD_ARM_COMBINED" "$NEW_ARM"
  elif grep -qF -e "$NEW_ARM" "$DOCKER"; then
    note "Dockerfile: dispatch arm already names claude-deepseek"
  else
    echo "Dockerfile: no dispatch arm anchor found — refusing to guess" >&2
    exit 1
  fi

  # profile.ts: swap the retired profile entry for the relay one, and add the
  # network spread the relay needs. Anchored on the exact lines the previous
  # template wrote, so a project that already customised this file is reported
  # rather than silently rewritten.
  PROF="$WORK/.sandcastle/profile.ts"
  if grep -qF -e '"claude-deepseek"' "$PROF" && ! grep -qF -e '"claude-stepfun"' "$PROF"; then
    note "profile.ts: already names only claude-deepseek"
  elif grep -qF -e '"claude-stepfun"' "$PROF"; then
    if grep -qF -e '"claude-deepseek": process.env.AFK_DEEPSEEK_SETTINGS' "$PROF"; then
      # Hand-migrated: the relay entry is already there, so only the retired
      # entry is removed. Rewriting it would duplicate the profile key.
      node -e '
        const fs = require("fs");
        const [path] = process.argv.slice(1);
        const lines = fs.readFileSync(path, "utf8").split("\n");
        const i = lines.findIndex((l) => l.includes("\"claude-stepfun\": process.env.AFK_STEPFUN_SETTINGS"));
        if (i >= 0) lines.splice(i, 1);
        fs.writeFileSync(path, lines.join("\n"));
      ' "$PROF"
      note "profile.ts: removed the retired claude-stepfun entry"
    else
    subst "$PROF" \
      '  "claude-stepfun": process.env.AFK_STEPFUN_SETTINGS ?? join(homedir(), "cliproxyapi/settings.stepfun.json"),' \
      '  // Local relay (cli-proxy-api on 127.0.0.1:8317), reached with a host-network
  // sandbox. The settings file points ANTHROPIC_BASE_URL at the relay loopback
  // address, so the container MUST share the host network namespace —
  // a default-bridge container cannot reach the host 127.0.0.1 (measured).
  "claude-deepseek": process.env.AFK_DEEPSEEK_SETTINGS ?? join(homedir(), "cliproxyapi/settings.deepseek.json"),'
    fi
    # The network spread must land inside the docker() call, before the mounts —
    # the same position the template writes it. Without it the relay profile
    # would mount a loopback URL the sandbox cannot reach.
    if grep -qF 'sandboxNetworkOptions(profile)' "$PROF"; then
      note "profile.ts: network spread already present"
    else
      subst "$PROF" \
        '      ...(settingsPath' \
        '      ...sandboxNetworkOptions(profile),
      ...(settingsPath'
      subst "$PROF" \
        'import { docker } from "@ai-hero/sandcastle/sandboxes/docker";' \
        'import { docker } from "@ai-hero/sandcastle/sandboxes/docker";
import { sandboxNetworkOptions } from "./profile-network.js";'
    fi
  else
    say ""
    say "profile.ts names neither claude-stepfun nor claude-deepseek — it has"
    say "project edits this script will not overwrite. Migrate it by hand: it must"
    say "keep only the claude and claude-deepseek profiles, and spread"
    say "sandboxNetworkOptions(profile) into its docker() call."
    exit 1
  fi

  # The two network modules are new files, not edits. They are what confines
  # host networking to the loopback profile and what asserts that confinement.
  cp "$S/scaffold/.sandcastle/profile-network.ts" "$WORK/.sandcastle/profile-network.ts"
  cp "$S/scaffold/.sandcastle/profile-network.check.ts" "$WORK/.sandcastle/profile-network.check.ts"

  MAIN="$WORK/.sandcastle/main.ts"
  NEW_USAGE="--profile claude|claude-deepseek"
  # Same two-shape problem as the Dockerfile arm: a 1.2.0 project may still carry
  # the 1.1.x usage string.
  OLD_USAGE_120="--profile claude|claude-stepfun"
  OLD_USAGE_110="--profile claude|claude-ark|agentrouter|psydo|aliyun-deepseek"
  if grep -qF -e "$OLD_USAGE_120" "$MAIN"; then
    subst "$MAIN" "$OLD_USAGE_120" "$NEW_USAGE"
  elif grep -qF -e "$OLD_USAGE_110" "$MAIN"; then
    subst "$MAIN" "$OLD_USAGE_110" "$NEW_USAGE"
  elif grep -qF -e "$NEW_USAGE" "$MAIN"; then
    note "main.ts: usage string already current"
  else
    echo "main.ts: no usage string anchor found — refusing to guess" >&2
    exit 1
  fi

  # Workflows: the fallback default, in every workflow that carries one.
  # GitHub reads both extensions, so a project that named its workflow .yaml
  # must be migrated too — otherwise it keeps a fallback the new profile map
  # rejects and its next run stops before the agent starts.
  for wf in "$WORK"/.github/workflows/*.yml "$WORK"/.github/workflows/*.yaml; do
    [ -e "$wf" ] || continue
    subst_all "$wf" "vars.AFK_PROFILE || 'claude-stepfun'" "vars.AFK_PROFILE || 'claude-deepseek'"
  done
fi

# ---- step: 1.5.0 -> 1.5.1 — CI actually runs the network check ---------------
# 1.5.0 added `profile-network.check.ts` but wired it into the *scaffold*
# workflow only. A project bootstrapped before 1.5.0 — or one that reached 1.5.0
# from an older version — never receives that workflow edit, because the scaffold
# is copied once at bootstrap and no upgrade step patched this file. The project
# therefore holds a check that nothing runs, which is the same as not having it:
# a typo widening the sandbox's reach fails nothing.
#
# Gated on the patch level within 1.5.x, so it runs exactly once for a project at
# 1.5.0 and is a no-op for anything already carrying the step.
if [ "$from_minor" -eq 5 ] && [ "$from_patch" -lt 1 ] && [ "$to_minor" -ge 5 ]; then
  STEP_RAN=1
  say "== $FROM -> $TEMPLATE_VERSION: CI runs the sandbox network check =="
  POLICY="$WORK/.github/workflows/afk-policy.yml"
  ANCHOR="        run: node .sandcastle/policy-check.mjs workflows"
  ADDITION="$ANCHOR
      # The profile-network check decides whether the agent sandbox keeps Docker
      # bridge isolation. Without it in CI, a typo in the loopback-profile set
      # silently widens the sandbox's reach — or silently breaks the relay
      # profile — and nothing fails. It was a runnable check with no runner.
      - name: Verify sandbox network isolation
        run: npx --yes tsx .sandcastle/profile-network.check.ts"
  if [ ! -e "$POLICY" ]; then
    note "afk-policy.yml absent; nothing to wire (the scaffold supplies it)"
  elif grep -qF "profile-network.check.ts" "$POLICY"; then
    note "afk-policy.yml: network check already wired"
  elif grep -qF "$ANCHOR" "$POLICY"; then
    subst "$POLICY" "$ANCHOR" "$ADDITION"
  else
    echo "afk-policy.yml: no anchor for the workflow-boundary step — refusing to guess" >&2
    exit 1
  fi
fi

# ---- step: 1.5.x -> 1.5.2 — architecture review proposes, the workflow publishes
# Every architecture-review run past the oldest shipped template produced TWO
# issues: the prompt told the agent to "Publish it via `/to-prd-project`" and to
# apply the provenance label, while the workflow's own *Publish PRD issue* step
# built an issue from the same `<output>`. Two writers, one run, two issues
# seconds apart — measured as #90/#91 and #109/#110 (Health-Flow), #177/#178 and
# #201/#202 (genesis-evidence), #163-169 (Auto_Test), #323/#325 (AI-Ops).
#
# The agent's copy is also the worse one: the skill `/to-prd-project` does not
# exist in the sandbox, so the agent falls back to a raw `gh issue create` with a
# token scoped `issues=read` — creation succeeds, the label write 403s, and the
# duplicate lands **unlabelled**. `check-backlog` throttles on that label, so the
# unlabelled issue is invisible to the very next run's duplicate check.
#
# The fix has to reach BOTH prompts of the two-phase run. `extraction.md` is the
# second pass, and it described `title` as "the issue you created" and `body` as
# "the PRD body you published". Removing the instruction to publish, without
# fixing that, leaves the extract pass asking the agent to report an issue that
# now does not exist — and `status: skipped` is a legal answer to a question
# about something absent, so a drafted PRD would be discarded as "nothing to
# publish". The two files are one change.
#
# Two projects (AI-Ops, genesis-evidence) were repaired by hand in their own
# commits, with their own wording. This step therefore keys on the DEFECT, not on
# the version: a prompt that no longer names `/to-prd-project` has already been
# fixed — by hand or by this step — and is left exactly as it is. Rewriting it
# would discard that repair and import this scaffold's wording over it.
#
# Not gated on a patch level: the 1.3.1 budget step once gated on `to_patch` and
# silently stopped running the moment the template moved past it, stranding every
# later project on the old behavior. "At or above the version that introduced it"
# is the condition, and the defect marker inside the file is what decides.
if [ "$to_minor" -ge 5 ]; then
  STEP_RAN=1
  ARCH_PROMPT="$WORK/.sandcastle/architecture-review/prompt.md"
  ARCH_EXTRACT="$WORK/.sandcastle/architecture-review/extraction.md"
  # Both blocks are literal prompt text, backticks and all: nothing here is meant
  # to expand. SC2016 is the warning against single quotes doing that, which is
  # exactly the intent, so it is disabled rather than worked around — rewriting
  # these as double-quoted strings to silence it would make the anchors harder to
  # read against the file they must match byte for byte.
  # shellcheck disable=SC2016
  ARCH_PROMPT_OLD='4. Publish it via `/to-prd-project`.
5. Apply the `source:architecture-review` label to the new issue.'
  # shellcheck disable=SC2016
  ARCH_PROMPT_NEW='4. Write it up **in your `<output>` block** — title, full body, one-line
   summary, and the candidates you considered.

**Do NOT create the issue yourself.** The workflow'"'"'s own *Publish PRD issue*
step creates the issue from the `title` and `body` you emit. If you also run
`gh issue create`, the run publishes **twice**.'
  # shellcheck disable=SC2016
  ARCH_RULE_OLD='- Read-only on the repo. No commits. No edits to `docs/`, ADRs, or
  source files. The only mutations allowed are creating the PRD issue (via
  `/to-prd-project`) and applying the `source:architecture-review` label.'
  # shellcheck disable=SC2016
  ARCH_RULE_NEW='- **Read-only.** No commits, no edits to `docs/`, ADRs, or source files, and
  **no tracker writes** — no `gh issue create`, no `gh issue edit`, no label
  changes. You *propose*; the workflow *publishes*. This is not a style
  preference: your token has `issues=read` and label writes return 403, so a
  self-published issue also ends up **unlabelled** — the same failure that
  duplicated #178/#177 and #202/#201.'
  # The skipped rule names an `<output>` the produce pass no longer emits. It is
  # a rule about reporting, not about the defect, so it reads as harmless — but
  # it is the same class of instruction as `/to-prd-project`: one naming a
  # mechanism this step removed. It is anchored rather than left to the two above
  # because nothing else in the file would carry it.
  # shellcheck disable=SC2016
  ARCH_SKIP_OLD='- One PRD per run. If every reasonable candidate is already covered by a
  prior `source:architecture-review` proposal, emit a `skipped` output and
  stop.'
  # shellcheck disable=SC2016
  ARCH_SKIP_NEW='- One PRD per run. If every reasonable candidate is already covered by a
  prior `source:architecture-review` proposal, say so plainly and stop — the
  next pass reports it as `skipped`, so it needs no structured output here.'
  # shellcheck disable=SC2016
  ARCH_EXTRACT_OLD='End your response with a single `<output>` block, exactly as specified in the project skill `improve-codebase-architecture-project`. It has one of two shapes.'
  # shellcheck disable=SC2016
  ARCH_EXTRACT_NEW='End your response with a single `<output>` block, exactly as specified in the project skill `improve-codebase-architecture-project`. It has one of two shapes.

The `title` and `body` you emit are what the workflow will publish as the issue — you do not create it yourself. Report the PRD you drafted, not one you opened.'
  # shellcheck disable=SC2016
  ARCH_EXTRACT_TITLE_OLD='"title": "PRD title (matches the issue you created)"'
  # shellcheck disable=SC2016
  ARCH_EXTRACT_TITLE_NEW='"title": "PRD title — this becomes the issue title"'
  # shellcheck disable=SC2016
  ARCH_EXTRACT_BODY_OLD='"body": "The PRD body you published.",'
  # shellcheck disable=SC2016
  ARCH_EXTRACT_BODY_NEW='"body": "The full PRD body — this becomes the issue body.",'

  if [ ! -e "$ARCH_PROMPT" ]; then
    note "architecture-review/prompt.md absent; nothing to converge (a 1.1.x project gets the current one)"
  elif ! grep -qF -e '/to-prd-project' "$ARCH_PROMPT"; then
    note "architecture-review/prompt.md: already proposes only; left as the project wrote it"
  else
    say "== $FROM -> $TEMPLATE_VERSION: architecture review proposes, the workflow publishes =="
    # `subst` refuses an anchor it cannot find, which is the point: the two blocks
    # below are the whole defect, and a prompt carrying one but not the other is a
    # shape this step has not seen and must not half-migrate.
    subst "$ARCH_PROMPT" "$ARCH_PROMPT_OLD" "$ARCH_PROMPT_NEW"
    subst "$ARCH_PROMPT" "$ARCH_RULE_OLD" "$ARCH_RULE_NEW"
    # The skipped rule names a `skipped` OUTPUT the produce pass no longer emits.
    # Same class of instruction as `/to-prd-project`: one naming a mechanism this
    # step removed. Left half-migrated it reads as harmless, which is why it needs
    # an anchor of its own rather than relying on the two above.
    subst "$ARCH_PROMPT" "$ARCH_SKIP_OLD" "$ARCH_SKIP_NEW"
    # Optional, because a project that repaired the two blocks above by hand but
    # kept the old heading would otherwise be refused by a strict anchor. The
    # heading is not the defect; it only reads as one next to the old step 4.
    subst_all "$ARCH_PROMPT" "opportunity in this codebase and publish it as a PRD." \
                             "opportunity in this codebase and report it as a PRD."
    # If `/to-prd-project` survives anywhere the two replacements did not reach,
    # the instruction is still live somewhere in the file. Publishing a
    # half-migrated prompt would restore the double publication this step removes.
    if grep -qF -e '/to-prd-project' "$ARCH_PROMPT"; then
      echo "architecture-review/prompt.md: /to-prd-project still present after migration — refusing to publish a half-migrated prompt" >&2
      exit 1
    fi
    note "architecture-review/prompt.md: agent no longer creates the issue or mutates labels"
  fi

  # The extraction pass, converged independently of the prompt. The same shape of
  # gate: absent means nothing to fix; an extraction prompt that no longer says
  # the agent published the issue has already been repaired and is left as it is.
  # Keyed per anchor, not per file. A file gate on one anchor silently skips a
  # file that carries the other: a project can reword the body example and keep
  # "matches the issue you created" on the title, and a file-level check would
  # call that repaired while the extract pass still asks about an issue the
  # produce pass was forbidden to create. Each anchor migrates alone, and the
  # heading anchor migrates only when something else in the file has.
  if [ ! -e "$ARCH_EXTRACT" ]; then
    note "architecture-review/extraction.md absent; nothing to converge (a 1.1.x project gets the current one)"
  else
    if grep -qF -e "$ARCH_EXTRACT_TITLE_OLD" "$ARCH_EXTRACT"; then
      EXTRACT_TOUCHED=1
      subst "$ARCH_EXTRACT" "$ARCH_EXTRACT_TITLE_OLD" "$ARCH_EXTRACT_TITLE_NEW"
    fi
    if grep -qF -e "$ARCH_EXTRACT_BODY_OLD" "$ARCH_EXTRACT"; then
      EXTRACT_TOUCHED=1
      subst "$ARCH_EXTRACT" "$ARCH_EXTRACT_BODY_OLD" "$ARCH_EXTRACT_BODY_NEW"
    fi
    # The preamble sentence is the counterpart of the two examples and the only
    # place the pass says who publishes. Present but uninteresting when nothing
    # else moved, which is why it is not an anchor of its own: a hand-repaired
    # file already has it, and a pristine one gets it exactly once.
    if [ "${EXTRACT_TOUCHED:-0}" = "1" ]; then
      say "== $FROM -> $TEMPLATE_VERSION: the extract pass stops asking for the issue the agent created =="
      if grep -qF -e "$ARCH_EXTRACT_OLD" "$ARCH_EXTRACT"; then
        subst "$ARCH_EXTRACT" "$ARCH_EXTRACT_OLD" "$ARCH_EXTRACT_NEW"
      fi
      note "architecture-review/extraction.md: title/body now read as what the workflow publishes"
    else
      note "architecture-review/extraction.md: already describes the workflow as publisher; left as the project wrote it"
    fi
    # The prompt half refuses a half-migrated file by looking for `/to-prd-project`
    # wherever the anchors did not reach; this is the same invariant for the
    # extraction half. Per-anchor gates cannot cover a project that reworded an
    # example into different words that still name an agent-created issue — the
    # exact anchors miss it, both halves of the migration "succeed", and the file
    # is stamped 1.5.2 so nothing ever revisits it. Refusing is the only safe
    # answer: this file is short and the phrases are unambiguous, so a residual
    # match here is a shape this step has never seen, not a false positive.
    if grep -qF -e 'the issue you created' -e 'body you published' "$ARCH_EXTRACT"; then
      echo "architecture-review/extraction.md: still asks the agent to report an issue it created — refusing to record this project as migrated" >&2
      exit 1
    fi
  fi
fi

# ---- step: 1.5.2 -> 1.5.3 — the produce pass writes prose, not `<output>` -----
# The first revision of the previous step handed publication to the workflow and
# converged the extract pass, but left the produce prompt asking for an
# `<output>` block and pointing at the exact schema. `runWithExtraction` runs
# that phase with NO output definition — its own source says the produce prompt
# "should contain no JSON-emission instructions" — so the instruction named a
# mechanism that does not exist there, and a run where every candidate was
# already covered answered "skipped" in the produce pass and published nothing.
#
# This needs a step of its own rather than a wider previous one. `upgrade-afk.sh`
# returns early when the recorded version equals the template version, so a
# project that already ran the previous revision is at 1.5.2 and can never reach
# a 1.5.2 step again — the version is the only thing that can carry the change
# to it. Both projects migrated before this fix carry exactly that shape.
#
# The gates test single-line markers, never the multi-line anchors they guard:
# `grep -F` matches a newline-containing pattern against EACH LINE, so a
# multi-line anchor gates on its first line alone, and `SKIP_OLD`/`SKIP_NEW`
# share theirs — the gate would open on text this step has already replaced,
# where `subst`, which is exact, fails with "anchor not found".
#
# Gated on the version being upgraded TO, like the step above it, not on the one
# being upgraded FROM. The 1.5.2 step runs for ANY project arriving below 1.5 and
# installs `PRODUCE_OLD` — the very text this step removes — so a project that
# starts at 1.2 and lands on 1.5.3 needs both, and a `from_minor` gate would
# strand exactly those projects: stamped 1.5.3 with the produce prompt still
# asking for structured output, and never revisited because the recorded version
# then equals the template version. The anchors are conditional, so a prompt this
# step has nothing to say about is left alone.
if [ "$to_minor" -ge 5 ]; then
  STEP_RAN=1
  ARCH_PROMPT="$WORK/.sandcastle/architecture-review/prompt.md"
  # shellcheck disable=SC2016
  PRODUCE_MARK='in your `<output>` block'
  # shellcheck disable=SC2016
  TAIL_MARK='and the exact `<output>`'
  # shellcheck disable=SC2016
  SKIP_MARK='emit a `skipped` output and'
  # shellcheck disable=SC2016
  PRODUCE_OLD='4. Write it up **in your `<output>` block** — title, full body, one-line
   summary, and the candidates you considered.'
  # shellcheck disable=SC2016
  PRODUCE_NEW='4. Write it up **in prose** — the proposed title, the full PRD body in
   Markdown, and the candidates you considered. Keep it in your final
   response; a follow-up pass lifts it into structured output.'
  # shellcheck disable=SC2016
  TAIL_OLD='The full process — including the methodology (deletion test, deepening,
glossary), the loose-duplicate rule, the PRD shape, and the exact `<output>`
schema — is documented in the project skill
`improve-codebase-architecture-project`. Follow it.'
  # shellcheck disable=SC2016
  TAIL_NEW='The full process — including the methodology (deletion test, deepening,
glossary), the loose-duplicate rule, and the PRD shape — is documented in the
project skill `improve-codebase-architecture-project`. Follow it. The extraction
pass carries the schema; this one just leaves the PRD in prose it can lift.'
  # shellcheck disable=SC2016
  SKIP_OLD='- One PRD per run. If every reasonable candidate is already covered by a
  prior `source:architecture-review` proposal, emit a `skipped` output and
  stop.'
  # shellcheck disable=SC2016
  SKIP_NEW='- One PRD per run. If every reasonable candidate is already covered by a
  prior `source:architecture-review` proposal, say so plainly and stop — the
  next pass reports it as `skipped`, so it needs no structured output here.'

  if [ ! -e "$ARCH_PROMPT" ]; then
    note "architecture-review/prompt.md absent; nothing to converge"
  elif grep -qF -e "$PRODUCE_MARK" "$ARCH_PROMPT" \
    || grep -qF -e "$TAIL_MARK" "$ARCH_PROMPT" \
    || grep -qF -e "$SKIP_MARK" "$ARCH_PROMPT"; then
    say "== $FROM -> $TEMPLATE_VERSION: the produce pass writes prose, not structured output =="
    # Each anchor on its own. A project can carry the produce request without the
    # schema paragraph, or keep the rule that names a `skipped` output — one file
    # gate on any of them would skip the others.
    if grep -qF -e "$PRODUCE_MARK" "$ARCH_PROMPT"; then
      subst "$ARCH_PROMPT" "$PRODUCE_OLD" "$PRODUCE_NEW"
    fi
    if grep -qF -e "$SKIP_MARK" "$ARCH_PROMPT"; then
      subst "$ARCH_PROMPT" "$SKIP_OLD" "$SKIP_NEW"
    fi
    if grep -qF -e "$TAIL_MARK" "$ARCH_PROMPT"; then
      subst "$ARCH_PROMPT" "$TAIL_OLD" "$TAIL_NEW"
    fi
    # Deliberately the multi-line-unsafe form: these markers are the first LINE of
    # phrases this step must not leave behind, so grep matching that line alone
    # makes the check at least as wide as the anchors rather than narrower. A
    # project that reworded one of these into different words that still ask the
    # produce pass for structured output is a shape this step has never seen, and
    # the version it is about to record is never revisited — refusing is the only
    # safe answer.
    # shellcheck disable=SC2016  # the patterns are prompt text; backticks are literal.
    if grep -qF -e 'in your `<output>` block' -e 'emit a `skipped` output' \
       "$ARCH_PROMPT"; then
      echo "architecture-review/prompt.md: still asks the produce pass for structured output — refusing to record this project as migrated" >&2
      exit 1
    fi
    # shellcheck disable=SC2016  # likewise: the tail paragraph names the schema in backticks.
    if grep -qF -e 'and the exact `<output>`' "$ARCH_PROMPT"; then
      echo "architecture-review/prompt.md: still points the produce pass at the output schema — refusing to record this project as migrated" >&2
      exit 1
    fi
    note "architecture-review/prompt.md: produce pass returns prose; the extract pass carries the schema"
  else
    note "architecture-review/prompt.md: produce pass already writes prose; left as the project wrote it"
  fi
fi

# ---- step: 1.5.x -> 1.6.0 — the sandbox gets code intelligence --------------
# Two changes with one purpose: stop the agent spending its budget rediscovering
# the repository. Measured on a real run (health-flow #114): 36 of 62 tool calls
# were `cat`/`ls`/`grep`/`sed` looking for entry points, test layout and docs.
#
#   1. The sandbox image gains `serena` (LSP symbols) and a mounted
#      `codebase-memory-mcp` (the repository graph), injected by the claude
#      wrapper via --mcp-config.
#   2. `.sandcastle/REPO-MAP.md` answers "where does what live" in one read, and
#      the implement prompts tell the agent to read it first.
#
# The image must be rebuilt for (1) — the Dockerfile gains a layer, and a wrapper
# that passes a config file the old image does not read. Until then the new
# prompts simply point at servers that are not there, which claude skips
# silently; that degrades rather than breaks, and the rebuild instruction below
# names the order.
if [ "$from_minor" -lt 6 ] && [ "$to_minor" -ge 6 ]; then
  STEP_RAN=1
  say "== $FROM -> $TEMPLATE_VERSION: sandbox code intelligence + repository map =="

  # 1. The generator and its check are new files, not edits.
  #
  # Tracked so the report below lists them and the publish loop writes them.
  # Staging a file is not delivering it: the report and the publish loop are both
  # driven by a list, so a file that is copied into $WORK and named on neither is
  # migrated in the stage and discarded at the end of the run. That is not a
  # missing nicety — `profile.ts` gains `import ... from "./mcp-config.js"` a few
  # lines below, so the project comes out stamped 1.6.0 holding a module that
  # cannot be resolved, and `pnpm afk` dies on the import.
  NEW_FILES=""
  cp "$S/scaffold/.sandcastle/repo-map.mjs" "$WORK/.sandcastle/repo-map.mjs"
  cp "$S/scaffold/.sandcastle/repo-map.check.mjs" "$WORK/.sandcastle/repo-map.check.mjs"
  cp "$S/scaffold/.sandcastle/mcp-config.ts" "$WORK/.sandcastle/mcp-config.ts"
  cp "$S/scaffold/.sandcastle/mcp-config.check.ts" "$WORK/.sandcastle/mcp-config.check.ts"
  NEW_FILES="$NEW_FILES .sandcastle/repo-map.mjs .sandcastle/repo-map.check.mjs"
  NEW_FILES="$NEW_FILES .sandcastle/mcp-config.ts .sandcastle/mcp-config.check.ts"

  # 1b. The Dockerfile is a RENDERED artifact that becomes project-owned after
  #     bootstrap, so it is edited by anchor — never re-rendered, which would
  #     discard the project's own edits (an enabled Playwright block, a pinned
  #     base image). The insertion is done by a node script written to the stage:
  #     the text being inserted contains `${AGENT_UID}`, which a shell heredoc or
  #     an unquoted replacement would expand into this host's uid.
  DOCKER="$WORK/.sandcastle/Dockerfile"
  if grep -qF "serena-agent" "$DOCKER"; then
    note "Dockerfile: serena layer already present"
  elif grep -qF "RUN npm install --global @anthropic-ai/claude-code" "$DOCKER"; then
    cat > "$STAGE/add-serena-layer.mjs" <<'SERENAJS'
import { readFileSync, writeFileSync } from "node:fs";

const [path] = process.argv.slice(2);
let src = readFileSync(path, "utf8");
const anchor = "RUN npm install --global @anthropic-ai/claude-code";

// The uv layer is inserted only when absent: the Node template did not ship one
// before this version, and the serena install needs it.
if (!src.includes("astral.sh/uv/install.sh")) {
  src = src.replace(
    anchor,
    [
      "# uv — serena is installed with uv tool install below.",
      "RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \\",
      "  && rm -rf /root/.cache",
      "",
      anchor,
    ].join("\n"),
  );
}

src = src.replace(
  anchor,
  [
    "# Serena MCP server — symbol-level code navigation, baked in so every run",
    "# does not pay 30-60 s to install it. Paths come from env vars: this RUN sits",
    "# above the USER line, and a bare uv tool install would land in the root home.",
    "RUN UV_TOOL_BIN_DIR=/usr/local/bin UV_TOOL_DIR=/home/agent/.local/share/uv/tools \\",
    "      uv tool install serena-agent==1.7.0 \\",
    "  && chown -R ${AGENT_UID}:${AGENT_GID} /home/agent/.local \\",
    "  && serena --version",
    "",
    anchor,
  ].join("\n"),
);

// npm 11 refuses to run a package's postinstall unless it is named, and
// claude-code's postinstall is what fetches its platform-native binary. Without
// it npm only WARNS, the build still exits 0, and the container starts with a
// claude that reports "claude native binary not installed". The template has
// carried --allow-scripts since the image was written, but no migration step
// ever delivered it: a project scaffolded before then rebuilds to that broken
// image and nothing goes red. Supplied here because this step is already
// editing the file.
const npm = "RUN npm install --global @anthropic-ai/claude-code";
if (src.includes(npm) && !src.includes("--allow-scripts=@anthropic-ai/claude-code")) {
  src = src.replace(
    npm,
    "RUN npm install --global --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code",
  );
}

writeFileSync(path, src);
SERENAJS
    node "$STAGE/add-serena-layer.mjs" "$DOCKER"
    note "Dockerfile: serena layer + uv layer added"
  else
    echo "Dockerfile: no npm-install anchor found — refusing to guess" >&2
    exit 1
  fi

  # The wrapper's exec line gains --mcp-config. Anchored on the settings path the
  # previous template wrote; a project that rewrote that line is reported.
  if grep -qF ".afk-mcp.json" "$DOCKER"; then
    note "Dockerfile: wrapper already passes --mcp-config"
  elif grep -qF -- "--settings /home/agent/.afk-profile-settings.json" "$DOCKER"; then
    # shellcheck disable=SC2016  # both strings are literal Dockerfile text
    subst "$DOCKER" \
      "--settings /home/agent/.afk-profile-settings.json" \
      "--settings /home/agent/.afk-profile-settings.json --mcp-config /home/agent/.afk-mcp.json"
  else
    echo "Dockerfile: no wrapper --settings anchor found — refusing to guess" >&2
    exit 1
  fi

  # The `claude` arm of the wrapper gained --mcp-config too, and the anchor above
  # cannot reach it: that arm is the *only* one with no --settings flag, which is
  # also why the profile mounts it is paired with are no longer conditional. The
  # two halves are one change — a mount the wrapper never reads is a server the
  # agent never gets, and the reverse. A project that rewrote the arm is refused
  # rather than half-migrated, because an unread mount is exactly the silent
  # degradation this step exists to remove.
  CLAUDE_ARM="  '  claude) exec /usr/local/bin/claude-real \"\$@\" ;;' \\"
  CLAUDE_ARM_NEW="  '  claude) exec /usr/local/bin/claude-real --mcp-config /home/agent/.afk-mcp.json \"\$@\" ;;' \\"
  if grep -qF -- "$CLAUDE_ARM_NEW" "$DOCKER"; then
    note "Dockerfile: claude arm already passes --mcp-config"
  elif grep -qF -- "$CLAUDE_ARM" "$DOCKER"; then
    subst "$DOCKER" "$CLAUDE_ARM" "$CLAUDE_ARM_NEW"
  else
    echo "Dockerfile: no claude dispatch arm found — refusing to guess" >&2
    exit 1
  fi

  # 1c. The map is *not* generated here. It has to describe the published tree,
  #     and the glossary above renames a root document in the stage — so a map
  #     built now would list CONTEXT.md while the publication writes GLOSSARY.md,
  #     and the freshness check this step wires would fail on the first push.
  #     Generating from a shadow copy instead does not work either: the generator
  #     skips symlinked entries, so a shadow built by linking the real tree loses
  #     `docs/` from the map's tree section. It is generated in the publish phase
  #     below, where $TARGET *is* the finished project, and remembered here.
  if [ -e "$TARGET/.sandcastle/REPO-MAP.md" ]; then
    note "REPO-MAP.md: already present"
  elif [ -e "$WORK/.sandcastle/repo-map.mjs" ]; then
    MAP_NEEDED=1
  fi

  # 2. profile.ts gains the MCP import, the write call, and the mounts. All three
  #    are anchored on what the previous template wrote, so a project that has
  #    customised this file is reported rather than silently rewritten.
  PROF="$WORK/.sandcastle/profile.ts"
  if grep -qF "mcp-config.js" "$PROF"; then
    note "profile.ts: MCP wiring already present"
  elif grep -qF 'import { sandboxNetworkOptions } from "./profile-network.js";' "$PROF"; then
    subst "$PROF" \
      'import { sandboxNetworkOptions } from "./profile-network.js";' \
      'import { sandboxNetworkOptions } from "./profile-network.js";
import { mcpConfigMounts, writeMcpConfig } from "./mcp-config.js";'
    subst "$PROF" \
      '): { agent: AgentProvider; sandbox: SandboxProvider } {' \
      '): { agent: AgentProvider; sandbox: SandboxProvider } {
  // Materialise the MCP config before the sandbox is created — the mount below
  // needs a file to point at, and writing it per run is what keeps it true to
  // what this host actually has.
  writeMcpConfig();'
    # The mounts literal 1.5.x wrote is replaced whole. It was a conditional
    # one-element list; it becomes an unconditional list, so the `claude` profile
    # — the one that resolves no settings file — still receives the MCP pair.
    # Anchored on the exact three lines 1.5.x emitted, so a project that has
    # rewritten them is refused rather than half-migrated.
    node -e '
      const fs = require("fs");
      const [path] = process.argv.slice(1);
      const src = fs.readFileSync(path, "utf8");
      const anchor = [
        "      ...(settingsPath",
        "        ? { mounts: [{ hostPath: settingsPath, sandboxPath: \"/home/agent/.afk-profile-settings.json\", readonly: true }] }",
        "        : {}),",
      ].join("\n");
      if (!src.includes(anchor)) {
        console.error("profile.ts: mount literal not found — refusing to guess");
        process.exit(1);
      }
      const replacement = [
        "      // The mounts are unconditional. The MCP pair is independent of the",
        "      // endpoint: the graph is mounted from the host and serena is in the image,",
        "      // both regardless of how the agent authenticates. Gating them on",
        "      // settingsPath (as this started out) made the setting a proxy for",
        "      // \"is this a non-default profile\" — and the claude profile is the one",
        "      // that resolves no settings file, so the default profile was exactly the",
        "      // one that got no mounts, no config file, and therefore no servers. The",
        "      // wrapper arm also passes no --mcp-config, so nothing else",
        "      // supplied them: not a wrong path, just absent.",
        "      mounts: [",
        "        // Present only when the profile resolves an endpoint, because without",
        "        // one there is no file to mount — the wrapper claude arm uses the",
        "        // Anthropic default and reads no settings.",
        "        ...(settingsPath",
        "          ? [{ hostPath: settingsPath, sandboxPath: \"/home/agent/.afk-profile-settings.json\", readonly: true }]",
        "          : []),",
        "        ...mcpConfigMounts(),",
        "      ],",
      ].join("\n");
      fs.writeFileSync(path, src.replace(anchor, replacement));
    ' "$PROF"
    note "profile.ts: MCP config wiring added"
  else
    say ""
    say "profile.ts does not carry the 1.5.x network import this step anchors on."
    say "Migrate it by hand: import mcpConfigMounts/writeMcpConfig from"
    say "./mcp-config.js, call writeMcpConfig() at the top of claudeProfile, and"
    say "spread mcpConfigMounts() into the docker() mounts."
    exit 1
  fi

  # 3. The five implement prompts gain the map pointer. Anchored on the
  #    read-list sentence the previous template emitted, so a project that
  #    rewrote that sentence is left alone (its author had a reason).
  #
  #    Two anchors, not one, because the sentence differs per prompt: four of the
  #    five open `Read \`GLOSSARY` (implement.md, implement-prompt.md,
  #    implement/prompt.md, implement-pr/prompt.md), while the PRD prompt
  #    (`.sandcastle/implement-prd/prompt.md`) opens `Read the relevant files
  #    under \`docs/\`` — it is the one that lists docs before the glossary. A
  #    single anchor matched four of the five and reported the loop as done: the
  #    prompt that runs every *PRD* agent was left without the map pointer, and
  #    the miss is silent by design (`rc=3` means "the author rewrote it"), so
  #    nothing anywhere said so. Each prompt is anchored on what it carries.
  for rel in \
    .sandcastle/implement.md \
    .sandcastle/implement-prompt.md \
    .sandcastle/implement/prompt.md \
    .sandcastle/implement-pr/prompt.md \
    .sandcastle/implement-prd/prompt.md ; do
    [ -e "$WORK/$rel" ] || continue
    grep -qF "REPO-MAP.md" "$WORK/$rel" && continue
    # Node rather than perl: the replacement text contains backticks, and perl
    # treats those in a replacement as command substitution — the first attempt
    # at this produced an empty string instead of the new sentence. The script is
    # written to a file so shellcheck does not read the backticks as SC2016.
    cat > "$STAGE/add-map-pointer.mjs" <<'MAPJS'
import { readFileSync, writeFileSync } from "node:fs";
const [path] = process.argv.slice(2);
// Each pair is (what the previous template wrote, what it becomes). The first
// prefix that matches wins; a prompt carrying none of them is one this step has
// not seen, and the caller reports it rather than claiming the migration ran.
const ANCHORS = [
  ["Read `GLOSSARY", "Read `.sandcastle/REPO-MAP.md` first (where things live), then `GLOSSARY"],
  ["Read the relevant files under `docs/`", "Read `.sandcastle/REPO-MAP.md` first (where things live), then the relevant files under `docs/`"],
];
const before = readFileSync(path, "utf8");
for (const [from, to] of ANCHORS) {
  if (!before.includes(from)) continue;
  writeFileSync(path, before.replace(from, to));
  process.exit(0);
}
process.exit(3);
MAPJS
    node "$STAGE/add-map-pointer.mjs" "$WORK/$rel" || rc=$?
    case ${rc:-0} in
      0) NEW_FILES="$NEW_FILES $rel" ;;
      3) : ;;  # anchor absent — a project edit; leave it
      *) echo "$rel: could not rewrite the read-list — refusing to guess" >&2; exit 1 ;;
    esac
    rc=0
  done

  # 4. The CI job gains the three new checks. Anchored on the check 1.5.1 added.
  POLICY="$WORK/.github/workflows/afk-policy.yml"
  if [ ! -e "$POLICY" ]; then
    note "afk-policy.yml absent; the scaffold supplies it"
  elif grep -qF "mcp-config.check.ts" "$POLICY"; then
    note "afk-policy.yml: code-intelligence checks already wired"
  else
    A1="        run: npx --yes tsx .sandcastle/profile-network.check.ts"
    A2="$A1
      - name: Verify sandbox MCP config
        run: npx --yes tsx .sandcastle/mcp-config.check.ts
      # A stale map is read with the same confidence as the code, so it is
      # checked rather than trusted. --check regenerates to stdout and compares —
      # it never writes the file it is judging.
      - name: Verify the repository map is current
        run: node .sandcastle/repo-map.check.mjs"
    if grep -qF "$A1" "$POLICY"; then
      subst "$POLICY" "$A1" "$A2"
    else
      echo "afk-policy.yml: no anchor for the network check — refusing to guess" >&2
      exit 1
    fi
  fi
fi

# ---- step: 1.6.0 -> 1.6.1 — the MCP config is written atomically, and the
#      codebase-memory binary must be executable ------------------------------
# Two defects in the 1.6.0 modules, both silent in the same way: the agent loses
# half its tools and nothing reports it.
#
#   1. `writeMcpConfig` truncated the shared file before writing it. The planner
#      starts several implementations at once and every one of them calls
#      `claudeProfile`, so a sandbox that was already starting could read the
#      mount mid-rewrite. claude treats a config it cannot parse as "no servers"
#      rather than as an error, so the run silently lost both. It is written by
#      rename now. Measured on this host: an in-place write produced ~16000
#      unparseable reads in 400 ms, the rename none.
#   2. The availability test was `R_OK`, which a readable non-executable file
#      passes. claude cannot launch such a command and skips that server without
#      saying so. It is a regular, executable file now.
#
# Both files are replaced wholesale rather than edited by anchor: they are this
# scaffold's own modules, not project-owned inputs, and an anchored edit of a
# function body would have to guess at whatever a project did to it. The
# comparison is against the 1.6.0 shape this step was written for — both
# revisions export the same names, so a presence marker would prove nothing.
if [ "$from_minor" -eq 6 ] && [ "$from_patch" -lt 1 ] && [ "$to_minor" -ge 6 ]; then
  STEP_RAN=1
  say "== $FROM -> $TEMPLATE_VERSION: MCP config written atomically; binary must be executable =="

  RESTAGE=""
  for rel in .sandcastle/mcp-config.ts .sandcastle/mcp-config.check.ts .sandcastle/repo-map.mjs; do
    SRC="$S/scaffold/$rel"
    [ -e "$SRC" ] || { echo "migration reference missing: $SRC" >&2; exit 1; }
    if [ -e "$WORK/$rel" ] && cmp -s "$WORK/$rel" "$S/references/$(basename "$rel").1.6.0"; then
      cp "$SRC" "$WORK/$rel"
      RESTAGE="$RESTAGE $rel"
    else
      say "$rel is not the 1.6.0 shape — leaving it as the project has it."
      say "Re-apply the two changes by hand: writeMcpConfig must write a temp file"
      say "and rename it over the target, and the availability test must require a"
      say "regular executable (isFile + X_OK), not merely a readable path."
    fi
  done

  # The map is regenerated unconditionally at this version, because the generator
  # changed: `entryPoints` now reads `[project.scripts]`, so every project that
  # ships console commands has a map whose content is out of date even though its
  # file is current. Leaving it would fail the freshness check this scaffold's own
  # CI runs, on the project's next push, for a reason the project did not cause.
  if [ -e "$WORK/.sandcastle/repo-map.mjs" ]; then
    MAP_NEEDED=1
  fi

  # NEW_FILES drives both the change report and the publish loop; a path that is
  # restaged without being named there is migrated in the stage and discarded at
  # exit — the 1.6.0 defect this same file records.
  for rel in $RESTAGE; do
    note "restaged: $rel"
    NEW_FILES="$NEW_FILES $rel"
  done

  # The generator gained a parser for pyproject.toml's console scripts, and a
  # self-check for it. A project that already runs the map freshness check has no
  # line that exercises the parser: a fresh scaffold carries no console scripts,
  # so the map is empty there and correct — the defect is only visible in the
  # Python projects this step is largely aimed at. Anchored on the map step the
  # 1.6.0 wiring installed; a project that reordered its CI is reported.
  POLICY="$WORK/.github/workflows/afk-policy.yml"
  if [ ! -e "$POLICY" ]; then
    note "afk-policy.yml absent; the scaffold supplies it"
  elif grep -qF "repository-map generator self-check" "$POLICY"; then
    note "afk-policy.yml: generator self-check already wired"
  else
    P1="      - name: Verify the repository map is current
        run: node .sandcastle/repo-map.check.mjs"
    P2="$P1
      # The generator's own parser, not the map it produced: a regex that matches
      # nothing yields a map that looks complete and omits the answer, and a fresh
      # scaffold cannot catch that because a fresh scaffold has no console scripts
      # to omit. Deliberately NOT wired into repo-map.check.mjs — the map check
      # must use the shipping code path or it would validate one thing and ship
      # another.
      - name: Repository-map generator self-check
        run: node .sandcastle/repo-map.mjs --self-check"
    if grep -qF "$P1" "$POLICY"; then
      subst "$POLICY" "$P1" "$P2"
      note "afk-policy.yml: generator self-check added"
    else
      say "afk-policy.yml has no map-freshness step to anchor on."
      say "Add a CI step running 'node .sandcastle/repo-map.mjs --self-check' by hand."
    fi
  fi
fi


if [ "$STEP_RAN" = "0" ]; then
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
for rel in .sandcastle/Dockerfile .sandcastle/profile.ts .sandcastle/main.ts .sandcastle/profile-network.ts .sandcastle/profile-network.check.ts .afk-bootstrap.json; do
  # Only report a file this run actually staged: the network modules arrive in
  # 1.5.0, so a run that only executes the 1.5.1 CI step has none to compare.
  [ -e "$WORK/$rel" ] || continue
  cmp -s "$TARGET/$rel" "$WORK/$rel" && continue
  CHANGED=1
  note "changed: $rel"
done
# The architecture-review runner. The 1.5.2 step edits `prompt.md` in place, and
# a file this run actually changed would otherwise be missing from the report:
# the list above is fixed, so an unlisted path is migrated silently. Compared per
# file for the same reason publishing is — the directory is project-owned, and
# "the directory differs" would report a project's own extra module as changed.
if [ -d "$WORK/.sandcastle/architecture-review" ]; then
  for f in "$WORK/.sandcastle/architecture-review"/*; do
    [ -f "$f" ] || continue
    rel=".sandcastle/architecture-review/${f##*/}"
    cmp -s "$TARGET/$rel" "$f" 2>/dev/null && continue
    CHANGED=1
    note "changed: $rel"
  done
fi
if ! diff -rq "$TARGET/.github/workflows" "$WORK/.github/workflows" >/dev/null 2>&1; then
  CHANGED=1
  note "changed: .github/workflows/"
fi
# Files the 1.4.0 glossary step rewrote. Without this the change report would
# under-state the run: the comparison above is a fixed list, so a file that only
# this step touches would be silently migrated.
for rel in ${GLOSSARY_FILES:-}; do
  CHANGED=1
  note "changed: $rel"
done
# Files the 1.6.0 step staged. These are paths the project did not have, so the
# comparison above — a fixed list of files every project already carries — can
# never see them. Reported for the same reason the glossary files are: the
# report is how an operator knows what a run touched.
for rel in ${NEW_FILES:-}; do
  CHANGED=1
  note "changed: $rel"
done
# The map is generated in the publish tail rather than staged with NEW_FILES, so
# it would otherwise be the one file a --dry-run report omits. That matters more
# for this path than for the others: the operator's whole reason to dry-run is to
# see what a migration will add, and a map is added to every project that has
# none. `--dry-run` exits before the publish tail, so this is reporting only.
if [ "${MAP_NEEDED:-0}" = "1" ]; then
  CHANGED=1
  note "changed: .sandcastle/REPO-MAP.md (generated after publish)"
fi
if [ "${GLOSSARY_RENAME:-0}" = "1" ]; then
  CHANGED=1
  note "renamed: CONTEXT.md -> GLOSSARY.md"
fi

if [ -n "$PROSE" ]; then
  say ""
  say "Project prose still names something this migration replaced (it does not edit project prose):"
  while IFS= read -r f; do
    [ -n "$f" ] && say "  - $f"
  done <<EOF
$PROSE
EOF
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

# Staging protects the transform phase, but publishing still mutates the target.
# Back every destination up and restore all of them if any write fails, so an
# interrupted or failing publish cannot leave a migrated Dockerfile next to
# metadata that still claims the old version.
#
# Each destination is registered *before* its write, not after: a copy that fails
# partway has already truncated or half-written the destination, so restoring
# only the copies that succeeded would leave the failed one damaged.
PUBLISHED_FILES=""
PUBLISHED_DIRS=""
# Files this migration deletes as part of a rename. A delete has no copy to roll
# back from, so the original is backed up first and restored like any other file.
PUBLISHED_DELETES=""
restore_published() {
  local status=$?
  if [ -n "$PUBLISHED_FILES$PUBLISHED_DIRS$PUBLISHED_DELETES" ]; then
    say "publish failed; restoring the project" >&2
    # A directory is restored by removing whatever is there now and copying the
    # backup back. Copying onto a partially-written directory would nest the old
    # tree inside the new one instead of replacing it.
    for rel in $PUBLISHED_DIRS; do
      rm -rf "${TARGET:?}/$rel"
      cp -R "$STAGE/backup/$rel" "${TARGET:?}/$rel" || say "could not restore $rel" >&2
    done
    for rel in $PUBLISHED_FILES; do
      if [ -e "$STAGE/backup/$rel.absent" ]; then
        # The migration added this file; rolling back means removing it, not
        # restoring a backup that never existed. Its parent directory may also
        # have been created by the migration, so remove it when it is left
        # empty — an empty `.sandcastle/architecture-review/` is residue the
        # project never asked for.
        rm -f "$TARGET/$rel"
        rmdir "$(dirname "$TARGET/$rel")" 2>/dev/null || true
        continue
      fi
      cp "$STAGE/backup/$rel" "$TARGET/$rel" || say "could not restore $rel" >&2
    done
    # A deletion is restored by putting the backed-up original back. This runs
    # after the loop above, so a rename is undone as: new name written, then old
    # name restored — the project returns to holding exactly CONTEXT.md.
    for rel in $PUBLISHED_DELETES; do
      cp "$STAGE/backup/$rel" "$TARGET/$rel" || say "could not restore $rel" >&2
    done
  fi
  rm -rf "$STAGE"
  exit "$status"
}
mkdir -p "$STAGE/backup"
trap restore_published EXIT

publish_file() {
  local rel="$1"
  mkdir -p "$(dirname "$TARGET/$rel")" "$(dirname "$STAGE/backup/$rel")"
  # A file this migration ADDS has nothing to back up. The restore path skips a
  # backup that is absent, so not creating one is correct — failing here instead
  # would mean the migration could never add a file, only edit one.
  if [ -e "$TARGET/$rel" ]; then
    cp "$TARGET/$rel" "$STAGE/backup/$rel" || return 1
  else
    : >"$STAGE/backup/$rel.absent"
  fi
  PUBLISHED_FILES="$rel $PUBLISHED_FILES"
  cp "$WORK/$rel" "$TARGET/$rel" || return 1
  return 0
}

publish_dir() {
  local rel="$1"
  mkdir -p "$(dirname "$STAGE/backup/$rel")"
  cp -R "$TARGET/$rel" "$STAGE/backup/$rel" || return 1
  PUBLISHED_DIRS="$rel $PUBLISHED_DIRS"
  rm -rf "${TARGET:?}/$rel"
  cp -R "$WORK/$rel" "${TARGET:?}/$rel" || return 1
  return 0
}

# Remove a file as part of a rename, keeping a restorable backup. Used instead of
# a bare `rm` so a failure later in the publish cannot leave the project holding
# the new name without the old one having existed.
publish_delete() {
  local rel="$1"
  [ -e "$TARGET/$rel" ] || return 0
  mkdir -p "$(dirname "$STAGE/backup/$rel")"
  cp "$TARGET/$rel" "$STAGE/backup/$rel" || return 1
  PUBLISHED_DELETES="$rel $PUBLISHED_DELETES"
  rm -f "$TARGET/$rel" || return 1
  return 0
}

# Metadata goes last: until every content file is in place it should keep
# describing the version the tree actually is.
for rel in .sandcastle/Dockerfile .sandcastle/profile.ts .sandcastle/main.ts .sandcastle/profile-network.ts .sandcastle/profile-network.check.ts; do
  # Skip anything this run did not stage. A 1.5.0 -> 1.5.1 run only wires CI and
  # never touches these modules; publishing a path with no staged source fails
  # the whole publish and rolls the project back.
  [ -e "$WORK/$rel" ] || continue
  publish_file "$rel" || { say "could not publish $rel" >&2; exit 1; }
done
if ! diff -rq "$TARGET/.github/workflows" "$WORK/.github/workflows" >/dev/null 2>&1; then
  publish_dir ".github/workflows" || { say "could not publish .github/workflows" >&2; exit 1; }
fi
# Files the 1.6.0 step staged. Same reason the glossary files are published
# here: the loop above lists files every project already has, so a path this
# migration *adds* has no other route to the project. Without this the run
# discards them at exit while stamping the metadata 1.6.0.
for rel in ${NEW_FILES:-}; do
  publish_file "$rel" || { say "could not publish $rel" >&2; exit 1; }
done
# The architecture-review runner. Published per file, not as a directory: it
# sits inside `.sandcastle/`, which is project-owned — replacing that directory
# wholesale would discard every project edit to the other modules.
if [ -d "$WORK/.sandcastle/architecture-review" ]; then
  for f in "$WORK/.sandcastle/architecture-review"/*; do
    [ -f "$f" ] || continue
    rel=".sandcastle/architecture-review/${f##*/}"
    cmp -s "$TARGET/$rel" "$f" 2>/dev/null && continue
    publish_file "$rel" || { say "could not publish $rel" >&2; exit 1; }
  done
fi
# Files the 1.4.0 glossary step rewrote, then the rename itself. The new name is
# written before the old one is removed, so an interruption can only leave both
# present — never neither.
for rel in ${GLOSSARY_FILES:-}; do
  cmp -s "$TARGET/$rel" "$WORK/$rel" 2>/dev/null && continue
  publish_file "$rel" || { say "could not publish $rel" >&2; exit 1; }
done
if [ "${GLOSSARY_RENAME:-0}" = "1" ]; then
  publish_file "GLOSSARY.md" || { say "could not publish GLOSSARY.md" >&2; exit 1; }
  publish_delete "CONTEXT.md" || { say "could not remove CONTEXT.md" >&2; exit 1; }
fi
publish_file ".afk-bootstrap.json" || { say "could not publish .afk-bootstrap.json" >&2; exit 1; }

# The repository map, now that $TARGET is the finished project. It is the last
# write for two reasons: it is the only artifact whose content depends on every
# other change having landed, and until it exists the freshness check the 1.6.0
# step wires has nothing to compare — so a project that reached 1.6.0 without a
# map would go red on its first push.
#
# This is the one write that happens *after* the metadata, so it is not covered
# by the rollback above: a failure here leaves a correctly migrated project with
# a missing map rather than a half-migrated one, which is the safe direction.
# The check is not silent about it either — the policy job regenerates and fails
# until someone runs `node .sandcastle/repo-map.mjs`.
if [ "${MAP_NEEDED:-0}" = "1" ]; then
  # Not inside the `if` above: `say` is this script's reporter, and the failure
  # branch has to leave the run successful rather than abort it.
  if ( cd "$TARGET" && node .sandcastle/repo-map.mjs ); then
    note "generated: .sandcastle/REPO-MAP.md"
  else
    echo "note: could not generate .sandcastle/REPO-MAP.md — run it by hand" >&2
  fi
fi

# Every write is done; disarm the rollback rather than restoring over it.
PUBLISHED_FILES=""
PUBLISHED_DIRS=""
PUBLISHED_DELETES=""
trap 'rm -rf "$STAGE"' EXIT

say ""
say "== upgraded $TARGET: $FROM -> $TEMPLATE_VERSION =="
cat <<EOF
Still to do (host runner owns delivery — this script commits nothing):

1. Rebuild the sandbox image from the upgraded Dockerfile:
     docker build --build-arg AGENT_UID="\$(id -u)" --build-arg AGENT_GID="\$(id -g)" -t <image> .sandcastle
2. Then switch the repository variable, in that order:
     gh variable set AFK_PROFILE --repo <owner/name> --body claude-deepseek
   Changing it before the rebuild makes the image's claude wrapper exit 2,
   because the old image has no claude-deepseek dispatch arm.
3. Update the project prose listed above — this script reports it but never
   rewrites a project-owned document.
EOF

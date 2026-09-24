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
      PROSE="$PROSE ${f#"$TARGET"/}"
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
if [ "$to_patch" -ge 1 ] && [ "$to_minor" -ge 3 ]; then
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
fi

# A version pair no step handles must fail rather than publish a copy that only
# has its metadata rewritten — the project would then claim a version whose
# changes it never received.
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
restore_published() {
  local status=$?
  if [ -n "$PUBLISHED_FILES$PUBLISHED_DIRS" ]; then
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

# Metadata goes last: until every content file is in place it should keep
# describing the version the tree actually is.
for rel in .sandcastle/Dockerfile .sandcastle/profile.ts .sandcastle/main.ts; do
  publish_file "$rel" || { say "could not publish $rel" >&2; exit 1; }
done
if ! diff -rq "$TARGET/.github/workflows" "$WORK/.github/workflows" >/dev/null 2>&1; then
  publish_dir ".github/workflows" || { say "could not publish .github/workflows" >&2; exit 1; }
fi
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
publish_file ".afk-bootstrap.json" || { say "could not publish .afk-bootstrap.json" >&2; exit 1; }

# Every write is done; disarm the rollback rather than restoring over it.
PUBLISHED_FILES=""
PUBLISHED_DIRS=""
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

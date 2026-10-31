#!/usr/bin/env bash
#
# Regression test: an upgrade must not write back a file the project removed
# from version control.
#
# Run: test/repo-map-removal.sh [<repo-with-a-removed-map>]
#
# Why this is a separate script and not a section of `smoke.sh`
# -------------------------------------------------------------
# `smoke.sh` builds its fixtures by hand: a `.sandcastle/` directory, a
# `.github/workflows/` directory, a Dockerfile, a metadata file. An upgrade run
# refuses a tree missing any of those ("missing .sandcastle/Dockerfile"), so a
# hand-built fixture has to reproduce more of the template than the behaviour
# under test justifies — and my first attempt at exactly that produced a fixture
# whose "tracked" variant was not actually tracked, which made a correct script
# look broken for two rounds.
#
# This test instead takes REAL repository trees and mutates only the one fact it
# is about. A real tree is also the only kind that can answer the question: the
# signal is git history, and a fixture built with `git init` has none.
#
# The bug it guards
# -----------------
# `upgrade-afk.sh` set `MAP_NEEDED` from `[ ! -e .sandcastle/REPO-MAP.md ]`, which
# is true on EVERY run for a project that deliberately removed the file — so each
# upgrade re-created it, and `git add -A` carried it into the migration commit.
# Measured on AI-Ops 2026-10-31: a sandbox-image migration added 201 lines of an
# unrelated generated map. AI-Ops's own `conflict-surface.mjs --check` caught it,
# not this script.
set -uo pipefail

S="$(cd "$(dirname "$0")/.." && pwd)"
UPGRADE="$S/upgrade-afk.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The hooks are machine-wide and refuse commits outside a linked worktree; these
# fixtures are throwaway repos that are not worktrees, so the hooks are scoped off
# for this process and everything it spawns.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.hooksPath
export GIT_CONFIG_VALUE_0=/dev/null

fail() { echo "repo-map-removal: $*" >&2; exit 1; }
ok() { echo "  ok: $*"; }

# Both halves must run an upgrade that actually executes. A tree already at the
# template's version exits with "already at X; nothing to do" before any step, so
# `MAP_NEEDED` never becomes 1 and both assertions pass for the wrong reason —
# on a tree that was never migrated. Measured: the source repositories are
# already at 1.7.38, so every fixture starts by recording the version just below.
downgrade() {
  python3 - "$1/.afk-bootstrap.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
doc["afk_template_version"] = "1.7.37"
open(path, "w").write(json.dumps(doc, indent=2) + "\n")
PY
  git -C "$1" add .afk-bootstrap.json
  git -C "$1" -c user.email=t@e -c user.name=t commit -qm "test: record the version before this migration"
}

# Default to AI-Ops, the repository the bug was measured on. Any clone works.
SOURCE="${1:-$HOME/Projects/AI-Ops}"
[ -d "$SOURCE/.git" ] || fail "source is not a git repository: $SOURCE"
[ -f "$SOURCE/.sandcastle/repo-map.mjs" ] || fail "source has no repo-map.mjs: $SOURCE"

clone() { git clone -q --no-single-branch "$SOURCE" "$1" || fail "could not clone $SOURCE"; }

# ---------------------------------------------------------------------------
echo "1. a project that removed the map does not get it back"

A="$TMP/removed"
clone "$A"
git -C "$A" checkout -q origin/main 2>/dev/null || git -C "$A" checkout -q main

# The fixture has to actually be in the state the bug is about. Building it from
# a commit that DELETES the file is what gives it the history the signal reads;
# `rm` alone would leave the path tracked-but-deleted, which is a different state
# and one the guard should refuse for a different reason.
git -C "$A" rm -q --cached .sandcastle/REPO-MAP.md 2>/dev/null || true
rm -f "$A/.sandcastle/REPO-MAP.md"
git -C "$A" -c user.email=t@e -c user.name=t commit -qm "test: remove the generated map" --allow-empty 2>/dev/null || true

[ -e "$A/.sandcastle/REPO-MAP.md" ] && fail "fixture: the map is still on disk"
[ -n "$(git -C "$A" ls-files -- .sandcastle/REPO-MAP.md)" ] && fail "fixture: the map is still tracked"
[ -z "$(git -C "$A" log --all --oneline -- .sandcastle/REPO-MAP.md)" ] \
  && fail "fixture: no history for the map, so the signal has nothing to read"
ok "fixture is a real removal (history present, index and tree empty)"
downgrade "$A"

bash "$UPGRADE" "$A" >/dev/null 2>&1 || fail "the upgrade run failed"
[ -e "$A/.sandcastle/REPO-MAP.md" ] \
  && fail "a project that removed REPO-MAP.md had it written back"
ok "the map was not written back"

# ---------------------------------------------------------------------------
echo "2. a project that TRACKS the map still gets it regenerated"

B="$TMP/tracked"
clone "$B"
git -C "$B" checkout -q origin/main 2>/dev/null || git -C "$B" checkout -q main

# Same repository, one fact changed: the path is in the index. Without this half
# the guard could be `return 1` unconditionally and every assertion above would
# still pass — that is the mutation this test exists to catch.
git -C "$B" show "$(git -C "$B" log --all --format=%H -- .sandcastle/REPO-MAP.md | head -1)^:.sandcastle/REPO-MAP.md" \
  > "$B/.sandcastle/REPO-MAP.md" 2>/dev/null \
  || fail "fixture: could not recover a historical copy of the map"
git -C "$B" add .sandcastle/REPO-MAP.md
git -C "$B" -c user.email=t@e -c user.name=t commit -qm "test: track the generated map"
rm -f "$B/.sandcastle/REPO-MAP.md"

[ -z "$(git -C "$B" ls-files -- .sandcastle/REPO-MAP.md)" ] \
  && fail "fixture: the map is not in the index"
[ -e "$B/.sandcastle/REPO-MAP.md" ] && fail "fixture: the map is still on disk, so nothing needs regenerating"
ok "fixture is tracked with a missing working copy"
downgrade "$B"

bash "$UPGRADE" "$B" >/dev/null 2>&1 || fail "the upgrade run failed"
[ -e "$B/.sandcastle/REPO-MAP.md" ] \
  || fail "a project that TRACKS REPO-MAP.md did not get its map regenerated"
ok "the map was regenerated"

echo "repo-map-removal: passed"

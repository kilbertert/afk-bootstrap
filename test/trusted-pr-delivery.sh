#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scaffold/.sandcastle/trusted-pr-delivery.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=test
export GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test
export GIT_COMMITTER_EMAIL=test@example.com

git init -q --bare --initial-branch=main "$TMP/origin.git"
git init -q -b test/base "$TMP/seed"
printf 'base one\n' > "$TMP/seed/base.txt"
git -C "$TMP/seed" add base.txt
git -C "$TMP/seed" commit -qm 'test: base one'
base_one="$(git -C "$TMP/seed" rev-parse HEAD)"
git -C "$TMP/seed" remote add origin "$TMP/origin.git"
git -C "$TMP/seed" config serverPolicy.defaultBranch main
git --git-dir="$TMP/origin.git" fetch -q "$TMP/seed" test/base
git --git-dir="$TMP/origin.git" update-ref refs/heads/main "$base_one"
git -C "$TMP/seed" fetch -q origin main:refs/remotes/origin/main
git -C "$TMP/seed" remote set-head origin main

git -C "$TMP/seed" checkout -qb feat/review
printf 'feature\n' > "$TMP/seed/feature.txt"
git -C "$TMP/seed" add feature.txt
git -C "$TMP/seed" commit -qm 'test: feature'
feature_head="$(git -C "$TMP/seed" rev-parse HEAD)"
git --git-dir="$TMP/origin.git" fetch -q "$TMP/seed" feat/review
git --git-dir="$TMP/origin.git" update-ref refs/heads/feat/review "$feature_head"

git -C "$TMP/seed" checkout -q test/base
printf 'base two\n' >> "$TMP/seed/base.txt"
git -C "$TMP/seed" commit -qam 'test: base two'
base_two="$(git -C "$TMP/seed" rev-parse HEAD)"
git --git-dir="$TMP/origin.git" fetch -q "$TMP/seed" test/base
git --git-dir="$TMP/origin.git" update-ref refs/heads/main "$base_two" "$base_one"

git clone -q "$TMP/origin.git" "$TMP/candidate"
git -C "$TMP/candidate" config serverPolicy.defaultBranch main
git -C "$TMP/candidate" checkout -q --detach "$feature_head"
git -C "$TMP/candidate" branch -f main "$base_one"

if AFK_DEFAULT_BRANCH=trunk bash "$HELPER" prepare "$TMP/candidate" "$feature_head" "$base_two" trunk >/dev/null 2>&1; then
  echo 'trusted delivery accepted the configured default branch' >&2
  exit 1
fi

bash "$HELPER" prepare "$TMP/candidate" "$feature_head" "$base_two" feat/review
test "$(git -C "$TMP/candidate" rev-parse main)" = "$base_two"
git -C "$TMP/candidate" merge -q --no-edit -m 'chore(test): merge main' main
result_head="$(git -C "$TMP/candidate" rev-parse HEAD)"
bash "$HELPER" capture "$TMP/candidate" "$feature_head" feat/review "$TMP/result.bundle" "$TMP/has_changes"
test "$(cat "$TMP/has_changes")" = true

git clone -q "$TMP/origin.git" "$TMP/delivery"
git -C "$TMP/delivery" config serverPolicy.defaultBranch main
AFK_READ_TOKEN=synthetic-read-token bash "$HELPER" import "$TMP/delivery" "$feature_head" feat/review "$TMP/result.bundle"
test "$(git -C "$TMP/delivery" rev-parse HEAD)" = "$result_head"
git -C "$TMP/delivery" merge-base --is-ancestor "$base_two" HEAD
AFK_READ_TOKEN='' bash "$HELPER" push "$TMP/delivery" "$feature_head" feat/review
test "$(git --git-dir="$TMP/origin.git" rev-parse refs/heads/feat/review)" = "$result_head"

git -C "$TMP/candidate" checkout -q feat/review
printf 'review fix\n' >> "$TMP/candidate/feature.txt"
git -C "$TMP/candidate" commit -qam 'fix: review result'
bash "$HELPER" capture "$TMP/candidate" "$result_head" feat/review "$TMP/race.bundle" "$TMP/race_changes"

git clone -q "$TMP/origin.git" "$TMP/racer"
git -C "$TMP/racer" config serverPolicy.defaultBranch main
git -C "$TMP/racer" checkout -q feat/review
printf 'racer\n' >> "$TMP/racer/feature.txt"
git -C "$TMP/racer" commit -qam 'test: advance branch'
race_head="$(git -C "$TMP/racer" rev-parse HEAD)"
git --git-dir="$TMP/origin.git" fetch -q "$TMP/racer" feat/review
git --git-dir="$TMP/origin.git" update-ref refs/heads/feat/review "$race_head" "$result_head"

git clone -q "$TMP/origin.git" "$TMP/race-delivery"
git -C "$TMP/race-delivery" config serverPolicy.defaultBranch main
if bash "$HELPER" import "$TMP/race-delivery" "$result_head" feat/review "$TMP/race.bundle" >/dev/null 2>&1; then
  echo 'trusted delivery accepted an advanced remote branch' >&2
  exit 1
fi
if bash "$HELPER" push "$TMP/race-delivery" "$result_head" feat/review >/dev/null 2>&1; then
  echo 'trusted delivery push accepted an advanced remote branch' >&2
  exit 1
fi
test "$(git --git-dir="$TMP/origin.git" rev-parse refs/heads/feat/review)" = "$race_head"

echo 'trusted PR delivery test passed'

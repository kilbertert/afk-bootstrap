#!/usr/bin/env bash
#
# Prepare this repository inside a freshly started AFK sandbox, before the agent
# runs. Called once per iteration by the `onSandboxReady` hook in `profile.ts`.
#
# WHY THIS FILE EXISTS
#
# A run's workspace starts empty: dependencies, build output and virtualenvs are
# gitignored, so the checkout carries none of them. Without this hook the agent
# installs them itself — and that is worse than it sounds. An agent that runs a
# check and sees "not installed" cannot tell *this checkout was never set up*
# from *this sandbox lacks the prerequisite*, so the reasonable-looking remedy is
# to download one. Measured: an agent spent its last ten minutes repeatedly
# fetching a 150 MB browser build for a browser the image already had.
#
# What a run needs before it starts is a property of the environment, not
# something to re-derive by probing. Write it here once and every run begins
# ready.
#
# WHAT TO PUT HERE
#
# The project's own setup commands, in the order a contributor would run them.
# For a repo whose checks are `uv run pytest` plus `npm run build`:
#
#     uv sync --extra dev
#     ( cd frontend && npm install && npm run build )
#
# Keep it idempotent: sandcastle runs it for every iteration of a run, not only
# the first. `npm ci` and `uv sync` already are; `npm run build` is cheap when
# nothing changed and is what makes `dist/` exist for the verification skill.
#
# WHAT NOT TO PUT HERE
#
#   - Anything that needs the network unless the sandbox really must have it.
#     A long silent fetch looks exactly like a hang, and the run has a timeout.
#   - Prerequisites the *image* provides (browsers, language runtimes, the MCP
#     servers). Those are already there; a hook that tries to install them will
#     download a second copy or fail outright. Check with a launch, not a lookup.
#   - Secrets. This file is committed. Anything needed at runtime belongs in the
#     run's environment, which the workflow injects.
#
# This scaffold ships the file as a no-op so the hook has something to point at.
# Replace the body with the real setup; delete the file to turn the hook off
# entirely (profile.ts only registers it when the file exists).
set -euo pipefail

echo "sandbox-prepare: nothing configured for this repository."
echo "sandbox-prepare: edit .sandcastle/sandbox-prepare.sh to add setup steps."

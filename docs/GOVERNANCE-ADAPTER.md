# Governance Adapter Contract

`server-development-consensus` owns the server-wide governance baseline. This repository owns only the AFK execution adapter: the project files, Docker runtime, Actions, labels, and prompts that apply that baseline to a repository.

## Precedence

The baseline is authoritative. Repository rules may be stricter, and AFK implementation details are subordinate. No AFK prompt, workflow, container, or generated file may weaken account boundaries, secret isolation, protected-default-branch delivery, pull-request requirements, deterministic CI, or human QA gates.

## Execution matrix

| Plane | AFK responsibility | Boundary |
|---|---|---|
| Interactive session | Grill terms, write the PRD, define acceptance and QA | Does not treat chat as the durable task record |
| Host runner | Prepare task branches, run delivery checks, push and open PRs | Never pushes the default branch |
| Docker agent | Implement and commit task-branch changes; run the portable policy check | No host-maintenance access or long-lived write credentials |
| GitHub | Run CI/Ruleset and merge the protected default branch | The final merge authority |

The normal path is `idea/grill -> PRD -> native sub-issues -> ready-for-agent -> AFK implement -> draft PR -> CI/review -> human QA -> merge`. The GitHub issue and PR provide the durable task identity.

## Portable policy check

AFK must provide a small fail-closed check for container-observable invariants:

- commit messages use the repository's accepted convention;
- the current branch is a task branch, never the default branch;
- the expected worktree and changed-path boundaries hold;
- provider settings and GitHub credentials are not copied to source, logs, or images.

The host runner repeats the delivery checks before push, and GitHub Rulesets remain authoritative. A direct `git push origin main` must be rejected by all three layers.

## Credentials

Only the current task's short-lived, minimum-scope provider configuration and read-oriented GitHub token may enter the Docker agent. `AGENT_PAT`, runner-registration tokens, long-lived write credentials, label mutation, branch push, and PR creation remain on the host/GitHub boundary.

The scaffold ships `policy-check.mjs` and `consensus-contract.json`. The
container runs `node .sandcastle/policy-check.mjs commit`; host push steps run
the `delivery` command. The check is intentionally portable and small: it
validates the generated `.afk-bootstrap.json`, `.afk-exceptions.json`, task
branch, and `git diff --check`. It does not replace the server installer,
managed hooks, or GitHub Ruleset.

The generated metadata uses `afk_template_version`, `consensus_version`, and
`consensus_compatibility` SemVer fields. A compatibility mismatch or missing
field fails closed. A structured exception must include `invariant`, `reason`,
`scope`, `compensating_control`, `owner`, `approved_at`, and `expires_at`;
security and delivery invariants listed by the contract are never
exceptionable.

## Version and exceptions

The generated `.afk-bootstrap.json` must record `consensus_version`, `afk_template_version`, and a SemVer `consensus_compatibility` range. CI blocks absent or incompatible declarations; it does not silently auto-upgrade repositories.

Implementation differences such as Docker isolation, Playwright dependencies, and self-hosted workspace persistence require a structured, owner-approved exception with `invariant`, `reason`, `scope`, `compensating_control`, `owner`, `approved_at`, and `expires_at`. Security boundaries and merge gates are never exception-eligible.

## Ownership

The consensus maintainer publishes the baseline and compatibility window. Each repository owner upgrades the AFK adapter. The host operator provisions runners and secrets. AFK remains an adapter and must not become a second source of server policy.

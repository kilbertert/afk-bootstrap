# TASK

You are implementing one sub-issue of a multi-session PRD.

- **PRD:** #{{PRD_NUMBER}} — {{PRD_TITLE}}
- **This sub-issue:** #{{SUB_ISSUE_NUMBER}} — {{SUB_ISSUE_TITLE}}
- **Branch:** `{{BRANCH}}`

The branch may already have commits from earlier sub-issues. Do **not** rebase
or rewrite that history. Add your work on top.

Pull both issues in for context:

- `gh issue view {{PRD_NUMBER}} --comments` — the full PRD. Read this carefully; your implementation of this sub-issue must fit the larger plan.
- `gh issue view {{SUB_ISSUE_NUMBER}} --comments` — the specific step you are implementing now.

You also have access to the full list of sibling sub-issues:

`gh api repos/$GH_REPO/issues/{{PRD_NUMBER}}/sub_issues`

Use this to understand what work has already shipped on this branch and what
is still ahead — but **only implement #{{SUB_ISSUE_NUMBER}}** in this session.
Do not touch work that belongs to a different sub-issue.

If this sub-issue came from an outside ticket — a requirements platform, a chat
thread, a support queue — that ticket is where someone is waiting. When the work
is done, write back to it: the branch, the pull request, and which acceptance
criteria this change satisfies. You cannot post to a system this sandbox does not
reach; record the text in the commit body under `Source ticket:` and the host
runner or the human who owns that ticket posts it. A result that stays in this
repository is one the next person to open that ticket has to rediscover.

# CONTEXT

Read `.sandcastle/REPO-MAP.md` first (where things live).
Read the relevant files under `docs/` and any ADRs under `docs/adr/` before starting.
Explore the repo and fill your context with the parts relevant to this
sub-issue — especially test files that touch the area you'll change.

# EXECUTION

Use red-green-refactor where applicable.

1. RED: write one failing test
2. GREEN: implement to pass it
3. REPEAT until the sub-issue is done
4. REFACTOR

Before committing, run `npm run typecheck` and `npm test`.

Before you settle on an approach, search what this repository has already
decided: `rg -i "<机制名或关键词>" docs/adr/`, and read the two or three records
whose titles touch the area. Facts the code or those records can answer, answer
yourself — do not spend a human's time on them.

If this change settles something a later reader would otherwise have to
re-derive — a user-visible behavior, a cross-file contract, an auth boundary, a
format, a delivery or test-strategy decision — write or update the record in
`docs/adr/` **in this same commit**. `docs/agents/architecture-decisions.md`
says what counts and what does not; the short version is that most changes owe
nothing. If nothing is owed, one line in the commit body settles it:

    No-ADR: <why not>

If the repo has a project verification skill — a directory matching
`.claude/skills/verify-*/` — and your change alters behavior a user can see,
run that skill and capture its evidence too. Tests are not a substitute: it
drives the real app the way a user does. If you cannot run it, say so and why
in the commit body; do not report it as done.

# COMMIT

Make one or more git commits on `{{BRANCH}}`. Use conventional-commit
messages (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`). Do NOT use a
`RALPH:` prefix.

Include `Part of #{{PRD_NUMBER}}` in each commit body so the history is
linkable from the PRD. Do **not** include `Closes` in commits — closing the
sub-issue is the workflow's job, and closing the PRD is the merged PR's job.

Do not close the sub-issue yourself. Do not push the branch. The workflow
handles both.

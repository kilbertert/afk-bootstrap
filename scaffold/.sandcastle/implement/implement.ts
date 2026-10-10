import { execSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as sandcastle from "@ai-hero/sandcastle";
import { claudeProfile } from "../profile.js";

const ISSUE_NUMBER = required("ISSUE_NUMBER");
const ISSUE_TITLE = required("ISSUE_TITLE");
const BRANCH = required("BRANCH");
const OUTPUT_DIR = process.env.OUTPUT_DIR ?? "/tmp";

const result = await sandcastle.run({
  name: `implement-#${ISSUE_NUMBER}`,
  ...claudeProfile(process.env.AFK_PROFILE),
  // An isolated worktree, not the runner's checkout.
  //
  // Without this the default applies: the bind-mount provider's `head` strategy,
  // which mounts the workflow's own checkout straight into the container. That
  // checkout is not a clean tree — the review and update-branch workflows leave
  // their own directories in it (`candidate/`, `controller/`, `delivery/`, each
  // with its own `.git`), and they are untracked and unignored, so they are
  // simply *part of the repository* as far as anything reading the filesystem is
  // concerned.
  //
  // Measured: the knowledge-graph indexer walked them and went from 6 283 nodes
  // to 24 627, because `candidate/.serena/cache/python/*.pkl` are serena's own
  // caches that the indexer tries to parse as source and times out on. The same
  // residue is visible to the agent, which may read a second copy of the code
  // that is not the one it is working on.
  //
  // `branchStrategy: branch` makes sandcastle create a worktree from
  // `origin/main` and mount that instead. `main.ts` and `planner.ts` have always
  // done this; the label-driven chain did not.
  branchStrategy: { type: "branch", branch: BRANCH, baseBranch: "origin/main" },
  // `verbose` appends every raw stdout line the agent emits, including the
// tool-use blocks sandcastle's parser drops. Its typed `toolCall` events only
// cover four tools (Bash, WebSearch, WebFetch, Agent) — everything else, and
// every MCP call, is invisible without this. Measured on a real run: the log
// showed 70 tool calls, all Bash, while the session had also used Read, Edit
// and MCP tools that simply never appeared. Debugging why an agent ignored an
// instruction needs the calls it actually made, not the subset the renderer
// happens to know.
logging: { type: "stdout", verbose: true },
  promptFile: path.join(import.meta.dirname, "prompt.md"),
  promptArgs: {
    ISSUE_NUMBER,
    ISSUE_TITLE,
    BRANCH,
  },
});

// Count on the **branch**, not on HEAD and not on `result.commits`.
//
// The agent works in a worktree under `.sandcastle/worktrees/`, and that
// worktree holds the branch — the host checkout stays where it was, because git
// refuses to check the same branch out twice. So the host's HEAD is the base
// branch, and every HEAD-relative count reads zero.
//
// `result.commits` is that same count one level in: sandcastle collects it with
// `git rev-list <base>..HEAD` run in the host repository. Measured on a real
// run: the agent committed, the branch had the commit, the run reported "Agent
// finished but no commits were made on the branch", and the worktree was
// deleted.
//
// The branch ref is shared across worktrees, so naming it is both correct and
// independent of where the host happens to be.
const commitsAhead = Number(
  execSync(`git rev-list --count "origin/main..${BRANCH}"`, { encoding: "utf8" }).trim()
);
if (!Number.isFinite(commitsAhead) || commitsAhead === 0) {
  fail("Agent finished but no commits were made on the branch.");
}

console.log(`\nImplementation produced ${commitsAhead} commit(s) on ${BRANCH}.`);

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    console.error(`Missing required env var: ${name}`);
    process.exit(1);
  }
  return value;
}

function fail(message: string): never {
  console.error(`\nFAILED: ${message}`);
  fs.writeFileSync(path.join(OUTPUT_DIR, "failure_reason.txt"), message);
  process.exit(1);
}

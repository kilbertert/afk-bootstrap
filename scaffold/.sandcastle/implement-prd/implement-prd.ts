import { execSync } from "node:child_process";
import * as sandcastle from "@ai-hero/sandcastle";
import { claudeProfile } from "../profile.js";
import * as path from "node:path";

const PRD_NUMBER = required("PRD_NUMBER");
const PRD_TITLE = required("PRD_TITLE");
const SUB_ISSUE_NUMBER = required("SUB_ISSUE_NUMBER");
const SUB_ISSUE_TITLE = required("SUB_ISSUE_TITLE");
const BRANCH = required("BRANCH");

const result = await sandcastle.run({
  name: `implement-prd-#${PRD_NUMBER}-sub-#${SUB_ISSUE_NUMBER}`,
  ...claudeProfile(),
  // An isolated worktree, not the workflow checkout: that checkout carries the
  // review and update-branch workflows' residue (candidate/, controller/,
  // delivery/, each with its own .git), and everything reading the filesystem
  // sees it as part of the repository — the agent included.
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
    PRD_NUMBER,
    PRD_TITLE,
    SUB_ISSUE_NUMBER,
    SUB_ISSUE_TITLE,
    BRANCH,
  },
});

// No "did this produce commits?" check: a sub-issue's work may already have
// been completed by a previous iteration, in which case the agent legitimately
// produces zero new commits and we still want the workflow to proceed (close
// the sub-issue, advance to the next one).
//
// The count below is reported for the log, and it is taken on the **branch**
// rather than from `result.commits` or the host's HEAD. Both of those are
// HEAD-relative and the host stays on the base branch — sandcastle checks the
// task branch out in a worktree, where git allows each branch only once — so
// either would print `0` for a run that did commit. Measured on a real run: the
// implement runner reported "no commits were made" and deleted the worktree
// while the commit sat on the branch.

console.log(`\nImplementation finished for sub-issue #${SUB_ISSUE_NUMBER}.`);
console.log(
  `  commits this run: ${commitsOnBranch(BRANCH)}`,
);

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    console.error(`Missing required env var: ${name}`);
    process.exit(1);
  }
  return value;
}

/**
 * Commits on `branch` that are not on `origin/main`.
 *
 * The branch ref is shared across worktrees, so this is correct regardless of
 * which branch this process's checkout happens to be on.
 */
function commitsOnBranch(branch: string): number {
  return Number(
    execSync(`git rev-list --count "origin/main..${branch}"`, { encoding: "utf8" }).trim(),
  );
}

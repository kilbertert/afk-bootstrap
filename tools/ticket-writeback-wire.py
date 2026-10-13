#!/usr/bin/env python3
"""Add the source-ticket write-back step to an agent-implement workflow.

Usage: ticket-writeback-wire.py <path-to-agent-implement.yml>

Exit codes:
  0  wired (or already wired)
  2  the file does not look like the scaffold's agent-implement workflow
  3  the anchor step is missing, so the insertion point cannot be found
  1  anything else

TEXT, not `yaml.safe_dump`. Dumping the parsed document rewrites the whole file
and loses what the parser normalises: `on:` becomes `true:` (YAML 1.1 reads it as
a boolean), quotes and block-scalar styles change, key order is whatever the
dumper chooses. Measured while writing this: the round-trip produced a file whose
`on:` key had become `true:`, which the workflow assertions in `test/smoke.sh`
then correctly refused. `tools/ticket-wire.py` sets the precedent — read the YAML
only to LOCATE, splice the text, re-parse to ASSERT.

The new step goes after "Open PR" and before "Request automated review": it needs
the pull request's URL, which only exists once Open PR has run.
"""

import re
import sys

import yaml

STEP_NAME = "Write the delivery link back to the issue"
ANCHOR_NAME = "Request automated review (add agent:review label)"

# Indentation of the scaffold's job steps: `      - name: …` is six spaces.
STEP_INDENT = " " * 6

STEP = """\
{ind}- name: {name}
{ind}  if: steps.shape.outputs.proceed == 'true' && steps.preflight.outputs.refused != 'true' && success()
{ind}  env:
{ind}    PR_URL: ${{{{ steps.open_pr.outputs.pr_url }}}}
{ind}    BRANCH: ${{{{ steps.branch.outputs.name }}}}
{ind}    GH_TOKEN: ${{{{ secrets.AGENT_PAT }}}}
{ind}  run: |
{ind}    bash .sandcastle/ticket-writeback.sh "$ISSUE_NUMBER" "$PR_URL" "$BRANCH" || true
""".format(ind=STEP_INDENT, name=STEP_NAME)

NOTE = """{ind}# The prompt tells the agent to record the ticket and NOT to name a pull
{ind}# request, because at commit time none exists. The host knows the URL, so the
{ind}# host posts it — this is what makes the prompt's "the host posts that link
{ind}# to the issue itself" a description rather than a promise.
""".format(ind=STEP_INDENT)


def die(code: int, message: str) -> None:
    print(message)
    sys.exit(code)


def steps_of(text: str):
    jobs = (yaml.safe_load(text) or {}).get("jobs") or {}
    if len(jobs) != 1:
        die(2, f"expected exactly one job, found {len(jobs)}")
    steps = next(iter(jobs.values())).get("steps")
    if not isinstance(steps, list):
        die(2, "the job has no steps list")
    return steps


def name_of(step) -> str:
    return str(step.get("name", ""))


def main(path: str) -> int:
    try:
        text = open(path, encoding="utf8").read()
    except FileNotFoundError:
        die(2, f"no such file: {path}")
        return 2

    steps = steps_of(text)
    names = [name_of(s) for s in steps]

    if STEP_NAME in names:
        step = steps[names.index(STEP_NAME)]
        env = step.get("env") or {}
        missing = [k for k in ("PR_URL", "BRANCH", "GH_TOKEN") if k not in env]
        if missing:
            die(3, f"the write-back step exists but does not pass {', '.join(missing)}")
        if ANCHOR_NAME not in names or names.index(STEP_NAME) > names.index(ANCHOR_NAME):
            die(3, "the write-back step sits after the review trigger")
        if not any(s.get("id") == "open_pr" for s in steps):
            die(3, "no step with id `open_pr` — its `pr_url` output is what the write-back needs")
        print("already wired")
        return 0

    if ANCHOR_NAME not in names:
        die(3, f"no step named {ANCHOR_NAME!r} to insert before")
    if not any(s.get("id") == "open_pr" for s in steps):
        die(3, "no step with `id: open_pr` — the write-back needs its `pr_url` output")

    # Anchor on the anchor step's own `- name:` line. The literal is unique: a
    # name that appeared twice would make the splice ambiguous, which is a
    # reason to stop rather than to pick one.
    anchor_line = f"{STEP_INDENT}- name: {ANCHOR_NAME}\n"
    if text.count(anchor_line) != 1:
        die(3, f"the anchor step's `- name:` line appears {text.count(anchor_line)} times")

    # The write-back needs the PR's URL, and the scaffold's Open PR step only
    # exports its NUMBER. Add the URL output beside it — same anchor discipline,
    # and asserted below, because a step that publishes `$PR_URL` from an empty
    # output would post an empty link.
    pr_number_line = '          echo "pr_number=$pr_number" >> "$GITHUB_OUTPUT"\n'
    if 'echo "pr_url=$pr_url"' not in text:
        if text.count(pr_number_line) != 1:
            die(3, "the Open PR step's `pr_number` output line is not uniquely identifiable")
        text = text.replace(
            pr_number_line,
            pr_number_line + '          echo "pr_url=$pr_url" >> "$GITHUB_OUTPUT"\n',
            1,
        )

    new_text = text.replace(anchor_line, NOTE + STEP + anchor_line, 1)

    # Re-parse what is about to be written, and assert the two things that
    # matter: it still parses, and the step is where it belongs.
    after = [name_of(s) for s in steps_of(new_text)]
    if STEP_NAME not in after:
        die(1, "the insertion did not survive a re-parse")
    if after.index(STEP_NAME) > after.index(ANCHOR_NAME):
        die(1, "the step landed after the review trigger")
    # `on:` must still be spelled `on:` in the FILE. Asserted on the text, not on
    # the parse: PyYAML reads `on:` as the boolean True in every GitHub workflow
    # (YAML 1.1), so a parse-level check cannot tell an edited file from an
    # untouched one — it fires on the scaffold itself. Measured, and the reason
    # this tool splices text instead of dumping the document.
    if "\non:" not in new_text:
        die(1, "the `on:` key did not survive the edit")
    if 'echo "pr_url=$pr_url"' not in new_text:
        die(1, "the Open PR step does not export `pr_url`, so the write-back would post nothing")

    with open(path, "w", encoding="utf8") as handle:
        handle.write(new_text)
    print("added the write-back step before the review trigger")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    sys.exit(main(sys.argv[1]))

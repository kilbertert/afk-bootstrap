#!/usr/bin/env python3
"""Wire the ticket-eligibility pre-flight into an AFK workflow.

Additive and structural, like `policy-wire.py`, and for the same reason: five
rounds of reconciling `afk-policy.yml` by text each closed the case that was
measured and left a sibling open. The judgement sits on the parse result, the
edit sits on the step it belongs to, and the result is re-parsed and asserted —
because every one of those five earlier attempts printed success when the edit
had not happened.

Two workflows, two shapes:

  single  `agent-implement.yml`. Insert the check and its refusal immediately
          before the existing open-PR pre-flight, and gate that step on the
          check having passed. Both steps share the same `if:` otherwise, and a
          refused ticket would go on to open a branch and a pull request.

  prd     `agent-implement-prd.yml`. The shape step already selects the next
          open sub-issue, so the check goes *inside* it: the verdict becomes
          another `mode`, and a `skip-unimplementable` step comments on the leaf
          and lets the loop move on. Skipping the leaf rather than refusing the
          PRD is deliberate — one vaguely-written sub-issue must not stop every
          sibling behind it.

Script edits are applied to the step's `run` body as YAML gives it (already
dedented), then re-indented by the step's own block indent. Matching against the
raw file instead would have meant hard-coding each project's indentation, which
is the same class of mistake as matching text instead of structure.

Exit codes:
  0  wired, or already wired (idempotent)
  2  the workflow could not be parsed, or the edit did not take
  3  a step or anchor this needs could not be located — a report, not a failure
"""

import pathlib
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - CI installs PyYAML
    print("PyYAML is required", file=sys.stderr)
    sys.exit(2)


CHECK_STEP_NAME = "Pre-flight — refuse if the ticket is not implementable"
REFUSE_STEP_NAME = "Refuse — the ticket is not one an agent can finish"
SKIP_STEP_NAME = "Skip — the selected sub-issue is not implementable"
OPEN_PR_STEP_NAME = "Pre-flight — refuse if an open PR already exists for this issue"
NESTED_PRD_STEP_NAME = "Refuse — nested PRD"
SHAPE_STEP_NAME = "Detect — sub-issues + parent shape"
MARKER = "ticket-check.mjs --json --strict"

# No `.format()` on these: `${{ … }}` is a GitHub expression, and one `.format`
# call turns every one of them into `${ … }` — a silent break of every expression
# in the emitted step. Verified the hard way; the templates are literal text.
CHECK_STEP_TEMPLATE = r"""      # The shape gate above judges the ticket's POSITION — is it a leaf, is it
      # blocked, is it a PRD. This one judges the ticket ITSELF, which nothing
      # has ever done: whether it says what to build and what "done" looks like.
      #
      # `--strict` is asked for explicitly because the check reports by default
      # (reading a ticket should never fail a shell); a caller that wants a gate
      # says so. Everything it fails on is a fact about the ticket that whoever
      # authorised the work can fix in the issue body — nothing here needs a
      # human decision the author did not already own.
      #
      # `--json <` and not `--title`: `gh issue view --json title,body` is
      # already the shape the check reads, so the step adds no parsing and no
      # second source of truth about what a ticket is.
      - name: Pre-flight — refuse if the ticket is not implementable
        if: steps.shape.outputs.proceed == 'true'
        id: ticket
        env:
          # Named per issue so two runs on the runner do not share a file. The
          # runner workspace persists between jobs, which is exactly how a stale
          # file would otherwise be judged instead of this issue's.
          AFK_TICKET_TMP: ${{ runner.temp }}/ticket-${{ github.event.issue.number || inputs.issue_number }}.json
        run: |
          set -uo pipefail
          gh issue view "$ISSUE_NUMBER" --json title,body > "$AFK_TICKET_TMP"
          if node .sandcastle/ticket-check.mjs --json --strict < "$AFK_TICKET_TMP"; then
            echo "implementable=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          {
            echo "implementable=false"
            # The check's own report, unfenced so the issue shows the list.
            echo "report<<AFK_TICKET_REPORT"
            node .sandcastle/ticket-check.mjs --json < "$AFK_TICKET_TMP" || true
            echo "AFK_TICKET_REPORT"
          } >> "$GITHUB_OUTPUT"

      # No `exit 0` here. It would only end THIS step — measured: the job runs
      # on and implements the ticket anyway. The refusal registers itself in the
      # same `refused` output the open-PR pre-flight uses, and every step that
      # does work already gates on that one signal.
      - name: Refuse — the ticket is not one an agent can finish
        if: steps.shape.outputs.proceed == 'true' && steps.ticket.outputs.implementable == 'false'
        env:
          REPORT: ${{ steps.ticket.outputs.report }}
        run: |
          set -uo pipefail
          gh issue edit "$ISSUE_NUMBER" --remove-label "agent:implement" || true
          gh issue edit "$ISSUE_NUMBER" --add-label "agent:blocked" || true
          gh issue comment "$ISSUE_NUMBER" --body "$(cat <<EOF
          Refused to run: this ticket is not one an agent can finish unattended.

          $REPORT

          Clear \`agent:blocked\` and re-add \`agent:implement\` once the ticket says
          what to build and what "done" looks like.
          EOF
          )"

"""

SKIP_STEP_TEMPLATE = r"""
      - name: Skip — the selected sub-issue is not implementable
        if: steps.shape.outputs.mode == 'skip-unimplementable'
        env:
          SUB_ISSUE_NUMBER: ${{ steps.shape.outputs.next_open_number }}
          REPORT: ${{ steps.shape.outputs.ticket_report }}
        run: |
          set -uo pipefail
          gh issue comment "$SUB_ISSUE_NUMBER" --body "$(cat <<EOF
          Skipped: this sub-issue is not one an agent can finish unattended, so the
          PRD's loop moved past it. Fix the sub-issue, then re-add
          \`agent:implement\` to the PRD.

          $REPORT
          EOF
          )"
          gh issue edit "$SUB_ISSUE_NUMBER" --add-label "agent:blocked" || true

"""

# Applied to the shape step's `run` body, which YAML hands over dedented.
PRD_BODY_EDITS = [
    (
        "the next-open selection",
        """if [ -n "$next_open" ]; then
  next_open_number=$(echo "$next_open" | jq -r '.number')
  next_open_title=$(echo "$next_open" | jq -r '.title')
fi
""",
        """if [ -n "$next_open" ]; then
  next_open_number=$(echo "$next_open" | jq -r '.number')
  next_open_title=$(echo "$next_open" | jq -r '.title')
fi

# The sub-issue about to be implemented must itself be implementable. The
# verdict comes from the exit code and the report is captured separately, so
# the two never share a stream: `--strict` prints the same lines a report run
# does, and reading stdout for the verdict is how a passing ticket gets read
# as a failing one.
#
# `--strict` is passed to say out loud that this call is a gate, so a later
# change to the reporting default cannot silently turn this step into one
# that always proceeds.
implementable="yes"
ticket_report=""
if [ -n "$next_open_number" ]; then
  sub_json=$(gh issue view "$next_open_number" --json title,body)
  rc_check=0
  node .sandcastle/ticket-check.mjs --json --strict <<<"$sub_json" >/dev/null 2>&1 || rc_check=$?
  if [ "$rc_check" != "0" ]; then
    if [ ! -f .sandcastle/ticket-check.mjs ]; then
      # The checker is not here, so its exit code says nothing about this ticket
      # — and letting it stand would report EVERY leaf as unimplementable, which
      # is how a gate gets removed. Say so and run; `agent-review` still sees the
      # pull request. Measured: a migration publishes into a project whose
      # `.sandcastle/` is its own, so "the script is always there" is not a fact
      # this workflow can rely on.
      echo "::warning::ticket-check.mjs is absent, so this leaf was not screened"
      implementable="yes"
    else
      implementable="no"
      ticket_report=$(node .sandcastle/ticket-check.mjs --json <<<"$sub_json" 2>&1 || true)
    fi
  fi
fi
""",
    ),
    (
        "the mode decision",
        """elif [ -z "$next_open_number" ]; then
  mode="refuse-all-closed"
else
""",
        """elif [ -z "$next_open_number" ]; then
  mode="refuse-all-closed"
elif [ "$implementable" = "no" ]; then
  mode="skip-unimplementable"
else
""",
    ),
    (
        "the step outputs",
        """  echo "$next_open_title"
  echo "EOF"
} >> "$GITHUB_OUTPUT"
""",
        """  echo "$next_open_title"
  echo "EOF"
  # The check's report is multi-line; the delimiter is on its own line by
  # construction, which is what the heredoc form needs. Kept in the same group
  # as the title so this is still one redirect to one file (SC2129).
  echo "ticket_report<<AFK_TICKET_REPORT"
  echo "$ticket_report"
  echo "AFK_TICKET_REPORT"
} >> "$GITHUB_OUTPUT"
""",
    ),
]

# And one edit on the always-remove step, which lives in its own step and so is
# matched against the parse, not the body.
ALWAYS_OLD = "'run: gh issue edit \"$PRD_NUMBER\" --remove-label \"agent:in-progress\""
ALWAYS_NEW_IF = (
    "always() && (steps.shape.outputs.mode == 'run' "
    "|| steps.shape.outputs.mode == 'skip-unimplementable')"
)


def die(code, message):
    print(message)
    sys.exit(code)


def parse(path):
    text = pathlib.Path(path).read_text()
    try:
        return text, yaml.safe_load(text)
    except yaml.YAMLError as exc:
        die(2, f"{path}: not parseable as YAML: {exc}")


def steps_of(doc):
    for job in (doc.get("jobs") or {}).values():
        for step in job.get("steps") or []:
            if isinstance(step, dict):
                yield step


def names_of(doc):
    return [s.get("name") for s in steps_of(doc)]


def find_step(doc, name):
    for step in steps_of(doc):
        if step.get("name") == name:
            return step
    return None


def body_indent(text, name):
    """The indent of the `run: |` block's CONTENT, read from the raw text.

    Read, not assumed: the block scalar's content sits two spaces past its own
    `run:` key, and a project that reformats its workflows would otherwise get
    silently mis-indented YAML — or, worse, YAML that still parses.
    """
    m = re.search(rf"^(\s*)- name: {re.escape(name)}\s*$", text, re.M)
    if not m:
        die(3, f"could not find the step `{name}` in the raw file")
    # Only look forward, and only as far as the step could plausibly reach.
    m2 = re.search(r"^(\s*)run: \|\s*$", text[m.end() :], re.M)
    if not m2:
        die(3, f"step `{name}` has no `run: |` block to edit")
    return m2.group(1) + "  "


def replace_body(text, name, new_body):
    """Splice a step's `run` body back, re-indented, anchored on the old block."""
    step = find_step(yaml.safe_load(text), name)
    old_body = step.get("run")
    indent = body_indent(text, name)
    old_block = "".join(
        (indent + line if line else "") + "\n" for line in old_body.rstrip("\n").split("\n")
    )
    if text.count(old_block) != 1:
        die(3, f"step `{name}`: its `run` block is not uniquely identifiable in the file")
    new_block = "".join(
        (indent + line if line else "") + "\n" for line in new_body.rstrip("\n").split("\n")
    )
    return text.replace(old_block, new_block, 1)


# Carried into the open-PR pre-flight, so a refused ticket stops the job there
# rather than only ending its own refusal step. One signal for two refusal
# reasons: every later step already gates on `preflight.refused`.
CARRY_FORWARD_OLD = """        id: preflight
        run: |
          set -euo pipefail
"""
CARRY_FORWARD_NEW = """        id: preflight
        run: |
          set -euo pipefail
          # The ticket refusal is carried forward into this step's own output, so
          # `preflight.refused` is the single signal every later step already
          # gates on. Two refusal reasons, one concept — a second output would
          # mean touching every downstream `if:` and getting one of them wrong.
          if [ "${{ steps.ticket.outputs.implementable }}" = "false" ]; then
            echo "refused=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi
"""


def wire_single(path, text, doc):
    if MARKER in text:
        return None, "already wired"
    if find_step(doc, CHECK_STEP_NAME) is not None:
        return None, "already wired"

    anchor = f"      - name: {OPEN_PR_STEP_NAME}\n"
    if text.count(anchor) != 1:
        die(3, f"{path}: expected exactly one `{OPEN_PR_STEP_NAME}` step, found {text.count(anchor)}")
    text = text.replace(anchor, CHECK_STEP_TEMPLATE + anchor, 1)

    # The carry-forward goes into the open-PR step, which the file already has,
    # so it is a second edit rather than part of the template above.
    if text.count(CARRY_FORWARD_OLD) != 1:
        die(3, f"{path}: could not locate the open-PR pre-flight's run block")
    text = text.replace(CARRY_FORWARD_OLD, CARRY_FORWARD_NEW, 1)

    open_pr = find_step(yaml.safe_load(text), OPEN_PR_STEP_NAME)
    condition = str(open_pr.get("if"))
    if "steps.ticket.outputs.implementable" not in condition:
        # Anchored on the step's NAME line together with its `if:`, not on the
        # `if:` alone. The check step just inserted carries the same condition
        # string at the same indent, so a bare `if:` anchor matches twice and
        # `replace(…, 1)` rewrites the check instead of the gate it was aimed at
        # — leaving the open-PR pre-flight ungated while printing success.
        old = f"      - name: {OPEN_PR_STEP_NAME}\n        if: {condition}\n"
        if text.count(old) != 1:
            die(3, f"{path}: could not re-anchor the open-PR pre-flight's `if:` (matched {text.count(old)})")
        text = text.replace(
            old,
            f"      - name: {OPEN_PR_STEP_NAME}\n"
            f"        if: {condition} && steps.ticket.outputs.implementable != 'false'\n",
            1,
        )
    return text, "wired"


def wire_prd(path, text, doc):
    if "ticket_report<<AFK_TICKET_REPORT" in text:
        return None, "already wired"
    if find_step(doc, SKIP_STEP_NAME) is not None:
        return None, "already wired"

    shape = find_step(doc, SHAPE_STEP_NAME)
    if shape is None:
        die(3, f"{path}: no `{SHAPE_STEP_NAME}` step — this project's shape step differs")
    body = shape.get("run") or ""
    for what, old, new in PRD_BODY_EDITS:
        if old not in body:
            die(3, f"{path}: could not locate {what} in the shape step; it differs from the scaffold's bytes")
        if body.count(old) != 1:
            die(3, f"{path}: {what} matched {body.count(old)} times, expected exactly one")
        body = body.replace(old, new, 1)
    text = replace_body(text, SHAPE_STEP_NAME, body)

    always = find_step(yaml.safe_load(text), "Always remove in-progress from PRD")
    if always is None:
        die(3, f"{path}: no `Always remove in-progress from PRD` step")
    if ALWAYS_NEW_IF not in str(always.get("if")):
        old_if = f"        if: {always.get('if')}\n"
        if text.count(old_if) < 1:
            die(3, f"{path}: could not re-anchor the always-remove `if:`")
        text = text.replace(old_if, f"        if: {ALWAYS_NEW_IF}\n", 1)

    anchor = f"      - name: {NESTED_PRD_STEP_NAME}\n"
    if text.count(anchor) != 1:
        die(3, f"{path}: expected exactly one `{NESTED_PRD_STEP_NAME}` step, found {text.count(anchor)}")
    text = text.replace(anchor, SKIP_STEP_TEMPLATE + anchor, 1)
    return text, "wired"


def assert_single(path, text):
    doc = yaml.safe_load(text)
    names = names_of(doc)
    for required in (CHECK_STEP_NAME, REFUSE_STEP_NAME):
        if required not in names:
            die(2, f"{path}: `{required}` is not in the parsed result")
    if names.index(CHECK_STEP_NAME) > names.index(OPEN_PR_STEP_NAME):
        die(2, f"{path}: the check landed after the open-PR pre-flight")
    open_pr = find_step(doc, OPEN_PR_STEP_NAME)
    if "steps.ticket.outputs.implementable" not in str(open_pr.get("if")):
        die(2, f"{path}: the open-PR pre-flight is not gated on the check")


def assert_prd(path, text):
    doc = yaml.safe_load(text)
    if SKIP_STEP_NAME not in names_of(doc):
        die(2, f"{path}: `{SKIP_STEP_NAME}` is not in the parsed result")
    shape = find_step(doc, SHAPE_STEP_NAME)
    script = shape.get("run") or ""
    for needle, what in (
        (MARKER, "the check invocation"),
        ('mode="skip-unimplementable"', "the skip mode branch"),
        ("ticket_report<<AFK_TICKET_REPORT", "the report export"),
    ):
        if needle not in script:
            die(2, f"{path}: {what} is not in the shape step of the parsed result")


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in ("single", "prd"):
        die(2, "usage: ticket-wire.py <workflow-path> single|prd")
    path, mode = sys.argv[1], sys.argv[2]
    text, doc = parse(path)

    new_text, message = (wire_single if mode == "single" else wire_prd)(path, text, doc)
    if new_text is None:
        print(message)
        return

    # Re-parse and assert the RESULT. Reporting success from the fact that the
    # write returned, rather than from the state of what was written, is exactly
    # what made five earlier rounds on the policy file print success on an edit
    # that had not happened.
    try:
        yaml.safe_load(new_text)
    except yaml.YAMLError as exc:
        die(2, f"{path}: the edit produced invalid YAML, refusing to publish: {exc}")
    (assert_single if mode == "single" else assert_prd)(path, new_text)

    pathlib.Path(path).write_text(new_text)
    print(f"wired ({mode})")


if __name__ == "__main__":
    main()

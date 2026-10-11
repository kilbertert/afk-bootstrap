#!/usr/bin/env python3
"""Ensure a policy workflow's decision-record check has what it needs.

Reads the YAML to decide, edits only the lines of the steps it names, then
re-parses and asserts the result. Exit codes:
  0  the file now carries what the check needs (or already did)
  2  the file could not be parsed, or the edit did not take
  3  a step could not be located
"""
import sys

try:
    import yaml
except ImportError:
    print("PyYAML unavailable; cannot wire the policy workflow", file=sys.stderr)
    sys.exit(2)

DECISION = "Verify decision records"
CHECKOUT = "actions/checkout@"
PREPARE = "Verify the sandbox prepare hook"
DEPTH = "fetch-depth: 0"
REF = "ref: ${{ github.event.pull_request.head.sha }}"
NAMED = {"fetch-depth", "ref"}

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
lines = text.split("\n")

try:
    doc = yaml.safe_load(text)
except yaml.YAMLError as exc:
    print(f"not valid YAML ({exc})", file=sys.stderr)
    sys.exit(2)

jobs = list((doc.get("jobs") or {}).values())


def steps_of(job):
    return [s for s in (job.get("steps") or []) if isinstance(s, dict)]


# ── where is the decision step, and what has to be true around it ───────────
decision_jobs = [j for j in jobs if any(s.get("name") == DECISION for s in steps_of(j))]
if not decision_jobs:
    # Nothing carries it. Insert it after the prepare-hook step if that exists —
    # the anchor the 1.7.12 migration used, so a project that received the step
    # from that release and one that never did end up in the same place.
    anchor = next((j for j in jobs if any(s.get("name") == PREPARE for s in steps_of(j))), None)
    if anchor is None:
        print(f"no '{PREPARE}' step to insert it after", file=sys.stderr)
        sys.exit(3)
    at = next(n for n, l in enumerate(lines) if l.strip() == f"- name: {PREPARE}")
    indent = lines[at][: len(lines[at]) - len(lines[at].lstrip())]
    # The step's own `run:` line is the last line before the next step begins.
    end = at + 1
    while end < len(lines) and (not lines[end].strip() or lines[end].startswith(indent + " ")):
        end += 1
    lines[end:end] = [
        f"{indent}- name: {DECISION}",
        f"{indent}  env:",
        f"{indent}    AFK_ADR_BASE: ${{{{ github.event.pull_request.base.sha || github.event.before }}}}",
        f'{indent}  run: node .sandcastle/adr.check.mjs --base "$AFK_ADR_BASE"',
    ]
    changed_any = True
    # Re-parse rather than assume the insertion landed where the yaml model now
    # says it is: the line insert above is what the post-edit assertion judges.
    doc = yaml.safe_load("\n".join(lines))
    jobs = list((doc.get("jobs") or {}).values())
    decision_jobs = [j for j in jobs if any(s.get("name") == DECISION for s in steps_of(j))]
    if not decision_jobs:
        print("the inserted step did not appear in the file", file=sys.stderr)
        sys.exit(2)

problems = []
changed_any = False

for job in decision_jobs:
    steps = steps_of(job)
    decision_at = next(n for n, s in enumerate(steps) if s.get("name") == DECISION)
    # The checkout THIS job's decision step runs under: the nearest preceding
    # checkout, restricted to one that does not redirect the working directory.
    # A checkout with `path:` lands in a subdirectory, and the decision step runs
    # at the job's default cwd, so that is not the one providing its history.
    checkout_at = None
    for idx in range(decision_at - 1, -1, -1):
        if not str(steps[idx].get("uses", "")).startswith(CHECKOUT):
            continue
        target = (steps[idx].get("with") or {}).get("path")
        if target not in (None, "", "."):
            continue
        checkout_at = idx
        break
    if checkout_at is None:
        problems.append("no checkout before it that does not redirect the working directory")
        continue

    checkout_step = steps[checkout_at]
    have = checkout_step.get("with") or {}
    missing = []
    depth = have.get("fetch-depth")
    if not (isinstance(depth, int) and depth == 0):
        missing.append(DEPTH)
    if not isinstance(have.get("ref"), str) or "github.event.pull_request.head.sha" not in have["ref"]:
        missing.append(REF)
    if not missing:
        continue

    # Edit the checkout step's own lines. Located by its `uses:` line, bounded by
    # the step's start — never by the decision step, which is what made an earlier
    # version insert keys after a later step's.
    uses_at = decision_idx = None
    decision_name_at = next(
        (n for n, l in enumerate(lines) if l.strip() == f"- name: {DECISION}"), None
    )
    for n in range(decision_name_at - 1, -1, -1):
        if CHECKOUT in lines[n]:
            uses_at = n
            break
    if uses_at is None:
        problems.append("its checkout cannot be located in the text")
        continue
    start = next((n for n in range(uses_at, -1, -1) if lines[n].lstrip().startswith("- ")), uses_at)
    indent = lines[start][: len(lines[start]) - len(lines[start].lstrip())]
    end = start + 1
    while end < len(lines) and (not lines[end].strip() or lines[end].startswith(indent + " ")):
        end += 1

    for key in missing:
        want = key.split(":")[0]
        found = next(
            (n for n in range(start, end) if lines[n].strip().startswith(want + ":")), None
        )
        if found is not None:
            line = lines[found]
            pad = line[: len(line) - len(line.lstrip())]
            tail = line.partition(want + ":")[2]
            comment = "  " + tail[tail.index("#") :].strip() if "#" in tail else ""
            lines[found] = f"{pad}{key}{comment}"
            continue
        with_at = next((n for n in range(start, end) if lines[n].strip() == "with:"), None)
        if with_at is None:
            problems.append(f"its checkout has no `with:` to put `{want}` in")
            break
        pad = lines[with_at][: len(lines[with_at]) - len(lines[with_at].lstrip())]
        lines[with_at + 1 : with_at + 1] = [f"{pad}  {key}"]
    else:
        changed_any = True

if problems:
    for p in problems:
        print(p, file=sys.stderr)
    sys.exit(3)

edited = "\n".join(lines)
try:
    again = yaml.safe_load(edited)
except yaml.YAMLError as exc:
    print(f"the edit produced invalid YAML ({exc})", file=sys.stderr)
    sys.exit(2)

# Assert the RESULT, not that an edit was attempted. Every earlier version of this
# printed a success line for an edit that had not happened.
still = []
for job in (again.get("jobs") or {}).values():
    steps = steps_of(job)
    at = next((n for n, s in enumerate(steps) if s.get("name") == DECISION), None)
    if at is None:
        continue
    for idx in range(at - 1, -1, -1):
        if not str(steps[idx].get("uses", "")).startswith(CHECKOUT):
            continue
        if (steps[idx].get("with") or {}).get("path") not in (None, "", "."):
            continue
        have = steps[idx].get("with") or {}
        depth = have.get("fetch-depth")
        if not (isinstance(depth, int) and depth == 0):
            still.append("fetch-depth is not 0")
        ref = have.get("ref")
        if not isinstance(ref, str) or "github.event.pull_request.head.sha" not in ref:
            still.append("ref does not name the pull request's head")
        break

if still:
    print("after the edit: " + "; ".join(sorted(set(still))), file=sys.stderr)
    sys.exit(2)

if changed_any:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(edited)
    print("wired")
else:
    print("already wired")

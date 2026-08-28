#!/usr/bin/env python3
"""Validate the small set of workflow invariants this template depends on."""

from pathlib import Path
import re
import sys

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = sorted((ROOT / ".github/workflows").glob("*.yml")) + sorted(
    (ROOT / "scaffold/.github/workflows").glob("*.yml")
)


class UniqueKeyLoader(yaml.BaseLoader):
    pass


def construct_mapping(loader: UniqueKeyLoader, node: yaml.MappingNode, deep: bool = False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise ValueError(f"duplicate key {key!r} at line {key_node.start_mark.line + 1}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping)

errors = []
for path in WORKFLOWS:
    relative = path.relative_to(ROOT)
    try:
        workflow = yaml.load(path.read_text(), Loader=UniqueKeyLoader)
    except Exception as error:
        errors.append(f"{relative}: {error}")
        continue

    pull_request_target = "pull_request_target" in workflow.get("on", {})
    for job_name, job in workflow.get("jobs", {}).items():
        if pull_request_target and "github.event.pull_request.head.repo.full_name == github.repository" not in job.get("if", ""):
            errors.append(f"{relative}: job {job_name} does not reject fork PRs")
        for index, step in enumerate(job.get("steps", []), 1):
            actions = [key for key in ("run", "uses") if key in step]
            if len(actions) != 1:
                errors.append(
                    f"{relative}: job {job_name} step {index} must have exactly one run/uses action"
                )
            run = step.get("run", "")
            if re.search(r"git\s+push[^\n]*--force(?:-with-lease)?", run):
                errors.append(f"{relative}: job {job_name} step {index} force-pushes")

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)

print(f"workflow structure passed ({len(WORKFLOWS)} files)")

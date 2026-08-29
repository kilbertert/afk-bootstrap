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
    source = path.read_text()
    try:
        workflow = yaml.load(source, Loader=UniqueKeyLoader)
    except Exception as error:
        errors.append(f"{relative}: {error}")
        continue

    pull_request_target = "pull_request_target" in workflow.get("on", {})
    for job_name, job in workflow.get("jobs", {}).items():
        if pull_request_target and "github.event.pull_request.head.repo.full_name == github.repository" not in job.get("if", ""):
            errors.append(f"{relative}: job {job_name} does not reject fork PRs")
        if pull_request_target and "github.event.pull_request.user.login == github.repository_owner" not in job.get("if", ""):
            errors.append(f"{relative}: job {job_name} does not require a repository-owner PR")
        if pull_request_target and job.get("permissions", {}).get("contents") != "read":
            errors.append(f"{relative}: job {job_name} grants unnecessary contents write permission")
        if pull_request_target and "GH_TOKEN" in job.get("env", {}):
            errors.append(f"{relative}: job {job_name} exposes a write token to every step")
        for index, step in enumerate(job.get("steps", []), 1):
            actions = [key for key in ("run", "uses") if key in step]
            if len(actions) != 1:
                errors.append(
                    f"{relative}: job {job_name} step {index} must have exactly one run/uses action"
                )
            run = step.get("run", "")
            if re.search(r"git\s+push[^\n]*--force(?:-with-lease)?", run):
                errors.append(f"{relative}: job {job_name} step {index} force-pushes")
            if pull_request_target and run.strip() == "npm ci" and step.get("working-directory") != "controller":
                errors.append(f"{relative}: job {job_name} installs candidate-controlled host dependencies")
            candidate_token = step.get("env", {}).get("GH_TOKEN", "")
            if pull_request_target and step.get("working-directory") == "candidate" and candidate_token and "AFK_AGENT_READ_TOKEN" not in candidate_token:
                errors.append(f"{relative}: job {job_name} exposes a write token in the candidate checkout")
            if pull_request_target and step.get("name") == "Push result from clean delivery workspace" and "AGENT_PAT" not in candidate_token:
                errors.append(f"{relative}: job {job_name} does not fail closed on the delivery token")

    if pull_request_target:
        if source.count("persist-credentials: false") < 2:
            errors.append(f"{relative}: trusted and candidate checkouts do not disable persisted credentials")
        if "../controller/node_modules/.bin/tsx" not in source:
            errors.append(f"{relative}: candidate workflow does not execute the trusted controller")
        if "trusted-pr-delivery.sh" not in source:
            errors.append(f"{relative}: workflow does not use trusted bundle delivery")
        if "skills@latest" in source:
            errors.append(f"{relative}: workflow installs a provider-specific skill at runtime")

    if relative.name in {"agent-implement.yml", "agent-implement-prd.yml", "agent-promote-queued.yml"}:
        if "GITHUB_TOKEN_FALLBACK" in source:
            errors.append(f"{relative}: delivery mutation falls back to a token that cannot trigger workflows")
        if "AGENT_PAT" not in source:
            errors.append(f"{relative}: delivery mutation does not require AGENT_PAT")
    if relative.name == "agent-implement-prd.yml":
        steps = [step for job in workflow.get("jobs", {}).values() for step in job.get("steps", [])]
        push_step = next((step for step in steps if step.get("name") == "Push branch"), {})
        if "AGENT_PAT" not in push_step.get("env", {}).get("GH_TOKEN", ""):
            errors.append(f"{relative}: PRD branch push does not use AGENT_PAT")
        names = [step.get("name") for step in steps]
        if names.index("Close completed sub-issue") < names.index("Open draft PR if one doesn't exist for this branch"):
            errors.append(f"{relative}: closes a sub-issue before PR delivery succeeds")

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)

print(f"workflow structure passed ({len(WORKFLOWS)} files)")

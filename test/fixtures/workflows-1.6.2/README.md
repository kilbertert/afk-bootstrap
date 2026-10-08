# The two agent-running workflows as 1.6.2 shipped them

Verbatim copies, pinned so the 1.6.3 migration is exercised against real previous
output. It cannot be taken from a ref at test time: CI checks out a detached HEAD
with no local `main`, so `git show main:…` fails there — which is how this
fixture came to exist.

Only these two carry an agent step; the others (`agent-review`,
`agent-update-branch`, `agent-implement-pr`) call a shared controller and never
run an agent against this repository's tree.

Regenerate after a template change that moves the agent step:

    for f in agent-implement.yml agent-implement-prd.yml; do
      git show <ref>:scaffold/.github/workflows/$f > $f
    done

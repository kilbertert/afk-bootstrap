# The two agent-runner workflows as 1.7.4 shipped them

Verbatim copies, pinned so the 1.7.5 migration is exercised against real previous
output.

They are here because the step edits a line that is indented differently in each:
10 spaces in `agent-implement.yml`, 12 in `agent-implement-prd.yml`, where it sits
inside an `if`/`else`. An exact-anchor substitution on the wrong indent fails
loudly rather than missing, so a fixture carrying only one of them would leave the
harder case untested.

Regenerate after a template change that alters either file:

    for f in agent-implement.yml agent-implement-prd.yml; do
      git show <ref>:scaffold/.github/workflows/$f > $f
    done

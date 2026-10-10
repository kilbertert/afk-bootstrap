# The three agent runners as 1.7.3 shipped them

Verbatim copies, pinned so the 1.7.4 migration is exercised against real previous
output.

They live here rather than in `legacy-1.1.x/` because they are not part of that
fixture's shape: these files arrive from `bootstrap-afk.sh`, which copies them out
of `scaffold/.sandcastle/`, and no migration step installs them. A cumulative
fixture built from `legacy-1.1.x/` therefore has none of them, and an assertion
against them passes vacuously.

Note the two spellings of the profile spread across the three files —
`...claudeProfile(process.env.AFK_PROFILE),` in two and `...claudeProfile(),` in
the PRD runner. The 1.7.4 step anchors on both; anchoring on one silently skips
the file that uses the other.

Regenerate after a template change that alters any of them:

    for f in implement/implement.ts implement-prd/implement-prd.ts \
             implement-pr/implement-pr.ts; do
      git show <ref>:scaffold/.sandcastle/$f > .sandcastle/$f
    done

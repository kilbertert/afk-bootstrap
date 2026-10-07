# The five implementation prompts as 1.5.2 shipped them

Verbatim copies of the read-list sentences the previous template emitted, pinned
so the 1.6.0 migration is exercised against real output rather than a
reconstruction of it. Taking them from the project under test would defeat the
purpose: the fixture is what says which shapes the migration has to recognise.

The fifth path — `implement.md` — is `templates/implement.node.md` in this
repository; bootstrap renders it into `.sandcastle/implement.md`. It is stored at
the fixture root because a `.sandcastle/implement.md` here would be the render of
one language, and the migration runs against both.

Regenerate after a template change that alters a read list:

    git show origin/main:templates/implement.node.md > implement.md
    for f in implement-prompt.md implement/prompt.md implement-pr/prompt.md \
             implement-prd/prompt.md; do
      git show "origin/main:scaffold/.sandcastle/$f" > ".sandcastle/$f"
    done

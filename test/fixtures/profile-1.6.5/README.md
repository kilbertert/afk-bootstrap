# `profile.ts` and `afk-policy.yml` as 1.6.5 shipped them

Verbatim copies, pinned so the 1.7.0 migration is exercised against real previous
output rather than a reconstruction of it.

They are here rather than reconstructed by stripping the new feature out of the
current template: a strip is a regex against text the migration is about to
change, so it silently stops producing a 1.6.5 shape the moment the template is
edited — and the test then passes while testing nothing. That is not
hypothetical; the first version of this fixture did exactly that, and the smoke
run caught it by asserting the fixture carries no prepare hook.

Regenerate after a template change that alters either file:

    git show <ref>:scaffold/.sandcastle/profile.ts          > profile.ts
    git show <ref>:scaffold/.github/workflows/afk-policy.yml > afk-policy.yml

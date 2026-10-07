Captured from `origin/main` (`scaffold/.sandcastle/architecture-review/`), the
revision the 1.5.2 step shipped **before** the prose fix.

It is the input a real project carries when it ran that revision: the prompt
already hands publication to the workflow (step 4 no longer mentions
`/to-prd-project`) while still asking the produce pass for an `<output>` block
and pointing it at the exact schema.

Keeping it as a file rather than synthesising the text inside `test/smoke.sh`
means the migration is exercised against a prompt this template actually
emitted. A hand-written approximation is the false green that makes a migration
look verified when it is not.

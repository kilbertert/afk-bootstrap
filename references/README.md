Shapes of `.sandcastle/profile.ts` that per-project templates have produced, kept
here — not under `test/` — because `upgrade-afk.sh` reads them at run time.
`test/` is not part of the shipped tool; a migration that needed it would fail
for anyone who installed the script without the test fixtures.

- `profile-1.1.x.ts` — a template's own output (five profiles, settings-driven).
- `profile-handport.ts` — the same code with a single `claude-stepfun` entry and
  the endpoint baked into the image, as a project that applied the change by hand
  would have left it.

The migration compares a candidate to these with the profile table and image name
normalised away, which is what makes it able to refuse a file carrying project
edits instead of overwriting it.

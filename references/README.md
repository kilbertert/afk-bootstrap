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

- `mcp-config.ts.1.6.0` / `mcp-config.check.ts.1.6.0` — the two MCP modules as
  1.6.0 shipped them, before the config was written atomically and before the
  codebase-memory binary had to be executable. The 1.6.1 step replaces a project's
  copy only when it still matches these byte for byte; both revisions export the
  same names, so a presence test would accept a file the step must not touch.

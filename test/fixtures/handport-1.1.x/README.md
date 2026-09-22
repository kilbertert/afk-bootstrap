Verbatim `profile.ts` + `Dockerfile` as AI-Ops #322 left them: the pristine
1.1.x code with a `claude-stepfun` table entry, the endpoint baked in with a
BuildKit secret, and the error message derived from the profile keys.

This is the second shape the migration recognises. It exists as a fixture so
the recognition is a comparison against real previous output rather than a
list of markers that a project edit could satisfy by accident.

`main.ts` and the workflow come from the same AI-Ops checkout so the fixture is
a complete project the migration can run against end to end.

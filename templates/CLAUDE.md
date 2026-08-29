<!-- afk-bootstrap:planning-gate:start -->
## AFK planning phase gate

For an idea or grilling task, read `docs/afk-workflow.md` before choosing a
phase.

`/grill-with-docs` ends when its frontier is empty: report
`GRILLING_COMPLETE`, summarize the shared understanding, ask the user to
confirm it, and end the turn. Confirmation completes grilling only. Wait for
the user to explicitly invoke `/to-spec`, `/to-tickets`, `/implement`, or
`/implement-spec` before entering another phase.
<!-- afk-bootstrap:planning-gate:end -->

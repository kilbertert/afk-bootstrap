# Native planning and Sandcastle review orchestration

Planning follows the official `/grill-with-docs` -> `/to-spec` -> `/to-tickets`
sequence. Requirements remain in specs, execution order and blockers remain in
native GitHub issues, and the AFK runner executes only eligible leaf issues.
Review is orchestrated by Sandcastle with parallel Standards and Spec passes,
using the configured provider profile so Claude and Codex remain interchangeable.

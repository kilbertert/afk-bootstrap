Feature: Self-contained AFK bootstrap baseline

  Rule: afk-bootstrap owns the complete scaffold payload

    Scenario: Scaffold a Node project without an Auto-Test checkout
      Given a clean temporary Git repository with a GitHub origin
      And afk-bootstrap is available without an Auto-Test repository
      When bootstrap-afk runs for the Node language without building an image
      Then the project contains the AFK runners, workflows, official skill pointers, and Node checks
      And the generated profile supports every documented model profile
      And the project records the afk-bootstrap template version
      And the planner opens a delivery pull request instead of pushing the default branch

    Scenario: Scaffold a Python project without an Auto-Test checkout
      Given a clean temporary Git repository with a GitHub origin
      And afk-bootstrap is available without an Auto-Test repository
      When bootstrap-afk runs for the Python language without building an image
      Then every generated agent prompt uses the Python verification command
      And the generated Dockerfile contains the Python and uv toolchain

  Rule: repository checks detect scaffold drift

    Scenario: Continuous integration validates both language adapters
      Given a change to the bootstrap tool or scaffold payload
      When repository CI runs
      Then the Node and Python smoke tests execute from afk-bootstrap alone
      And a missing or inconsistent scaffold file fails the check
      And bundled workflows reject duplicate keys, incomplete steps, unsafe fork execution, and force-push commands

  Rule: planning and execution remain explicit phases

    Scenario: Generated agent entries preserve the grilling phase boundary
      Given a clean temporary Git repository whose Claude instructions may already exist
      When bootstrap-afk runs without building an image
      Then the generated Claude Code and Codex entries require explicit confirmation after grilling
      And existing Claude instructions remain intact
      And existing Codex override instructions are updated in place when present
      And the generated planner can execute only eligible leaf issues marked ready-for-agent

    Scenario: Official planning skills remain the only interactive planning entry
      Given a project scaffolded from afk-bootstrap
      When the project is inspected after bootstrap
      Then no automatic PRD splitter workflow, script, or project-local planning skill is generated
      And the retained PRD workflow runs only after native sub-issues exist
      And CONTEXT.md is a glossary while docs/agents and docs/adr point to the other fact sources

    Scenario: Review is provider-neutral and preserves two axes
      Given a project pull request with a linked issue and review conversation
      When the review workflow runs with either configured provider profile
      Then Sandcastle runs Standards and Spec review passes in parallel
      And a fixer receives both reports without merging their findings
      And the workflow emits validated review comments and thread replies

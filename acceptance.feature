Feature: Self-contained AFK bootstrap baseline

  Rule: afk-bootstrap owns the complete scaffold payload

    Scenario: Scaffold a Node project without an Auto-Test checkout
      Given a clean temporary Git repository with a GitHub origin
      And afk-bootstrap is available without an Auto-Test repository
      When bootstrap-afk runs for the Node language without building an image
      Then the project contains the AFK runners, workflows, official skill pointers, and Node checks
      And the generated profile supports every documented model profile
      And the generated profile mounts its endpoint instead of baking it into the image
      And the project records the afk-bootstrap template version
      And the planner opens a delivery pull request instead of pushing the default branch

    Scenario: Scaffold a Python project without an Auto-Test checkout
      Given a clean temporary Git repository with a GitHub origin
      And afk-bootstrap is available without an Auto-Test repository
      When bootstrap-afk runs for the Python language without building an image
      Then every generated agent prompt uses the Python verification command
      And the generated Dockerfile contains the Python and uv toolchain

  Rule: an already-scaffolded project can be upgraded to the current template

    Scenario: Upgrade a previous-template project onto the current provider
      Given a project scaffolded by a previous template version
      When upgrade-afk runs against it
      Then the Dockerfile dispatches the current provider profile
      And the retired provider profiles are gone from the generated files
      And the workflows fall back to the current profile
      And the project records the new template version
      And a project-owned document naming a retired profile is reported, not rewritten

    Scenario: Upgrade refuses what it cannot migrate safely
      Given a project with no template provenance, or a Dockerfile whose provider dispatch it does not recognise
      When upgrade-afk runs against it
      Then the command fails without writing
      And a dry run writes nothing

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
      And no provider-specific review skill is installed at runtime

    Scenario: Implementation economy is provider-neutral
      Given a project scaffolded from afk-bootstrap
      When an implementation or review agent chooses how to change code
      Then the shared coding standards require the first adequate economy ladder option
      And the agent traces the affected flow before fixing the root cause
      And compatibility, dependency, module, and architecture choices follow explicit project boundaries
      And implement and Standards review prompts apply the same contract without a container-installed skill

  Rule: pull request automation has a trusted control plane

    Scenario: Persistent runner review uses the current default branch
      Given a persistent runner whose local main branch is stale
      And origin main has advanced
      When the review workflow prepares the candidate checkout
      Then local main matches the trusted controller checkout
      And the reviewed diff is computed against the current default branch

    Scenario: Candidate code cannot receive host delivery credentials
      Given an owner-authored pull request from the same repository
      When a pull request mutation workflow runs
      Then host dependencies and orchestration load from the default branch controller
      And candidate commands run only in the Docker sandbox with the read token
      And a clean delivery checkout imports and pushes the resulting commits

    Scenario: Untrusted pull requests cannot start mutation workflows
      Given a pull request from a fork or an author other than the repository owner
      When an AFK mutation label is added
      Then the pull request mutation job does not run

    Scenario: Missing delivery credentials stop the workflow
      Given AGENT_PAT is missing or cannot perform the requested delivery mutation
      When a workflow must create a pull request or add a workflow-triggering label
      Then the workflow fails and records an agent:blocked state
      And it does not report a successful automated handoff

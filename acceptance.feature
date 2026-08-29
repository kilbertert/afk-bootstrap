Feature: Self-contained AFK bootstrap baseline

  Rule: afk-bootstrap owns the complete scaffold payload

    Scenario: Scaffold a Node project without an Auto-Test checkout
      Given a clean temporary Git repository with a GitHub origin
      And afk-bootstrap is available without an Auto-Test repository
      When bootstrap-afk runs for the Node language without building an image
      Then the project contains the AFK runners, skills, workflows, and Node checks
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
      And the generated planner can execute only issues marked ready-for-agent

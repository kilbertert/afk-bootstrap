import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  claudeCode,
  type AgentProvider,
  type SandboxHooks,
  type SandboxProvider,
} from "@ai-hero/sandcastle";
import { docker } from "@ai-hero/sandcastle/sandboxes/docker";
import { sandboxNetworkOptions } from "./profile-network.js";
import {
  SANDBOX_CBM_BINARY,
  codebaseMemoryAvailable,
  mcpConfigMounts,
  writeMcpConfig,
} from "./mcp-config.js";

/** The prepare script, relative to the repository root. */
const PREPARE_SCRIPT = join(".sandcastle", "sandbox-prepare.sh");

// Endpoints are supplied as host settings files mounted read-only into the
// sandbox, never baked into the image. A baked key lands in an image layer
// that anyone who can pull the image can read, and rotating it means rebuilding
// with --no-cache because a secret mount does not invalidate the layer cache.
// A mount leaves the key on the host, where rotating it is an edit.
const profiles = {
  claude: undefined,
  // Local relay (`cli-proxy-api` on 127.0.0.1:8317), reached with a host-network
  // sandbox. The settings file points ANTHROPIC_BASE_URL at the relay's loopback
  // address, so the container **must** share the host network namespace —
  // a default-bridge container cannot reach the host's 127.0.0.1 (measured).
  "claude-deepseek": process.env.AFK_DEEPSEEK_SETTINGS ?? join(homedir(), "cliproxyapi/settings.deepseek.json"),
} as const;

export function claudeProfile(
  profile = process.env.AFK_PROFILE,
  env?: Record<string, string>,
): { agent: AgentProvider; sandbox: SandboxProvider; hooks: SandboxHooks } {
  // Materialise the MCP config before the sandbox is created — the mount below
  // needs a file to point at, and writing it per run is what keeps it true to
  // what this host actually has.
  writeMcpConfig();
  if (profile && !(profile in profiles)) {
    throw new Error(`Unsupported profile; use ${Object.keys(profiles).join(", ")}.`);
  }
  const settingsPath = profile ? profiles[profile as keyof typeof profiles] : undefined;
  if (settingsPath && !existsSync(settingsPath)) throw new Error(`Profile settings not found: ${settingsPath}`);
  const safeEnv = { ...(env ?? {}) };
  const explicitAgentToken = safeEnv.AFK_AGENT_GH_TOKEN;
  delete safeEnv.GH_TOKEN;
  delete safeEnv.AFK_AGENT_GH_TOKEN;
  const agentToken = process.env.AFK_AGENT_GH_TOKEN ?? explicitAgentToken;

  return {
    // The project's own sandbox preparation, run once per iteration after the
    // container is up and before the agent starts.
    //
    // Why this exists: a run's workspace starts empty — dependencies, build
    // output and virtualenvs are all gitignored, so nothing is installed. An
    // agent asked to verify its own change therefore spends its budget
    // installing, and when a check it runs reports "missing" it cannot tell
    // *this checkout has not been set up* from *this sandbox lacks the
    // prerequisite*, so the sensible-looking remedy is to download one.
    //
    // The fix belongs here rather than in the agent's instructions: what a run
    // needs before it starts is a property of the environment. A project states
    // it once in `.sandcastle/sandbox-prepare.sh` and every run begins ready.
    //
    // The second hook is not the project's: the knowledge-graph server holds no
    // data until the repository is indexed, so its tools answer an empty graph
    // on the first call — and an agent that gets an empty result concludes the
    // tool is useless and goes back to grep.
    //
    // `hooks` is an option of `run()`, NOT of the sandbox provider. It lived
    // inside `docker()` for two releases, where it was silently ignored — a
    // hook that never runs is indistinguishable from one that ran and did
    // nothing, and the first measurement that appeared to confirm it (a ready
    // venv) turned out to be the agent installing dependencies itself.
    hooks: {
      sandbox: {
        onSandboxReady: [
          ...(existsSync(join(process.cwd(), PREPARE_SCRIPT))
            ? [
                {
                  command: "bash .sandcastle/sandbox-prepare.sh",
                  timeoutMs: Number(process.env.AFK_PREPARE_TIMEOUT_MS ?? 15 * 60 * 1000),
                },
              ]
            : []),
          // Indexed only when the server will actually be mounted — the same
          // `codebaseMemoryAvailable()` the mount decision uses, so a host
          // without the binary runs no hook it cannot satisfy.
          ...(codebaseMemoryAvailable()
            ? [
                {
                  // `timeout 120` is load-bearing, not decoration. A sandbox
                  // hook runs through `execOk`, which fails the effect when the
                  // command exits non-zero **or when it outlives `timeoutMs`** —
                  // and a timeout raises `HookTimeoutError`, which kills the
                  // whole run. So `|| true` covers only the first case: a
                  // command that hangs has nothing to fall back to.
                  //
                  // Measured: a run sat exactly `timeoutMs` (5 min) inside
                  // "Setting up sandbox" and then died, on a command that takes
                  // 1.2 s locally in every workspace shape tried (with and
                  // without `.venv`, with and without `.git`). The hang was not
                  // reproducible outside the runner, which is the point — a
                  // borrowed accelerator must not be able to stop the run for a
                  // reason nobody can reproduce.
                  //
                  // So the command's own deadline is strictly smaller than the
                  // hook's. Indexing may fail, may produce nothing, and the
                  // agent falls back to grep; that is a fine outcome. An
                  // accelerator that can kill the run is not.
                  command: `timeout 120 ${SANDBOX_CBM_BINARY} cli index_repository --repo-path . --mode fast || true`,
                  // The outer deadline stays generous because it is now
                  // unreachable in practice: any hang is cut at 120 s by the
                  // command itself, and the hook only fails if the runtime
                  // cannot even start it.
                  timeoutMs: Number(process.env.AFK_INDEX_TIMEOUT_MS ?? 5 * 60 * 1000),
                },
              ]
            : []),
        ],
      },
    },
    agent: claudeCode(process.env.AFK_MODEL ?? "claude-sonnet-4-6"),
    sandbox: docker({
      // Use the same image name that `npx sandcastle docker build-image`
      // produces (defaultImageName = sandcastle:<repo>). A hardcoded custom
      // name here means rebuilds target a different tag and the sandbox keeps
      // running a stale image — the cause of repeated false BLOCKEDs.
      imageName: process.env.AFK_IMAGE ?? "__AFK_IMAGE__",
      env: {
        ...safeEnv,
        // AFK_PROFILE lives in the sandbox env (not the agent env) so that
        // both run() and createSandbox() containers see it — createSandbox
        // does not re-inject agent env into an already-started container, and
        // the Dockerfile claude wrapper dispatches on it.
        ...(profile ? { AFK_PROFILE: profile } : {}),
        ...(agentToken ? { GH_TOKEN: agentToken } : {}),
      },
      // The project's own sandbox preparation, run once per iteration after the
      // container is up and before the agent starts.
      //
      // Why this exists: a run's workspace starts empty — dependencies, build
      // output and virtualenvs are all gitignored, so nothing is installed. An
      // agent asked to verify its own change therefore spends its budget
      // installing, and when a check it runs reports "missing" it cannot tell
      // *this checkout has not been set up* from *this sandbox lacks the
      // prerequisite*, so the sensible-looking remedy is to download one. That
      // was measured: an agent spent its last ten minutes repeatedly fetching a
      // 150 MB Chromium build for a browser the image already had.
      //
      // The fix belongs here rather than in the agent's instructions: what a run
      // needs before it starts is a property of the environment, not something to
      // re-derive by probing. A project states it once in
      // `.sandcastle/sandbox-prepare.sh` and every run after that begins ready.
      //
      // Optional by construction — no file, no hook, no cost. A project with no
      // setup step (a pure Node repo whose one `npm ci` the workflow already
      // does) simply does not have the script.
      // Host networking is required only by profiles whose endpoint is the
      // host-loopback relay: a default-bridge container cannot reach the host's
      // 127.0.0.1. Every other profile talks to a public HTTPS origin and stays
      // on the default bridge. The options come from `profile-network.ts` so
      // `profile-network.check.ts` asserts the exact object this call splats —
      // the helper's return value alone would leave a broken wiring green.
      ...sandboxNetworkOptions(profile),
      // The MCP servers the agent gets. Two, deliberately, and they are the
      // read-only code-intelligence pair: `serena` (LSP symbols, baked into the
      // image) and `codebase-memory-mcp` (the repository graph, mounted from the
      // host — a 258 MB static binary, so mounting beats growing every project's
      // image, and an upgrade takes effect without a rebuild).
      //
      // NOT bundled, on purpose:
      //   * team-memory — it holds other projects' memory. An agent working an
      //     issue in this repository must not be able to read it.
      //   * google-scholar — needs a Serper API key, and nothing in an
      //     implementation task needs to search the open web.
      // If you add a server here, ask what it can reach that the agent cannot.
      //
      // A server whose command is missing is dropped from the file rather than
      // declared with a path that may not exist: claude silently skips a server
      // it cannot start (verified — the session still exits 0), so a dead path
      // would degrade the agent's tools with no signal anywhere. mcp-config.ts
      // owns that decision; mcp-config.check.ts asserts it.
      // The mounts are unconditional. The MCP pair is independent of the
      // endpoint: the graph is mounted from the host and serena is in the image,
      // both regardless of how the agent authenticates. Gating them on
      // `settingsPath` (as this started out) made the setting a proxy for
      // "is this a non-default profile" — and the `claude` profile is the one
      // that resolves no settings file, so the default profile was exactly the
      // one that got no mounts, no config file, and therefore no servers. The
      // wrapper's `claude` arm also passes no --mcp-config, so nothing else
      // supplied them: not a wrong path, just absent.
      mounts: [
        // Present only when the profile resolves an endpoint, because without
        // one there is no file to mount — the wrapper's `claude` arm uses the
        // Anthropic default and reads no settings.
        ...(settingsPath
          ? [{ hostPath: settingsPath, sandboxPath: "/home/agent/.afk-profile-settings.json", readonly: true }]
          : []),
        ...mcpConfigMounts(),
      ],
    }),
  };
}

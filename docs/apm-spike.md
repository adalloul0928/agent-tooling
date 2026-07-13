# Microsoft APM spike

Date: 2026-07-13  
APM version: `0.25.0`  
Decision: **partial adopt; native manifests remain authoritative**

## Question

Can [`microsoft/apm`](https://github.com/microsoft/apm) replace the hand-authored
Claude and Codex adapters in this repository without losing behavior or release
policy?

## Fixture

The isolated fixture used:

- the complete `obsidian-vault` skill package;
- Claude and Codex targets;
- one direct, secret-free HTTP MCP declaration;
- a `PreToolUse` command hook;
- temporary producer, consumer, and output directories under `/tmp`;
- APM installed into a temporary Python virtual environment.

No APM output was installed into a live Claude or Codex home.

## Results

### What worked

- Installed one skill into `.claude/skills/` and `.agents/skills/` with identical
  content.
- Rendered the MCP declaration into `.mcp.json` and `.codex/config.toml`.
- Produced an integrity lockfile with per-file hashes and ownership metadata.
- `apm audit --ci` replayed the install and reported a clean result.
- A deliberate edit to the installed Claude skill failed the audit with both
  content-integrity and drift findings; reinstall restored the package.
- Rendered a shared hook into Claude and Codex native hook files after the hook
  command used the correct package-relative `.apm/hooks/` path.
- Generated both Claude and Codex marketplace catalogs from one declaration.

### What was not lossless

- The generated Claude plugin manifest and Claude catalog contain `version`,
  conflicting with this repository's Git-revision release policy.
- APM does not generate the native Codex `.codex-plugin/plugin.json` manifest.
- Codex-only `agents/openai.yaml` metadata was copied into Claude's skill tree.
- Hook output still requires target-aware review; a superficially portable
  `${PLUGIN_ROOT}/hooks/...` command failed to deploy its script until rewritten
  to the actual `.apm/hooks/...` source path.
- MCP installation is a machine/project configuration operation, not a plugin
  dependency declaration or hosted-account synchronization mechanism.
- Claude project MCP output was skipped when the redirected target lacked an
  existing `.claude/` directory, even with the Claude target selected. The
  isolated test had to pre-create the target directory.

## Decision

Do not make `apm.yml` the compiler for the first `agent-tooling` release.

Keep these files hand-authored and validated natively:

- `.claude-plugin/marketplace.json`;
- `.agents/plugins/marketplace.json`;
- `.claude-plugin/plugin.json`;
- `.codex-plugin/plugin.json`;
- platform-specific hooks, agents, MCP configuration, and release policy.

APM remains a candidate for a later, optional layer where its strengths are
independent of adapter generation:

- consumer-side lockfiles;
- explicit multi-client installation;
- hidden-Unicode scanning;
- integrity and drift auditing;
- dependency provenance and SBOM export.

Adopting those features later requires a separate PR and must not make APM a
prerequisite for installing the native Claude or Codex marketplaces.

## Revisit when

- Codex plugin manifest generation is supported;
- generated Claude output can omit versions;
- target-scoped metadata and hook transformations are lossless for our package;
- the native catalog workflow creates enough real maintenance cost to justify
  another required tool.

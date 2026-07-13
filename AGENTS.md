# Agent Tooling Repository

`AGENTS.md` is the canonical instruction layer for this repository. Keep
`CLAUDE.md` as a lightweight import rather than duplicating these rules.

## Purpose

This private repository packages reusable personal tooling for Claude Code and
Codex. Shared behavior belongs in portable Agent Skills. Platform-specific
behavior belongs in native adapter manifests.

## Authoring rules

- Put each distributable bundle under `plugins/<plugin-name>/`.
- Keep exactly one physical copy of a shared skill at
  `plugins/<plugin-name>/skills/<skill-name>/SKILL.md`.
- Use standard `name` and `description` skill frontmatter. Put platform-only
  metadata in the corresponding adapter rather than the shared instructions.
- Write instructions in capability terms. Do not assume a specific model,
  connector, MCP server, or tool name when a portable capability description is
  sufficient.
- Resolve scripts, references, and assets relative to the active skill
  directory. Never hard-code `~/.claude`, `~/.codex`, or marketplace cache paths.
- Keep plugin directories self-contained. Do not reference files outside a
  plugin package.
- Never commit secrets, tokens, OAuth state, certificates, machine-local
  settings, generated caches, or user-specific absolute paths.

## Adapter rules

- Claude catalog: `.claude-plugin/marketplace.json`.
- Codex catalog: `.agents/plugins/marketplace.json`.
- Claude plugin metadata: `plugins/<name>/.claude-plugin/plugin.json`.
- Codex plugin metadata: `plugins/<name>/.codex-plugin/plugin.json`.
- Omit Claude plugin versions while Git-revision updates are the chosen policy.
- Omit Codex plugin versions while Git-revision updates are the chosen policy.
  Introduce semver only if a future client or dependency contract requires it.
- Keep agents, hooks, MCP declarations, and client configuration platform-native
  unless both clients have been explicitly validated against the same contract.

## Change discipline

- Add one pilot or migration batch at a time.
- Preserve old standalone installations until both clients pass explicit and
  implicit invocation tests.
- Run Claude manifest validation and isolated Claude/Codex marketplace
  add/install smoke tests before treating a package as releasable. Normal Claude
  validation is the blocking gate; do not automate `--strict` while intentional
  Git-SHA versioning produces a warning.
- Review the Git diff and scan for secrets before committing.
- Do not commit or push unless the user explicitly asks.

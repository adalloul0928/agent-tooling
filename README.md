# Agent Tooling

Private, cross-client tooling for Claude Code and Codex.

This repository is the source of truth for portable Agent Skills and the thin,
platform-native manifests that package them. It does not contain machine-local
settings, OAuth state, secrets, or project-critical instructions that belong in
an application repository.

## Status

The repository is in bootstrap mode. The first pilot packages the shared
`obsidian-vault` skill as the `obsidian` plugin for both clients. Existing
standalone installations remain the rollback path until the pilot passes.

## Repository contract

```text
agent-tooling/
  .claude-plugin/marketplace.json
  .agents/plugins/marketplace.json
  plugins/
    <plugin>/
      .claude-plugin/plugin.json
      .codex-plugin/plugin.json
      skills/<skill>/SKILL.md
```

- Keep one physical skill core under its plugin directory.
- Keep Claude and Codex manifests as separate adapters.
- Share scripts, references, assets, and tool-neutral workflow guidance.
- Keep MCP authentication, client settings, and hosted-environment configuration
  outside this repository.
- Keep application-critical skills committed in the application repository.

## Version policy

- Claude plugin releases follow the marketplace Git revision; omit plugin
  `version` fields unless a future compatibility requirement changes the policy.
- Codex plugin manifests use semantic versions and must be bumped when their
  packaged contents change.

## Rollout

1. Validate the repository contract and the `obsidian-vault` pilot.
2. Test local path installation in isolated client homes.
3. Test private GitHub marketplace installation and refresh behavior.
4. Run explicit invocation, implicit invocation, non-trigger, read, write, and
   Git-review canaries.
5. Migrate additional skills in small, independently reversible batches.

## Validation

Run the cross-client validation and isolated Claude/Codex install smoke tests:

```bash
./scripts/validate
```

Claude's validator reports the intentionally omitted Claude plugin version as a
warning. The warning is expected while Git revisions are the release mechanism.

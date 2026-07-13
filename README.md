# Agent Tooling

Private, cross-client tooling for Claude Code and Codex.

This repository is the source of truth for portable Agent Skills and the thin,
platform-native manifests that package them. It does not contain machine-local
settings, OAuth state, secrets, or project-critical instructions that belong in
an application repository.

## Status

The dual catalogs now publish four native plugins from one shared skill core:

- `obsidian`: vault workflows;
- `pumpd-workflows`: PUMPD research, planning, review, delivery, and Git workflows;
- `agent-ops`: tooling management, research, learning, usage review, and Cyrus setup;
- `personal-productivity`: IAWIS reporting and personal task workflows.

Existing standalone installations remain the rollback path until Git-backed
install, update, and normal-use canaries pass.

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
- Codex plugin releases also follow the marketplace Git revision; omit plugin
  `version` fields unless a future compatibility requirement changes the policy.

Microsoft APM was tested as a possible compiler. The result was a partial adopt:
native manifests remain authoritative, while APM's lockfile and audit features
remain candidates for a later optional layer. See [docs/apm-spike.md](docs/apm-spike.md).

## Rollout

1. Validate the repository contract and each plugin package.
2. Test local path installation in isolated client homes.
3. Test private GitHub marketplace installation and refresh behavior.
4. Run explicit invocation, implicit invocation, non-trigger, read, write, and
   Git-review canaries.
5. Remove the matching standalone copies only after the relevant canaries pass.

## Validation

Run the cross-client validation and isolated Claude/Codex install smoke tests:

```bash
./scripts/validate
```

Claude's validator reports the intentionally omitted Claude plugin version as a
warning. The warning is expected while Git revisions are the release mechanism.

## Desired-state profiles

Composable profiles record what a workstation or project should contain without
storing secrets or pretending hosted account state is synchronized. The
read-only doctor compares those profiles with native local configuration:

```bash
./scripts/doctor
./scripts/doctor pumpd-project --json
```

See [docs/profiles-and-doctor.md](docs/profiles-and-doctor.md) for the profile
model, status meanings, and safety boundary.

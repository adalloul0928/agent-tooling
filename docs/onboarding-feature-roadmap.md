# Onboarding and configuration roadmap

Reviewed against the current repository and vendor documentation on 2026-09-07.
This document proposes follow-up features; it does not claim they are implemented.

Agent Tooling should help people understand what they already have, choose what
they want to maintain here, and review changes to each client. A discovered item,
a managed source, an installation, and an authenticated account are separate
states. Making those distinctions clear is more valuable than importing every
file into another directory.

## Existing foundations

| Capability | Verified implementation | Boundary to explain in onboarding |
| --- | --- | --- |
| Client and inventory discovery | [TargetAdapters.swift](../apps/agent-tooling-macos/Sources/AgentToolingCore/TargetAdapters.swift), [InventoryCompiler.swift](../apps/agent-tooling-macos/Sources/AgentToolingCore/InventoryCompiler.swift) | The active adapters scan Claude Code, Codex CLI configuration, and Gemini CLI. Desktop/cloud target names exist in the model, but do not imply independent scan coverage. |
| Skill creation, copying, and adoption | [AppModel+Skills.swift](../apps/agent-tooling-macos/Sources/AgentToolingCore/AppModel+Skills.swift), [WorkspaceLibrary.swift](../apps/agent-tooling-macos/Sources/AgentToolingCore/WorkspaceLibrary.swift) | Adoption makes a separately maintained library copy. It does not migrate a plugin's hooks, agents, or MCP dependencies, and does not merge future upstream updates. |
| Native plugin and standalone-skill installation | [AppModel+SkillAvailability.swift](../apps/agent-tooling-macos/Sources/AgentToolingCore/AppModel+SkillAvailability.swift) | Plugin skills use a verified whole-plugin installer. Copying a standalone skill is not continuous source synchronization. |
| A small set of native preference edits | [SkillAvailability.swift](../apps/agent-tooling-macos/Sources/AgentToolingCore/SkillAvailability.swift), [AppModel+SkillAvailability.swift](../apps/agent-tooling-macos/Sources/AgentToolingCore/AppModel+SkillAvailability.swift) | Skill/plugin availability has preserved-file edits and backups. There is no general client-settings editor yet. |
| Project configuration inventory | [ProjectDiscovery.swift](../apps/agent-tooling-macos/Sources/AgentToolingCore/ProjectDiscovery.swift) | Finds instruction files, supported settings, skill roots, and MCP declarations. It does not resolve every effective setting or enumerate standalone agents/hooks. |
| Package component recognition | [ControlPlaneModels.swift](../apps/agent-tooling-macos/Sources/AgentToolingCore/ControlPlaneModels.swift), [Marketplace.swift](../apps/agent-tooling-macos/Sources/AgentToolingCore/Marketplace.swift) | Agent/hook/command kinds exist and package inspection recognizes relevant directories. Dedicated inventories and editors still need implementation. |
| Backup, encrypted exchange, and change review | [AppModel+BackupSync.swift](../apps/agent-tooling-macos/Sources/AgentToolingCore/AppModel+BackupSync.swift), [EncryptedSyncService.swift](../apps/agent-tooling-macos/Sources/AgentToolingCore/EncryptedSyncService.swift), [Reconciliation.swift](../apps/agent-tooling-macos/Sources/AgentToolingCore/Reconciliation.swift) | Portable desired state and managed packages can be exported/reviewed. This is not an always-on hosted sync service, and it does not transfer client credentials. |

## What the wizard should establish

1. **Choose the apps you use.** Show detection results and missing clients; allow
   proceeding with the library alone. State which local configuration was scanned.
2. **Review what was found.** Separate skills, plugin bundles, direct MCP servers,
   and locally discovered account connector declarations. Surface unreadable or
   unsupported sources as incomplete coverage rather than zero items.
3. **Choose how to maintain it.** Keep vendor/third-party plugins linked to their
   native source and update route. Offer copying suitable personal standalone
   skills into the library. Explain that customizing a plugin skill creates an
   independent copy with its own maintenance obligations.
4. **Choose destinations and review.** Show existing versus requested client
   installations, changed files, name collisions, unsupported components, and
   any remaining native authentication steps before applying an operation.
5. **Finish with a useful checklist.** Offer project discovery, backup/recovery,
   and a fresh-session check. Make personal-work analysis an explicit optional
   step rather than a prerequisite for setup. Let users revisit onboarding.

The success state should report what actually happened: inventoried items,
saved configuration, copied skills, applied installs, and work still pending.
Avoid one blanket “everything is synced” status.

## Recommended follow-up order

| Priority | Feature | Why it belongs |
| --- | --- | --- |
| 1 | **Configuration inspector, then editor** | Show the saved value, scope, defining file, and known override for model, reasoning, permissions, sandbox, MCP, skills, and plugin availability. Start with a small schema-validated set; include an advanced source view and restore action. |
| 1 | **Complete desktop and CLI coverage** | Discover the desktop-only Claude MCP file and explain which surfaces consume each definition. Detect duplicate names and differing definitions before offering a native import. |
| 2 | **Hooks inventory and editor** | A searchable list with client, event, matcher, owner, source, command/type, and native trust state makes hidden automation understandable. Editing a user hook should show the exact change. Plugin-owned hooks should link to the plugin rather than edit its cache. |
| 2 | **Agents inventory and editor** | Show purpose, instructions, client-specific model settings, tool restrictions, skills, MCP requirements, and source. Preserve native agent formats and validate capabilities for the installed client version. |
| 2 | **Instructions and rules** | Surface AGENTS.md, CLAUDE.md, scoped rules, and project/user precedence alongside settings. Detect conflicting or duplicated instructions; preserve user-authored text rather than silently generate replacements. |
| 3 | **Source tracking and repair** | Preserve upstream repository, package ID, revision, and update route; show missing sources, duplicates, diverged local copies, and unsupported destinations. Offer reviewable repairs instead of blanket reinstall. |
| 3 | **Portable setup profiles and export** | Make project/role presets useful across Macs, with machine-specific paths and credentials kept separate. Export compatible skills with a compatibility summary; do not imply hooks, local commands, and MCP authentication travel with a cloud skill upload. |

Keep these in existing navigation: **Library** can gain Agents and Hooks;
**Apps** can own client configuration and coverage; **Projects** can explain
project overrides. Avoid another top-level screen for every file format.

## Current vendor contracts that affect the design

**Codex local app and CLI.** The desktop app's local agents share agent
configuration with the CLI and IDE extension, including MCP configuration in
`config.toml`. Ordinary app preferences are a separate surface. Hosted ChatGPT
Work does not read the Mac's local configuration. A settings screen therefore
needs an explicit local/client/scope context, not independent copies of a
“Codex Desktop config” and “Codex CLI config.”
[OpenAI developer settings](https://learn.chatgpt.com/docs/developer-settings),
[configuration layers](https://learn.chatgpt.com/docs/config-file/config-basic).

**Claude desktop and CLI.** Local Code-tab sessions share Claude Code settings,
skills, hooks, and project instructions. Current Desktop also reads MCP servers
from `claude_desktop_config.json`; the standalone CLI does not. The desktop
definition wins for a duplicate server name in local Code sessions. Our current
adapter omits that file, so desktop-only servers are a real discovery gap.
Anthropic documents `claude mcp add-from-claude-desktop` as a native import route.
Chat, Code, Cowork, SSH, and cloud availability should be represented separately
where they differ.
[Anthropic desktop configuration](https://code.claude.com/docs/en/desktop#shared-configuration).

**Hooks are supported by both vendors, with different runtime contracts.** Codex
loads adjacent `hooks.json`, inline TOML hooks, and plugin hooks; matching sources
are additive. Changed non-managed definitions require native trust review.
Claude supports settings, plugin, and component-scoped hooks. Its current hook
browser is read-only, and individual settings hooks cannot simply be disabled
in place; global disable also respects managed policy. A cross-client editor
must preserve those differences instead of inventing one universal toggle or
copying trust decisions between clients.
[OpenAI hooks](https://learn.chatgpt.com/docs/hooks),
[Anthropic hooks](https://code.claude.com/docs/en/hooks).

**Custom agents are no longer a Claude-only concept.** Codex documents personal
and project TOML agent files with name, description, and developer instructions.
Claude defines subagents in Markdown with native frontmatter, and plugin agents
have different supported controls from user/project agents. A shared UI can
present common concepts, while the saved format and capability checks remain
native. Older repository rollout notes saying agents are Claude-only should not
drive new architecture.
[OpenAI subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents),
[Anthropic subagents](https://code.claude.com/docs/en/sub-agents).

**Config changes need provenance.** Both products layer configuration and
administrative policy. A file edit alone does not establish the value active in
an existing session. Preserve unrelated fields, detect concurrent edits, keep
backups, explain when a new session is needed, and mark organization-owned values
as managed. Do not infer account authentication from a local manifest.
[OpenAI configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference),
[Anthropic settings](https://code.claude.com/docs/en/settings).

These recommendations are based on repository inspection and public vendor
contracts. They are not proof that every documented feature is available in the
client versions or accounts installed on a particular Mac.

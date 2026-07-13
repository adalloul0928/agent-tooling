---
name: add-tool
description: Decide how and where to add a skill, plugin, MCP server, connector, hook, or agent across Claude and Codex. Use when adding tooling, choosing scope, or deciding which product surface should receive a capability.
---

# Add Tool

Choose the smallest supported mechanism and scope that provides the requested capability.

## Decision order

1. Identify the required surfaces: Claude chat, Claude Code local, Claude Code cloud, Codex local, Codex cloud, or a specific project.
2. Classify the capability:
   - skill: reusable instructions or a workflow;
   - plugin: a distributable bundle of skills, MCP definitions, hooks, agents, or presentation metadata;
   - MCP server: external tools or data accessed at runtime;
   - hosted connector: account-managed SaaS access, usually with OAuth;
   - hook: deterministic behavior around agent lifecycle events;
   - agent: isolated delegated work with its own instructions and tools.
3. Choose ownership: vendor-owned, personal cross-project, project-critical, machine-private, or hosted-only.
4. Choose the source of truth:
   - vendor-owned components stay in the vendor marketplace;
   - personal cross-project components live in `agent-tooling`;
   - project-critical components live in the application repository;
   - licensed or secret-bearing components remain machine-local;
   - hosted OAuth state remains in the account store.
5. Check for an existing provider before adding another definition.
6. Describe authentication, cloud availability, update behavior, rollback, and any manual account step.

## Output

Return the recommended mechanism, owner, scope, source-of-truth location, installation path for each client, and any duplication that should be removed. Do not install or authenticate until the user asks for implementation.

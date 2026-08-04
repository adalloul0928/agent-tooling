---
name: sync-agent-tooling
description: >-
  Refresh the shared agent-tooling marketplace and installed Developer Workflows
  plugin for both Codex and Claude Code. Use when the user asks to sync agent
  tools, pull the latest shared skills, refresh developer workflows, or make a
  newly merged agent-tooling skill available locally. Do not use for creating
  new skills or updating a project-specific skill.
---

# Sync Agent Tooling

Bring the installed `agent-tooling` marketplace up to date in both local coding
clients, then make the activation boundary explicit.

## Run the sync

Run [`scripts/sync-agent-tooling.sh`](scripts/sync-agent-tooling.sh) from any
directory. It refreshes the Codex marketplace, refreshes Claude Code's
marketplace, updates the installed Developer Workflows plugin, and reports any
client CLI that is unavailable.

Treat a failed client refresh as a partial result. Report which client updated,
which did not, and the actionable error. Do not claim that a skill is available
until that client's refresh completed.

## Activate the updated content

The refresh only updates local files.

- In Claude Code, run `/reload-plugins` in the active session.
- In Codex, start a fresh task. Existing tasks retain their already-discovered
  skill set.

## Verify

Confirm the target skill appears in the Developer Workflows plugin's skill
inventory. Invoke plugin skills using the `developer-workflows:<skill-name>`
namespace in Claude Code.

## Automatic updates

This is an on-demand synchronization skill. It cannot receive a GitHub merge
event by itself. Use a separately scheduled local job when a machine must
refresh without an interactive request.

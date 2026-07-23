---
name: usage-recommender
description: Analyze available agent usage evidence and recommend skills, plugins, MCP servers, hooks, or agents that would remove recurring friction. Use when reviewing agent usage, insights, transcripts, failures, or automation opportunities.
---

# Usage Recommender

Recommend tooling from observed behavior rather than a generic catalog.

## Evidence

Use only sources the active client can safely access, such as user-provided insight reports, recent task summaries, approved session history, recurring tool-failure logs, or the durable learnings note. Do not read secrets, authentication stores, or unrelated private transcripts.

## Workflow

1. Identify repeated tasks, repeated corrections, failed tool calls, manual handoffs, and long instruction sequences.
2. Group observations by capability rather than client-specific tool names.
3. For each material pattern, decide whether the best response is an instruction update, skill, plugin, MCP server, connector, hook, agent, or no new tooling.
4. Check existing project, personal, vendor, and hosted tooling before recommending a duplicate.
5. Rank recommendations by frequency, time saved, safety, maintenance cost, and cross-client portability.
6. Separate evidence-backed recommendations from experiments.

## Output

For each recommendation include the evidence, proposed capability, mechanism, owner, intended surfaces, implementation size, risks, and a measurable canary. Ask for approval before scaffolding or changing configuration.

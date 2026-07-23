# PUMPD Idea Intake

Use this reference when the user sends a PUMPD idea and wants it organized into Obsidian.

## Intake Goal

Turn raw user ideas into retrievable PUMPD knowledge. Preserve the original wording, but add enough structure that the idea can become a plan, ticket, decision, research task, or implementation note later.

## First Pass Classification

Classify the idea into one primary bucket:

- `product-ux`: UI, interaction, navigation, copy, onboarding, stats, cards, charts, workouts, gym setup.
- `stats-analytics`: Stats tab, Strength Progress, PRs, chart behavior, dashboard metrics, terminology.
- `ai-coach`: AI Coach cards, chat, summaries, prompts, coach behavior.
- `workout-flow`: Active session, completed workout, exercise sheets, sets, rest timer, session review.
- `data-backend`: Supabase, Edge Functions, schema, query hooks, generated types, sync.
- `deployment-ops`: preview/prod, EAS, TestFlight, CI/CD, Supabase branching, app store.
- `ai-tooling`: Codex, Claude, Linear, MCP, automations, skills, agent workflows.
- `beta-launch`: launch blockers, QA, release readiness, prioritization.
- `research`: needs investigation before it can be planned.

Secondary tags are fine, but choose one primary destination.

## Search Before Writing

Search active notes first:

```bash
rg --glob '*.md' --glob '!PUMPD/Research/archive/**' --glob '!**/.obsidian/**' --glob '!**/.smart-env/**' 'keyword|phrase' "$VAULT/PUMPD"
```

Use archive notes only for historical context. Do not move or rewrite existing `PUMPD/Research/archive/` docs during intake.

## Destination Rules

- New fuzzy idea or beta-launch priority -> Linear; use `00 Inbox/` only for explicit capture when Linear is unavailable
- Tooling/workflow investigation -> `PUMPD/AI Tooling/` when PUMPD-specific, otherwise the `agent-tooling` repository
- Deployment/release/env documentation -> the relevant PUMPD repository docs
- Research question -> `PUMPD/Research/<Topic>.md`
- Approved direction -> promote the same note to `PUMPD/Plans/<Topic>.md`
- Direct update to an active research or plan note -> append to that note

If there is no active note to append to, prefer Linear for backlog capture or start a research note when investigation is beginning. Do not overload archive docs.

## Idea Note Shape

Use `type: idea` and `status: captured` for new idea notes.

Required sections:

```markdown
## Raw Idea

> Paste or lightly quote the user's idea.

## Interpretation

What this likely means in product/workflow terms.

## Why It Matters

The user value, operator value, launch impact, or risk reduction.

## Affected Surfaces

- Mobile screens/components/routes
- Backend/data contracts
- Tooling/workflows
- Docs/Linear/tickets

## Next Action

One concrete next step: research, design prompt, Linear ticket, repo inspection, prototype, or decision.

## Open Questions

- Only real blockers, not generic prompts.
```

## Append Shape For Existing Notes

When appending to an active PUMPD note, add:

```markdown
## Idea Capture - YYYY-MM-DD

**Raw idea:** ...

**Interpretation:** ...

**Next action:** ...
```

Keep append sections short. Do not turn every idea into a long spec unless the user asks.

## Promotion Rules

- When an idea becomes actionable, create or update its Linear issue.
- When research produces an approved direction, move the same topic note from `PUMPD/Research/` to `PUMPD/Plans/`.
- When work ships, archive the plan and update current repository documentation.
- Do not delete captured ideas; archive them instead.

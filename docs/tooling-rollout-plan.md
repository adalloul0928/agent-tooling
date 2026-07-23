# Tooling rollout plan — 2026-07

The actionable roadmap from the July 2026 tooling discovery. Full rationale,
evidence, and the complete decision record live in
[tooling-discovery-2026-07.md](tooling-discovery-2026-07.md); this doc tracks
execution. Update the status columns as items land.

Decisions recorded 2026-07-22: **31 approved · 9 deferred · 3 denied.**
Scope: `agent-tooling`, client configs, and vendor catalogs only
(`pumpd-dev-tools` is explicitly out of scope by owner decision).

## How work is organized

Every approved item is exactly one of three lanes:

- **Lane A — connectors** (Claude/Codex client config). The owner mints tokens
  and clicks OAuth; the agent writes config. Anything stdio + tokened lives as
  a Doppler-routed block in a plugin `.mcp.json` (the `heroui-native-pro`
  pattern) so installing the plugin installs the MCP.
- **Lane B — vendor installs** (`npx skills add` / plugin catalogs). Installed
  per client, recorded as profile checks with `install` recipes, never mirrored
  into this repo.
- **Lane C — builds** (skills/agents authored here). One physical `SKILL.md`
  per skill + platform adapters, per `AGENTS.md`.

Repeatability contract: every landed item adds a check (+ `install` recipe
where automatable) to `profiles/`, so `./scripts/setup <profile> --apply`
reproduces the machine. Doctor verifies; setup applies; OAuth grants and token
mints stay in `manual_checks`.

Per-batch gate (from AGENTS.md): `scripts/validate` (static + both-client
validation), isolated Claude/Codex marketplace add/install smoke tests,
explicit + implicit invocation checks, diff review + secret scan. One batch =
one PR.

## Batch 1 — P0 unblock

| Item | Lane | Status | Notes |
|---|---|---|---|
| `env-topology` skill | C | **done** | `plugins/developer-workflows/skills/env-topology/`; validate-static green; Codex-side smoke test pending (codex CLI not on the authoring shell's PATH) |
| `scripts/setup` apply mode + `install` recipe convention | C | **done** | Documented in [profiles-and-doctor.md](profiles-and-doctor.md); dry-run default |
| Sentry → hosted OAuth remote (`mcp.sentry.dev`) | A | **done** | **Decision revised 2026-07-23:** owner chose Sentry's hosted remote MCP over the stdio-token approach. Added via `claude mcp add --scope user --transport http` (project-scoped `avad-technologies-llc/pumpd`), tracked as `claude.sentry-mcp` / `codex.sentry-mcp` in `base-workstation`. `--scope user` is required — the default local scope hides the server outside the directory it was added from. Local OAuth, reused by local scheduled runs; no detached-cloud/headless path. Owner completes the browser OAuth per client |
| Expo MCP (Claude; Codex deferred) | A | **done** (Claude) | Claude side landed as `claude.expo-mcp` in `base-workstation`, recipe `claude mcp add --scope user --transport http expo https://mcp.expo.dev/mcp`. **Codex deferred 2026-07-23** to a dedicated pass: `pumpd-workstation` asserts `codex.duplicate-expo-mcp` absent (Codex gets expo from `openai-curated`), so a `present` check would contradict it — that pass settles curated-vs-raw for expo and sentry together. OAuth-only, no PAT/CI fallback — never relied on in CI/cron |
| `expo/skills` subset | B | **done** (Claude) | 9 of 23 installed via `skills` CLI (MIT, not mirrored), tracked as `path` checks with per-skill recipes in `base-workstation`: expo-router, expo-module, expo-tailwind-setup, expo-upgrade, eas-app-stores, eas-workflows, expo-examples, **expo-project-structure**, **expo-dev-client**. Dropped 2026-07-23: `eas-simulator` (its own guidance says don't auto-trigger on macOS with local sims; `ios-simulator-mcp` covers it) and `eas-observe` (paid APM overlapping Sentry). Claude-only; Codex deferred. `-g` required — `skills add` defaults to project scope |

## Batch 2 — workflow core

| Item | Lane | Status | Notes |
|---|---|---|---|
| `doppler-cli-skill` | C | pending | Names-only env-mesh queries via Doppler CLI; feeds env-topology; works where the MCP isn't loaded (CI/headless/Codex) |
| `worktree-bootstrap` | C | pending | Detect per-dir manager (mobile npm, backend pnpm, edge deno) → install → materialize env (mobile `eas env:pull`; others `doppler run`) → patch-package. No blind `.env` copy |
| `create-pr` | C | pending | Full gate (lint + typecheck + entire suite, real counts, no tail/head) → commit → push → PR to `preview`; Linear link |
| Review agent | C | pending | Claude-native agent composing thermo-nuclear + security-review + correctness in parallel; one synthesized verdict |
| `mcp-preflight` | C | pending | List connected-but-unauthenticated MCPs at session start + exact reconnect command each |
| Permission allowlist | config | pending | Via `fewer-permission-prompts`: git, gh, npm, pnpm, deno, cp, sips, `xcrun simctl list/boot` |

## Batch 3 — vendor adopts + Maestro

| Item | Lane | Status | Notes |
|---|---|---|---|
| `software-mansion-labs/skills` | B | pending | Confirm LICENSE first; Claude-only upstream → add `.agents` Codex adapter; covers Reanimated 4 / gestures / worklets bundle-mode (Uniwind conflict) |
| `callstackincubator/agent-skills` | B | pending | Perf/profiling/bundling + react-native-testing + react-compiler reference |
| Supabase agent skills | B | pending | `npx skills add supabase/agent-skills` |
| Shopify AI Toolkit storefront skills | B | pending | Read skills only (`shopify-storefront-graphql`, `shopify-custom-data`, `shopify-dev`); `OPT_OUT_INSTRUMENTATION=true`; exclude store-write CLI skill |
| `webapp-testing` (anthropics/skills) | B | pending | Playwright visual-QA loop |
| `frontend-design` (anthropics/skills) | B | pending | UI aesthetic direction |
| Maestro MCP | A | pending | stdio, ships in Maestro CLI; plugin-scoped `.mcp.json` |

## Batch 4 — P2 builds

| Item | Lane | Status | Notes |
|---|---|---|---|
| `sim-coldstart` | C | pending | Client-aware (Claude `ios-simulator-mcp` / Codex `build-ios-apps`); iOS 26.5 runtime (27 crashes on UIScene); parallel sims + Metro ports — **owner supplies port-scheme docs at build time** |
| `linear-manage` | C | pending | Create/update/comment/triage/link-to-PR on the Linear MCP; consolidate with `personal-task` / `sim-qa` |

## Personal track (parallel to dev batches)

| Item | Status | Notes |
|---|---|---|
| `ticktick-capture` | pending | NL quick-add → right project/tag/date/priority |
| `email-triage` | pending | Draft-only — never sends; sensitive labels for private mail |
| `weekly-review` | pending | TickTick + Linear + Obsidian + Raindrop → vault review note |
| `daily-plan` | pending | Composes with built-in `morning`; TickTick due dates as schedule source |
| `raindrop-tidy` | pending | Connector-native find-misplaced/find-mistagged |
| `read-later-digest` | pending | Raindrop → summarize → note/task |
| `imessage-catchup` | pending | Send only on explicit per-message confirm; never paste contents |
| `habit-review` | pending | TickTick habits/check-ins/streaks |
| `personal-journal` | pending | Dad-update Q&A pattern → Obsidian `Personal/` |

## Connector posture (approved)

- Keep the Doppler MCP; harden to a read-only scoped token (`--project/--config`).
- Keep idle personal connectors mounted (TickTick, Gmail, Raindrop, Canva,
  Drive) — activation targets, not dead weight.
- Verify Linear stays connected (`personal-task`/`sim-qa` depend on it).

## Deferred (investigate later)

`sentry-triage` skill · `heroui-charts` note · `mcp-builder` · delete stray
mobile `pnpm-lock.yaml` · `metro-mcp` · Radon AI MCP (paid gate) · `capture`
universal inbox · Google Calendar connector · Next.js cursor-rule mining.

## Denied

RN/Expo cursor rules · `GeLi2001/shopify-mcp` · Biome/knip/HealthKit/voltra
MCPs.

## Open questions (owner)

1. `EXPO_PUBLIC_SECURE_STORAGE_KEY` — local `.env` only; how do release builds
   get it?
2. Doppler `pumpd-backend` `SUPABASE_AUTH_*` → remote Supabase push mechanism?
3. Doppler→GitHub secrets and Doppler→EAS: integration sync or manual mirror?
4. `pumpd-ci` `VERCEL_*` — deploys IAWIS `always-wet-store` or `pumpd-website`?
5. Which repo consumes `pumpd-keymat` dotenvx keys?
6. `pumpd-workstation` profile `project_root` defaults to
   `~/ws/PUMPD-MOBILE-APP/pumpd-mobile-app` while current work happens in
   `~/ws/PUMPD-Repo/pumpd-app/pumpd-mobile-app` — which checkout is canonical?

# Agent Tooling Discovery — 2026-07

> **Status:** Draft for review. Nothing installed or committed yet — this is a decision doc.
> **Method:** four parallel Opus 4.8 research channels (usage mining, stack sweep, registry
> sweep, personal-workflow sweep), cross-checked against each other and the repo.
> **Window:** last 60 days (2026-05-23 → 2026-07-22).
> **Verification note:** the `mcp-registry` MCP is **dead/stubbed** in this environment
> (empty for all ~13 queries), so every supply-side finding was verified directly against
> GitHub + vendor docs on 2026-07-22. Items still needing install-time confirmation are in §G.

---

## TL;DR — do these first

The same handful of items surfaced independently from multiple channels. Ranked by ROI
(demand evidence × leverage × low risk):

1. **Build an `env-topology` reference skill** — your #1 friction (~88 prompts, real profanity-level frustration). It's a *knowledge* gap, not a connector gap. Highest ROI, no secrets, portable.
2. **Fix Sentry with a stdio token via Doppler** — unblocks the re-auth wall that hit ~52 sessions. Reuses your existing HeroUI-Pro Doppler pattern.
3. **Adopt the official Expo MCP + a subset of `expo/skills`** — the single largest slice of your stack (EAS/build/TestFlight/OTA/sim), first-party, cross-client, currently *not* connected.
4. **Build three portable workflow skills** — `worktree-bootstrap`, `review-and-pr`, `mcp-preflight` — each clears measured, repeated friction.
5. **Adopt Supabase agent skills** + feed the **permission allowlist** (`fewer-permission-prompts`).
6. **Personal track (separate):** activate your three richest idle connectors with `ticktick-capture`, `email-triage` (draft-only), and a `weekly-review` routine.

Two things need *your* decision before they move: (a) whether to add a **Google Calendar**
connector, and (b) accepting that `review-and-pr` / `worktree-bootstrap` cross the repo's
deliberate "defer generic git/worktree tooling" line — your measured volume now meets its
own "repeated use justifies it" bar, but it's your call.

---

## How this was investigated

| Channel | Question | Source | Result |
|---|---|---|---|
| **1 — Usage mining** | What do we actually struggle with? | 261 in-window sessions, 60,638 events, 720 user prompts + your `/insights` profile (68 sessions) | Ranked friction list, tool tally |
| **2 — Stack sweep** | What does our stack officially offer? | PUMPD `package.json`/`eas.json`/`app.config.ts` + vendor docs (Context7-verified) | Per-stack candidate matrix |
| **3 — Registry/community** | What good tooling exists out there? | GitHub API + vendor docs (registry was dead) | Adopt shortlist |
| **4 — Personal workflows** | What do I do manually every day? | Repo `plugins/personal/` + connected personal MCPs | Connector→skill gap map |

**Demand concentration:** PUMPD `pumpd-mobile-app` is ~85% of all activity; the IAWIS
Shopify store, `trivia-quizup`, and small personal/agent-tooling sessions round it out.
Your dominant goal type is **create_pr** (~19 sessions); sessions overwhelmingly end in a
shipped PR. Top tools by real invocation: Bash (6,586), Read (3,156), Edit (1,665);
top MCPs: Playwright (315), ios-simulator-mcp (285), Claude_Browser (132), Linear (81),
Sentry (57, auth-blocked), Supabase (43).

---

## Cross-channel convergence (highest confidence)

These were flagged by **2+ independent channels** — treat them as high-confidence:

- **Env-var topology skill** — C1 (#1 friction), C2 (top rec), C3 (shortlist #3). Unanimous.
- **Sentry stdio-token via Doppler** — C1 (#4), C2 (rec #2). Config verified.
- **Expo MCP + `expo/skills`** — C2 (rec #3), C3 (shortlist #1–2). "Highest-value single find."
- **Worktree-bootstrap skill** — C1 (#3), C2 (rec #6), C3 (shortlist #7). Prior art exists (Claude-hooks-locked → build portable).
- **Review→PR skill** — C1 (#6), C2 (rec #4), C3 (shortlist #8). Matches your dominant workflow.
- **Session/MCP-preflight skill** — C1 (#7), C3 (shortlist #4). Bespoke recurring friction.
- **Doppler MCP → SKIP** — C2 and C3 independently rejected it (secret-bearing, experimental, 5★, violates AGENTS.md no-secrets posture). Solve the pain with the *skill*, not a connector.

---

## Master recommendation table

Priority: **P0** = do first · **P1** = strong, measured demand · **P2** = valuable, narrower/less urgent.
Effort: **S** ≤ half-day · **M** ~1–2 days · **L** larger. Channels: C1 usage · C2 stack · C3 registry · C4 personal.

| # | Recommendation | Type | Pri | Effort | Channels | Secrets / portability |
|---|---|---|---|---|---|---|
| R1 | **`env-topology`** reference skill (Doppler↔Supabase↔Vercel↔EAS↔GitHub↔local) | build-skill | P0 | M | C1,C2,C3 | none · portable |
| R2 | **Sentry** OAuth-remote → **`@sentry/mcp-server` stdio + Doppler token** | adopt-MCP (reconfig) | P0 | S | C1,C2 | `SENTRY_ACCESS_TOKEN` via Doppler · portable |
| R3 | **Expo MCP** (`mcp.expo.dev/mcp`) — connect | adopt-MCP | P0 | S | C2,C3 | OAuth (PAT fallback unverified) · both clients |
| R4 | **`expo/skills`** subset (expo-router, expo-module, expo-tailwind-setup, expo-upgrade, eas-app-stores, eas-workflows, eas-observe, eas-simulator, expo-examples) | adopt-skill | P0 | S | C2,C3 | none · install from vendor catalog, don't mirror |
| R5 | **`worktree-bootstrap`** skill + optional hook (pkg-manager-aware npm/pnpm/deno, copy `.env`, run patch-package) | build-skill | P1 | M | C1,C2,C3 | none · portable |
| R6 | **`review-and-pr`** skill (base `preview`, full quality gate, real counts, no tail/head) | build-skill | P1 | M | C1,C2,C3 | none · portable |
| R7 | **`mcp-preflight`** skill (inventory unauth'd MCPs at session start, emit exact reconnect cmd) | build-skill | P1 | S–M | C1,C3 | none · portable |
| R8 | **Supabase agent skills** (`npx skills add supabase/agent-skills`) | adopt-skill | P1 | S | C2 | none · pairs with connected MCP |
| R9 | **Permission allowlist** via `fewer-permission-prompts` (git, gh, pnpm, cp, sips, `xcrun simctl list/boot`) | config | P1 | S | C1 | n/a · project settings |
| R10 | **`sentry-triage`** skill (search_issues→search_events→seer→update loop) | build-skill | P1 | M | C1 | none · pairs with R2 |
| R11 | **Maestro MCP** (ships in Maestro CLI, stdio) | adopt-MCP | P2 | S | C2 | Cloud token via Doppler *if* cloud runs · both clients |
| R12 | **Shopify Dev MCP** (`@shopify/dev-mcp`, local, no secrets) | adopt-MCP | P2 | S | C2,C3 | none · both clients |
| R13 | **`webapp-testing`** skill (anthropics/skills) — Playwright visual-QA loop | adopt-skill | P2 | S | C3 | none · wraps existing Playwright MCP |
| R14 | **`sim-coldstart`** skill (iOS 26.5 runtime, boot→install→Metro→sim-serve→local Supabase) | build-skill | P2 | M | C1,C2 | none · portable (extends mobile-development) |
| R15 | **`heroui-charts` usage note** (import Pro components from package root; query the MCP first) | build-skill (tiny) | P2 | S | C1,C2 | none · portable |
| R16 | **`linear-view`** skill (browser-drive the saved view MCP can't create) | build-skill | P2 | M | C1 | none · uses Claude_Browser |
| R17 | **`mcp-builder`** skill (anthropics/skills) — reference for authoring our own MCPs | adopt-skill | P2 | S | C3 | none |
| R18 | **GitHub MCP Server** — only if R6 needs richer PR-comment/Actions-log tooling than `gh` | adopt-MCP (trial) | P2 | S | C3 | OAuth · overlaps `gh` CLI |
| R19 | **`reanimated-worklets`** micro-skill (the recurring `'worklet'` directive bug) | build-skill (tiny) | P2 | S | C3 | none · portable |
| R20 | **`frontend-design`** skill (anthropics/skills) — UI polish | adopt-skill (trial) | P2 | S | C3 | none |

### Personal track (separate, lower urgency than dev)

| # | Recommendation | Type | Pri | Composes | Safety |
|---|---|---|---|---|---|
| P1 | **`ticktick-capture`** — NL quick-add routed to right project/tag/date | build-skill | P1 | TickTick | — |
| P2 | **`email-triage`** — sweep→label→draft→task | build-skill | P1 | Gmail (+TickTick/Linear) | **draft-only, never sends** |
| P3 | **`weekly-review`** — flagship cross-connector review note | build-skill | P1 | TickTick+Linear+Obsidian+Raindrop | — |
| P4 | **`daily-plan` / `today`** — today's tasks, time-blocked (composes with `morning`) | build-skill | P1 | TickTick+Linear | — |
| P5 | **`raindrop-tidy`** — uses connector-native find_misplaced/find_mistagged | build-skill | P2 | Raindrop | — |
| P6 | **`read-later-digest`** — fetch→summarize→note/task | build-skill | P2 | Raindrop+Obsidian+TickTick | — |
| P7 | **`imessage-catchup`** — summarize unread, draft replies | build-skill | P2 | iMessage | **send only on explicit confirm; never paste contents** |
| P8 | **`habit-review`** — TickTick habit check-ins + streaks | build-skill | P2 | TickTick | — |
| P9 | **`personal-journal`** — self-facing daily note (reuse dad-update Q&A pattern) | extend-existing | P2 | Obsidian | — |
| P10 | **`capture`** — universal inbox → route (careful scoping vs P1) | build-skill | P2 | TickTick+Obsidian+Raindrop+Linear | — |

---

## A. Adopt now — external tooling (MCPs & vendor skills)

**R3 · Expo MCP** — `https://mcp.expo.dev/mcp` (Streamable HTTP, OAuth). 30+ tools:
`build_list/info/logs/run/submit`, `workflow_*`, `testflight_crashes/feedback`, App Store
reviews, local `automation_*`/`collect_app_logs`/`expo_router_sitemap`. Add — Claude:
`claude mcp add --transport http expo https://mcp.expo.dev/mcp`; Codex: `codex mcp add expo --url https://mcp.expo.dev/mcp`.
Explicitly documented for both clients. *Caveat:* OAuth (same re-auth class as Sentry) — see §D.
Sources: [docs.expo.dev/mcp](https://docs.expo.dev/mcp/), [docs.expo.dev/agents/claude](https://docs.expo.dev/agents/claude/).

**R4 · `expo/skills` subset** — official Expo skill collection ([github.com/expo/skills](https://github.com/expo/skills),
2,307★, pushed 2026-07-22). Structured exactly like this repo (AGENTS.md + adapters), installs via
`npx skills add expo/skills`, natively cross-client. Adopt the subset that maps to your stack:
`expo-router`, `expo-module` (the path for HealthKit/Watch bridges), `expo-tailwind-setup`
(matches HeroUI's Uniwind), `expo-upgrade`, `eas-app-stores` (TestFlight), `eas-workflows`
(CI), `eas-observe` (Sentry-adjacent), `eas-simulator` (cloud sims), `expo-examples` (incl.
Supabase). **Per AGENTS.md: install from Expo's catalog and record desired presence in a
profile — do not mirror vendor source into this repo.**

**R8 · Supabase agent skills** — `npx skills add supabase/agent-skills` →
`supabase` + `supabase-postgres-best-practices`. Pairs with your connected Supabase MCP;
covers Deno edge functions + RLS (your backend) and documents the CI PAT auth path that
feeds R1. Vendor-owned → install from vendor, record in a profile.

**R11 · Maestro MCP** — official, ships inside the Maestro CLI (stdio, Apache-2.0, both
clients). The app has extensive `.maestro/` E2E suites; this turns agent-authored flow
maintenance from hand-YAML into tool-driven authoring on a live sim. Complements (doesn't
replace) PUMPD's `pumpd-testing` + `ios-simulator-mcp`.
Source: [docs.maestro.dev/get-started/maestro-mcp](https://docs.maestro.dev/get-started/maestro-mcp).

**R12 · Shopify Dev MCP** — `@shopify/dev-mcp` v1.14.3 (local, **no credentials**, talks to
public docs/schemas). Validates GraphQL/Liquid against the live schema — directly counters
"config-from-memory" for the marketing site. The visual-QA half of that workflow is already
covered by Playwright. Adopt Dev MCP; add Admin MCP only if catalog-editing becomes routine.

**R13 · `webapp-testing`**, **R17 · `mcp-builder`**, **R20 · `frontend-design`** — from
`anthropics/skills` (163k★). `webapp-testing` wraps your Playwright MCP into a repeatable
visual-QA loop (Shopify + mobile-Safari + Next.js). `mcp-builder` is reference material for
when you build your own servers (e.g. if R1 ever graduates to an MCP). `frontend-design` is
a UI-polish trial. (You already have `docx/pdf/pptx/xlsx/claude-api/dataviz` — not gaps.)

---

## B. Build — portable skills (our own)

These are pure knowledge/workflow, no secrets, portable → their home is `agent-tooling`
(one physical copy + Claude/Codex adapters). PUMPD-schema-specific behavior stays in the
PUMPD repo (it already does).

**R1 · `env-topology` (P0, highest ROI).** Encode the integration mesh once:
- **Source of truth = Doppler** → fans out to CI (GitHub Actions secrets), EAS (`eas.json`
  env + EAS secrets, `appVersionSource: remote`), Vercel env, local `.env`.
- Mobile runtime reads `EXPO_PUBLIC_*`; build identity from `APP_VARIANT` (dev|staging) →
  bundle id + update channel; EAS channels `development/staging/preview/production`.
- Supabase **local vs remote** toggle: `EXPO_PUBLIC_USE_LOCAL_SUPABASE=true` (localhost:54322)
  vs remote `project-id likkyekzftelrfindaes`; types pulled from remote by default.
- A "where do I set X / why is X undefined at runtime" decision table + the flow diagram.
- Evidence: ~88 prompts, e.g. *"why does it create a bunch of 'production' env variables in
  vercel?"*, *"explain how all the integrations work."* Doppler MCP used only 7× → knowledge, not access.

**R5 · `worktree-bootstrap` (P1).** Detects package manager from `packageManager`/lockfile
(npm|pnpm|bun) or Deno, runs the right install, copies `.env` (per R1), runs
`postinstall`/`patch-package`. Deliver as a skill **and** an optional post-worktree hook.
Evidence: 9 sessions hard-blocked, 1,108 pnpm-install refs. (PUMPD's `worktree` skill is
`wtp`+npm-only; backend is pnpm; agent-tooling's own `.claude/worktrees/` get no install.)
Mine `isoapp/claude-worktree-hooks` + `tfriedel/claude-worktree-hooks` for exact steps
(both Claude-hooks-locked → build portable).

**R6 · `review-and-pr` (P1).** The dominant end-of-task loop (git 316 / gh 130 calls).
PUMPD's `pr` skill mismatches your stated workflow (diffs `main` not `preview`; fast gate
not the full suite; npm-locked). Build portable: detect the repo quality command
(`npm run quality` / `pnpm quality` / deno tasks), run the **full** lint+typecheck+entire
suite, report **real** pass counts, **never pipe through tail/head**, default base
`preview`, conventional-commit title + Summary/Changes/Testing body, Linear-id linking.

**R7 · `mcp-preflight` (P1).** At session start, inventory connected-but-unauthenticated
MCPs and emit the exact reconnect command per connector (Sentry, Linear, claude_design,
Doppler). Evidence: *"the MCP server is still serving the old cached token"*, *"Please run
/design-login"*, *"the Linear MCP is disconnected this session."*

**R10 · `sentry-triage` (P1).** Codify the observed loop
`search_issues → search_events → analyze_issue_with_seer → update_issue`. Pairs with R2 so
non-interactive runs don't dead-end.

**R14 · `sim-coldstart` (P2).** Extend `mobile-development`: select iOS **26.5** runtime
(iOS 27 crashes on launch — UIScene), boot, install dev build, start Metro + `sim-serve` on
a non-conflicting port, verify local Supabase. Evidence: 514 UIScene/26.5 refs, 248
`xcrun simctl` calls. *Confirm PUMPD's `pumpd-ios-simulator/setup-checklist.md` doesn't
already cover iOS-26 before building — could downgrade to skip.*

**R15 · `heroui-charts` note (P2, tiny).** Diagnosed: `heroui-native-pro/radial-chart`
fails because there's **no subpath export** — import from the package root
(`import { RadialChart } from 'heroui-native-pro'`); charts need `victory-native` +
`@shopify/react-native-skia` (already in deps). Fix = a one-paragraph usage note ("import
Pro from package root; query the heroui-native-pro MCP before writing any HeroUI
component"), possibly folded into an existing mobile skill.

**R16 · `linear-view` (P2).** The Linear MCP can create issues/labels/projects but **has no
tool for saved views**. Drive the browser (Claude_Browser, already used 132×) to build the
"just my tasks" board, or standardize label/filter conventions so views are reproducible.

**R19 · `reanimated-worklets` (P2, tiny) — re-scoping needed.** Correction: the app uses
`react-native-reanimated` v4 with the separate `react-native-worklets` package (worklets in
~17 files) and **Uniwind**, not NativeWind — the earlier NativeWind claim was wrong and has
been removed. Whether a small worklet-gotchas note earns a place is an open question pending
the Software Mansion / Reanimated tooling research.

---

## C. Personal workflow skills (separate track)

**Framing:** your personal *connectors are wired* — the gap is *skills* on top of them, the
way `dad-daily-update` sits on messaging. Already mature: `obsidian-vault`, `personal-task`
/ `personal-task-done`, `dad-daily-update`. The three richest connectors — **TickTick,
Gmail, Raindrop — have zero skills**. That's the whole gap.

- **P1 (activate the idle richest):** `ticktick-capture` (highest-frequency action, zero
  coverage), `email-triage` (**draft-only, never sends**; uses sensitive labels when
  triaging private mail), `weekly-review` (flagship — nothing covers it), `daily-plan`
  (composes with, doesn't duplicate, built-in `morning`).
- **P2:** `raindrop-tidy` (connector ships the tidy tools — nearly free), `read-later-digest`,
  `imessage-catchup` (**send only on explicit per-message confirm; never paste contents**),
  `habit-review`, `personal-journal` (extend dad-update pattern into the vault), `capture`
  (universal router — scope carefully so it doesn't swallow `ticktick-capture`).

**Extend, don't build:** add an optional confirm-first iMessage delivery step to
`dad-daily-update` (look up contact via `search_contacts` → confirm → send).

---

## D. Configuration & environment

**Doppler routing pattern (reuse for every new tokened MCP):**
```
doppler --silent run --project agent-tooling --config prd --only-secrets <VAR> --no-fallback \
  --command "exec npx -y <server> ..."
```
Route through this exactly like the existing `heroui-pro` / `analytics-mcp` blocks: Sentry
(`SENTRY_ACCESS_TOKEN`, R2), Maestro Cloud token (R11, if cloud runs), Shopify Admin token
(only if you add Admin MCP). Commit only Doppler project/config ids + env-var allowlists —
never tokens.

**OAuth re-auth risk (the class that broke Sentry).** Expo, Shopify, and Supabase *remote*
MCPs use browser OAuth and can hit the same re-auth wall in headless/cloud sessions.
Verified fallbacks: Sentry → stdio token (R2); Supabase → PAT header
(`Authorization: Bearer $SUPABASE_ACCESS_TOKEN` + `?project_ref=`). **Unverified:** whether
Expo MCP supports a PAT/header fallback for CI — flag before relying on it in cloud (§G).

**Permission allowlist (R9).** Feed `fewer-permission-prompts`: allowlist high-frequency safe
commands (`git`, `gh`, `pnpm`, `cp`, `sips`, `xcrun simctl list/boot`) in project
`.claude/settings.json` so bash-classifier outages (51 sessions) stop stalling commits.

---

## E. Connector decisions (add / verify / keep)

- **ADD? Google Calendar** — *no calendar connector is connected today.*
  `scheduled-tasks`/`schedule` are agent-run cron, not a calendar. Calendar-aware
  time-blocking isn't possible now. **Your call:** add Google Calendar if you want
  time-blocking; otherwise `daily-plan` uses TickTick due dates as the schedule source.
  (Do **not** build on `Control_your_Mac` osascript Calendar — macOS+Claude-only, brittle.)
- **VERIFY: Linear still connected** — `personal-task` / `personal-task-done` both depend on
  Linear `save_issue`, and Linear tools weren't exposed to the personal-sweep subagent.
  Channel 1 shows 81 real Linear calls in-window, so it's almost certainly fine — but
  confirm; if genuinely disconnected, those two skills are broken.
- **KEEP all idle personal connectors** — TickTick, Gmail, Raindrop are idle only because
  the 60-day window is dev-heavy; they're the *activation targets* above, not dead weight.
  **Canva:** keep, but it's project/marketing (Harstem/IAWIS/PUMPD), not personal — hand to
  a project channel. **Google Drive:** keep as a cheap utility; no dedicated skill yet.
- **Note (out of scope):** the Vercel connector exposes purchase tools
  (`buy_domain`/`buy_credits`/`buy_pro`) — prohibited financial actions; any skill on it must
  route purchases to you.

---

## F. Explicitly skipped (and why)

- **Doppler MCP** (`DopplerHQ/mcp-server`, 5★, experimental) — secret-bearing, violates
  AGENTS.md no-secrets posture. Both C2 and C3 rejected it. Solve the pain with R1.
- **RN/Expo `.cursorrules`** (PatrickJS) — generic 27–43-line boilerplate, superseded by
  `expo/skills`. *Exception:* the meatier **Next.js+Vercel+Supabase** rules are worth mining
  (low priority) into a "marketing-site conventions" skill.
- **`GeLi2001/shopify-mcp`** — runtime store-ops MCP; you need build-time dev guidance →
  official Dev MCP (R12) instead.
- **Biome / knip / HealthKit / voltra / react-buoy** — CLI or niche; no MCP, no demand signal.
- **Any MCP duplicating already-connected servers** — Supabase, Vercel, Context7, Linear,
  Sentry, TickTick, Gmail, Google Drive, Raindrop, Canva, Playwright, iOS-sim, HeroUI-docs.

---

## G. Verify at install (unverified claims)

Per your "don't answer infra from memory" rule, these were flagged but not fully verified:

- Exact per-skill body of the Expo `eas-*`/`expo-*` skills (confirmed the plugin + categories,
  not each skill's text).
- Whether the *connected* "Doppler MCP" is the official `@dopplerhq/mcp-server` or a community
  build — either way the #1 fix is R1, not the connector.
- Whether **Expo MCP supports a PAT/header fallback** for CI (its token is browser-generated) —
  gates cloud reliability.
- Maestro MCP local-vs-Cloud tool split and whether Cloud runs need a token (affects Doppler routing).
- Which Shopify server (Dev vs Admin vs Storefront) the wet-in-seattle workflow actually needs.
- Whether PUMPD's `pumpd-ios-simulator/setup-checklist.md` already covers iOS-26/UIScene
  (would downgrade R14 to skip).

---

## H. Suggested rollout (per AGENTS.md "one pilot batch at a time")

**Batch 1 — unblock + highest ROI (P0):** R1 (env-topology), R2 (Sentry stdio token),
R3+R4 (Expo MCP + skills subset). Validate Claude manifest + isolated Claude/Codex
marketplace add/install smoke tests before treating as releasable.

**Batch 2 — workflow skills (P1):** R5 (worktree-bootstrap), R6 (review-and-pr),
R7 (mcp-preflight), R8 (Supabase skills), R9 (allowlist), R10 (sentry-triage).

**Batch 3 — depth + narrower (P2):** R11–R20 as demand justifies each.

**Personal track — run in parallel, independent of dev batches:** P1–P4 first
(ticktick-capture, email-triage, weekly-review, daily-plan), then P5–P10.

Preserve any old standalone installs until both clients pass explicit + implicit invocation
tests. Review the git diff and scan for secrets before any commit (nothing here commits secrets).

---

## Open decisions for you

1. **Google Calendar connector** — add it (enables real time-blocking) or lean on TickTick due dates?
2. **The AGENTS.md deferral line** — R5/R6 (worktree/PR skills) were intentionally deferred
   "until repeated use justifies a custom workflow." Your measured volume (316 git, 130 gh,
   1,108 installs, 9 blocked sessions) is that justification — approve, or keep deferring?
3. **Vendor-skill hosting** — confirm the policy: install `expo/skills` and Supabase skills
   from vendor catalogs and record desired presence in a profile, **not** mirrored into this repo.
4. **Batch 1 go/no-go** — want me to open a Linear backlog (one issue per R#) once you've
   trimmed the list, or start drafting Batch 1?

---

## Revision 2 — post-review + round-2 research (2026-07-22)

Folds in the owner's feedback on the first draft plus four verified round-2 research threads
(Software Mansion/RN, Shopify AI Toolkit, Doppler CLI-vs-MCP, Claude-vs-Codex delivery). All
claims verified against GitHub/vendor docs on 2026-07-22 (the MCP registry is dead in this env).
Items marked **[pending]** need an owner answer (listed at the end).

### Corrections
- **NativeWind was wrong.** The app uses **Uniwind + Tailwind v4**, not NativeWind. The only
  NativeWind reference anywhere was in this doc (R19) — removed. Reanimated is **v4 + the separate
  `react-native-worklets` 0.7.2** (worklets in ~17 files).
- **Expo MCP is OAuth-only — no PAT/CI fallback** (resolves §G's open question). Works
  interactively; will hit the re-auth wall headless/CI. Don't rely on it in cron/cloud runs.
- **Package managers — RESOLVED: mobile = npm.** Corepack `packageManager` = `npm@10.9.3`;
  `.npmrc` sets `legacy-peer-deps=true` (an npm-only flag); `package-lock.json` is git-tracked;
  CI (`pr-dev-deploy`, `main-staging-deploy`) runs `npm ci` with `cache: npm`. The
  `pnpm-lock.yaml` is **git-ignored local cruft** (`.gitignore:58`) — safe to delete. Net:
  **mobile = npm, backend = pnpm, edge/e2e = deno.** `worktree-bootstrap` detects per-dir.

### Changed items
- **R2 Sentry stdio-token → REVISED to hosted OAuth remote (2026-07-23).** Owner chose Sentry's
  hosted MCP (`https://mcp.sentry.dev/mcp`, project-scoped `avad-technologies-llc/pumpd`) over the
  `@sentry/mcp-server` stdio + Doppler-token approach. Rationale: scheduled automations
  (`pumpd-sentry-miner`) run from **local** Claude and reuse the **local** Sentry OAuth session, so
  the headless re-auth wall that motivated the original stdio switch does not apply here; owner
  accepts periodic browser re-auth. Added per client via `claude mcp add --transport http` /
  `codex mcp add --url`, tracked as `claude.sentry-mcp` / `codex.sentry-mcp` in `base-workstation`.
  No `plugins/mobile-development/.mcp.json` block and no `SENTRY_ACCESS_TOKEN` — the earlier
  "remove OAuth-remote connector" note is void. Note `sentry@openai-curated` still supplies Codex a
  Sentry capability on `pumpd-workstation`; reconcile the raw vs curated server if both are enabled.
- **R6 review-and-pr → SPLIT.** `create-pr` = mechanical action skill (full gate → commit → push
  → PR to `preview`). Plus a **review agent** (subagent) composing existing review skills —
  `thermo-nuclear-code-quality-review`, `security-review`, a correctness pass — in parallel, one
  synthesized verdict. PUMPD already has scoped `pr`/`review`/`quality`/`resolve-pr-comments` →
  portablize + generalize, don't duplicate.
- **R5 worktree-bootstrap → RESCOPED.** No blind `.env` copy. Detect pkg-manager from
  lockfile/field → install → **materialize env correctly** (mobile → `eas env:pull`; backend/
  others → `doppler run`; edge → deno) → `patch-package`. **[pending: npm-vs-pnpm]**
- **R14 sim-coldstart → EXPANDED.** Client-aware: Claude → `ios-simulator-mcp`; Codex →
  `build-ios-apps@openai-curated` (bundles XcodeBuildMCP) — one capability, two servers. Add
  parallel-sim + non-overlapping Metro ports. **[pending: where the port-scheme docs live;
  reconcile with `pumpd-dev-tools/react-native-ios-plugin`, which already ships an ios-sim MCP.]**
- **R16 linear-view → `linear-manage`.** Drop "views." A dev-task create/update/comment/triage/
  link-to-PR skill on the connected Linear MCP (no strong official CLI). Saved-view creation =
  optional minor browser step. Consolidate with `personal-task`/`personal-task-done`/`sim-qa`.
- **R12 Shopify Dev MCP → Shopify AI Toolkit (targeted).** The Dev MCP is **one of three install
  modes** of the `Shopify/shopify-ai-toolkit` plugin — not a separate product; installing both
  duplicates. For the Next.js headless storefront, adopt only the read skills:
  `shopify-storefront-graphql` (names Next.js), `shopify-custom-data`, `shopify-dev`
  (± `shopify-customer`). **Set `OPT_OUT_INSTRUMENTATION=true`** (telemetry ships queries+code by
  default); skip `shopify-use-shopify-cli` (store-write). Consume, don't fork.
- **R19 reanimated-worklets → DROPPED**, replaced by SWM skills (below) — they cover
  worklets/bundle-mode properly. The real pain is Bundle Mode × Uniwind, not the directive.
- **Doppler MCP → KEEP (owner) + harden + add CLI skill.** Keep the MCP as interactive console
  (harden to a read-only scoped token, `--project/--config`). No official Doppler *coding* skill
  exists → **build a first-party Doppler CLI skill** that feeds `env-topology` and runs in
  CI/headless/Codex where the MCP isn't loaded. Keep runtime-injection for launching tokened
  servers. Three distinct lanes.
- **GitHub MCP → REMOVED** (owner: `gh` CLI suffices).

### New candidates (round-2 research)
- **`software-mansion-labs/skills`** (251★, MIT, "tested with Claude Code") — **ADOPT.** RN
  best-practices sub-skills mapping ~1:1 to your SWM deps (Reanimated 4, Gesture Handler, svg,
  `multithreading`/worklets, `enable-worklets-bundle-mode` = the Uniwind×worklets Metro conflict).
  Claude marketplace only → add a `.agents` Codex adapter. *Confirm LICENSE (API returned null) +
  strip pinned version per git-SHA policy.*
- **`callstackincubator/agent-skills`** (1558★, MIT) — **ADOPT.** Perf/profiling/bundling +
  `react-native-testing` (matches RNTL) + `js-react-compiler` ref (for the `react-compiler`
  worktree). Also ships the exact dual `.claude-plugin` + `.agents` layout — a structural template.
- **Radon AI MCP** (SWM Radon IDE, 1709★) — **TRIAL, paid-gated.** 8-tool MCP (fresh RN docs +
  live logs/screenshots/component-tree/network). Only if the team licenses Radon IDE.
- **metro-mcp** (69★, MIT) — **TRIAL.** Live-app debug + test recording → **Maestro**. Small/new;
  pilot before standardizing. Pairs with the Maestro MCP (R11).
- **Doppler CLI skill** — **BUILD** (see above).
- **Shopify AI Toolkit storefront skills** — **ADOPT-PART** (see R12 change).

### Architecture — Claude vs Codex delivery (heuristic)
1. **Knowledge / no-secret gap → portable skill** (one `SKILL.md` + thin adapters, byte-identical
   across clients) — even when an MCP exists (e.g. `env-topology` over the Doppler MCP).
2. **Live service + maintained server → MCP** — token/stdio over OAuth for headless, Doppler-wrap
   secrets. (Same server, different config: Claude JSON `.mcp.json`/`claude mcp add`; Codex **TOML**
   `[mcp_servers.x]`/`codex mcp add --url`.)
3. **Vendor ships a catalog bundle → per-client plugin, install don't mirror**, record presence in
   a profile. (Same capability, different coordinate: `x@claude-plugins-official` vs
   `x@openai-curated`; some exist in one client only.)
- **Codex plugins are user-scoped only** → project-critical behavior must be committed *project
  skills*, not a project plugin.
- Divergences: **Playwright** — Claude add-on MCP vs Codex bundled `browser` runtime → portable
  `webapp-testing` skill on top. **iOS-sim** — Claude `ios-simulator-mcp` vs Codex `build-ios-apps`
  (XcodeBuildMCP).

### Open items — all resolved (see Decisions below)
- **A) Mobile package manager** — RESOLVED: npm (corepack `npm@10.9.3`, npm-only `.npmrc`,
  tracked `package-lock.json`, `npm ci` in CI). Backend = pnpm; edge/e2e = deno.
- **B) Parallel-sim / Metro-port docs** — owner supplies them when `sim-coldstart` is built.
- **C) `pumpd-dev-tools`** — owner decision: **ignore entirely.** No dedup, migration, or
  boundary work against it. This plan touches `agent-tooling`, client configs, and vendor
  catalogs only.

---

## Decisions — 2026-07-22 (final)

Recorded from the owner's review (widget + chat deltas). Supersedes every "open decision"
above. Totals: **31 approved · 9 deferred · 3 denied.**

### Approved (31)

**Build in `agent-tooling` (8):**
`env-topology` (P0) · `doppler-cli-skill` · `worktree-bootstrap` · `create-pr` ·
**review agent** (Claude-native agent composing thermo-nuclear + security-review + a
correctness pass) · `mcp-preflight` · `sim-coldstart` (owner supplies parallel-sim/port docs
at build time) · `linear-manage`.

**Adopt from vendor catalogs (7):**
`expo/skills` subset (P0) · `software-mansion-labs/skills` (confirm LICENSE; add `.agents`
Codex adapter) · `callstackincubator/agent-skills` · Supabase agent skills · Shopify AI
Toolkit storefront read-skills (`OPT_OUT_INSTRUMENTATION=true`; exclude the store-write CLI
skill) · `webapp-testing` · `frontend-design`.

**MCP / connector setup (3):**
Sentry → stdio token via Doppler (P0) · Expo MCP (P0 — OAuth-only, interactive use only,
never relied on in CI/cron) · Maestro MCP.

**Config (1):** permission allowlist via `fewer-permission-prompts`
(git, gh, npm, pnpm, deno, cp, sips, `xcrun simctl list/boot`).

**Personal skills (9):**
`ticktick-capture` · `email-triage` (draft-only, never sends) · `weekly-review` ·
`daily-plan` · `raindrop-tidy` · `read-later-digest` · `imessage-catchup` (confirm-first
send, never paste contents) · `habit-review` · `personal-journal`.

**Connector posture (3):**
Keep Doppler MCP + harden to a read-only scoped token (`--project/--config`) · keep idle
personal connectors mounted (TickTick, Gmail, Raindrop, Canva, Drive) · verify Linear is
connected (`personal-task`/`sim-qa` depend on it).

### Deferred — investigate later (9)
`sentry-triage` skill · `heroui-charts` note · `mcp-builder` · delete stray mobile
`pnpm-lock.yaml` (git-ignored, harmless) · `metro-mcp` (pilot later) · Radon AI MCP (paid
gate) · `capture` universal inbox (scope vs `ticktick-capture`) · Google Calendar connector
(until time-blocking is wanted; `daily-plan` uses TickTick due dates) · Next.js cursor rules
(selective mining, low priority).

### Denied (3)
RN/Expo cursor rules · `GeLi2001/shopify-mcp` · Biome / knip / HealthKit / voltra MCPs.

### Execution plan — three lanes, batch at a time (per AGENTS.md)

**Lane A — client/connector setup** (Claude + Codex apps/CLIs; owner mints tokens & clicks
OAuth, agent writes config): Sentry stdio block Doppler-routed in
`plugins/mobile-development/.mcp.json` beside `heroui-native-pro`; Expo MCP added on both
clients (`claude mcp add --transport http` / `codex mcp add --url`); Maestro MCP (stdio,
ships in the Maestro CLI); Doppler MCP hardened to a read-only service token; Linear
verification.

**Lane B — vendor catalog installs** (per client via `npx skills add` or plugin catalogs;
recorded in a profile + `tooling-inventory.md`; **never mirrored into this repo**): Expo,
SWM, Callstack, Supabase, Shopify storefront, webapp-testing, frontend-design.

**Lane C — `agent-tooling` builds** (one physical `SKILL.md` + Claude/Codex adapters per
AGENTS.md). Per-skill loop: scaffold → evidence-gather → write → wire adapters → validate
(manifest validation + isolated Claude/Codex marketplace add/install smoke tests) → invoke
explicitly + implicitly in both clients → diff review + secret scan → commit/PR.

**Batches:**
1. **Batch 1 — P0 unblock:** Sentry stdio via Doppler · Expo MCP (both clients) ·
   `expo/skills` subset · build `env-topology`.
2. **Batch 2 — workflow core:** `doppler-cli-skill` · `worktree-bootstrap` · `create-pr` ·
   review agent · `mcp-preflight` · permission allowlist.
3. **Batch 3 — vendor adopts:** SWM (+ Codex adapter) · Callstack · Supabase · Shopify
   storefront · `webapp-testing` · `frontend-design` · Maestro MCP.
4. **Batch 4 — P2 builds:** `sim-coldstart` (owner docs) · `linear-manage`.
5. **Personal track (runs parallel, any time):** `ticktick-capture` → `email-triage` →
   `weekly-review` → `daily-plan`, then the five P2 personal skills.

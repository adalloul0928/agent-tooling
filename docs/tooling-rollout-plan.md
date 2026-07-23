# Tooling rollout plan — 2026-07

The actionable roadmap from the July 2026 tooling discovery. Full rationale,
evidence, and the complete decision record live in
[tooling-discovery-2026-07.md](tooling-discovery-2026-07.md); this doc tracks
execution. Update the status columns as items land.

Decisions recorded 2026-07-22: **31 approved · 9 deferred · 3 denied.** Those
counts are the original record and are **not** updated as items land; the status
columns below plus the 2026-07-23 reversals and deferrals are the current truth.
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
| `doppler-cli-skill` | C | **done** | `plugins/developer-workflows/skills/doppler-cli-skill/`. Names-only live queries via the Doppler CLI; live companion to `env-topology`'s static map. **Primary** Doppler path, not a fallback — the Doppler MCP was retired the same day (see Connector posture). Encodes the verified config topology (`preview` not `stg` on `pumpd-website`; `prd`-only on `agent-tooling`/`pumpd-ci`/`pumpd-keymat`) and the `doppler run` injection pattern |
| `worktree-bootstrap` | C | **done** | `plugins/developer-workflows/skills/worktree-bootstrap/`. Skill only — **hook evaluated and declined**: `WorktreeCreate` fires only for Claude-created worktrees (PUMPD's come from `wtp`), `SessionStart` can't block, user-scoped hooks fire in every repo, and Codex has no worktree events so hook logic can't be portable. Corrections found while building: the `packageManager` field is authoritative because mobile's `pnpm-lock.yaml` is untracked/gitignored cruft that misleads lockfile detection; the backend's local `.env` is generated by `pnpm run init` from `supabase status`, **not** `doppler run`; patch-package already runs via mobile's `postinstall`. Follow-up (PUMPD repo, out of scope): `.claude/skills/worktree` still blind-copies `.env` and hardcodes `npm install` |
| `create-pr` | C | **deferred** | Deferred 2026-07-23 pending a scoping decision. PUMPD's `/pr` already does the full gate, conventional title, Summary/Changes/Testing body, and Linear linking — R6 said *portablize + generalize, don't duplicate*. Gaps if revived: `/pr` targets `main` while **11 of the last 12 merged PRs went to `preview`** (live bug), is `disable-model-invocation: true` so "create pr" never triggers it, hardcodes `npm run …` (breaks backend/edge), has no commit/push, and is Claude-only. Open question: always-true rules (base `preview`; never pipe the gate through tail/head — it masks non-zero exit codes) may belong in `AGENTS.md` rather than a skill |
| Review agent | C | **deferred** | Deferred 2026-07-23. Built-in `/code-review ultra` already does parallel multi-agent, severity-ranked, synthesized review; with `/code-review`, `/security-review`, thermo-nuclear, `pumpd-review`, `pumpd-security-scan`, and PUMPD's `review`/`quality` there are 6+ paths already. Would be the repo's **first packaged agent** (no `agents/` dir or manifest key exists) and agents are Claude-only per AGENTS.md, cutting against the portability thesis. Evidence was borrowed from R6's PR half (~19 create_pr sessions); no review-specific friction is recorded. If revived, build as a **skill**, not an agent |
| `mcp-preflight` | C | **done** | `plugins/developer-workflows/skills/mcp-preflight/`. Everything observed from `claude mcp list` / `--help`, not recalled. Three states with unrelated fixes: `✔ Connected`; `! Needs authentication` → `claude mcp login <name>` (`--no-browser` for SSH/headless); `⏸ Pending approval` → an unapproved project `.mcp.json` server Claude never connects to (`reset-project-choices`). No `--json` on `list`; **don't key off the exit code**. Doppler-wrapped stdio servers usually fail because of Doppler, not the MCP. Doppler MCP dropped from scope (retired in #32); Codex side marked unverified — CLI not on PATH |
| Permission allowlist | config | **deferred** | Deferred 2026-07-23 — owner is doing this one separately. Prefer `fewer-permission-prompts`, which scans real transcripts to produce a scoped allowlist instead of guessing: git, gh, npm, pnpm, deno, cp, sips, `xcrun simctl list/boot` |

## Batch 3 — vendor adopts + Maestro

| Item | Lane | Status | Notes |
|---|---|---|---|
| `software-mansion-labs/skills` | B | **done** (Claude) | All 8 installed. **LICENSE resolved: MIT, README-only — no LICENSE file**, which is why the API reported none. Its `react-native-best-practices` won the name collision with Callstack's and carries the Reanimated 4 / gestures / svg / worklets-bundle-mode content (those sub-skills are bundled, not separately installable). **The `.agents` Codex adapter is unnecessary** — `skills add --agent` handles Codex, and hand-authoring would mirror upstream bodies |
| `callstackincubator/agent-skills` | B | **done** (Claude) | 9 of 10 installed (MIT). `react-native-best-practices` excluded — name collision with SWM's, and `skills add` has no rename option, so installing both silently overwrites one. **Cost:** its perf material (FPS/TTI/bundle/Hermes/FlashList) is not installed anywhere. **Correction:** the `react-native-testing` and react-compiler skills this row was justified by do not exist in the repo |
| Supabase agent skills | B | **done** (Claude) | Both installed (MIT). Clean — no collisions, no corrections |
| Shopify AI Toolkit storefront skills | B | **deferred** | Deferred 2026-07-23 by owner; kept out of the grouped Batch 3 sweep. Targets the IAWIS storefront rather than PUMPD, and needs `OPT_OUT_INSTRUMENTATION=true` set **before first use** (it ships queries + code to shopify.dev by default). Read skills only; exclude the store-write CLI skill |
| `webapp-testing` (anthropics/skills) | B | **done** (Claude) | Installed in the grouped Batch 3 sweep |
| `frontend-design` (anthropics/skills) | B | **done** (Claude) | Installed in the grouped Batch 3 sweep. **`anthropics/skills` states no license** (no LICENSE file, no README section, only THIRD_PARTY_NOTICES.md) — recorded as unstated, not assumed. 12 of 18 installed; docx/pdf/pptx/xlsx/skill-creator/claude-api excluded as already-registered plugin names |
| Maestro MCP | A | **deferred** | Deferred 2026-07-23 by owner. Lane A connector wire, not a skill install, so it was excluded from the grouped Batch 3 sweep. stdio, ships in the Maestro CLI; would go in a plugin-scoped `.mcp.json` with no secrets |

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

- **Doppler MCP: retired 2026-07-23** (reverses the earlier "keep + harden"
  decision). It was not installed on any surface, was used 7× in 60 days, served
  stale cached tokens, and is secret-bearing + experimental. `doppler-cli-skill`
  is now the primary way to query Doppler — names-only by rule, and it also works
  in CI, headless, and non-Claude clients. Do **not** reinstate the MCP. The
  Doppler **CLI** stays load-bearing: it injects secrets at runtime for every
  tokened MCP (`heroui-pro`, `heroui-native-pro`, `analytics-mcp`).
- Keep idle personal connectors mounted (TickTick, Gmail, Raindrop, Canva,
  Drive) — activation targets, not dead weight.
- Verify Linear stays connected (`personal-task`/`sim-qa` depend on it).

## Codex pass — resolved 2026-07-23

**The blocker was a false premise.** This pass was recorded as blocked on "the
`codex` CLI is not installed." It is installed — the binary ships **inside the
ChatGPT desktop app** at `/Applications/ChatGPT.app/Contents/Resources/codex`
(`codex-cli 0.145.0-alpha.30`), just not symlinked onto `PATH`, so
`command -v codex` fails while Codex is fully configured. Symlinked into
`~/.local/bin` and tracked as the `codex.cli-on-path` manual check, since the
app-bundle path is machine-specific and must not be committed into a recipe.

Running it showed Codex was **already near parity**, so four of the five
accumulated decisions resolved by observation:

| Decision | Resolution |
|---|---|
| Sentry curated-vs-raw | **Curated.** `sentry@openai-curated` installed + enabled; no raw MCP. The advisory `codex.sentry-mcp` check asserted the opposite and was **removed** |
| Expo curated-vs-raw | **Curated.** `expo@openai-curated` installed + enabled; `codex.duplicate-expo-mcp` (absent) was already correct |
| Owned plugins | Already done — marketplace added, all six installed + enabled |
| Vendor skills | **The real gap.** 38 installed with `--agent codex`, tracked as `codex.*-skill-*` path checks |
| `mcp-preflight` Codex section | Still unverified in the skill text; the state vocabulary (`enabled`/`disabled`, `OAuth`/`Bearer token`/`Unsupported`) is now observable and should be filled in |

One rule replaces the curated-vs-raw question: **Codex takes sentry/expo/linear/
supabase/github from the curated catalog, never as raw MCPs.** The
`codex.duplicate-*-mcp` "absent" checks enforce it.

**Skill placement gotcha:** `skills add --agent codex` installs to
`~/.agents/skills/<name>/SKILL.md`, **not** `~/.codex/skills/`. Verified before
writing checks; the assumed path would have been wrong.

Two Codex-only exclusions on content grounds: `web-artifacts-builder` (about
claude.ai artifacts) and `brand-guidelines` (Anthropic brand) — hence 38 rather
than Claude's 40. Note the six `anthropics/skills` names excluded on both sides
were justified by *Claude's* plugin set; in Codex only `pdf` genuinely collides,
so `docx`/`pptx`/`xlsx`/`skill-creator`/`claude-api` could be revisited for
stricter parity.

Still open: **`pumpd-automations` on Codex, deferred by owner** — its advisory
check remains as a marker.

## Cross-repo follow-ups (outside `agent-tooling`)

Found while executing this rollout. Recorded here because the rollout's scope
stops at this repo, so these will not otherwise get picked up:

- **PUMPD `/pr` targets the wrong base.**
  `pumpd-mobile-app/.claude/skills/pr/SKILL.md` diffs `main` and passes no
  `--base`, but **11 of the last 12 merged PRs went to `preview`**. Live bug,
  one-line fix.
- **PUMPD `worktree` skill bootstraps incorrectly.**
  `pumpd-mobile-app/.claude/skills/worktree/SKILL.md` blind-copies `.env` and
  hardcodes `npm install` — wrong for backend (pnpm) and edge (deno). It should
  delegate to `worktree-bootstrap`.
- **`react-compiler` worktree is missing its `.env`** — the single bootstrap gap
  observed across the 11 leaf worktrees.

## Deferred (investigate later)

`sentry-triage` skill · `heroui-charts` note · `metro-mcp` · Radon AI **MCP**
(paid gate) · `capture` universal inbox · Google Calendar connector · Next.js
cursor-rule mining.

Corrections to this list as of 2026-07-23:

- **`mcp-builder` is no longer deferred — it is installed**, as part of the
  `anthropics/skills` adoption (everything except name collisions). Flagged here
  because it entered via a batch install rather than its own decision.
- **Radon:** the *MCP* remains deferred behind its paid gate, but the `radon-mcp`
  **skill** is now installed as part of the Software Mansion collection. The skill
  documents tools that are not connected — harmless, but do not read its presence
  as adoption of the MCP.
- **Delete stray mobile `pnpm-lock.yaml`** is now load-bearing rather than
  cosmetic: that untracked, gitignored file is exactly what makes lockfile-based
  package-manager detection pick pnpm in an npm project. `worktree-bootstrap`
  works around it by treating the `packageManager` field as authoritative;
  deleting the file would remove the trap at the source.

## Denied

RN/Expo cursor rules · `GeLi2001/shopify-mcp` · Biome/knip/HealthKit/voltra
MCPs.

## Open questions (owner)

0. **`react-native-best-practices` — the profile contradicts the collision
   decision (surfaced 2026-07-23).** `pumpd-workstation` asserts
   `claude.callstack-react-native-plugin` →
   `react-native-best-practices@callstack-agent-skills` **enabled** at project
   scope. But the Batch 3 collision was resolved the other way: Software
   Mansion's `react-native-best-practices` is the one installed (user scope,
   file), and Callstack's was deliberately excluded because the two share a
   directory name. Enabling the callstack plugin would put a second skill of that
   name back in play. The check currently **fails**, so nothing is broken today —
   but the profile is asking for something the rollout decided against. Either
   drop the check (consistent with the collision decision) or reverse the
   collision in Callstack's favour and drop SWM's; do not leave both asserted.

1. `EXPO_PUBLIC_SECURE_STORAGE_KEY` — local `.env` only; how do release builds
   get it?
2. Doppler `pumpd-backend` `SUPABASE_AUTH_*` → remote Supabase push mechanism?
3. Doppler→GitHub secrets and Doppler→EAS: integration sync or manual mirror?
4. `pumpd-ci` `VERCEL_*` — deploys IAWIS `always-wet-store` or `pumpd-website`?
5. Which repo consumes `pumpd-keymat` dotenvx keys?
6. `pumpd-workstation` profile `project_root` defaults to
   `~/ws/PUMPD-MOBILE-APP/pumpd-mobile-app` while current work happens in
   `~/ws/PUMPD-Repo/pumpd-app/pumpd-mobile-app` — which checkout is canonical?

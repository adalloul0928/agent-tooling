# Build prompts — one per item

A copy-paste prompt for every approved tooling item. Work them one at a time:
open a **fresh AI coding chat in the `agent-tooling` repo root**, paste the
item's prompt block, let it build → validate → open a PR, then check the box
here.

(`env-topology` and `scripts/setup` already shipped in #26 and are not listed
below.)

## Driver prompt — paste this into each new session

Run the session in **plan mode** (in the Claude Code TUI, press Shift+Tab to
cycle the permission mode to "plan") so the plan comes back with native
approve / reject buttons. Then paste this once per session:

```text
You are helping roll out tooling in the agent-tooling repo, ONE item per
session, with a plan-and-approve gate. Start on the latest main
(git checkout main && git pull). Open docs/build-prompts.md and find the FIRST
unchecked item — a line starting with "- [ ]".

DO NOT change any files yet. First:
1. Read that item's prompt block plus AGENTS.md, docs/tooling-rollout-plan.md,
   and plugins/developer-workflows/skills/env-topology/SKILL.md as a reference,
   and inspect whatever the item touches.
2. Present a concise PLAN for that ONE item for my approval: what you'll
   create or change and where it lives, how you'll validate
   (./scripts/validate-static), any human steps I'll need (token mints / OAuth),
   and any open questions. Present it via plan mode so I get approve / reject
   buttons. If I want changes, revise the plan and re-present it — do not start
   until I approve.

After I approve:
- Build/install the item, validate with ./scripts/validate-static, change its
  "- [ ]" to "- [x]" in docs/build-prompts.md, commit on a new branch, and open
  a PR to main. Portable across Claude Code + Codex; no hard-coded client paths;
  never commit secrets.
- If it's a connector needing a token/OAuth from me, do the config parts, then
  STOP and print the exact human steps; don't check the box until I confirm.

Do ONE item only. End by reporting the item, the PR link, and anything I must do
by hand.
```

To target a specific item instead, append: "Skip to the `<name>` item." If a
plan looks off, just chat with it — it revises and re-presents before doing any
work.

## How to use

- Every **build** prompt tells the fresh chat to read this repo's conventions
  itself (`AGENTS.md`, the rollout plan, and the `env-topology` skill as a
  worked example), so the prompts stay short and self-contained.
- **Build** items (skills/agents) produce a `SKILL.md` + a PR to `main`.
- **Install** items are a command + a "record it in profiles/inventory" step.
- **Connector** items have human steps (mint a token / click OAuth) called out
  — an AI chat can't do those.
- Order is not a dependency chain. Soft pairings only: `doppler-cli-skill`
  complements `env-topology`; `create-pr` + the review agent are used together.
- Each item opens its own PR. Group several into one branch if you're doing
  them in a single sitting.

Context every build prompt leans on (already in the repo): `AGENTS.md`
(authoring rules — portable across Claude Code + Codex, one physical `SKILL.md`,
no hard-coded `~/.claude`/`~/.codex` paths, capability-term instructions),
`docs/tooling-rollout-plan.md`, `docs/tooling-discovery-2026-07.md`, and
`plugins/developer-workflows/skills/env-topology/SKILL.md` as the shape to
mirror. Validate with `./scripts/validate-static`.

---

## Phase 1 — Batch 1 finish (connectors + first vendor install)

- [x] **Sentry MCP** — **REVISED 2026-07-23 → hosted OAuth remote** (supersedes the
  original stdio-token plan; see `docs/tooling-discovery-2026-07.md` → Changed
  items → R2). Owner chose Sentry's hosted MCP (`https://mcp.sentry.dev/mcp`,
  project-scoped `avad-technologies-llc/pumpd`) over `@sentry/mcp-server` stdio + a Doppler
  token: the scheduled automations run from **local** Claude and reuse the
  **local** Sentry OAuth session, so the headless re-auth wall that motivated the
  stdio plan doesn't apply, and the owner accepts periodic browser re-auth.
  Landed as per-client checks `claude.sentry-mcp` / `codex.sentry-mcp` in
  `profiles/base-workstation.json` with `claude mcp add --scope user --transport
  http sentry <url>` / `codex mcp add sentry --url <url>` install recipes — no
  `plugins/mobile-development/.mcp.json` block and no `SENTRY_ACCESS_TOKEN`.
  `--scope user` is required: `claude mcp add` defaults to local/project scope,
  which hides the server from the PUMPD checkout where the Sentry automations
  run. **Done 2026-07-23** — registered at user scope and OAuth confirmed
  (`claude mcp list` → `sentry … ✔ Connected`). Codex side still open: see the
  `codex.duplicate-*-mcp` guards in `pumpd-workstation`.

- [x] **Expo MCP** — **REVISED 2026-07-23 → Claude only; Codex deferred.** Landed
  as `claude.expo-mcp` in `profiles/base-workstation.json` with recipe
  `claude mcp add --scope user --transport http expo https://mcp.expo.dev/mcp`,
  plus an `expo.mcp-oauth` manual check. **Done 2026-07-23** — registered at user
  scope and OAuth confirmed connected in Claude by the owner.

  The original prompt also asked for a `codex_mcp` check and
  `codex mcp add expo --url …`. That was **dropped deliberately**:
  `pumpd-workstation` already asserts `codex.duplicate-expo-mcp` →
  `expected: absent` (Codex receives expo from the `openai-curated` catalog), so a
  `present` check on the same server would be a direct contradiction. Owner's call
  was to finish Claude first, then do a dedicated Codex pass that settles
  curated-vs-raw for expo *and* sentry together. `codex` CLI was also not on PATH,
  so that side could not be verified here.

  Expo is **OAuth-only with no PAT/CI fallback** — interactive use only; never
  depend on it in cloud/cron runs.

- [x] **expo/skills subset** — **Done 2026-07-23.** Installed 9 of the 23 skills
  `expo/skills` ships (MIT, installed via the `skills` CLI, **not mirrored**),
  tracked as `path` checks with per-skill recipes in
  `profiles/base-workstation.json` and recorded as vendor-owned in
  `docs/tooling-inventory.md`.

  Subset: `expo-router`, `expo-module`, `expo-tailwind-setup`, `expo-upgrade`,
  `eas-app-stores`, `eas-workflows`, `expo-examples`, **`expo-project-structure`**,
  **`expo-dev-client`**.

  **Tuned from the original list** — dropped `eas-simulator` (its own description
  tells macOS users with local simulators not to auto-trigger it; `ios-simulator-mcp`
  and the planned `sim-coldstart` cover that) and `eas-observe` (paid EAS APM that
  overlaps the Sentry MCP wired the same day); added `expo-project-structure` and
  `expo-dev-client` instead. Subset size is deliberate — every installed skill's
  description is loaded for trigger matching, so unused skills cost context on
  every session.

  Claude-only (`--agent claude-code`); Codex deferred to its own pass. Two CLI
  gotchas worth keeping: `skills add` defaults to **project** scope so `-g` is
  required, and `--skill` takes **one skill per flag** (comma-separated is
  silently rejected — it just prints the full skill list).

---

## Phase 2 — Batch 2 workflow core (build)

- [x] **doppler-cli-skill** — **Done 2026-07-23.** Built at
  `plugins/developer-workflows/skills/doppler-cli-skill/SKILL.md` as the live
  companion to `env-topology`'s static map: that skill says where a variable
  *should* live, this one says what is *actually* in Doppler now.

  **Reframed from the original prompt.** It was written as a fallback "for
  contexts where the Doppler MCP is not loaded." The Doppler MCP was **retired
  the same day** (not installed on any surface, 7 uses in 60 days, served stale
  cached tokens, secret-bearing + experimental — see
  `docs/tooling-discovery-2026-07.md` → *Doppler MCP → RETIRED*), so this skill is
  the **primary** Doppler path, not a backup. Two lanes remain, not three: this
  skill for live queries, and `doppler run` for runtime injection into tokened
  servers.

  Encodes the hard names-only rule (including that plain `doppler secrets`
  without `--only-names` prints values — the actual footgun), the config topology
  verified live at authoring time (`preview` not `stg` on `pumpd-website`;
  `prd`-only on `agent-tooling`/`pumpd-ci`/`pumpd-keymat`), a config-diff recipe
  for "why does prd work but dev not", and troubleshooting for doppler-wrapped
  MCPs that fail to start.

- [x] **worktree-bootstrap** — **Done 2026-07-23.** Built at
  `plugins/developer-workflows/skills/worktree-bootstrap/SKILL.md`.

  **Shipped as a skill only — a hook was evaluated and declined.** Claude has a
  purpose-built `WorktreeCreate` event, but it fires only for worktrees *Claude*
  creates; PUMPD's come from `wtp`, so it would never fire where the friction is.
  `SessionStart` cannot block, user-scoped hooks fire in *every* repo with no
  per-project opt-out, and Codex's hook set has no worktree events — so hook logic
  can't be portable. Bootstrapping is judgment (per-directory manager, per-surface
  env), not a fixed script, which is skill territory.

  **Three claims in the original prompt were falsified against the repos and are
  NOT what shipped:**
  1. *"`packageManager` field / lockfile"* as equivalent signals — for mobile they
     **disagree**. It declares `npm@10.9.3` but also carries a `pnpm-lock.yaml`
     that is untracked and gitignored. Lockfile detection picks pnpm and is wrong.
     The skill makes the `packageManager` field authoritative and teaches proving
     a lockfile is real (`git check-ignore` / `git ls-files`) before trusting it.
  2. *"backend/others via `doppler run`"* — **wrong**. The backend's local `.env`
     is generated by `pnpm run init` → `scripts/init.ts` → `supabase status`.
     Doppler holds *remote* `pumpd-backend` config. Using `doppler run` yields a
     file that looks right and points at the wrong stack.
  3. *"runs patch-package where a `patches/` dir exists"* — redundant. Mobile
     wires `"postinstall": "patch-package"`, so the install already runs it (and
     no `patches/` dir exists today).

  Also encodes the `EXPO_PUBLIC_SECURE_STORAGE_KEY` gap (consumed in mobile `src`,
  no EAS/Doppler home) as something to report rather than fabricate.

  **Follow-up, out of scope here:** `pumpd-mobile-app/.claude/skills/worktree/SKILL.md`
  still does a blind `.env` copy and a hardcoded `npm install`. It should delegate
  to this skill — but that's a PUMPD-repo change.

- [ ] **create-pr**

  ```text
  Build the `create-pr` skill in the agent-tooling repo. Read AGENTS.md and the
  env-topology skill for shape. Place it at plugins/developer-workflows/skills/
  create-pr/SKILL.md. It runs the everyday ship loop: detect the repo's quality
  command (npm/pnpm/deno scripts), run the FULL gate — lint + typecheck + the
  ENTIRE test suite — report the REAL pass counts, and NEVER pipe test/build
  output through tail/head (it masks non-zero exit codes); then commit, push, and
  open a PR whose BASE defaults to `preview`, with a conventional-commit title and
  a Summary / Changes / Testing body, linking the Linear issue if the branch or
  commits reference one. Keep it distinct from the review agent (that reviews;
  this ships). Acceptance: full gate not a fast subset; base preview; passes
  ./scripts/validate-static. Branch, commit, open a PR.
  ```

- [ ] **review agent**

  ```text
  Build a Claude-native `review` agent in the agent-tooling repo that composes
  this repo's existing review skills. Read AGENTS.md, then INSPECT how the repo
  packages agents (check plugins/*/ for an agents/ convention or existing agent
  definitions; if none exists, propose the minimal placement and note it in the
  PR). The agent runs, in parallel over the working diff, the
  thermo-nuclear-code-quality-review skill (plugins/developer-workflows/skills/),
  a security review, and a correctness pass, then synthesizes ONE deduplicated,
  severity-ranked verdict. It is a reviewer only — it must not commit or open PRs
  (that is create-pr's job). Note in the PR that this is Claude-specific and a
  Codex equivalent is future work. Acceptance: composes the existing skills,
  parallel, one synthesized verdict; passes ./scripts/validate-static. Branch,
  commit, open a PR.
  ```

- [ ] **mcp-preflight**

  ```text
  Build the `mcp-preflight` skill in the agent-tooling repo. Read AGENTS.md and
  the env-topology skill for shape. Place it at plugins/developer-workflows/
  skills/mcp-preflight/SKILL.md. It inventories MCP servers that are connected
  but unauthenticated at session start and prints the EXACT reconnect action per
  connector and per client (e.g. the `claude mcp` command or `/command` for
  Claude Code, the equivalent for Codex), for the servers this owner uses
  (Sentry, Linear, Expo, Doppler, design). Verify how each client exposes MCP
  auth state before asserting commands — do not guess. Acceptance: lists
  unauthenticated MCPs with a correct, client-specific fix each; passes
  ./scripts/validate-static. Branch, commit, open a PR.
  ```

- [ ] **permission allowlist** (config, not a skill)

  ```text
  In the agent-tooling repo (and/or the appropriate project settings), reduce
  permission prompts by allowlisting these high-frequency safe commands: git, gh,
  npm, pnpm, deno, cp, sips, and `xcrun simctl list`/`xcrun simctl boot`. Prefer
  using the `fewer-permission-prompts` skill to scan real transcripts and produce
  a scoped allowlist; otherwise add them to the correct settings.json permissions
  block. Decide user-scope vs project-scope deliberately and explain the choice.
  Do not allowlist anything destructive. Open a PR if repo files change.
  ```

---

## Phase 3 — Batch 3 vendor adopts + Maestro

- [ ] **software-mansion-labs/skills** (install + Codex adapter)

  ```text
  In the agent-tooling repo: adopt the Software Mansion RN skills
  (github.com/software-mansion-labs/skills). FIRST confirm its LICENSE from the
  repo (the earlier check returned null). Find the correct install command from
  its README and install it. It ships Claude-only, so author a thin `.agents`
  Codex adapter so it works in Codex too, following AGENTS.md's adapter rules —
  without mirroring the upstream skill bodies into this repo. Record it as
  vendor-owned in docs/tooling-inventory.md and as profile checks with install
  recipes. Validate, branch, open a PR. Relevant sub-skills for this stack:
  animations (Reanimated 4), gestures, svg, multithreading/worklets, and
  enable-worklets-bundle-mode (the Uniwind x worklets Metro conflict).
  ```

- [ ] **callstackincubator/agent-skills** (install)

  ```text
  In the agent-tooling repo: adopt callstackincubator/agent-skills. Confirm its
  install command + LICENSE from the repo; it already ships dual .claude-plugin +
  .agents adapters, so both clients are covered — do not mirror source. Record as
  vendor-owned in docs/tooling-inventory.md + profile checks with install
  recipes. Validate, branch, open a PR.
  ```

- [ ] **Supabase agent skills** (install)

  ```text
  In the agent-tooling repo: install the official Supabase agent skills with
  `npx skills add supabase/agent-skills` (yields supabase +
  supabase-postgres-best-practices). Record as vendor-owned in
  docs/tooling-inventory.md + profile checks with the install command as recipe.
  Validate, branch, open a PR.
  ```

- [ ] **Shopify AI Toolkit storefront skills** (install, read-only subset)

  ```text
  In the agent-tooling repo: adopt ONLY the storefront read-skills from the
  Shopify AI Toolkit (github.com/Shopify/shopify-ai-toolkit) —
  shopify-storefront-graphql, shopify-custom-data, shopify-dev (optionally
  shopify-customer). Find the exact per-skill install syntax from its README
  (e.g. `npx skills add ... --skill <name>`). MUST: set OPT_OUT_INSTRUMENTATION=
  true before first use (it ships queries + code to shopify.dev by default), and
  do NOT install shopify-use-shopify-cli (store-write surface). This is for the
  Next.js headless storefront (always-wet-store), not a Shopify app. Record as
  vendor-owned + profile checks. Validate, branch, open a PR.
  ```

- [ ] **webapp-testing** (install)

  ```text
  In the agent-tooling repo: adopt the `webapp-testing` skill from
  anthropics/skills (Playwright visual-QA loop). Find its install command from
  the repo. Record as vendor-owned + a profile check. Validate, branch, open a PR.
  ```

- [ ] **frontend-design** (install)

  ```text
  In the agent-tooling repo: adopt the `frontend-design` skill from
  anthropics/skills. Find its install command from the repo. Record as
  vendor-owned + a profile check. Validate, branch, open a PR.
  ```

- [ ] **Maestro MCP** (wire)

  ```text
  In the agent-tooling repo: add the Maestro MCP server (stdio; it ships inside
  the Maestro CLI). Confirm the exact launch command from the official Maestro
  MCP docs, add it to plugins/mobile-development/.mcp.json (no secrets — it's
  local stdio), and add claude_mcp + codex_mcp profile checks with install
  recipes. Record in docs/tooling-inventory.md. Validate, branch, open a PR.
  ```

---

## Phase 4 — Batch 4 builds

- [ ] **sim-coldstart** — paste your parallel-sim / Metro-port docs into the chat before running this.

  ```text
  Build the `sim-coldstart` skill in the agent-tooling repo. Read AGENTS.md and
  the env-topology skill for shape; also read the parallel-sim/port docs I paste
  below. Place it at plugins/mobile-development/skills/sim-coldstart/SKILL.md.
  It is a client-aware iOS cold-start runbook: in Claude Code drive the
  ios-simulator-mcp; in Codex use build-ios-apps (XcodeBuildMCP) — one
  capability, two servers. Steps: select the iOS 26.5 runtime (iOS 27 crashes on
  launch via UIScene), boot, install the dev build, start Metro + sim-serve on
  NON-OVERLAPPING ports, verify local Supabase; support multiple simulators in
  parallel across worktrees using the port scheme in the pasted docs. Acceptance:
  passes ./scripts/validate-static; encodes the real port scheme, not an invented
  one. Branch, commit, open a PR.

  --- PARALLEL-SIM / PORT DOCS ---
  <paste here>
  ```

- [ ] **linear-manage**

  ```text
  Build the `linear-manage` skill in the agent-tooling repo. Read AGENTS.md, and
  the existing plugins/personal/skills/personal-task and personal-task-done
  skills plus the sim-qa skill so you CONSOLIDATE conventions rather than
  duplicate them. Place it at plugins/developer-workflows/skills/linear-manage/
  SKILL.md. It manages Linear DEV tasks on the connected Linear MCP:
  create/update/comment/triage/move-state/link-to-PR, using consistent
  label/status conventions. Saved-view creation (which the MCP can't do) is an
  optional browser-driven step, not the focus. Acceptance: passes
  ./scripts/validate-static; no overlap/conflict with the personal-task skills.
  Branch, commit, open a PR.
  ```

---

## Personal track (build, any time)

All live in `plugins/personal/`. Each prompt should read `AGENTS.md` and the
existing `plugins/personal/skills/` (obsidian-vault, personal-task,
dad-daily-update) for shape and voice, and be written in capability terms so it
works in both clients.

- [ ] **ticktick-capture**

  ```text
  Build the `ticktick-capture` skill in plugins/personal/skills/ of the
  agent-tooling repo. Read AGENTS.md and the existing personal skills for shape.
  It does natural-language quick-add into TickTick, routed to the right
  project/tag/date/priority, discovering the user's TickTick lists/tags at
  runtime (don't hardcode). Acceptance: passes ./scripts/validate-static. Branch,
  commit, open a PR.
  ```

- [ ] **email-triage**

  ```text
  Build the `email-triage` skill in plugins/personal/skills/ of agent-tooling.
  Read AGENTS.md + existing personal skills. It sweeps unread Gmail, summarizes,
  proposes+applies labels (including sensitive labels for private mail), and per
  thread picks an action: draft a reply, suggest archive, or spin a task. HARD
  SAFETY RULE it must encode: DRAFT ONLY — never send; sending stays a manual
  user action. Acceptance: passes ./scripts/validate-static; never sends. Branch,
  open a PR.
  ```

- [ ] **weekly-review**

  ```text
  Build the `weekly-review` skill in plugins/personal/skills/ of agent-tooling.
  Read AGENTS.md + existing personal skills. It pulls the week from TickTick
  (done/overdue/upcoming + habit streaks), Linear (assignee:me + personal),
  Obsidian (open task notes), and Raindrop (unsorted), then writes a review note
  into the vault. Acceptance: passes ./scripts/validate-static. Branch, open a PR.
  ```

- [ ] **daily-plan**

  ```text
  Build the `daily-plan` skill in plugins/personal/skills/ of agent-tooling. Read
  AGENTS.md + existing personal skills. It assembles today's plan from TickTick
  due-today + Linear personal, helps pick + time-block, and optionally starts a
  focus session. It COMPOSES WITH, and does not duplicate, the built-in `morning`
  brief. Use TickTick due dates as the schedule source (no calendar connector
  today). Acceptance: passes ./scripts/validate-static. Branch, open a PR.
  ```

- [ ] **raindrop-tidy**

  ```text
  Build the `raindrop-tidy` skill in plugins/personal/skills/ of agent-tooling.
  Read AGENTS.md + existing personal skills. It runs the connector's
  find_misplaced_bookmarks + find_mistagged_bookmarks, proposes fixes, refiles
  into collections, and normalizes tags. Acceptance: passes
  ./scripts/validate-static. Branch, open a PR.
  ```

- [ ] **read-later-digest**

  ```text
  Build the `read-later-digest` skill in plugins/personal/skills/ of
  agent-tooling. Read AGENTS.md + existing personal skills. It pulls recent /
  unsorted Raindrop bookmarks, fetches content, summarizes + surfaces highlights,
  and for keepers creates an Obsidian note or a TickTick "read" task. Acceptance:
  passes ./scripts/validate-static. Branch, open a PR.
  ```

- [ ] **imessage-catchup**

  ```text
  Build the `imessage-catchup` skill in plugins/personal/skills/ of agent-tooling.
  Read AGENTS.md + existing personal skills. It summarizes unread iMessages
  grouped by contact, flags who is awaiting a reply, and optionally drafts
  replies. HARD SAFETY RULES it must encode: send ONLY on explicit per-message
  user confirmation; NEVER paste message contents into notes/reports/summaries —
  summarize only. Acceptance: passes ./scripts/validate-static. Branch, open a PR.
  ```

- [ ] **habit-review**

  ```text
  Build the `habit-review` skill in plugins/personal/skills/ of agent-tooling.
  Read AGENTS.md + existing personal skills. It checks in on TickTick habits,
  logs check-ins, and gives a weekly streak summary + nudge, discovering the
  user's habit set at runtime. Acceptance: passes ./scripts/validate-static.
  Branch, open a PR.
  ```

- [ ] **personal-journal**

  ```text
  Build the `personal-journal` skill in plugins/personal/skills/ of agent-tooling.
  Read AGENTS.md and especially the dad-daily-update skill (reuse its
  question/voice pattern). It runs a short self-facing reflection Q&A and writes a
  daily note into the Obsidian `Personal/` tree (a note, not a message).
  Acceptance: passes ./scripts/validate-static. Branch, open a PR.
  ```

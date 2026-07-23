# Build prompts — one per item

A copy-paste prompt for every approved tooling item. Work them one at a time:
open a **fresh AI coding chat in the `agent-tooling` repo root**, paste the
item's prompt block, let it build → validate → open a PR, then check the box
here.

(`env-topology` and `scripts/setup` already shipped in #26 and are not listed
below.)

## Driver prompt — paste this into each new session

Instead of copying individual blocks, paste this once per session and it picks
up the next item:

```text
You are helping roll out tooling in the agent-tooling repo. Start on the latest
main (git checkout main && git pull). Open docs/build-prompts.md and find the
FIRST unchecked item — a line starting with "- [ ]". Do EXACTLY that one item,
following the copy-paste prompt block beneath it and the repo conventions in
AGENTS.md (portable Claude Code + Codex, no hard-coded client paths; validate
with ./scripts/validate-static).

- Build item (skill/agent): build it, validate, then change its "- [ ]" to
  "- [x]" in docs/build-prompts.md, commit on a new branch, and open a PR to main.
- Install item: run the install, record it in the right profile +
  docs/tooling-inventory.md, check its box, commit + PR.
- Connector item needing a token mint or OAuth click: do the parts you can
  (write config, add profile checks), then STOP and print the exact human steps
  I must take. Do NOT check the box or claim it done until I confirm.

Do ONE item only. If the first unchecked item is blocked on a human step I
haven't done yet, say so and either wait or move to the next item if I tell you
to. End by reporting which item you did, the PR link, and anything I need to do
by hand.
```

To target a specific item instead, append: "Skip to the `<name>` item."

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

- [ ] **Sentry MCP** — DECIDED: stdio `@sentry/mcp-server` + `SENTRY_ACCESS_TOKEN`
  via Doppler. Research confirmed the claude.ai "Web" connector works in Claude
  Code CLI only under an active subscription login (not with an API key /
  setup-token) and can never re-auth headlessly — that is the ~52-session
  re-auth wall — and you already run `disableClaudeAiConnectors: true`, so it is
  off in your CLI today. stdio is the only headless-safe, cross-client (Claude
  Code + Codex), no-re-auth option; keep `disableClaudeAiConnectors: true` so the
  stdio server doesn't collide with a duplicate OAuth connector. Human step
  first: mint a Sentry User Auth Token (scopes `org:read, project:read,
  project:write, team:read, team:write, event:write`) and set it into Doppler:
  `doppler secrets set SENTRY_ACCESS_TOKEN --project agent-tooling --config prd`.
  Then the wire prompt:

  ```text
  In the agent-tooling repo, add a Sentry MCP server to
  plugins/mobile-development/.mcp.json using the EXISTING heroui-native-pro block
  in that file as the exact pattern: launch @sentry/mcp-server (stdio) with its
  access token injected at runtime via `doppler run --project agent-tooling
  --config prd --only-secrets SENTRY_ACCESS_TOKEN --no-fallback --command "exec
  npx -y @sentry/mcp-server@latest --access-token=$SENTRY_ACCESS_TOKEN"`. Verify
  the exact server package, flag, and required scopes against the official Sentry
  MCP docs first; never commit the token. Add matching claude_mcp + codex_mcp
  checks (with install recipes) to profiles/base-workstation.json and record the
  server in docs/tooling-inventory.md. Validate with ./scripts/validate-static,
  then branch and open a PR to main.
  ```

- [ ] **Expo MCP (both clients)** — already added to Claude (`claude mcp list`
  shows it "Needs authentication" → click OAuth in the app once). Then:
  - Codex: run `codex mcp add expo --url https://mcp.expo.dev/mcp` and OAuth once.
  - Wire prompt:

  ```text
  In the agent-tooling repo, add claude_mcp + codex_mcp checks for the Expo MCP
  server "expo" (https://mcp.expo.dev/mcp) to profiles/base-workstation.json,
  each with an install recipe (`claude mcp add --transport http expo <url>` /
  `codex mcp add expo --url <url>`) and a manual_checks note that first use needs
  browser OAuth per client. Record it in docs/tooling-inventory.md, noting it is
  OAuth-only with no CI/headless fallback. Validate with ./scripts/validate-static,
  branch, open a PR.
  ```

- [ ] **expo/skills subset** — install + record:

  ```text
  In the agent-tooling repo: install the official Expo skill collection with
  `npx skills add expo/skills`, then confirm which of these are present and
  useful — expo-router, expo-module, expo-tailwind-setup, expo-upgrade,
  eas-app-stores, eas-workflows, eas-observe, eas-simulator, expo-examples.
  Do NOT mirror the skill source into this repo. Record the desired subset as
  path checks (on the installed SKILL.md locations) with the `npx skills add`
  command as their install recipe in the appropriate profile, and list them in
  docs/tooling-inventory.md as vendor-owned. Validate, branch, open a PR.
  ```

---

## Phase 2 — Batch 2 workflow core (build)

- [ ] **doppler-cli-skill**

  ```text
  Build the `doppler-cli-skill` skill in the agent-tooling repo. Read AGENTS.md,
  docs/tooling-rollout-plan.md, and plugins/developer-workflows/skills/
  env-topology/SKILL.md first (this skill is env-topology's live companion).
  Place it at plugins/developer-workflows/skills/doppler-cli-skill/SKILL.md.
  It teaches an agent to answer env/secret-placement questions LIVE via the
  Doppler CLI (names only) in contexts where the Doppler MCP is not loaded
  (CI, headless, Codex): `doppler projects --json`, `doppler configs --project
  <p> --json`, `doppler secrets --only-names --project <p> --config <c>`. Hard
  rule the skill must enforce: NEVER print secret values — names only, always
  `--only-names`. Confirm the real project/config names by running the commands
  yourself while authoring. Acceptance: passes ./scripts/validate-static; never
  emits values. Branch claude/doppler-cli-skill, commit, open a PR to main.
  ```

- [ ] **worktree-bootstrap**

  ```text
  Build the `worktree-bootstrap` skill in the agent-tooling repo. Read AGENTS.md,
  docs/tooling-rollout-plan.md, and the env-topology skill (for env
  materialization facts). Place it at plugins/developer-workflows/skills/
  worktree-bootstrap/SKILL.md. On a fresh git worktree it: (1) detects the
  package manager PER DIRECTORY from the corepack `packageManager` field /
  lockfile — PUMPD mobile = npm (npm@10.9.3), PUMPD backend = pnpm, Supabase edge
  = deno — and runs the correct install; (2) materializes env the correct way,
  NOT a blind .env copy: mobile via `eas env:pull` for the mapped environment,
  backend/others via `doppler run`, edge via deno; (3) runs patch-package where a
  patches/ dir exists. Acceptance: chooses npm for mobile / pnpm for backend /
  deno for edge; passes ./scripts/validate-static. Branch, commit, open a PR.
  ```

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

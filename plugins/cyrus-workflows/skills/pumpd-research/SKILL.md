---
name: pumpd-research
description: >-
  Investigate and scope a PUMPD feature idea BEFORE planning. Explores the
  mobile app (apps/mobile, React Native/Expo) and the Supabase backend (apps/backend), the web (libraries/SDKs/docs), and the Obsidian vault;
  reads the in-repo constitution; asks clarifying questions one at a time;
  proposes 2-3 approaches with trade-offs; then writes a research note to the
  vault. Use when the user wants to think through a new feature or large piece
  of work (e.g. "add Sentry to the mobile app", "redo onboarding"). This is the
  GATE before /pumpd-plan — do not write a plan or code until research is done
  and an approach is chosen.
---

# /pumpd-research — investigate a PUMPD feature

Stage 1 of the PUMPD planning pipeline: **research → plan → review → decompose → Cyrus**.
Turns a rough idea into a researched, decision-bearing note that `/pumpd-plan` can build on.

## Scope — mobile + backend
**This workflow targets two surfaces of the `pumpd-mobile-app` monorepo:** the **React Native / Expo app (`apps/mobile`)** and the **Supabase backend (`apps/backend`** — Deno edge functions, Postgres migrations, RLS). Research, plan, and decompose stay within `apps/mobile`, `apps/backend`, and the shared `packages/*` they use. Do **not** plan changes to the other apps — `apps/admin` (Next.js), `apps/website`, `apps/catalog`, `apps/docs`. If a feature needs one of those, **flag it as an out-of-scope dependency**.

## Hard gate (non-negotiable)
Do **not** write implementation code, scaffold anything, or jump to `/pumpd-plan` until you have (a) explored the relevant code, (b) researched externally, (c) asked the clarifying questions, and (d) gotten the user to pick an approach. This holds *regardless of how simple the idea seems*.

## "Too big" check (do this first)
If the idea spans **multiple independent subsystems** (e.g. "rebuild stats + add social feed + new onboarding"), stop and say so. Split it into independent sub-features, identify build order, and research **only the first** through this skill. Each sub-feature gets its own research → plan → decompose cycle.

## Inputs
- A rough idea from chat, Linear, or an existing `PUMPD/Research/<Topic>.md` note.
- Repo: the **`apps/mobile`** React Native / Expo app of the `pumpd-mobile-app` monorepo. **Find it:** use the current working directory when it contains `apps/mobile`; otherwise locate the checkout with the workspace tools available in the active client. **In scope:** `apps/mobile` (RN/Expo) + `apps/backend` (Supabase/Deno) + the shared `packages/*` they import. **Out of scope:** `apps/admin` (Next.js), `apps/website`, `apps/catalog`, `apps/docs`.
- Vault: use the connected Obsidian capability when available; otherwise use `$OBSIDIAN_VAULT` or ask once for the vault root. The project root inside the vault is `PUMPD/`.

## Steps
1. **Locate the idea.** Preserve the user's raw wording in the research note. Do not create a separate Obsidian backlog item: Linear owns ideas and task state. If the user only wants capture and is not ready to investigate, use Linear or `00 Inbox/` when Linear is unavailable.
2. **Explore the relevant surface(s).** Find prior art and what already exists (often more than expected) in **`apps/mobile`** (features/screens/stores/components) and/or **`apps/backend`** (edge functions/migrations/RLS) — whichever the feature touches — plus shared `packages/*`. Use a read-only code-search capability or a delegated explorer when available, scoped to those dirs. Note files as `path:line`. Don't roam into `apps/admin` / `apps/website` / `apps/catalog` / `apps/docs`.
3. **Read the constitution — per surface.** `AGENTS.md` + the rules for the surface(s) you're touching: **mobile** → `.claude/rules/mobile-*.md` (screens, components, forms, api-layer, stores, styling, testing); **backend** → `.claude/rules/backend-edge-functions.md` + `shared-types.md` + `apps/backend/AGENTS.md`/`CLAUDE.md`; plus `branching-first-architecture`. Constraints, not suggestions — base branch `preview`, Conventional Commits, `pnpm --dir apps/<surface> quality` is the gate, package boundaries hold.
4. **Research externally — exhaustive and recent.** Identify **every** technology involved (an integration has ≥2 sides — e.g. Sentry + React Native + Expo). **Match the surface's stack** — for `apps/mobile` prefer the **React Native / Expo** variant of a library/SDK (not its web/Next.js form); for `apps/backend` it's **Supabase + Deno** (edge functions, Postgres). For each:
   - **Official docs — deep read.** Open the canonical docs site for each tech and read the relevant sections thoroughly (e.g. Sentry's React-Native guide **and** the React Native / Expo docs themselves) — not just a search snippet. Capture the exact deep-link URLs you actually used.
   - **Recently-active GitHub (last 6 months).** Find real-world repos and example integrations that are **actively maintained — activity (a commit/push) in the last 6 months**, not abandoned. Use `gh search repos "<topic>" --sort updated` and the **`pushed:>YYYY-MM-DD`** qualifier set to **today minus 6 months** — `pushed:` filters by **last activity**, NOT `created:` (repo age). Also `gh search code "<import/api>"`. Note the integration patterns and which **versions** they pin. Prefer repos active in the last 6 months; treat ones with no activity in >1 year as possibly stale and verify before relying on them.
   - **Announcements / changelogs / releases.** Check the SDK's recent releases, migration guides, deprecations, and official blog/announcement posts so the plan targets the **current** API, not an old one.
   - Use a version-aware documentation capability such as Context7 when available; otherwise use the official versioned docs.
   - **Cite everything.** Every finding gets a **direct URL** (deep link to the specific page/section/repo file), with the library **version** where relevant. No claim without a source. Use parallel independent research only when the active client supports it.
5. **Check the vault** (`PUMPD/Research`, `PUMPD/Plans`, `PUMPD/AI Tooling`) so you build on prior decisions and don't duplicate. Search Archive only when historical context is necessary. Cross-link with `[[wikilinks]]`.
6. **Clarify — one question at a time.** Use the active client's structured question capability when available. Ask the *fewest* questions that actually change the approach (scope boundaries, PII/security, which surface — mobile and/or backend — and area, must-have vs later). Don't batch a wall of questions.
7. **Propose 2-3 approaches** with explicit trade-offs (a small table). Recommend one. Get the user to choose.
8. **Write the research note** to `PUMPD/Research/<Topic>.md`. Use a short noun-first filename with no `Research` or `Investigation` suffix. Include: Idea, Codebase findings, External research (every claim with a **direct URL**), Constraints, Approaches considered, **Decision + why**, a consolidated **Sources** list, and Open questions. Frontmatter: `type: research`, `status: draft`, tags `[pumpd, research, <domain>]`. These sources must survive when `/pumpd-plan` promotes the note.
9. **Hand off.** Tell the user the research is ready and offer to run `/pumpd-plan` (which will read this note).

## Output
A single research note in `PUMPD/Research/`, cross-linked, with a clear chosen approach. Show `git -C <vault> status --short` after writing. Do not commit unless asked.

## Style
Match the vault's existing planning notes: section headings + "Decision | Why" tables, explicit Non-Goals, cite `path:line` and URLs. Be concrete, not narrative-blobby.

## Finish — offer the next step
End your reply with a clear, copy-pasteable handoff:
> ▶ **Next:** `/pumpd-plan` — turn this research into the canonical plan.

(If you split a "too big" idea, point to the first sub-feature instead. If the user wants to stop, respect that — don't push.)

---
**Log learnings as you go.** If a step here was wrong, ambiguous, slow, or could be better, drop a quick `/log-learning` note (it feeds `/pumpd-retro`) before moving on.

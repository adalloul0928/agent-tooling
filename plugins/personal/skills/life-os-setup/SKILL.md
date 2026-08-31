---
name: life-os-setup
description: >-
  Set up, diagnose, or repair Aren's local-first Personal AI / Life OS, including its ledger, policy, voice artifacts, TickTick, Gmail, iMessage, Obsidian, Oura, Apple Health export, Tailscale, and schedules. Use when Aren says "set up my Life OS", "finish the Life OS", "Life OS doctor", or asks why a Life OS connector is unavailable. Do not use for an ordinary daily or weekly review.
---

# Life OS Setup

Bring the personal operating system to an evidenced, usable state without placing OAuth state, private message content, or machine-specific credentials in the plugin or vault.

Before acting, read `../../runtime/references/workflow-contract.md` and use the bundled runtime described in `../../runtime/README.md`.

## Step 1 — inspect before changing

Run `lifeos init`, then `lifeos doctor`. Report every connector as one of:

- ready and behaviorally verified;
- installed but awaiting authentication;
- blocked by a macOS privacy permission;
- optional and not configured;
- failing with the exact observed error.

Do not call an empty or inaccessible source "no items."

## Step 2 — establish connector paths

Use the official or already-selected path for each authority:

- TickTick: official TickTick CLI with browser OAuth; discover projects and tags at runtime.
- Gmail: official Gmail plugin and account connector; use its existing inbox and draft capabilities rather than copying them.
- iMessage: signed `imsg` CLI; Full Disk Access for reads and Messages Automation only for confirmed sends. SIP-disabled advanced features are not required.
- Obsidian: the existing vault skill and configured local clone.
- Oura: OAuth2 with the minimum `daily` scope; register the configured loopback redirect, pipe the client secret to `lifeos oura-authorize --client-id ...`, and keep secrets and refresh tokens in Keychain.
- Apple Health: a deliberately limited Health Auto Export v2 JSON automation to iCloud Drive; scan and ingest read-only with `lifeos health-scan`. Configure only `sleep_analysis`, `step_count`, `active_energy`, `resting_heart_rate`, `heart_rate_variability_sdnn`, and workouts without routes. The runtime allowlist rejects other exported categories.
- Remote access: Tailscale only. Never make a public Funnel or equivalent exposure.

Account authorization and macOS privacy prompts require Aren to complete the provider or System Settings screen. Open only the exact screen or URL needed, then re-run the behavioral canary.

## Step 3 — initialize personal artifacts

Verify the machine-local runtime contains:

- a SQLite ledger with schema version and WAL enabled;
- `policy.json` with automatic, confirm, and never action classes;
- `SOUL.md` for assistant behavior;
- `voice-profile.md` for writing as Aren;
- a health inbox and designated Obsidian write roots.

Do not populate the voice profile from unbounded history. Use a representative, reviewed sample and corrections through the voice skill.

## Step 4 — prove each integration

Canary with the smallest safe operation:

1. TickTick: list projects and open tasks; ensure `AI Follow-ups` only after confirmation if it does not exist.
2. Gmail: search one bounded recent window and create no mutations.
3. iMessage: list one chat, then read a bounded recent window without writing bodies to the ledger.
4. Obsidian: resolve the vault and write only a temporary test note inside a designated Life OS root; remove it only if Aren explicitly authorizes deletion, otherwise archive or leave it clearly marked.
5. Oura: retrieve a bounded daily range.
6. Apple Health: run `lifeos health-scan` against the configured local/iCloud inbox and ingest one real deliberately limited JSON v2 export. A fixture proves parsing only and must not be reported as a live connector canary.
7. Tailscale: verify tailnet status without exposing a public endpoint.

Installation is not proof. Authentication is not proof. A connector is ready only after its behavior succeeds.

## Step 5 — verify scheduling prerequisites

Test each workflow manually before scheduling it. Scheduled tasks that need local files must run in the local `agent-tooling` project with the Mac on and the desktop app running. Use the narrowest access that succeeds. Confirm recent run history after the first execution.

## Completion report

Return a readiness matrix, the canary evidence, every remaining human gate, and the precise next action. Never claim the full Life OS is operational while a required authority cannot be read.

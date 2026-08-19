---
name: ios-session-lanes
description: >-
  Set up, operate, diagnose, or test isolated PUMPD iOS development lanes for
  concurrent Claude and Codex sessions. Use when an agent needs Metro, an iOS
  Simulator, a local development binary, SimView, agent-device, Maestro,
  Tailscale, EAS environment bootstrap, Doppler, or shared local Supabase in a
  PUMPD worktree. Do not use for ordinary React Native advice that does not
  launch or control the PUMPD app.
---

# iOS session lanes

Use the user-installed lane commands for every PUMPD iOS launch. Never start
Expo, mutate a simulator, select an unscoped controller, or start or stop local
Supabase directly from an agent session.

## Required flow

1. A new worktree is bootstrapped separately with `ios-session-bootstrap`.
   This installs the pinned pnpm dependencies, pulls the mobile development
   environment from EAS into the ignored mobile environment file, validates
   Doppler secret-name access without writing Doppler values, and records a
   secret-free receipt.
2. Start or reconnect the current chat with
   `ios-session-lane up --client <claude|codex> --session-id <session-id>`.
3. Read the returned Metro port and simulator UDID. Never substitute another
   booted simulator.
4. Use `ios-session-lane control ... -- <agent-device args>` for exploratory
   input. Use SimView only for observation. Acquire the Maestro controller lease
   for deterministic flows and proof.
5. Run `ios-session-lane doctor ...` before claiming lane validation.
6. Release with `ios-session-lane down ...`; abandoned lanes are handled by
   `ios-session-lane reap`.

The lane computes Expo's iOS native fingerprint. A matching installed or cached
`.app` is reused for JavaScript-only changes. A fingerprint miss triggers a
local Xcode simulator build. It never submits an EAS development build.

Local Supabase is one shared backend with one lifecycle owner. Ordinary lanes
only consume a compatible running stack. `backend-up` and `backend-down` are
owner-gated; resets additionally require the writer lease, an explicit shared
reset acknowledgement, and zero other consumers.

Physical lanes are explicit with `--target physical:arens-iphone-pro`. They use
remote development Supabase and Tailscale. If the phone is not locally
reachable, the command reports that condition and falls back to a simulator.
Physical-device proof remains a joint user and agent test; no cloud EAS build is
a fallback.

Read [references/workflow.md](references/workflow.md) for the operating model,
controller choices, recovery, and test matrix.

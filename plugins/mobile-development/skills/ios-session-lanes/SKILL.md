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

## Choose the lane with the user

Before the first `up` in a task, check `ios-session-lane status` for this
client/session. Reconnect without asking if a lane already exists. If the user
already specified the device, backend, and network choices, honor them without
asking again. Otherwise ask one compact question using the client's interactive
question UI when available:

1. **Simulator + Local (Recommended)** — isolated simulator and Metro, shared
   local Supabase, no Tailscale. Preset: `simulator-local`.
2. **Simulator + Preview** — isolated simulator and Metro, hosted Preview
   Supabase, no Tailscale. Preset: `simulator-preview`.
3. **Physical iPhone** — Aren's iPhone, hosted Preview Supabase, Tailscale.
   Preset: `iphone-preview`.

Allow a free-form custom answer for other combinations. A custom lane must
explicitly set `--target`, `--backend`, and `--expose`. For example, a simulator
using Preview through a Tailscale Metro URL can use the
`simulator-preview-tailscale` preset.

Do not silently create a lane from implicit defaults. If the user says “use the
defaults,” select `simulator-local`. The CLI requires an explicit preset or all
three custom choices, so an overlooked question fails safely.

Keep two secondary defaults automatic unless the task makes them relevant:

- native binary policy is compatible reuse, then local Xcode build on a
  fingerprint miss; ask about `--build` only when a forced rebuild matters;
- `agent-device` is the default input writer; switch to Maestro, Argent, or
  XcodeBuildMCP only when the requested test requires it. SimView stays
  observation-only.

## Required flow

1. A new worktree is bootstrapped separately with `ios-session-bootstrap`.
   This installs the pinned pnpm dependencies, pulls the mobile development
   environment from EAS into the ignored mobile environment file, validates
   Doppler secret-name access without writing Doppler values, and records a
   secret-free receipt. `ios-session-worktree` starts from freshly fetched
   `origin/preview` by default. When a task must start from a long-lived remote
   integration branch, pass its exact `origin/<branch>` name with `--base-ref`;
   local refs, raw SHAs, other remotes, and stale fallbacks are refused.
2. Confirm the lane choice, then start the current chat with
   `ios-session-lane up --client <claude|codex> --session-id <session-id>
   --preset <preset>`. A later `up` for the same lane reuses its recorded choices
   and does not need `--preset` again.
3. Read the returned Metro port and simulator UDID. Never substitute another
   booted simulator.
4. Use `ios-session-lane control ... -- <agent-device args>` for exploratory
   input. Use SimView only for observation. Acquire the Maestro controller lease
   for deterministic flows and proof.
5. Run `ios-session-lane doctor ...` before claiming lane validation.
6. Release with `ios-session-lane down ...`; `ios-session-lane reap` removes
   only stale metadata after its owned runtime is already dead.

The lane combines Expo's iOS native fingerprint with the Xcode version and host
architecture. A matching installed or cached generic-simulator `.app` is reused
for JavaScript-only changes and installed into the assigned UDID. A cache-key
miss triggers one serialized local Xcode build. It never submits an EAS
development build.

Local Supabase is one shared backend with one lifecycle owner. Ordinary lanes
only consume a compatible running stack. `backend-up` and `backend-down` are
owner-gated; resets additionally require the writer lease, an explicit shared
reset acknowledgement, and zero other consumers.

Physical lanes are explicit with the `iphone-preview` preset or custom target
`physical:arens-iphone-pro`. They use Preview Supabase and Tailscale. If the
phone is not locally reachable, the command reports that condition and falls
back to a simulator. Physical-device proof remains a joint user and agent test;
no cloud EAS build is a fallback.

Read [references/workflow.md](references/workflow.md) for the operating model,
controller choices, recovery, and test matrix.

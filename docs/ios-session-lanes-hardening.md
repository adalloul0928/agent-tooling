# iOS session lanes hardening summary

Status: extended with the lane suite validated on `codex/ios-lanes-base-ref`
Repository: `agent-tooling` only
Base: `origin/codex/ios-lanes-hardening` at `baec188`
Updated: 2026-09-03 (America/Los_Angeles)

## Goal

Give every Claude Code or Codex session that works on PUMPD iOS an owned lane
instead of letting agents share or guess at Metro, Simulator, controller, build,
backend, or Tailscale state. Keep this machine-specific workflow out of the
shared PUMPD application repository.

```text
managed worktree
      |
      +-- separate bootstrap --> pinned pnpm + EAS mobile env + Doppler validation
      |
client session hook
      |
      +-- asks once for target/backend/exposure
      |
owned lane registry
      +-- Metro port 8081-8119
      +-- one PUMPD Agent Lane simulator (or the named physical iPhone)
      +-- native binary/cache decision
      +-- controller lease and rendered proof
      +-- shared-local or Preview Supabase
      `-- optional exact-port Tailscale Serve HTTPS proxy
```

## What this branch implements

- A portable `mobile-development:ios-session-lanes` skill plus native Claude
  and Codex hooks. SessionStart checks bootstrap and injects lane context,
  UserPromptSubmit refreshes the heartbeat, PreToolUse blocks raw conflicting
  commands, and SessionEnd releases only the current session's resources.
- `ios-session-worktree` creates an attested worktree and runs the separate,
  idempotent bootstrap. Bootstrap pins the configured pnpm and EAS CLI versions,
  pulls the mobile development environment into ignored
  `apps/mobile/.env.local`, validates every locally referenced Doppler name
  without printing values, and writes a secret-free private receipt.
- Worktree creation defaults to a freshly fetched `origin/preview` and accepts
  an explicit long-lived integration branch only as a validated
  `--base-ref origin/<branch>`. The wrapper resolves that remote-tracking ref
  once, creates from the immutable commit, records ref plus SHA in its private
  attestation and receipt, and rejects stale fallback or caller-supplied SHAs.
- One machine-global, clone-stable lane registry with atomic lifecycle, target,
  native-build, controller, backend, and Tailscale locks. A lane receives a
  unique Metro port and the lowest eligible simulator from
  `PUMPD Agent Lane 1` through `PUMPD Agent Lane 6`. It never deletes, erases,
  or broadly shuts down simulators.
- User-facing presets for simulator/local backend, simulator/Preview,
  simulator/Preview/Tailscale, and physical-iPhone/Preview/Tailscale. The skill
  asks once when no choice exists and reconnects an existing lane without
  asking again.
- Native reuse keyed by Expo's iOS fingerprint, Xcode version, host
  architecture, and a complete app-bundle digest. JavaScript-only work reuses
  an installed or shared cached generic-simulator app; a cache miss produces
  one serialized local Xcode build. No EAS development build is submitted.
- Explicit physical-device policy. The named iPhone is an exclusive lane and
  uses Preview plus Tailscale. If it is unreachable, or a new native binary is
  required without a locally attached device and explicit acknowledgement, the
  agent reports that and uses the simulator path instead of EAS.
- Loopback-only Metro and an optional lane-owned Tailscale Serve HTTPS mapping.
  Allocation inventories machine-global Serve configuration, skips occupied
  HTTPS ports, rechecks under a global operation lock, and will not overwrite
  or tear down another mapping.
- A guarded shared-local Supabase model with one lifecycle owner and compatible
  consumers. Reset requires the exact owner mount, writer lease, acknowledgement,
  and zero other consumers; ownership is re-attested before media publication.
  Preview remains the alternative. Doppler values stay runtime-only.
- Agent-device as the default writer, SimView as observation-only, and explicit
  leases for Maestro, Argent, or Xcode control. Render evidence must come from
  the assigned app, assigned Metro lane, and a fresh stable screenshot/snapshot.
- A separately installed stable command runtime with transactional v3
  integrity, exact rollback, retained recovery backups, strict legacy migration,
  and a mutation-free `--check` that proves the installed tree and wrappers
  match the current plugin revision.

## Review-driven hardening

The final audit found and fixed issues that ordinary happy-path tests did not
cover: dead Metro leaders with live owned children, installer path-swap deletion,
Tailscale Serve port replacement, harmless shell-inspection false positives,
post-reset backend mount replacement, incomplete Doppler preflight, stale
self-signed runtime manifests, wrapper symlink swaps, and generated-adapter
drift after the canonical plugin-manifest migration. The integration-base
extension also hardened the leader-exit cleanup transition: transient process
group membership is retried, but a group signal still requires exact ownership
proof and completion still requires an observed-empty process group.

The runtime fails closed when ownership or identity cannot be proved. Stale
reaping removes only dead metadata; it never kills a live lane. Successful
runtime refreshes retain prior-install backups until the operator removes the
reported paths after a canary.

## Verification

- Complete iOS lane Node suite: 103/103 passed.
- Runtime process-group and Tailscale lifecycle regressions: passed.
- Installer/hook security and read-only integrity regressions: passed.
- Backend ownership, environment, and bootstrap regressions: passed.
- Static Python/profile tests, plugin adapter generation, and isolated
  native-client installs: passed.
- `scripts/validate` and `scripts/release-check` currently stop at their
  prerequisite gate because this host does not have the external `agentskills`
  command. Rerun both unchanged in the release environment before publication.
- No live Metro server, simulator, physical device, Docker/Supabase stack, or
  Tailscale Serve mapping was mutated by the final review tests.

Physical-iPhone behavior remains the one intentionally joint test. Simulator
success does not claim physical-device success.

## Rollout

After this branch is selected for local use or lands on the marketplace ref:

1. Refresh `mobile-development` in both Claude and Codex from the same
   `agent-tooling` revision.
2. Run `./scripts/setup base-workstation --apply`, or invoke the runtime
   installer directly from that checkout.
3. Require
   `node plugins/mobile-development/skills/ios-session-lanes/scripts/install-runtime.mjs --check`
   to return `status: "ok"`.
4. Start fresh client sessions and confirm the four hook stages are enabled.
5. Run the two-simulator canary, then complete the physical-iPhone/Tailscale
   canary jointly.

The full operating contract and command reference live in
`plugins/mobile-development/skills/ios-session-lanes/references/workflow.md`.

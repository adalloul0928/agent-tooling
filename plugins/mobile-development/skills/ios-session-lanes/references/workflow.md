# PUMPD iOS session lanes

## What owns the workflow

The implementation lives in the user-installed `mobile-development` plugin in
`agent-tooling`. It does not add scripts, hooks, simulator names, or policy to
the shared PUMPD repository.

Installing the plugin gives Claude and Codex the skill plus client-native hooks.
The runtime installer separately copies stable command implementations into:

```text
~/Library/Application Support/agent-tooling/ios-session-lanes/runtime
```

It installs these user commands in `~/.local/bin`:

```text
ios-session-worktree
ios-session-bootstrap
ios-session-lane
```

The project profile recognizes PUMPD by its Git origin and required files.
Hooks are silent in every other repository.

## Installation

After installing or refreshing the `mobile-development` plugin, run the runtime
installer from the same `agent-tooling` revision:

```bash
node plugins/mobile-development/skills/ios-session-lanes/scripts/install-runtime.mjs
```

Verify that the installed runtime and all three wrappers still match that
plugin revision without changing the filesystem:

```bash
node plugins/mobile-development/skills/ios-session-lanes/scripts/install-runtime.mjs \
  --check
```

Check mode accepts only `--runtime-root` and `--bin-dir` path overrides. It
does not acquire the installer lock, create recovery files, or read or change
client hook settings. It prints one compact JSON status and exits nonzero when
the runtime, wrappers, or current plugin payload differ.

Every refresh verifies integrity schema v3, including regular-file hashes,
file and directory modes, empty directories, and wrapper mode `0755`. Existing
runtime, wrapper, and requested hook-settings targets are moved to unique
sibling backups rather than recursively deleted. The successful JSON result
lists them in `recoveryBackups`; retain those reported paths until the refreshed
runtime has been exercised, then remove them manually when recovery is no
longer needed. A failed transaction moves its promoted files or runtime to
reported `failed-install` recovery paths before restoring the exact prior
installation. Any unpromoted staging path is atomically retained as a reported
`abandoned-stage` recovery copy; the installer never recursively deletes a
path that another process could have replaced during failure cleanup.

The migration switch is never implicit. Use it only when upgrading the original
unmarked runtime at the exact default path shown above:

```bash
node plugins/mobile-development/skills/ios-session-lanes/scripts/install-runtime.mjs \
  --migrate-legacy-runtime
```

Migration refuses custom runtime roots, symbolic links, unknown or missing
legacy runtime files, or changed managed wrappers, and requires the three exact
legacy wrappers in `~/.local/bin`. It leaves unrelated commands in that
directory alone. It moves the old runtime and wrappers to unique
sibling `legacy-backup` paths before installing. A successful command reports
every retained legacy backup path in `legacyMigration` and all prior-install
backups in `recoveryBackups`; keep those paths until the new runtime has been
verified. Any installation failure restores the original
runtime, wrappers, and optional hook settings exactly. Re-running the same
command after a successful migration is safe and reports `already-current`
without creating another legacy backup set.

Run `node plugins/mobile-development/skills/ios-session-lanes/scripts/install-runtime.mjs --help`
to see all installer options. Do not add the migration switch to shell startup
files or automated refresh commands.

Trust/enable the plugin hooks in both clients; Codex exposes their current state
through `/hooks`. Claude resolves `${CLAUDE_PLUGIN_ROOT}` and Codex resolves
`${PLUGIN_ROOT}`, so neither hook manifest assumes a plugin-cache location.

Older versions installed equivalent hooks into user JSON. After the refreshed
plugin hooks are active, remove only those legacy managed groups once:

```bash
node plugins/mobile-development/skills/ios-session-lanes/scripts/install-runtime.mjs \
  --claude-settings-file "$CLAUDE_SETTINGS_FILE" \
  --codex-hooks-file "$CODEX_HOOKS_FILE" \
  --remove-managed-user-hooks
```

That cleanup is additive and idempotent: unrelated settings are preserved, and
the first write retains a sibling `*.before-ios-session-lanes.json` backup.

## Worktree bootstrap is separate

Create a worktree through the wrapper:

```bash
ios-session-worktree --client codex --name feature-name
ios-session-worktree --client claude --name feature-name
ios-session-worktree --client codex --name feature-name \
  --base-ref origin/codex/long-lived-integration
```

The wrapper creates `codex/feature-name` or `claude/feature-name` from a freshly
fetched `origin/preview`, then runs bootstrap. `--base-ref` may select a
different remote-tracking branch from the configured `origin`. It accepts only
the conservative `origin/<branch>` form: raw SHAs, local refs, other remotes,
path-like or shell-like input, and stale fallback are rejected. The wrapper
fetches the one named branch, resolves it once to an immutable commit, creates
the worktree from that commit, and records both the requested ref and resolved
commit in the private managed-worktree attestation and bootstrap receipt.

The older `--base origin/<branch>` spelling remains a deprecated alias routed
through the same validation and resolution path. `--allow-stale-base` is no
longer supported. If bootstrap fails, the wrapper preserves the branch and
worktree and prints the repair command.

Bootstrap can also be run or checked directly:

```bash
ios-session-bootstrap --project-root /absolute/path/to/worktree
ios-session-bootstrap --project-root /absolute/path/to/worktree --check
```

Bootstrap performs four independent tasks:

1. materializes Git LFS files and installs the pinned pnpm dependencies;
2. pulls the EAS `development` environment into ignored
   `apps/mobile/.env.local` with mode `0600`;
3. validates access to Doppler project `pumpd-backend`, config `dev_personal`,
   and required secret names without writing or printing values;
4. records a secret-free receipt in the worktree-specific Git directory.

The wrapper writes a private, worktree-specific attestation before bootstrap.
Claude and Codex `SessionStart` hooks may idempotently repair bootstrap only for
one of those attested managed worktrees. An independently created or external
worktree is never allowed to run pnpm, EAS, or Doppler merely because a session
opened there; its hook reports the exact explicit bootstrap command instead.

There is deliberately no global Claude `WorktreeCreate` hook. That lifecycle
hook replaces Claude's creation behavior for every repository and cannot be
scoped to PUMPD safely. Use `ios-session-worktree` in either client when a new
PUMPD worktree should be created and bootstrapped automatically. Lane startup
never owns bootstrap.

## Allocation model

Each chat identity is `<client>:<session-id>`. Its registry entry owns:

- one free Metro port from `8081-8119`;
- one unassigned simulator UDID from `PUMPD Agent Lane 1-6`;
- one worktree path and native fingerprint;
- one input-controller lease;
- evidence and log paths.

### Confirm the lane preset

Before creating the first lane for a chat, the agent checks status and asks one
compact question unless the user already supplied the choices:

| Preset | Device | Supabase | Metro exposure | Default use |
|---|---|---|---|---|
| `simulator-local` | assigned simulator | shared local | local Mac | recommended |
| `simulator-preview` | assigned simulator | hosted Preview | local Mac | avoid local backend coupling |
| `simulator-preview-tailscale` | assigned simulator | hosted Preview | Tailscale | advanced remote access |
| `iphone-preview` | Aren's physical iPhone | hosted Preview | Tailscale | joint physical-device testing |

If the user says “use defaults,” choose `simulator-local`. A custom selection
must explicitly provide `--target`, `--backend local|preview`, and
`--expose local|tailscale`. Binary reuse/build and controller selection remain
automatic unless the task specifically requires an override.

Do not combine a named preset with custom target, backend, or exposure flags.
After a lane has been created, a plain `up` for the same client/session reuses
the choices recorded in the registry; do not ask the user again.

Start or reconnect a simulator lane:

```bash
ios-session-lane up --client codex --session-id <id> \
  --preset simulator-local
ios-session-lane status --client codex --session-id <id>
ios-session-lane doctor --client codex --session-id <id>
```

Release only that chat's resources:

```bash
ios-session-lane down --client codex --session-id <id>
ios-session-lane reap --stale-after-minutes 120
ios-session-lane reap --stale-after-minutes 0 --dead-only
ios-session-lane simulator-recheck --udid <simulator-udid>
```

The allocator uses atomic registry and per-lane lifecycle locks, checks both
registry ownership and actual port availability, and validates process start
identity, working directory, listener ownership, and a per-process Metro nonce
before declaring the lane ready. Local Metro listens only on IPv4 loopback; the
launcher pins Node's DNS result order so Expo does not silently select IPv6
loopback on macOS. A Tailscale lane adds an owned foreground `tailscale serve`
HTTPS reverse proxy from the machine's MagicDNS name to that loopback listener.
This satisfies iOS App Transport Security without exposing Metro to the LAN.
It never uses broad process termination or a global `tailscale serve reset`.

Starting a lane automatically releases only sufficiently old registry entries
whose owned runtime is already dead. Explicit `reap` has the same dead-only
behavior; `--dead-only` remains as a readable compatibility flag. Reaping never
stops a live Metro or Tailscale process.

Simulator boot allows 15 minutes for first-boot data migration. Only a terminal
CoreSimulator `Data Migration Failed` result records a device in
`simulatorQuarantine`; ordinary app, controller, or render failures do not
quarantine a healthy simulator. Quarantine never deletes or erases a simulator.
An otherwise healthy simulator that times out during native app installation is
preserved on a 15-minute `simulatorCooldown` and another pool member is tried;
this transient pressure signal is not treated as terminal quarantine.

`simulator-recheck` removes only the registry quarantine or cooldown marker so a
preserved device can go through the full boot and rendered-app health check
again. It does not erase, delete, shut down, or recreate the simulator.

## Native binary decision

The lane computes Expo's native fingerprint and combines it with the Xcode
version and machine architecture:

```text
native fingerprint + Xcode version + architecture -> binary cache key
```

The decision is automatic:

- compatible app already installed on assigned UDID: reuse it;
- cache contains the same key: install that `.app` into the assigned UDID;
- another lane is building the same key: wait on its build lock, then reuse;
- cache miss or explicit `--build`: make one generic local Xcode simulator
  build, cache the `.app`, then install it into the assigned UDID.

JavaScript-only worktrees therefore share a compatible cached binary while
keeping Metro and simulator state isolated. A native fingerprint change makes
a new local binary. This workflow never requests an EAS cloud development
build.

## Controllers

Only one input writer owns a lane at a time.

| Tool | Use | Input policy |
|---|---|---|
| `agent-device` | default exploration, launch, taps, text, screenshots | default writer |
| SimView | visual observation, tree inspection, annotations | read-only while a lane writer is active |
| Maestro | deterministic repeatable flows and final proof | acquire writer lease |
| Argent | optional interactive accessibility controller | acquire writer lease |
| XcodeBuildMCP | optional build/test diagnostics | explicitly target the lane UDID and acquire lease when controlling UI |
| regular Simulator app | human viewing and manual intervention | never use as an agent's unscoped input controller |

Examples:

```bash
ios-session-lane control --client codex --session-id <id> -- snapshot -i
ios-session-lane controller-acquire --client codex --session-id <id> \
  --controller maestro --force-controller
ios-session-lane maestro --client codex --session-id <id> -- test path/to/flow.yaml
ios-session-lane controller-acquire --client codex --session-id <id> \
  --controller agent-device --force-controller
```

The wrapper supplies the assigned device name or UDID; raw controller commands
are denied by the client hooks.

## Shared local Supabase

The recommended simulator preset uses `--backend local`. The registry discovers
the running Supabase Docker bind mount and compares a contract digest covering
config, functions, migrations, schemas, seed, templates, and generated shared
types against the consuming worktree. A healthy stack mounted from another
worktree is accepted only when compatible. A lane-owned stack binds published
services to loopback through its dedicated Docker network.

There is one lifecycle owner:

```bash
ios-session-lane backend-up --client codex --session-id <id>
ios-session-lane backend-down --client codex --session-id <id>
ios-session-lane backend-adopt --client codex --session-id <id>
```

A reset additionally requires the writer lease, an explicit acknowledgement,
the owner's mounted worktree, and zero other local consumers:

```bash
ios-session-lane backend-writer-acquire --client codex --session-id <id>
ios-session-lane backend-reset --client codex --session-id <id> \
  --acknowledge-shared-reset
ios-session-lane backend-writer-release --client codex --session-id <id>
```

Doppler values enter backend lifecycle/reset commands only at runtime. They are
never copied to an environment file or stored in the lane registry. Supabase's
generated public local connection values are merged atomically into the ignored
backend environment file without overwriting unrelated entries.

## Physical iPhone lane

Physical-device mode is always an explicit choice:

```bash
ios-session-lane up --client codex --session-id <id> \
  --preset iphone-preview
```

The named phone is one exclusive lane. It uses a Tailscale Metro URL and hosted
Preview Supabase; local Supabase is never exposed. The same installed
development binary can load different JavaScript bundles from different Metro
URLs, but one physical phone can actively belong to only one chat lane at a
time.

If the phone is not locally reachable, the command reports that fact and falls
back to the simulator path. It does not submit an EAS build. If the native
fingerprint requires a physical binary that is not installed, report the joint
testing requirement and use the simulator until the user is available.

Physical-device testing is deliberately the remaining joint user/agent step.

## Hook enforcement

Claude and Codex receive the same four managed lifecycle/guard stages:

- `SessionStart`: check bootstrap, repair only an attested managed worktree, and
  inject the exact lane flow;
- `UserPromptSubmit`: refresh the registered lane heartbeat;
- `PreToolUse`: deny raw Expo/Metro, simulator mutation, broad kills,
  unleased controller use, raw worktree creation, and shared Supabase lifecycle;
- `SessionEnd`: release only that session's registered lane.

Neither client receives a worktree-creation hook. Both use
`ios-session-worktree` for managed creation, while `SessionStart` fails safely
with explicit bootstrap guidance in any unattested worktree.

The command wrapper is the authority; instruction text is supporting context.
This means an agent cannot accidentally choose an arbitrary booted simulator or
Metro port even if it overlooks the written runbook.

## Per-lane proof

Before claiming a lane works, `doctor` must prove:

- worktree bootstrap receipt is current;
- Metro PID, port, nonce, URL, and worktree identity agree;
- assigned simulator is booted and has the compatible app installed;
- native cache marker matches the full fingerprint/Xcode/architecture key;
- controller lease belongs to this lane;
- shared backend contract is compatible;
- the PUMPD app produced a rendered interactive snapshot and screenshot.

For concurrency, run two worktrees at once and verify different Metro ports,
different UDIDs, two rendered screens, and passing evidence for both. Repeat a
lane after a JavaScript-only change to prove binary cache reuse; change a native
input to prove a new cache key/local build. Physical-device proof is completed
jointly and is reported as pending rather than implied by simulator success.

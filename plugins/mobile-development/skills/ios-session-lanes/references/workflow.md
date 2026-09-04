# PUMPD iOS session lanes

## What owns the workflow

The implementation lives in the user-installed `mobile-development` plugin in
`agent-tooling`. It does not add scripts, hooks, simulator names, or policy to
the shared PUMPD repository.

The installer copies a stable runtime into:

```text
~/Library/Application Support/agent-tooling/ios-session-lanes/runtime
```

It installs these user commands in `~/.local/bin`:

```text
ios-session-worktree
ios-session-bootstrap
ios-session-lane
```

The project profile recognizes PUMPD only when the single `origin` fetch URL
normalizes to the exact `github.com/avad-technologies/pumpd-mobile-app`
identity and all required files exist. HTTPS, `ssh://`, and SCP-style GitHub
remotes normalize to that identity; owner, host, repository-name, ambiguous,
and malformed lookalikes fail closed. Linked worktrees are checked against
their own resolved top-level and the shared repository remote. Hooks are silent
in every other repository.

## Installation

Run the installer from the `agent-tooling` checkout and explicitly select the
local Claude and Codex JSON files:

```bash
node plugins/mobile-development/skills/ios-session-lanes/scripts/install-runtime.mjs \
  --claude-settings-file "$CLAUDE_SETTINGS_FILE" \
  --codex-hooks-file "$CODEX_HOOKS_FILE"
```

Set those two variables to the machine's user-level Claude settings JSON and
Codex hooks JSON. Keeping the paths as installer inputs prevents the shared
plugin from assuming either client's installation layout.

The install is additive and idempotent. It preserves unrelated settings and
hooks, replaces only groups marked `agent-tooling-ios-session-lanes`, and writes
a sibling `*.before-ios-session-lanes.json` backup before changing an existing
JSON file. Later idempotent installs preserve that original backup rather than
overwriting it with an already-managed configuration.

## Worktree bootstrap is separate

Create a worktree through the wrapper:

```bash
ios-session-worktree --client codex --name feature-name
ios-session-worktree --client claude --name feature-name
```

The wrapper creates `codex/feature-name` or `claude/feature-name` from
`origin/preview`, then runs bootstrap. If bootstrap fails, it preserves the
branch and worktree and prints the repair command.

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

Claude and Codex `SessionStart` hooks run this same idempotent bootstrap if a
new worktree has no current receipt. Lane startup never owns bootstrap.

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
ios-session-lane simulator-recheck --udid <simulator-udid>
```

The allocator uses an atomic registry lock, checks both registry ownership and
actual port availability, and validates a per-process Metro nonce before
declaring the lane ready. It never uses broad process termination.

Simulator boot allows 15 minutes for first-boot data migration. A device that
cannot provide a reachable SpringBoard or later proves unreachable is recorded
in `simulatorQuarantine` and skipped on future allocation. Quarantine never
deletes or erases a simulator. A `Data Migration Failed` report is retained as
a warning when SpringBoard is reachable and the rendered-app health check can
still provide stronger evidence.

`simulator-recheck` removes only the registry quarantine marker so a preserved
device can go through the full boot and rendered-app health check again. It does
not erase, delete, shut down, or recreate the simulator.

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
- cache miss or explicit `--build`: make one local Xcode simulator build and
  cache the `.app`.

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

The recommended simulator preset uses `--backend local`. The registry discovers the
running Supabase Docker bind mount and compares its backend contract digest
against the consuming worktree. A healthy stack mounted from another worktree
is accepted only when compatible.

There is one lifecycle owner:

```bash
ios-session-lane backend-up --client codex --session-id <id>
ios-session-lane backend-down --client codex --session-id <id>
```

A reset additionally requires the writer lease, an explicit acknowledgement,
the owner's mounted worktree, and zero other local consumers:

```bash
ios-session-lane backend-writer-acquire --client codex --session-id <id>
ios-session-lane backend-reset --client codex --session-id <id> \
  --acknowledge-shared-reset
ios-session-lane backend-writer-release --client codex --session-id <id>
```

Doppler values enter backend commands only at runtime. They are never copied to
an environment file or stored in the lane registry.

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

Claude and Codex receive the same three managed hook stages:

- `SessionStart`: independently ensure bootstrap and inject the exact lane flow;
- `PreToolUse`: deny raw Expo/Metro, simulator mutation, broad kills,
  unleased controller use, raw worktree creation, and shared Supabase lifecycle;
- `SessionEnd`: release only that session's registered lane.

The command wrapper is the authority; instruction text is supporting context.
This means an agent cannot accidentally choose an arbitrary booted simulator or
Metro port even if it overlooks the written runbook.

## Per-lane proof

Before claiming a lane works, `doctor` must prove:

- worktree bootstrap receipt is current;
- Metro PID, port, nonce, URL, and worktree identity agree;
- assigned simulator is booted and has the compatible app installed;
- native cache marker matches the current fingerprint;
- controller lease belongs to this lane;
- shared backend contract is compatible;
- the PUMPD app produced a rendered interactive snapshot and screenshot.

For concurrency, run two worktrees at once and verify different Metro ports,
different UDIDs, two rendered screens, and passing evidence for both. Repeat a
lane after a JavaScript-only change to prove binary cache reuse; change a native
input to prove a new cache key/local build. Physical-device proof is completed
jointly and is not implied by simulator success.

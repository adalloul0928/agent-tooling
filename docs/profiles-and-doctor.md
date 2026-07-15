# Profiles and doctor

Profiles describe desired state for a machine, project, or combination of the
two. They contain identifiers, expected revisions, file paths, and manual
verification reminders. They never contain credentials or OAuth state.

`scripts/doctor` is deliberately read-only. It reads native Claude and Codex
configuration plus committed project files, then reports:

- `PASS`: observed state matches the profile;
- `WARN`: advisory drift should be reviewed;
- `FAIL`: a required capability or file is missing;
- `MANUAL`: an account, desktop, cloud, or health check cannot be inferred from
  local files.

It does not install, remove, authenticate, prune, refresh, or rewrite anything.
Remote MCP health is excluded from the default run because checking a name in a
config file is not proof that OAuth or the remote service works.

## Composition

`pumpd-workstation.json` extends both `base-workstation.json` and
`pumpd-project.json`:

```text
base-workstation
       +
pumpd-project
       =
pumpd-workstation
```

`base-workstation.json` includes `personal` plus the reusable
`mobile-development` MCP bundle. The MCP bundle is local-workstation tooling;
it is not part of the committed PUMPD cloud contract.

`wet-in-seattle-workstation.json` extends `base-workstation.json`, adds the
`wet-in-seattle` plugin, which supplies `analytics-mcp` to both Claude and
Codex through a shared Doppler-backed declaration. The profile verifies that
the plugin is enabled; Doppler access, Google Analytics authentication, and
Shopify health remain manual checks.

Parent variables and checks are inherited in order. A child may override a
check by reusing its stable `id`. Paths use `~` and profile variables rather
than committed machine-specific absolute paths.

## Usage

```bash
./scripts/doctor
./scripts/doctor base-workstation
./scripts/doctor pumpd-project --json
./scripts/doctor pumpd-workstation --strict
./scripts/doctor wet-in-seattle-workstation
```

The default profile is `pumpd-workstation`. Required failures return exit code
`1`. Advisory warnings do not fail a normal run; `--strict` returns `2` when
warnings remain. Invalid profiles return `65`.

Profiles intentionally expose known next work rather than claiming a clean
setup. Connector separation remains advisory until every required local twin is
authenticated, hosted checks still require a person, and newly published
plugins remain required-but-missing until their release is installed.

The profile is an enforceable subset of the intended environment, not the full
inventory. [tooling-inventory.md](tooling-inventory.md) records vendor tools,
special local skills, hosted connectors, MCP placement, and authentication
boundaries that may be optional, private, or impossible to verify safely from a
read-only local doctor.

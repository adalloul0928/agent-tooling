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

Parent variables and checks are inherited in order. A child may override a
check by reusing its stable `id`. Paths use `~` and profile variables rather
than committed machine-specific absolute paths.

## Usage

```bash
./scripts/doctor
./scripts/doctor base-workstation
./scripts/doctor pumpd-project --json
./scripts/doctor pumpd-workstation --strict
```

The default profile is `pumpd-workstation`. Required failures return exit code
`1`. Advisory warnings do not fail a normal run; `--strict` returns `2` when
warnings remain. Invalid profiles return `65`.

The initial profiles intentionally expose known next work rather than claiming
a clean setup: project-owned review skills are still missing, connector
separation is not enabled, duplicate Codex MCP providers remain, and hosted
checks require a person.

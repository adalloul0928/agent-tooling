# Profiles and doctor

Profiles describe desired state for a machine, project, or combination of the
two. They contain identifiers, expected revisions, file paths, and manual
verification reminders. They never contain credentials or OAuth state.

`scripts/doctor` is deliberately read-only. It reads native Claude and Codex
configuration plus committed project files. A profile may also invoke an
explicitly read-only local-runtime checker, such as the iOS session-lane
installer's `--check` mode. It then reports:

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

`base-workstation.json` includes `personal`, the reusable `developer-workflows`
skill bundle, and the reusable `mobile-development` iOS-lane/MCP bundle. These are
local-workstation tools; they are not part of the committed PUMPD cloud
contract.

The `mobile-development` plugin supplies the skill and client-native hooks, but
the stable `ios-session-*` command runtime is installed separately. The base
profile verifies that runtime against the current `agent-tooling` revision and
offers the matching installer as its repair recipe. This prevents a machine
from passing doctor with hooks that point at missing or stale commands.

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
./scripts/doctor pumpd-workstation --project-root "$PWD"
./scripts/doctor wet-in-seattle-workstation
```

Use `--project-root` from an active worktree or checkout to override the
profile's default `project_root`. Project-scoped Claude plugin checks read that
checkout's `.claude/settings.json`, and project MCP checks read its committed
Claude and Codex configuration. This avoids reporting drift from a different or
stale checkout.

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

## Setup (apply mode)

`scripts/setup` is the apply-mode twin of doctor. Doctor stays deliberately
read-only; setup executes install recipes for the checks doctor reports as
failing. Together they make machine bootstrap repeatable: clone this repo, run
`doppler login`, then `./scripts/setup <profile> --apply` and follow the printed
manual checklist (OAuth grants and account-level connectors are never
automated).

```bash
./scripts/setup pumpd-workstation            # dry-run plan (default)
./scripts/setup pumpd-workstation --apply    # execute planned commands
./scripts/setup base-workstation --json      # machine-readable plan
./scripts/setup pumpd-workstation --only claude.expo-mcp --apply
```

A check opts into automation with an `install` object; the schema already
permits extra fields, so no schema change is required:

```json
{
  "id": "claude.expo-mcp",
  "kind": "claude_mcp",
  "server": "expo",
  "install": {
    "run": ["claude", "mcp", "add", "--transport", "http", "expo",
             "https://mcp.expo.dev/mcp"],
    "note": "First use opens browser OAuth to the Expo account."
  }
}
```

Rules:

- `install.run` is a command (list preferred; strings run through the shell).
  `${variables}` and `~` expand exactly as in doctor checks.
- `install.note` is printed with the plan — use it for OAuth prompts and
  follow-up steps.
- Without a recipe, `claude_plugin` checks fall back to
  `claude plugin install <plugin>`; every other kind is listed as TODO rather
  than guessed.
- Recipes are committed content: never embed secrets or tokens. Commands that
  need credentials fetch them at runtime (Doppler) or stay in `manual_checks`.
- Vendor skills installed via `npx skills add` are tracked as `path` checks on
  the installed `SKILL.md` with the add command as their recipe.
- The `ios_session_runtime` check executes only the installer's read-only
  `--check` path. Its repair recipe installs from the same `agent-tooling`
  revision; legacy migration remains an explicit one-time operator action.
- **Recipes must pin scope explicitly.** Both installers this repo relies on
  default to the *current directory*, not the user: `claude mcp add` needs
  `--scope user` and `skills add` needs `-g`. A recipe that omits them appears to
  succeed while registering the capability only where it happened to run — which
  is not reproducible, and hides it from the checkouts that need it. Both bugs
  were hit on 2026-07-23; `claude mcp list` showed the server while `doctor`
  correctly reported it missing, because doctor reads user scope.
- **A `warning`-severity check's `install` recipe never executes.** `setup` only
  plans fixes for *failing required* checks, so an advisory check reports
  "nothing to fix" and its recipe is inert. Give a check `warning` severity when
  you want drift surfaced but not auto-repaired; leave it required when you want
  `setup --apply` to reproduce it. Deciding severity is therefore a decision
  about automation, not just about noise.

---
name: doppler-cli-skill
description: "Query Doppler live through its CLI for projects, configs, and secret NAMES — never values. Use when you need to know what actually exists in Doppler right now — whether a variable is defined in a given project/config, which configs a project has, why one config works and another does not, why a doppler-wrapped MCP or command fails to start, or to check the env-topology map against reality. Works in CI, headless, and non-Claude clients. Names only; never print, fetch, or echo a secret value."
---

# Doppler CLI (names only)

The live companion to [`env-topology`](../env-topology/SKILL.md). That skill is
the **map** — where a variable *should* live, and why something is undefined.
This skill is the **operator** — what is *actually* in Doppler right now, asked
in a way that cannot leak.

Read `env-topology` first for placement questions. Come here to verify, or when
the map and reality disagree.

## The hard rule: names only

**Never print, fetch, echo, or write a secret value.** Query names only.

Safe — returns names, never values:

```bash
doppler projects --json
doppler configs --project <project> --json
doppler secrets --only-names --project <project> --config <config>
```

**Prohibited in agent contexts** — these emit plaintext values:

| Command | Why it is banned |
|---|---|
| `doppler secrets` *without* `--only-names` | Default output is a name **and value** table. This is the main footgun — the flag is the only thing standing between a listing and a leak. |
| `doppler secrets get <NAME>` | Prints the value. |
| `doppler secrets download` | Writes every value to disk. |
| `doppler run --command "env"` / `printenv` / `echo $VAR` | Injects then prints values. |

If a task seems to require a value, it does not: the value belongs in a
`doppler run` wrapper that hands it straight to the consuming process (see
*Runtime injection*), never through the agent's context or the transcript.

Never paste a value into a file, commit, PR body, issue, log, or chat message.
If a value is ever exposed, say so plainly and recommend rotating it.

## Topology (verified 2026-07-23 — re-verify, do not trust memory)

8 projects. Config shape is not uniform, and assuming `dev`/`prd` everywhere is
a common source of wrong answers:

| Projects | Configs |
|---|---|
| `pumpd-mobile`, `pumpd-backend`, `pumpd-admin`, `pumpd-docs` | `dev`, `dev_personal`, `stg`, `prd` |
| `pumpd-website` | `dev`, `dev_personal`, `preview`, `prd` — **`preview`, not `stg`** |
| `agent-tooling`, `pumpd-ci`, `pumpd-keymat` | `prd` only |

`dev_personal` is a personal branch config off `dev`. See `env-topology` for
what each project is *for*.

## Core recipes

Work outside-in — project, then config, then names.

```bash
# 1. What projects exist?
doppler projects --json | jq -r '.[].name'

# 2. What configs does one have? (never assume dev/prd)
doppler configs --project pumpd-mobile --json | jq -r '.[].name'

# 3. What names are defined there?
doppler secrets --only-names --project pumpd-mobile --config dev
```

**Is a specific name defined?**

```bash
doppler secrets --only-names --project pumpd-backend --config prd \
  | rg -q '^SENTRY_DSN$' && echo present || echo absent
```

**Why does `prd` work but `dev` not?** — the highest-value query here, and the
one `env-topology` cannot answer because it needs live state. Diff the name
sets:

```bash
diff \
  <(doppler secrets --only-names --project pumpd-backend --config dev  | sort) \
  <(doppler secrets --only-names --project pumpd-backend --config prd  | sort)
```

Lines only in `prd` are what `dev` is missing. Report the **names** and where
they should be set; never read across to fetch what they contain.

`--json` output from `doppler secrets --only-names` is safe to pipe through
`jq`, but keep `--only-names` on every invocation — adding `--json` alone does
not suppress values.

## Auth and troubleshooting

```bash
doppler me --json      # identity, token type, and workplace — no secrets
```

Diagnose in this order:

- **`doppler me` fails** → not logged in. `doppler login` for an interactive
  workstation; in CI/headless a `DOPPLER_TOKEN` service token is supplied by the
  environment instead.
- **"project not found" / empty project list** → almost always *scope*, not
  absence. A service token is usually scoped to a single project+config, so
  everything else is invisible to it. Check `doppler me --json` for the token
  type before concluding a project is missing.
- **A name is missing where you expected it** → confirm the config actually
  exists (`doppler configs`) before concluding the name is unset. `stg` vs
  `preview` on `pumpd-website` is the classic trap.
- **Ambient scope surprises** → `doppler setup` writes a per-directory default
  project/config, so a bare command can silently target something other than
  what you meant. Pass `--project` and `--config` explicitly in every command,
  which all recipes here do.

## Runtime injection (how tokened tools get secrets)

Values reach a process without ever entering the agent's context by wrapping it:

```bash
doppler --silent run --project agent-tooling --config prd \
  --only-secrets <VAR_NAME> --no-fallback \
  --command "exec <the real command>"
```

Each flag is load-bearing:

- `--silent` keeps CLI chatter out of the child's stdio — important for stdio
  MCP servers, where stray output corrupts the JSON-RPC stream.
- `--only-secrets <VAR>` injects just that variable instead of the whole config.
- `--no-fallback` fails loudly when the secret is missing rather than starting a
  half-configured process.
- `exec` replaces the shell so signals and exit codes propagate.

This pattern launches every tokened MCP in this repo. **When a wrapped tool
fails to start**, check in order: `doppler me` (auth), the name exists in that
project/config (`--only-names`), and the project/config pair in the wrapper is
correct. Diagnose by listing names — never by running the command with the
injection removed, and never by printing the injected environment.

## Where this runs

The CLI is the primary way to interrogate Doppler here — there is no Doppler MCP
in this setup, deliberately. A CLI path also works everywhere an MCP does not:
CI, headless and cron runs, and non-Claude clients. It carries no cached-token
staleness, and `--only-names` makes leaking a value take a deliberate act rather
than a default.

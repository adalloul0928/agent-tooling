# New machine setup (macOS)

Bring a fresh Mac to the same state as the current workstation. Run the steps in
order — later steps genuinely depend on earlier ones, and the two most common
failures are running `setup --apply` before `doppler login`, and assuming the
account-side pieces came along automatically.

**What this reproduces:** local Claude MCPs, vendor skills, owned plugins, and
the repo checkout — everything with an `install` recipe in `profiles/`.

**What it cannot reproduce** (see [Step 7](#step-7--what-does-not-come-along)):
OAuth grants, claude.ai / ChatGPT account connectors, and scheduled tasks. Those
are account- or machine-local state by design, not gaps.

Known-good versions, captured from a working machine 2026-07-23:

| Tool | Version |
|---|---|
| git | 2.54.0 | 
| node | v22.19.0 (**≥22.20.0 preferred** — the `skills` CLI warns below that) |
| npm | 10.9.3 |
| Claude Code | 2.1.218 |
| doppler | v3.76.0 |
| gh | 2.70.0 |
| jq | 1.7.1 · ripgrep 15.1.0 · python3 3.14.5 · agentskills 0.1.1 |

---

## Step 0 — prerequisites

`scripts/setup` cannot install the tools it runs. Get these first.

```bash
xcode-select --install                      # git and the toolchain
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew install node gh jq ripgrep python3 uv dopplerhq/cli/doppler
```

Install **Claude Code** from its official installer, then confirm `claude` is on
`PATH`.

`scripts/validate-static` hard-requires `jq`, `python3`, `rg`, **and
`agentskills`**, which is a `uv` tool rather than a Homebrew formula:

```bash
uv tool install skills-ref                  # provides the `agentskills` binary
agentskills --version                       # expect 0.1.1+
```

## Step 1 — authenticate the things only a human can

Do this **before** Step 3. Several MCPs are launched through `doppler run`, and
they fail to start if Doppler is not logged in.

```bash
gh auth login
doppler login
doppler me                                  # identity only — never `doppler secrets`
```

## Step 2 — clone, add the marketplace, install plugins

```bash
mkdir -p ~/ws && cd ~/ws
git clone https://github.com/adalloul0928/agent-tooling.git
cd agent-tooling

claude plugin marketplace add adalloul0928/agent-tooling
```

Install the plugins the profiles expect:

```bash
# base-workstation
claude plugin install personal@agent-tooling
claude plugin install developer-workflows@agent-tooling
claude plugin install mobile-development@agent-tooling

# PUMPD work
claude plugin install pumpd-workflows@agent-tooling
claude plugin install cyrus-workflows@agent-tooling
claude plugin install pumpd-automations@agent-tooling     # the automations — see Step 5

# IAWIS / Wet In Seattle only
claude plugin install wet-in-seattle@agent-tooling
```

## Step 3 — apply the profile

Dry-run first; it prints exactly what it would execute and changes nothing.

```bash
./scripts/setup base-workstation             # plan
./scripts/setup base-workstation --apply     # execute
```

This installs the hosted MCPs (`sentry`, `expo`, `supabase`) and every vendor
skill, each from a recipe committed in `profiles/base-workstation.json`.

For a PUMPD machine, run `pumpd-workstation` **after** cloning the PUMPD repo,
since its project checks read a checkout:

```bash
./scripts/setup pumpd-workstation --project-root ~/ws/PUMPD-Repo/pumpd-app/pumpd-mobile-app
```

> The `pumpd-workstation` `project_root` default is a known open question — it
> points at a different checkout than current work uses. Pass `--project-root`
> explicitly rather than trusting the default.

## Step 4 — authenticate the MCPs

`setup` registers servers; it cannot complete OAuth. Each of these opens a
browser:

```bash
claude mcp login sentry
claude mcp login expo
claude mcp login supabase

claude mcp list                              # all should read ✔ Connected
```

Over SSH or without a browser, add `--no-browser` to print the URL instead.

## Step 5 — the automations

The ten scheduled automations ship in the **`pumpd-automations`** plugin
(installed in Step 2): `pumpd-sentry-miner`, `pumpd-product-miner`,
`pumpd-tool-radar`, `pumpd-ai-tooling-radar`, `pumpd-agent-retro`,
`pumpd-appstore-readiness`, `pumpd-docs-freshness`, `pumpd-security-scan`,
`pumpd-setup-scout`, `pumpd-haiku-window-starter`.

They need three things beyond the plugin itself:

1. **Linear — required by nearly all of them.** Every automation files capped,
   evidence-linked suggestions into Linear team PUMPD **Triage** with its own
   `auto:` label and fingerprint dedupe. Linear is an **account-side connector**,
   not a local MCP, so it does **not** appear in `claude mcp list` and `setup`
   cannot install it. Enable it in your Claude account connector settings.
2. **Sentry MCP** — `pumpd-sentry-miner` specifically. Step 4 covers it.
3. **Schedules — machine-local, not in this repo.** Registered tasks live in
   `~/.claude/scheduled-tasks/<id>/SKILL.md`. That directory is per-machine
   state, so **a new Mac starts with none of them** and each must be re-created.

   Ask Claude to set one up by name, e.g. *"set pumpd-sentry-miner up as a
   recurring task."* As of 2026-07-23 only `pumpd-tool-radar` was registered, and
   as manual-only — so there is very little to re-create today. Check the source
   machine with `list_scheduled_tasks` before assuming otherwise.

**Plugin vs schedule — they are independent, which is easy to misread.** A
registered scheduled task carries **its own copy** of the skill at
`~/.claude/scheduled-tasks/<id>/SKILL.md` and fires without the plugin installed.
The `pumpd-automations` plugin is what makes the same automations **invocable
interactively** ("run the sentry miner now") and keeps every machine on one
source of truth. You want both.

> Worth knowing: as of 2026-07-23 the `pumpd-automations` plugin was **not
> installed** on the source workstation, even though the plugin is published and
> a `pumpd-tool-radar` schedule existed. That is exactly the drift this profile
> check now catches — `./scripts/setup pumpd-workstation` will plan
> `claude plugin install pumpd-automations@agent-tooling` until it is present.

Because these run **unattended from local Claude**, they reuse the local OAuth
session. Keeping Sentry and Linear authenticated on this machine is what keeps
them working; an unattended run that fires while a token has lapsed fails until
the next interactive re-auth.

## Step 5b — Codex

Codex is configured separately from Claude, and its CLI is easy to miss.

**The binary ships inside the ChatGPT desktop app** and is *not* symlinked onto
`PATH` by the installer — so `command -v codex` fails even when Codex is fully
installed and working. Symlink it:

```bash
ln -sf "/Applications/ChatGPT.app/Contents/Resources/codex" ~/.local/bin/codex
codex --version                              # expect codex-cli 0.145.x
```

Then add the marketplace and install the owned plugins, mirroring Step 2:

```bash
codex plugin marketplace add adalloul0928/agent-tooling   # confirm syntax with `codex plugin --help`
codex plugin list                                          # verify what is enabled
codex mcp list                                             # Status + Auth per server
```

**Codex takes hosted vendor MCPs from the curated catalog, not as raw MCPs.**
`sentry`, `expo`, `linear`, `supabase`, and `github` come from `@openai-curated`
plugins. Do **not** `codex mcp add` raw twins — the `codex.duplicate-*-mcp`
profile checks assert those stay absent, and enabling both is the failure mode
they exist to catch.

**Vendor skills install to a different directory than Claude's:**

```bash
npx skills@latest add <repo> -g -y --agent codex --skill <name>
```

lands in **`~/.agents/skills/<name>/SKILL.md`**, *not* `~/.codex/skills/`. The
profile's `codex.*-skill-*` checks carry the exact per-skill recipes, so
`./scripts/setup base-workstation --apply` handles this for you.

## Step 6 — verify

```bash
./scripts/doctor pumpd-workstation           # or base-workstation
./scripts/validate-static                    # repo contract + skill validation
claude mcp list
```

`doctor` is read-only. Expect `MANUAL` entries — those are the account-side
checks, and they stay manual permanently.

## Step 7 — what does not come along

Nothing below can be automated. Work the `manual_checks` list that `setup`
prints at the end of its run.

| Item | Why |
|---|---|
| claude.ai connectors (Linear, Gmail, Drive, TickTick, Raindrop, …) | Account-side; enabled in the web UI. `claude mcp login <name>` can *authenticate* a connector but cannot *enable* one |
| ChatGPT / Codex account apps | Account-side, and separate from local Codex MCPs |
| OAuth grants | Require a human and a browser |
| Scheduled tasks | Machine-local (`~/.claude/scheduled-tasks/`) |
| Doppler login | Machine-local credential |

Note `disableClaudeAiConnectors: true` is set at user scope. That governs the
**Claude Code CLI**, not every surface — the desktop/chat surface still exposes
account connectors. Do not read it as "connectors are off everywhere."

## Gotchas worth knowing before you hit them

- **Both installers default to the current directory, not the user.**
  `claude mcp add` needs `--scope user`; `skills add` needs `-g`. The committed
  recipes already do this, but a hand-run command without them registers the
  capability only where you ran it. The tell: `claude mcp list` shows the server
  while `doctor` reports it missing, because doctor reads user scope.
- **`skills add --skill` takes one skill per flag.** Comma-separated values are
  silently rejected — it prints a plausible skill listing and installs nothing.
  Verify installs from disk, not from command output.
- **A doppler-wrapped MCP that fails to start usually means Doppler**, not the
  MCP. `heroui-pro`, `heroui-native-pro`, and `analytics-mcp` all launch through
  `doppler run` with `--no-fallback`, so a missing login or secret is a hard
  failure by design. Check `doppler me` first.
- **`react-native-best-practices` exists in two vendor collections.** Only
  Software Mansion's is installed; installing Callstack's would silently
  overwrite it, since `skills add` has no rename option.

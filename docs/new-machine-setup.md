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
uv tool update-shell                        # REQUIRED: puts ~/.local/bin on PATH
exec $SHELL -l                              # reload so the change takes effect
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

This installs the hosted MCPs (`sentry`, `expo`, `supabase`), every vendor
skill, and the stable `ios-session-*` runtime, each from a recipe committed in
`profiles/base-workstation.json`. The `mobile-development` plugin carries the
skill and hooks; the command runtime is deliberately separate from the
versioned client plugin cache.

Verify that the runtime exactly matches this checkout and that its three
wrappers are on disk:

```bash
node plugins/mobile-development/skills/ios-session-lanes/scripts/install-runtime.mjs --check
command -v ios-session-worktree ios-session-bootstrap ios-session-lane
```

The check is read-only and fails on missing, stale, tampered, or wrong-mode
files. A normal refresh retains and reports the prior installation as recovery
backups; keep those paths until the refreshed runtime has passed a canary. If
upgrading the original unmarked v1 runtime, run the installer once with
`--migrate-legacy-runtime` yourself, review its reported backups, then return to
the normal command. Never automate the migration switch.

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
   recurring task."*

   **Enumerate the source machine first — do not trust a count from any doc,
   including this one.** The store is per-session, so what one machine reports is
   not what another has. `list_scheduled_tasks` shows only the sessions it can
   see; read the JSON directly (below) for the true picture.

### The `cwd` trap — the highest-risk step on this page

Every scheduled task carries a **working directory**, inherited from whichever
session created it. It decides which repo the automation actually inspects.

**Nothing surfaces it.** The scheduled-task tools return `taskId`, `description`,
`path`, `schedule`, `enabled` and `jitterSeconds` — **not `cwd`**. Neither you nor
an agent can see or set it through them. It lives only in the desktop app store:

```
~/Library/Application Support/Claude/claude-code-sessions/<workspace>/<session>/scheduled-tasks.json
```

Read it directly:

```bash
find ~/Library/Application\ Support/Claude/claude-code-sessions \
  -name scheduled-tasks.json -exec \
  jq -r '.scheduledTasks[] | "\(.id)  cwd=\(.cwd)"' {} \;
```

**On a new machine every task inherits the cwd of the session that created it**,
which is usually wrong — and the failure is silent. A miner pointed at the wrong
repo does not error; it finds nothing and files nothing, which is
indistinguishable from a genuinely quiet week. Set each task's `cwd` to the repo
it is meant to inspect (the PUMPD automations want the PUMPD checkout;
`pumpd-setup-scout` wants `agent-tooling`), then **restart the desktop app** —
edits are not picked up live — and re-read the file to confirm they survived.

Verify this before trusting a single scheduled run.

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
codex plugin marketplace add adalloul0928/agent-tooling
codex plugin add personal@agent-tooling
codex plugin add developer-workflows@agent-tooling
codex plugin add mobile-development@agent-tooling
codex plugin add pumpd-workflows@agent-tooling
codex plugin add cyrus-workflows@agent-tooling
codex plugin add pumpd-automations@agent-tooling
codex plugin list                                          # verify what is enabled
codex mcp list                                             # Status + Auth per server
```

Re-run the runtime `--check` after either client refreshes
`mobile-development`; the plugin hooks and separate command runtime must come
from the same `agent-tooling` revision.

**Codex takes hosted vendor MCPs from the curated catalog, not as raw MCPs.**
`sentry`, `expo`, `linear`, `supabase`, and `github` come from `@openai-curated`
plugins. Do **not** `codex mcp add` raw twins — the `codex.duplicate-*-mcp`
profile checks assert those stay absent, and enabling both is the failure mode
they exist to catch.

**Vendor skills install to a different directory than Claude's:**

```bash
npx skills@1.5.18 add <repo> -g -y --agent codex --skill <name>
```

lands in **`~/.agents/skills/<name>/SKILL.md`**, *not* `~/.codex/skills/`. The
profile's `codex.*-skill-*` checks carry the exact per-skill recipes, so
`./scripts/setup base-workstation --apply` handles this for you.

## Step 5c — Personal AI / Life OS Mac mini

On the always-on Life OS host, apply the dedicated profile after the normal
Codex setup:

```bash
./scripts/life-os-host-preflight
./scripts/setup life-os-workstation --apply
./scripts/setup-life-os
./scripts/activate-life-os --open-gates
lifeos doctor
```

Do not skip the first command. It must report the intended Mac mini, disabled AC
system sleep, ChatGPT installed/running/opening at login, and an online private
tailnet. Remote Login is reported separately so another tailnet device can
maintain the host without exposing a public service.

If the source checkout is dirty with unrelated work, use
`./scripts/deploy-life-os-to-host --host <tailscale-host>` for a dry-run preview
and add `--apply` only after reviewing the fixed Life OS file set. The deployer
requires an existing remote Git checkout, refuses overlapping changes, never
deletes remote files, and runs remote static validation. It also requires
non-interactive SSH key authentication; authorize the source workstation's
public key on the Mac mini rather than placing a password in a script or config.

This installs the official Gmail plugin, TickTick CLI, signed `imsg` CLI, local
runtime launcher, private state directory, policy, voice artifacts, and SQLite
ledger. It intentionally stops at the human gates:

1. authorize TickTick with `ticktick auth login`;
2. install and connect each approved Gmail account through the Codex Gmail connector;
3. grant the Codex/terminal parent Full Disk Access for iMessage reads and grant
   Messages Automation only for a confirmed send canary;
4. register and authorize the Oura OAuth application with minimum `daily` scope;
5. configure a deliberately limited Health Auto Export JSON flow;
6. recreate and verify the four Codex Scheduled tasks listed in
   [life-os.md](life-os.md).

Use `./scripts/doctor life-os-workstation` for the reproducible local state and
`lifeos doctor` for behavioral connector readiness. Neither one treats an
installed-but-unauthenticated connector as an empty data source.

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
| Scheduled tasks | Machine/account-local; Claude and Codex schedules must each be recreated and behaviorally verified |
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

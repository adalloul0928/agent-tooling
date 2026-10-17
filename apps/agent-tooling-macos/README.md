# Agent Tooling for macOS

Native SwiftUI control center for local Agent Skills, MCP servers, plugins,
desired-state profiles, connectors, marketplace sources, and operation
receipts. The interface uses real behind-window Liquid Glass with native SF
Symbols and macOS materials rather than an opaque dashboard theme.

## Install

The release workflow publishes signed alpha builds as versioned DMGs on the
repository's [Releases page](https://github.com/adalloul0928/agent-tooling/releases).
After the first release is available, download the newest
`Agent-Tooling-*-arm64.dmg`, open it, and drag **Agent Tooling** into
**Applications**. The destination Mac does not need Xcode, Swift, or a local
clone of this repository.

Because the repository is currently private, the downloader must have GitHub
access to it. See [the release runbook](../../docs/macos-app-release.md) for the
signing, notarization, and publishing setup.

## Local-first architecture

The app's source of truth is a SQLite workspace plus a managed portable package
library at `~/Library/Application Support/Agent Tooling/`. A Git repository is
optional: it can be imported as a catalog source or prepared as a local backup,
but no GitHub account, remote, commit, or push is needed to create or install a
skill.

- **Claude Code:** user/project/local MCP plans use Claude's native CLI.
- **Codex:** user MCP plans use `codex mcp add`; project-scoped MCP placement is
  deliberately shown as a manual review because the current CLI exposes no
  scope selector.
- **Gemini CLI:** a created skill is packaged as a valid `gemini-extension.json`
  extension and live-linked with `gemini extensions link`; Gemini owns its
  extension directory and loads the change in a new CLI session.
- **Kiro CLI:** skills are standard SKILL.md folders under `~/.kiro/skills`,
  and MCP servers are managed through verified `kiro-cli mcp add`/`remove`
  commands; Amazon Toolbox's `~/.toolbox/bin` is one of the fixed install
  roots the locator checks.
- **Marketplace:** local folders, checked-out Git repositories, and Agent
  Plugins packages are inspected locally. The official MCP Registry is queried
  through its documented API. Claude and Codex listings are read from their
  respective machine-readable native catalog commands. Gemini's gallery
  remains a native source rather than an undocumented scraped API. Adding an
  MCP Registry server to the library goes through the same reviewed intake as
  pasting one by hand: Discover builds the connection from the listing's
  reviewed transport, records one connection, and starts or contacts nothing.
  Every card and the detail pane carry **Install…**: it puts the listing in the
  library (a plugin through the client it is for, chosen first when more than
  one could take it), then opens the same picker the Library uses. A skills.sh
  skill is fetched from its GitHub repository at the default branch, from the
  folder named for the skill (or the one whose SKILL.md declares that name),
  and kept as a skill that follows that repository, so Updates can check it.
- **Connections:** the app records ownership, expected surfaces, and optional
  secret *reference names* only. OAuth tokens, API keys, and cloud connectors
  remain in their owning client, account, keychain, provider, or admin system.

Every client-affecting operation is first presented as a plan. The operation
engine has a fixed executable allowlist, restricts file writes to managed or
supported locations, moves replaced files to a rollback area, redacts receipts,
and records partial per-target outcomes.

## What the Library holds

The Library is a record of tools, not a mirror of any one app. The first run
writes down what a scan of this Mac found; after that, **Check apps** (and the
automatic check on open, when it is on) compares what it finds with what the
Library holds and adds the difference under the first run's own rules: a
package a client installed is that client's, its skills belong to it, and
everything else is only tracked. Rows already in the Library are never changed
by a check, and nothing is removed because a scan did not see it this time —
taking something out is a choice a person makes. When a check adds anything,
the Apps screen says how much.

`1 mine · 33 unclassified` counts ownership, not installation. *Mine* is a
skill whose source lives in this library; *tracked* is one the app knows about
and can find, but whose files belong to the app or folder that has them. Both
are installed wherever their row's marks say they were found.

## Set up your existing tools

Home shows a **Set up your library** card while a new workspace holds discovered
tools that have not been assigned anywhere yet. The card opens the Skills
screen, where the setup wizard runs. Skipping it never deletes tools, and it
reappears from Home until you assign something.

The wizard has three steps, **Found → Apps → Assign**:

- **Found** shows what the first run already discovered on this Mac and placed
  in your library. Nothing has been installed or assigned; this step is a
  read-only summary of what is there.
- **Apps** chooses which local clients this Mac keeps in sync. This only sets
  Agent Tooling's client visibility preference; what is already installed in
  each app does not change.
- **Assign** picks tools and the apps that should have them, then installs
  them the way the Install button does everywhere else (below). You can finish
  without assigning anything.

### Installing

**Install…** on a skill, plugin, connection, project, or preset opens one
dialog: the managed apps as rows (found on this Mac or not, the folder the
files would land in, whether the app already has it), a This Mac / One project
switch, and an Install button. Pressing it saves the assignment, plans what
that means for this Mac, and applies the plan — the same assign → plan →
safety review → execute → receipt pipeline the Apps screen runs, without the
hop to it. The outcome names each app, and **Undo** takes the install back out
of the apps it was just put in (the assignment and the copies), nothing else.

The plan is shown first, in the same dialog, only when it would do more than
the button said (`OperationPlanRiskClassifier`): content a scan flagged, a
removal, a change to a connection an app already has, more than five steps,
anything the planner had to leave out, or a request that came from an agent
rather than a click. Bulk changes and Sync between apps keep the Apps screen's
full review. One case is not a decision at all: a step that would replace files
Agent Tooling cannot prove it installed (a hand-made skill folder, say) is
listed as *left alone* and skipped, because the executor refuses it regardless.
Adopting the existing copy from Checkup, or removing it, is the way through.

### Updates

Settings › General › Updates sets how this Mac looks for updates to what it
manages and what it does with one. One cadence (when the app opens, once a
day, only on request) and, per kind, **Install automatically** or **Ask me
first**. The default is to ask. A check compares each item with its source and
changes nothing:

- skills that follow a repository, with what the repository publishes now;
- native plugins, with the catalog Discover kept;
- connections, with the catalog entry of the same name, when there is one.

A found update appears on Home with an **Update** button (and on its row in the
Library), unless its kind is set to install automatically, in which case the
check installs it and Home says so. Installing a skill update is the same path
as installing the skill: the library takes the content, then every copy this
app proved it installed is replaced. A copy somebody edited since it was
installed is left alone and waits on the Apps screen's review, where a person
can decide. A native plugin is updated by its own app's command (`claude plugin
update`, the only one recorded); an app with no recorded update command keeps
its own plugins up to date, and the row says so instead of offering **Update**.

Skill metadata supports standard YAML, including multiline descriptions and
quoted names. Managed copies use the name declared in `SKILL.md`, even when the
source folder has a different name; source files are preserved.

**Make personal copy** is a separate opt-in for a standalone skill that you
want to maintain independently. Bundled skills stay with their plugin. Assigning
a skill records where you want it and never requests a personal copy on its own;
only an explicit copy uses the operation-plan sheet before anything is written.

### Repository-linked skills and native plugin updates

In a standalone skill's details (or its setup row menu), choose **Link
repository** to record its public HTTPS GitHub repository, branch/tag/commit,
and skill subdirectory. An unknown source remains unknown until linked.
Linking records the existing files without moving, editing, or adopting them.
**Check for updates** fetches into an isolated temporary Git cache, compares
the skill bytes, and reports what was checked. **Review update** prepares a
fingerprinted plan for the existing installations. Local edits, changed
installation locations, unsupported links/nested reference folders, and
incomplete content reviews block replacement. A completed update keeps the
repository relationship and native availability settings. Stop following
removes only the relationship; it does not uninstall the skill.
Adding a linked skill to another supported client also keeps the new
installation on that repository's reviewed update path. Shared folders are
updated once, with every affected client named in the plan.

Public GitHub sources are supported in this version; private-repository
authentication and automatic background updates are not configured by setup.
Claude plugins with a confirmed user scope can be updated through a reviewed
native `claude plugin update` operation. Codex and unsupported native scopes
show client-owned update guidance; the app does not emulate updating by
reinstalling or extracting their skills.

This is local setup capture and reviewed source management. Claude Desktop-only
configuration is not yet fully inventoried. Hook/agent editors and broader
configuration management are documented as follow-up work in the
[feature roadmap](../../docs/onboarding-feature-roadmap.md).

## Choose apps

Open **Apps → Choose apps…** and check the apps you want Agent Tooling to
manage. Unchecking an app immediately removes it from navigation, inventory
badges, account checks, marketplace routes, project configuration, search, and
operation destinations. Setup, marketplace, history, and drift scans skip
unchecked apps. You can uncheck every app and continue using the local library.

This is a preference for this Mac. Existing workspaces start with all apps
selected. Selection survives relaunch and is not imported from another Mac's
backup. Unchecking does not uninstall an app, delete its configuration, or
remove saved desired state; checking it again restores its saved state. Run
**Check apps** to refresh its current installation. Historical records involving
unchecked apps are hidden, while their original receipts remain on disk. App
selection is locked while an operation is running or awaiting review.

## Apps, health, and why an install waits

The Apps screen states each managed client's health from its last check. A
client is only healthy when its command-line tool both answered and reported a
version: that pair is what tells an install the client will accept what it is
given. A client whose command ran but did not report a version shows **Found,
version unknown**, because it has not confirmed what it accepts — a tool asked
for in that client waits rather than installing until the client answers with a
version. A client whose files are present but whose command-line tool is missing
shows **Command unavailable**.

The launch-time check is a preference. **Settings → General → Check health
automatically** decides whether this Mac's apps are checked when Agent Tooling
opens; with it off, health is refreshed only when you run **Check apps**. The
manual button is unaffected by the setting.

## Projects and project folders

A project is two things. The shared half is a name and the repositories it is
a checkout of (`repositoryHints`), which travel with the workspace. The local
half is the folder on this Mac that backs it, which does not travel: a path
here means nothing on another Mac.

The Projects screen finds project folders on this Mac: the folders Claude Code
has run in (its own session index) and the children of any folder chosen under
**Where to look**. Each one is read for its agent files (`CLAUDE.md`,
`AGENTS.md`, `.mcp.json`, `.claude/skills`, `.agents/skills`, `.gemini/…`,
`.kiro/…`) and its Git `origin`; nothing is written and no command runs. A
found folder the workspace does not track yet appears under **Found on this
Mac** with two possible answers:

- **Track** makes it a project of its own, named after the folder, carrying its
  repository, and bound to the folder on this Mac.
- **Use for <project>** appears when the folder is a checkout of a repository
  one of your projects names and that project has no folder here. That is how
  a project set up on one Mac finds its folder on the next: clone the same
  repository and it is recognised, instead of being an unattached name with a
  bare Choose folder… button. A project detail with no folder offers the same
  recognition as **Use this folder** when a checkout is found.

A project can still be given any folder with **Choose folder…**. When that
folder is a checkout, the project learns its repository then, so the
recognition carries to the next Mac. **New Project…** can start from a folder
the same way. Until a project has a folder here, a project-scoped install has
nowhere to write, so it waits and says so.

The detail shows three things apart: **Assigned to this project** (library
items you assigned here; what Install puts into the folder), **In the folder**
(what the folder itself holds for each app, whoever put it there, marked
shared-with-the-repository or machine-local), and **Inherited from this Mac**
(library items assigned with no project). Adopting a folder's own skills into
the library is a separate step this screen does not take.

## Presets

The Presets tab manages named sets of library items. **New preset…** creates one
from items already in your library; each preset can be renamed and deleted from
its row menu. Deleting a preset leaves its items in the library. A preset can
also arrive with a workspace — restored from a backup, synced from another Mac,
or shared with you.

## Activity

The Activity screen is this Mac's journal. It lists the operation receipts a
real install, update, or removal wrote, alongside the drift the app has
recorded, reading the same receipts and journal the rest of the app writes.

## Create a skill with Claude Code or Codex

**New skill…** (⌘N) asks how the skill should be written: **Create with
Claude Code**, **Create with Codex**, or **Write it yourself**. The first two
open a conversation inside the app; the third opens the form.

The creator is a conversation, not a one-shot generator. The exchange is on the
left and the draft folder's files are on the right, re-read after every turn.
The assistant may ask a few questions before it writes anything, and you can
ask for changes after each draft. Each turn runs one fixed command through your
signed-in local client — `claude -p --session-id … / --resume …` or
`codex exec --json … / codex exec resume …` — with the prompt on standard input.
Both commands are checked against the operation policy's allowlist before they
launch; the assistant may write only inside a private staging folder; and
nothing reaches the library until you press **Save**, which runs the same
"choose where it is used" step every other new skill goes through. Closing the
sheet puts the staging folder away. The conversation is kept beside the draft,
so a sheet closed mid-exchange reopens where it stopped.

The assistants are offered only for clients this Mac manages. Each uses its
own skill creator: Claude Code's `skill-creator@claude-plugins-official`
plugin, or the skill creator Codex ships as a system skill. If the chosen
client does not have it, the sheet offers to install it first with the
client's own command (`claude plugin install skill-creator@claude-plugins-official`,
preceded by `claude plugin marketplace add anthropics/claude-plugins-official`
only when Claude Code does not know that marketplace yet), and records a
receipt like any other install. Codex's creator cannot be installed
separately; a Codex too old to have it is reported as such.

Neither assistant is given an API key by this app. Claude Code uses whatever
sign-in `claude` already has, and Codex uses the account `codex login status`
reports; Codex's own configuration is kept so the person's provider and
credentials apply. What is left out is everything that would act beyond the
folder: project rules, plugins, hooks, apps, MCP servers, Bash, and the web.

Requirements, per client:

```sh
claude plugin list | grep skill-creator
codex login status
test -f "${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/SKILL.md"
```

The app validates the canonical Agent Plugins package after every turn, shows
every generated file, and requires each file to be opened before the package
can be saved. A request queued by the CLI helper or the MCP server
(`--provider claude|codex`, or the `assistant` argument) names the assistant
and opens the same creator on the `agent-tooling://skills/create/<id>` route.

## Insights: what you keep doing by hand

The Insights screen reads recent local chat history from Claude Code, Codex,
and Kiro CLI (`~/.claude/projects`, `~/.codex/sessions` and its thread
history, `~/.kiro/sessions/cli`) and answers two questions: which skills are
actually being used, and what recurring work has no skill yet. Only aggregate
findings are kept, in `insights-report.json` inside the workspace; message
text never is.

**Scan recent work** is the instant pass: a keyword match between what was
asked and the skills the library holds. **Deep dive with Claude Code** (or
Codex, when Claude Code is not managed) runs that pass, then hands the same
conversations to your own signed-in assistant as bounded, redacted digests —
the first few things you asked in each, capped at 400 characters apiece, the
tool and skill names that answered, and the project folder's name, with
secrets and `/Users/…` paths removed. The assistant is asked, against the
list of skills you already have, for the themes it sees and for skills to
create, use, or improve, each citing how many conversations support it. Its
answer arrives in the background a minute or so later and appears above the
keyword pass, where a "create" recommendation opens the skill creator with the
brief the assistant wrote.

The deep dive also runs on its own: once a day, when the app opens, after the
library has been read, and only when the last one is more than a day old. It
never blocks the window. The commands it runs are held to one shape each by
the operation policy — `claude -p --output-format json --json-schema … --permission-mode plan`
with every tool disallowed, or `codex exec --json --ephemeral --sandbox read-only --output-schema …`
inside a private request folder — with the digests on standard input, so the
assistant can read and answer but cannot act. Nothing about the transcripts
leaves this Mac except through the assistant you are already signed in to.

## Checkup, setup, and reviewing an app

Three loops share one pipeline: a deterministic audit, then your own signed-in
assistant reading it, then a walk through what it proposes, one reviewed action
at a time.

**The audit** reads what the last check of each app saw plus a bounded look at
the folders it named, and lists facts with their evidence: a skill folder entry
that points at nothing, a plugin the app lists whose install folder is gone, a
skill one app can reach by two paths, a skill this library does not manage, an
MCP server whose command is not on disk or the login shell's PATH, old plugin
versions beside the one in use, a skill folder with no SKILL.md, an app whose
tool could not be run, a server configured by hand in several apps, a server
one app gets from several places (its own configuration and plugins), and two
plugins that carry most of the same skills. Every finding carries the actions
the app can take for it. It runs in a moment and gives the same answer every
time.

**The review** hands the audit to Claude Code (or Codex when Claude Code is not
managed) in a command the operation policy holds to one shape: it may read the
six tooling folders under home (`~/.claude`, `~/.codex`, `~/.agents`,
`~/.kiro`, `~/.gemini`, `~/.aim`), and for a client review the web, and nothing
else — no shell, no writes. Its answer is a schema of bounded strings mapped to
typed recommendations, each labelled with where its claim came from: a finding
id, the file or page the assistant read, or plainly its opinion. A
recommendation naming a finding or action that does not exist is dropped.

**Applying** is one row at a time. Adopting a skill copies its files into the
library as yours and leaves the app's folder alone; removing a copy moves the
folder into the workspace's trash (or removes a link, leaving its target);
reinstalling a plugin runs the app's own command; pruning old versions moves
them to the trash. Settings and server toggles open the screens that own them.
Nothing runs in bulk.

The **Checkup** tab under Apps shows the latest audit and review and runs both
on its own when the app opens and the last checkup is more than a week old.
**Set up…** on Apps, and **Walk through…** on Checkup, open the same wizard:
choose the apps this Mac manages, audit, hand off to the assistant, then one
stop per category — cleanup, duplicates, unmanaged skills, connections,
settings, what is worth adding, and what changed upstream — with the findings
and recommendations for it. At the end of
first-run onboarding, **Check this Mac** goes to the Checkup tab. Home
shows the last checkup in a sentence. Each app's page has **Review**, which
fetches what the app has published since your installed version (Claude Code's
changelog, Codex's GitHub releases, Kiro's changelog pages), hands the notes,
your configuration, and the audit to the assistant with the web allowed, and
shows what to adopt with each item's source.

## Accounts: what claude.ai and ChatGPT give each app

The **Accounts** tab under Apps shows what your claude.ai account gives Claude
Code (connectors, skills and plugins) and what your ChatGPT account gives Codex
(apps), read live on this Mac from the apps themselves: `claude auth status`,
`claude plugin list`, `claude mcp list`, and `codex app-server`. Nothing about
the accounts' contents is stored or synced; each Mac reads its own. Adding,
connecting or removing anything happens on the vendor's site, so those rows
open claude.ai or ChatGPT.

What the app does keep is your choice about the local switches: account skills,
plugins or connectors in Claude Code, one plugin or connector, ChatGPT apps in
Codex, one app, and how app tools are approved. A choice is saved once for
every Mac. Each Mac then shows a reviewed plan that edits only
`~/.claude/settings.json` or `~/.codex/config.toml`, backs the file up first,
and is refused if the file changed after you reviewed it. A choice an
organization's policy or another settings file decides is shown as held, with
the reason, rather than written.

Checkup and Home report an app not signed in with its subscription, a login
shell variable that replaces the sign-in (by name; values are never read),
choices this Mac does not follow yet, connectors that need signing in on the
vendor's site, and an account that differs from the one another Mac uses.
Skills and plugins the account syncs to `~/.claude/skills/synced/` and
`<name>@synced` are the account's: the Library shows them in its own strip and
never adopts, assigns or removes them.

Saving the first account choice raises the shared workspace to schema 6, which
older builds cannot read, so update the app on every Mac first. The contract,
including the exact keys and how to publish this repository's plugins to
claude.ai, is [account surfaces](../../docs/account-surfaces-v1.md).

## Try a skill in its app

Each row under **Apps** in a skill's details has a **Try…** button where the
last check found the skill. It opens Terminal.app with that client running
interactively and the skill invoked as the first message — `claude /name`
(`/plugin:name` for a plugin's skill), `codex $name`, or
`kiro-cli chat /name` — so you can watch what the skill does and keep talking
to the client afterwards. Gemini CLI is not offered: this app has no verified
way to call a skill there by name.

The launch is a `.command` file written under the workspace's own cache. It
runs the tool the app located (the same one every other command uses), through
your login shell so your profile applies, from your home directory. The
argument list is checked against the operation policy before the file is
written, and every value in the script is quoted. Nothing in the library or in
any client changes.

## Raycast shortcuts

The companion extension lives at
[`integrations/raycast/agent-tooling`](../../integrations/raycast/agent-tooling).
It can search the local inventory, queue a skill request, check setup,
open the Apps screen or Insights, and focus the app. It finds the signed CLI
helper inside `Agent Tooling.app/Contents/Helpers/agent-tooling`; no separate
shell setup is needed for a packaged build.

Until the extension is published in the Raycast Store, import it locally:

```sh
cd integrations/raycast/agent-tooling
npm ci
npx ray login
npx ray profile
npm run dev
```

Set `author` in the extension's `package.json` to the handle returned by
`ray profile`, then assign the six command hotkeys in Raycast Settings. Skill
instructions travel over stdin and the extension can only open review screens;
all installation and sync mutations remain in the desktop app.

## Backup and restore

`Prepare backup` makes a local Git-initialized export containing portable
packages, desired state, and a source lock. It intentionally does not add a
remote. `Inspect backup` compares skills, profiles, and sources before a
restore; conflicting desired state must be explicitly accepted, and the prior
managed library is retained as a rollback artifact.

## More than one Mac

Every Mac has a complete workspace of its own: the shared library, its own
device state, its own content store, its own receipts. Macs converge through a
private Git repository you connect (Settings › Sync) that acts as a mailbox:
each Mac reads what is there, merges in its own engine, and publishes on top of
exactly what it read. Nothing is force-pushed; no Mac depends on another being
awake. The repository carries the library's records, the files of skills you
wrote here (so another Mac can install them), and each Mac's own one-page
status. It never carries credentials, observed state, receipts, or folders.

**Second Mac.** On first launch choose *Join another Mac's workspace* and
paste the repository address. The Mac adopts the shared library, scans itself,
registers under its computer name, and shows up under Settings › Sync › Macs
on every Mac.

**Where an install goes.** The install picker asks *Every Mac* (the default),
*This Mac only*, *Choose Macs*, or *One project*. A Mac can be set to take
only what names it (Settings › Sync › Macs, the toggle); that is how one Mac
keeps a deliberately smaller set. An item's detail shows which Macs it is for
and lets you leave one out (*Except*).

**Arrivals.** When a sync brings something another Mac asked for here, Home
shows it under *From your other Macs*. Kinds set to *Install automatically* in
Settings › Updates install on arrival; the rest wait for Install. Nothing runs
on another Mac from this one: assigning to a Mac saves what it should have, and
it installs on its next sync.

The sidebar's foot says when this Mac last synced and when the others were
last seen. The Macs menu beside the app title opens another Mac's last report.
Design: [docs/multi-mac-sync-v1.md](../../docs/multi-mac-sync-v1.md).

`Encrypted folder sync` remains as a second transport for a folder a file-sync
service keeps in step. It carries records only, never skill files, and has not
had a two-Mac run.

Organizations can also distribute a reviewed local `agent-tooling-policy/v1`
JSON manifest through that folder or a checkout. It is data only: the app can
import managed profiles, required component lists, and named blocked plugins;
it will not execute policy-provided scripts or fetch a policy in the background.

## Development requirements

- macOS 26 or newer
- Xcode 27 or newer
- Swift 6.2 or newer

## Design tokens

Every view draws from the scales in `Sources/AgentToolingApp/DesignTokens.swift`
(and the colours, motion and page layout insets in `Theme.swift`) and nowhere
else. A raw number in a view is treated the way a raw hex colour would be.

- `AgentFont` — the type scale: `pageTitle` 20, `titleLarge` 17, `title` 15,
  `body` 13, `caption` 11, `micro` 10, plus `heading` for card titles, `mono`
  for paths and commands (`monoMicro` for a tool's raw output), `stat` for a
  headline number, and `capsKerning` for an all-caps label.
- `Space` — a 4-point grid (`xxs` 2 … `xxxl` 24, `huge` 32) for padding,
  stack spacing, and insets, with `nudge` 1 for lining a glyph up with the
  first line of text beside it.
- `WorkspaceLayout` (in `Theme.swift`) — the page's own insets, which every
  screen's heading, filters and content share: `pageInset` 24,
  `contentTopInset` 12, `sectionSpacing` 24, `paneInset` 20 for a sheet's body
  or an inspector's detail, and `floatingBarInset` 34 for a bar floating over
  a collection.
- `Radius` — `sm` 6 chips, `md` 8 controls and selection, `lg` 12 cards,
  `xl` 16 the palette. `RoundedRectangle.card/.control/.panel` are the shapes.
- `Size` — row and header heights, glyph, tile, disc, mark and identity-icon
  sizes, control heights, the sheet bar; field, search, picker and popover
  widths (`fieldNarrow` 160 … `fieldWide` 420, each named for the field it
  sizes, such as `fieldStandard` 320 for a field or picker in a form or detail
  pane like a preset's, or `fieldCapped` 300 for a URL or path in an editing
  sheet); pane widths for each split (the shared list/detail split, the
  sidebar, the History, skill creator and source editor columns); empty-state
  and placeholder heights; Discover card sizes.
- `SheetSize` — the fixed sheet sizes, from `popover` to `creator`; a sheet
  picks the smallest it fits in. The few that resize (the setup wizard, the
  ToolHive inspector) take a minimum and an ideal through
  `sheetSize(minimum:ideal:)`. `WindowSize` holds the main window's minimum
  and opening size and the Settings window's width.
- `CollectionColumn` — the hand-laid columns of the Skills, Plugins and
  Connections tables: shared widths (`clientMarks`, `source`, `narrow`,
  `nameMax`) at the top, and per table the width it switches layout at
  (`expandedFrom`), its name column's floor, share and ceiling, and its other
  columns, all measured on a table's inner width (its card less `Space.xl` on
  each side). `ListCellMargin` is what a native `List` adds around a row's
  content on its own (8 leading, 9 trailing), which a table row gives back so
  its columns stand under the header's titles.
- `Proportion` — the ratios a tile, disc or identity icon scales by, and the
  shares of a split's ideal width (`listShare` 0.55, `detailShare` 0.45,
  `evenShare` 0.5).
- `Opacity` — how strongly something is drawn, named by job in four
  families: washes under content in its own tint (`noticeWash`, `bannerWash`,
  `tagWash`, `badgeWash`, `selectedWash`, `messageWash`), the strokes that
  edge them (`noticeStroke`, `bannerStroke`, `selectedStroke`), neutral
  grounds at part strength (`editorWell`, `paneShade`, `insetGround`), and
  fades (`track`, `disabled`, `pulseLow`, `ghost`, `inactive`, `unavailable`,
  `quiet`, `supporting`, `secondaryOnSelection`, `labelOnSelection`).
  `Saturation.ghost` goes with `Opacity.ghost`.
- `Elevation` — the two shadows, `floatingBar` and `palette`, cast with
  `elevation(_:)`.
- `Hairline` — the one separator, drawn in `AgentTheme.hairline` (primary at
  10%) so it lifts in dark mode and shades in light on any material; a
  `Divider` darkens on a vibrant card. `Hairline(.vertical)` between cells.
  A bare `Divider()` belongs only inside a menu, where the system draws it.
  `Hairline.width` 1 is a drawn border, `ring` 1.5 a selection ring, `fine`
  0.5 a Discover card at rest.
- `AbsentMark` — what a row of client marks shows for an app that does not
  have the item: a small empty ring in `AgentTheme.absentMark`, which keeps at
  least 3:1 against a card in both appearances. Filled mark against empty ring
  is a difference of shape, so absence never rests on a faded colour alone. On
  a selected row the ring takes the row's secondary foreground
  (`AgentTheme.onSelection` at `Opacity.secondaryOnSelection`), which keeps
  3:1 on the accent fill; `ClientMarks` and `TableClientMarks` take the row's
  `selected` for it.
- `wrapsLines()` — for text that may wrap onto more lines. Never use
  `fixedSize(horizontal: false, vertical: true)`: when such a view appears
  after the window has laid out, AppKit measures the content's minimum size at
  zero width, the text answers one word per line, and the split view grows
  past the window (`LateContentLayoutTests` guards this).
- `AgentTheme.fillSubtle/fillHover/fillStrong`, `shadow`, `scrim`,
  `hairlineStroke` — the quiet fills and strokes.
- `AgentMotion` — `selection`, `quick` and `actionBar`, and `appearScale` for
  a row of controls fading in; `Angle.disclosureOpen` turns a disclosure
  chevron.
- `primaryActionStyle()`, `secondaryActionStyle()`, `inlineActionStyle()` —
  the three button treatments.

What stays a literal, because it is not a design value: indices and offsets
into a collection; counts and limits (how many rows to show, `lineLimit`, a
character cap, a threshold in logic, the 2 in "both sides"); time that paces
behaviour rather than motion (a debounce, a clipboard timeout, a clock's
tick); data such as picker tags and a setting's default; and 0 or 1 where they
mean none or all (opacity 0 and 1, spacing, padding and insets of 0, a scale
of 1, grayscale 0 and 1, an angle of zero). Everything else a view is drawn
with — frames, padding, opacity, shadows, offsets, kerning, ratios, column
widths, split proportions, animation durations — comes from a token. A value
two screens use for the same job is one token; a value that only happens to be
equal to another gets its own name.

The words on buttons that more than one screen shows come from
`ActionTitles`: `reviewChanges(count:)` for the button, and
`reviewChangesCommand(_:)` for the command, in title case in a menu and
sentence case in the command palette. Counted nouns come from `CountNoun`:
`CountNoun.connection.phrase(2)` is "2 connections".

Collections (Skills, Plugins, Connections, Presets, Projects, Activity,
History) sit on `collectionSurface()`. Native `List`s take
`collectionListChrome()` and each row `collectionRowChrome(selected:)`, which
switch the system's own separators off and draw the shared hairline; `Table`
cannot be quieted that way, so its former users lay their columns out by hand
inside a `List` (see `Components+Collections.swift`), and their rows take
`collectionTableRowChrome(selected:)`, which lines a row's content up with the
column titles above the list.

## Build and open the app

The packaging script compiles the executable and wraps it in a normal macOS
application bundle using the optimized release configuration. Its default output is ignored under
`.build/Agent Tooling.app`.

```sh
./scripts/package-app.sh
open '.build/Agent Tooling.app'
```

Pass a destination as the first argument when you want the bundle elsewhere:

```sh
./scripts/package-app.sh '/Applications/Agent Tooling.app'
```

Set `AGENT_TOOLING_CONFIGURATION=debug` when packaging for debugging.

## Verify

```sh
swift test --disable-sandbox
```

The three test targets share one plain `AgentToolingTestSupport` target
(`Tests/AgentToolingTestSupport`), not a product. It holds test scaffolding the
suites would otherwise copy: a self-cleaning `TemporaryFolder`, a `write(_:_:)`
file helper, real-git fixtures (`GitTestFixture`), `ScriptedCommandRunner` /
`RefusingCommandRunner`, `ContrastRatio` (the WCAG contrast between two
colours), and `fittingSize(of:)` (the size a view lays itself out at on its
own). It imports only Foundation, AppKit, SwiftUI and the public
`AgentToolingCore` API — no `import Testing`, no `@testable import` — so it
builds clean under CI's release gate
(`swift build --configuration release -Xswiftc -warnings-as-errors`). A helper
that has to fail a test returns an optional for the suite to `#require`.

[Periphery](https://github.com/peripheryapp/periphery) finds unused code, the
way knip does for JavaScript. With `brew install periphery`, run
`periphery scan` in this folder; `.periphery.yml` holds the options. Some of
what it lists is kept on purpose: protocol witnesses and the parameters a
protocol requires, cases of public error enums, and memberwise initializers of
saved models. Staged subsystems that back a written contract but that nothing in
the app calls yet are held in `.periphery.yml`'s `retain_files`, each with a
comment naming its contract, so a scan lists only real dead code. Its
redundant-public check should report nothing: a Core declaration is `public`
only when another target uses it.

The opt-in inventory benchmark uses an isolated synthetic workspace with 500
skills, 100 plugins, and 100 MCP servers. Run it alone, with no concurrent builds
or tests, and compare the same configuration and machine:

```sh
AGENT_TOOLING_BENCHMARK=1 AGENT_TOOLING_BENCHMARK_LABEL=release \
  swift test --disable-sandbox --configuration release --filter WorkspacePerformanceTests
```

It reports first-run and warm median timings for snapshot validation, encoding,
persistence, model loading, and screen rendering. Metrics named `settle60`
include a fixed 60 ms run-loop window and are not response latency; synchronous
layout and bitmap drawing are reported separately. The fixture does not measure
network activity, real client scans, or filesystem-backed connector discovery.
Add `AGENT_TOOLING_CATALOG_BENCHMARK=1` to include a separate plugin workload
with 500 marketplace listings, or select `WorkspacePerformanceTests/catalogHeavyPlugins`
to run that workload alone.

## Verification contract

“Observed” means a read-only scan found local configuration or a CLI. “Installed”
means a target write or native CLI command has a receipt. “Authenticated” and
“cloud connector verified” require verification in the owning product; the app
will never infer them from a local installation.

## Browse skills by ownership and source

Skills opens on **All skills**, with **My skills** and **Third-party** tabs.
Source, installation type, maintenance location, and client filters are saved
locally between launches. The Source menu lists discovered bundles, including
workflow plugins. Agent Tooling marketplace plugins are classified as My skills automatically;
recognized external publishers are classified as Third-party. Skill details explain
the evidence and allow a saved override or a return to automatic classification.
Unknown publishers and standalone skills without provenance remain unclassified;
standalone overrides apply individually. Classification never changes installed files.

My skills separates **Maintained here** from **Maintained elsewhere**. Skills
created or copied into the library are maintained here. Repository and plugin
skills can remain maintained elsewhere, with a link to reveal their observed
installed source. Copying a discovered skill into the library creates a separately
maintained standalone copy; it does not migrate its plugin dependencies or merge
publisher updates. Existing distinct skill identities are preserved.

The skill list uses the full content width until a row is selected. Selecting a
skill opens a resizable detail pane; its close button or Escape restores the full
list. Tabs and search remain above the list, with source/app menus and a compact
Filters menu for installation, maintenance, and tags.

Skill details offer per-client installation and native user-level availability.
Discovered standalone skills can be copied directly to a supported client without
adoption. Plugin skills use a verified native marketplace installer for the whole
bundle. Codex installed-plugin discovery requests only installed entries; targeted
marketplace lookup avoids truncating a large available catalog during installation.

Codex switches write the documented per-path `skills.config` setting. Claude
standalone switches write `skillOverrides`; Claude plugin switches explicitly
control the whole plugin via `enabledPlugins`. These are user preferences on this
Mac, not effective project/organization policy or live session state. Restart the
client after changes. Config edits preserve unrelated entries, keep private local
backups, and refuse symlinked settings or unsupported configuration syntax.

### Copies of one skill

Several plugins often re-ship the same skill, and AIM copies its skills into
Kiro CLI's folder as plain folders. Each copy is its own entry in the library,
but the Skills list shows one row per skill: the name a client calls it by,
without a plugin's `plugin:` prefix. Grouped by plugin, each plugin still shows
its own copy. A row with copies carries a badge: **3 copies**, or **2
versions** when their contents differ. Contents are compared by a hash of each
skill folder taken during the device check, with the package's build stamp
(the frontmatter `metadata:` block) ignored. A folder the check could not read
is shown as not compared, never as a match. The skill's details list every
copy with where it came from, who manages it, its version, and the apps it was
found in, and switch to any of them.

A standalone folder that AIM placed and keeps in step is shown as managed by
AIM (read from `~/.aim/state/skills/*.json`, `.aim-core-skills.json`, or the
folder's `.aim-managed` marker), and Checkup offers neither adopting nor
removing it: AIM would undo either at its next sync.

Insights judge copies once. A client records which skill it used, not which
copy, so usage of a skill's plain name is credited to it and each skill is
recommended at most once. Two different skills that share a name, told apart
by their descriptions, stay separate.

A server's details on Connections list, per app, every place that app gets a
server by that name. Claude Code runs a plugin's server alongside one with the
same name in its configuration unless the two are configured identically.

### Connections and compact browsers

The Connections screen separates account connector declarations discovered in installed Codex plugin manifests from directly configured MCP servers. Connector discovery reads bounded local `.app.json` mappings and display metadata; it does not enumerate cloud accounts or establish authentication. Empty connector results do not mean the user has no cloud connections. Account status remains explicitly unchecked.

Plugins and MCP servers use column tables with client filters. Skills, Plugins, Connections, Collections, Configurations, and Projects open with the browser filling the page; selecting an item reveals details, and Close/Escape restores the browser. Plugin and direct MCP table selections retain their existing multi-selection review actions.

# Launchpad setup v1

Status: current. This is the contract for the macOS app's setup stage
("Launchpad"): the window a Mac with no library opens on, the record it keeps,
how a later launch reads that record, what the shell may start after it, and
every way back into it. Code paths are under `apps/agent-tooling-macos/`.

## The stage

- A separate window, `Window("Set up Agent Tooling", id: "setup")`, at a fixed
  860 × 640 (`WindowSize.stage`). While setup owns the app the main window is
  suppressed; if it appears anyway, its root sends the person back to the
  stage. The workspace opens from `AppLaunchState`'s init, never from a
  window, so a launch with no window still opens it.
- One decision per screen. The footer names the step and fills one capsule
  per step reached (five on Start here, three on Join).
- ↩ is the primary and never writes to an app, the repository or a sign-in.
  ⌘↩ is the only key that does: the review panel's install, Your other Macs'
  Connect and share, Join's Join as and Finish joining, and Home's Sign in.
  A held ↩ never repeats, and a ⌘↩ repeat is ignored. A plain ↩ on a ⌘↩
  screen writes nothing, flashes the keycaps and says what ⌘↩ does there:
  "Press ⌘↩ to install", "Press ⌘↩ to connect" or "Press ⌘↩ to join"
  (`StageFooterSpec.CommandReturnHint`).
- ⎋ is layered: a popover or chooser first, then FooterConfirm's Keep going,
  then the review panel's Cancel, then the footer's later slot (Set up later
  or Stop). ⌘W and the close button open FooterConfirm, or cancel the review
  panel first. Nothing happens while something is finishing.

### Paths

| path | steps |
|---|---|
| Start here | Welcome → Your apps → What Agent Tooling reads → the read → Your library, as read → Start your library → Put in apps → Let your apps ask → [review] → Let your assistant help → How Agent Tooling behaves → Your other Macs → Done |
| no app found (V01) | Your apps → Continue without apps (an empty library) → Start your library (catalogs only) → How Agent Tooling behaves → Your other Macs → Done |
| no assistant managed | as Start here, without Let your assistant help |
| Join | Welcome → Join → You joined → ([review] or Install later) → Let your assistant help → How Agent Tooling behaves → Done |
| Join's detour | You joined → Let your apps ask → [review] → You joined; the footer keeps "Arrivals" and 2 of 3, and a join picked up again at Let your apps ask (left for later, quit, or relaunched by the move) is on the detour again |
| rerun | Your apps (no Back, no fork) → the read, which updates the library → the rest as Start here |

A step the table passes over records its screen's reason for Done
(`LaunchpadOutcomes.skipped`).

### The commit point

The library's existence. Before it nothing is on disk, and leaving quits
setup and keeps nothing. Start here commits when the read finishes:
`WorkspaceLaunch.create` writes revision 1 with this Mac's choices, then the
setup record, then the locator record last; a Mac that already has a locator
record refuses the creation. Continue without apps commits an empty library
the same way. Join commits as its store is made, and writes the record there
before the locator (`afterStoreCreated`).

After the commit, the read's own step stays on screen until Continue; leaving
then keeps the cursor the commit recorded (Your library), so coming back
never reads again.

### What each step writes

| moment | written |
|---|---|
| the read finishes | revision 1, the record {in progress, start here, cursor Your library}, the locator; then the sign-ins as they land, then the stage audit |
| Continue without apps | the same, with no observations and no chosen apps |
| Join ⌘↩ | a fresh checkout and the library read, this Mac's apps read; then the store with this Mac's choices, the sync enrollment, the record {in progress, join, cursor Join}, the registration, the first sync, and the locator last; then cursor You joined |
| a step reached after the commit | the record's cursor and seen steps (a first run or a resume only) |
| Start your library | one library revision; each S08 sheet save is its own |
| Put in apps | one library revision; also adds its placements to `setup-placements.json` (every path) |
| Let your apps ask | one library revision |
| the review's ⌘↩ | the executor's writes and receipts, then the re-check of the apps whose own tool ran |
| Let your assistant help, How Agent Tooling behaves | one device revision per change; appearance and the menu-bar item are app preferences |
| Connect and share ⌘↩ | enrollment, registry row, first publish |
| Done | the record, finished |
| Go to Home from FooterConfirm | a first run: left for later at the cursor; a resume: the cursor only; a rerun or a revisit: nothing |
| Quit setup from FooterConfirm | nothing; before the commit nothing is on disk, and at J01's Finish joining the record already says the join is unfinished, so FooterConfirm says the next launch offers Finish joining again |
| untick an app on Let your apps ask that Agent Tooling connected | one library revision withdrawing this Mac's ask; the review then runs the app's own `mcp remove` (D10) |

## The record

`<container>/setup-progress.json`, next to `setup-checkup.json`, where
`<container>` is `<support>/workspaces-v1/<workspace id>/`. It is the app's
own file, not device state: a device write mints a portable revision and a
History restore point, and moving a cursor is worth neither.

It is written whole: staged beside the file, made readable by this Mac's user
only (mode 0600), then renamed into place, so it is never seen half written.
JSON with ISO 8601 dates and sorted keys; `seen` is written in the steps' own
order, so the same record always writes the same bytes. Nothing larger than
256 KiB is read.

| field | meaning |
|---|---|
| `formatVersion` | 1 |
| `state` | `inProgress` (a first run not handed off: the only state that takes over a launch), `deferred` (left for later), `finished` (Done reached, on any path) |
| `path` | `startHere`, `join` or `rerun` |
| `cursor` | the step a resume opens at |
| `seen` | every step this setup showed; "has seen How Agent Tooling behaves" gates the network catalogs |
| `startedAt`, `updatedAt`, `finishedAt` | dates |
| `items` | Home's card rows, in order: `makeSkillsYours`, `putToolsInApps`, `connectAgentTooling`, `connectOtherMacs`, `signInConnections`, `lookAtCheckup`, `trySkill`, `trackProjects` |
| `ticks` | the rows done: item, place (`setup`, `home`, `library`, `discover`, `apps`, `checkup`, `projects`, `settings`, `insights`, `activity`), when, and the caption's summary. A tick latches: a later one of the same row keeps the first |
| `hiddenAt` | when the card was hidden, or absent while it shows |
| `evidence` | `personalSkillsBefore` (skills yours before this setup, so a join's arrivals never tick Make your skills yours), `placedContributionIDs` (this setup's placements), `checkupFindingIDs` (the findings left at hand-off), `trial` (the skill Home offers to try), `projectFolderCount` (folders Claude Code's history names, read with consent), `mayNeedSignIn` (connections that may need their app's sign-in before any check) |

### Tolerance

An older build reading a newer record still opens:

- an item, place, step or hint this build does not know is skipped;
- an unknown state reads as `deferred`; an unknown path as `rerun`;
- a record of a newer `formatVersion` reads as `finished`, so it never
  resumes and shows no card, and this build never writes it;
- a record with no `startedAt`, or that is not one at all, reads as no record.

### What changes it

`WorkspaceSetupProgressSession` is the only writer:

- `move(to:)` moves the cursor of an in-progress or deferred record;
- `deferSetup(at:)` leaves a first run for later;
- `finish(items:ticks:evidence:seen:now:)` makes a missing record a finished
  `rerun` one, or finishes an existing record keeping its path and
  `startedAt`: rows rebuilt, latched ticks kept, the card shown again, and the
  evidence replaced when given;
- `setChecklistHidden`, `tick` and `recordEvidence`.

A save that fails restores the record as it was and shows "This Mac could not
record that choice. Nothing was changed." Every change is saved before it is
shown as kept.

### Placements made here

`<container>/setup-placements.json` (`SetupPlacementsMadeHere`) lists the
contributions this Mac's setup placed, on any path, as each Put in apps saves
them, pruned to those the library still holds; the ones the save just
returned always stay, even when the library could not be read again after
it. A rerun writes its record only at Done, so a rerun left after Put in apps
would otherwise have no record of its own placements. The arrivals Home lists
under *From your other Macs* leave out every contribution in this list or in
the record's `placedContributionIDs`
(`WorkspaceSetupProgressSession.ownPlacements`, read at each look).

The file is `{"contributionIDs": […], "formatVersion": 1}`, with sorted keys,
written as the record is: staged beside it, mode 0600, then renamed into
place. It is read as tolerantly:

- a list with no `formatVersion` is version 1, and an ID this build cannot
  read is skipped;
- a file that is missing, larger than 256 KiB or not a list at all reads as
  an empty list, and the next save writes a new one in its place;
- a list of a newer `formatVersion` is read, so its placements are still
  never arrivals, but this build never writes over it;
- beside a newer build's record nothing is written, this list included;
  the placements a walk saves are kept for that launch only.

## Records across re-entry (D20)

- `inProgress` exists only for a first run that has not handed off.
- Resuming a `deferred` first run from Home keeps it `deferred`, moves its
  cursor, and finishes it at Done.
- A rerun writes the record only at Done: it creates a finished `rerun`
  record, or refreshes the existing one.
- Leaving a rerun or a revisit early writes nothing, and so does quitting in
  the middle of one.

## Launch

The launch decision never opens the store. `WorkspaceLaunch.recordState`
reads the locator record:

| workspace.json | other evidence | phase | entry |
|---|---|---|---|
| absent | none | setup | first run: Before you start when the copy should move, else Welcome |
| absent | exactly one container whose record is in progress on the join path | setup | Finish joining |
| newer format, damaged, or unreadable | — | unreadable | the unreadable screen |
| present | record in progress | setup | carry on at the cursor (Your library, or You joined, when the cursor is from before the commit) |
| present | record absent, deferred, finished, or newer | opening, then ready or failed | — |

`--workspace`, `--home` and `--defaults-suite` move the support folder, the
home folder and the app's preferences for a rehearsal. Give the suite as a
path inside the scratch folder (`--defaults-suite "$D/defaults.plist"`); a
suite given as a name leaves `~/Library/Preferences/<name>.plist` behind.
A suite does not cover what AppKit keeps for itself in the app's own domain.
Under a suite the main window turns off AppKit's autosave of its frame and of
its split views' dividers, so a rehearsal writes neither, but a frame this Mac
saved for the main window still applies, and the system's open and save
panels still write their size and last folder to the app's domain. A
rehearsal that must not read or write this Mac's own preferences at all runs
from a copy of the app with a bundle identifier of its own.

While setup owns the app a link only queues; at the hand-off Done's section
wins over a queued section, and queued reviews and skill creations stay
queued.

### What the shell may start

`LaunchWorkPolicy.decide(status:preferences:hints:checkedThisLaunch:)`:

| setup | launch work | check apps | audit | audit may scan | network catalogs |
|---|---|---|---|---|---|
| none (made before setup) | yes | on open | yes | on open | yes |
| in progress | no | — | — | — | — |
| left for later | yes | on open, unless just handed off | unless just handed off | on open | once How Agent Tooling behaves was seen |
| finished | yes | on open, unless just handed off | unless just handed off | on open | yes |

Just handed off means the walk handing off read this Mac's apps and audited
them in this launch: Start here's read, a rerun's read, or a join that read
the apps it chose. That read then stands as this launch's check. A walk
carried on from an earlier launch, Finish joining and a revisit read
nothing, so the shell checks and audits as on any launch. A re-check of
only the apps an install touched is not this launch's check.
The launch runs the library read with the check, then the audit, then two
lanes at once: updates (when the catalogs are allowed) then sync, and the
assistant's runs. Write-triggered sync and incoming reviews wait while the
stage is open over the shell, then one pass runs.

## Consent (D16, D27)

`DeviceWorkspacePreferences.assistantRuns` holds `AssistantRunConsent`
(`weeklyReview`, `dailyDeepDive`, `localInsights`; independent switches):

- nil, on a workspace made before the choice existed, means the runs it always
  had: weekly review and daily deep dive on, local insights off
  (`existingBehaviour`);
- a new setup and a join seed every run off;
- Let your assistant help records each switch as it changes; on a workspace
  made before the choice, its Continue records the runs it showed;
- Home shows a one-time notice while `assistantRuns` is nil and Claude Code or
  Codex is managed, naming the assistant (Claude Code first, else Codex);
  recording any choice, there, at Let your assistant help or in Settings ›
  General, ends it;
- every recording goes through `WorkspaceLaunch.Workspace.recordAssistantRuns`,
  which stops a scheduled run the new choice no longer allows before saving;
- a manual review sends conversation summaries only while the weekly review is
  allowed; a failed scheduled review is tried again after a day.

`findsProjectsFromClaudeHistory` (D17) is nil for on. What Agent Tooling reads
sets it for the read; a join seeds it off; a rerun's read records its choice
as this Mac's once the library has taken the read. Home never runs project
discovery.

## Quitting

| work | stops | finishing sentence |
|---|---|---|
| the read | while reading | "Creating your library…", or "Updating your library…" on a rerun, while the library is made |
| a join | until its store exists, and its sign-in reads after it lands | "Finishing joining…" |
| an install | — | "Stopping after this step…", shown in the review's bar from ⌘Q until the step under way ends |
| Connect and share | its checks | "Publishing…" |

⌘Q, the menu-bar item's Quit and the Dock's Quit stop what can stop, within
two seconds, wait out what is finishing with no limit, then, when anything
finished, stop what that left running (the read's sign-in reads go on after
its commit). Work that was asked to stop and did not is not asked again, so
the quit waits one grace for it, not two. Nothing that finishes is ever left
half done.

## Ways back in

| entry | from | opens |
|---|---|---|
| rerun | the app menu's *Set Up This Mac…*, the palette's and the Apps toolbar's *Set up this Mac…*, Settings › General › Run setup again, `agent-tooling://setup` | Your apps, no fork, no Back |
| resume | Home's Resume row | the record's cursor, on its path |
| revisit | Home's Move, Connect Agent Tooling and Connect your other Macs rows | that one step; its primary or its review's Continue hands off to Home |
| carry on, Finish joining | a launch | as the launch table says |

During a first run the app menu's command is disabled and the menu-bar item
offers Show Setup. A second Set up this Mac… while the stage is open brings
it forward and never replaces the walk on screen. `agent-tooling://setup` is
a route, not a section, so the MCP server neither lists nor builds it.

Hand-off opens the main window before closing setup.
With motion enabled, setup fades first. Each presentation has its own ID:
completion and close callbacks from an earlier presentation are ignored, and
reopened setup is visible even when SwiftUI retains the window's root view.

Once the workspace is ready, **Review Changes…** in the main menu or menu-bar
item brings the main window forward, reopening it if necessary. It opens Apps
and prepares a plan; applying that plan still requires review.

## Home's card

`FinishSetupChecklist` is a pure function of `FinishSetupFacts` (one snapshot
of the workspace that runs nothing). The card shows for a record that handed
off, on a Mac that may change its library, while it is not hidden; a
workspace made before setup has no card. Rows tick on positive evidence only,
from the shell's tracker, wherever the action happens, and name where; Done's
*Left for later* and the card's open rows come from the same count. Resume and
Move are rows of their own and are not counted.

# UI restoration on the versioned store

Status: planned, not started. This document is the specification for the work;
nothing in it has been built.

## What happened

The versioned workspace replaced `WorkspaceStore` and `AppModel`. Removing them
took every screen that was bound to them: 53 files and 18,687 lines of
`AgentToolingApp`, including the whole of the previous shell — Home, Library,
Discover, Projects, Configurations, Apps, Insights, Activity, Settings.

What stands in their place is `WorkspaceShellView`: a seven-item sidebar
(Library, Projects, Presets, Install, App settings, Sync, History) over the
versioned read model. It is correct and it is testable, and it looks nothing
like the app it replaced. None of the identity tiles, brand marks, glass
treatment, command palette, or the Home surfaces survived.

The task is to bring the previous interface back on top of the versioned store.
This is a **port, not a revert**: the layouts are recoverable verbatim, the data
bindings are not.

## What survives, and why this is cheaper than it looks

Three facts decide the shape of the work.

**1. Every deleted view is one command away.** Nothing was rewritten in place;
the files were removed. `ba6e098` is the last commit that contains them — the
parent of `bb20246`, which removed them.

```
git show ba6e098:apps/agent-tooling-macos/Sources/AgentToolingApp/SkillsView.swift
git ls-tree --name-only ba6e098 -- apps/agent-tooling-macos/Sources/AgentToolingApp/
```

Read the original before porting a screen. The layout, spacing, empty states and
copy are all there and were reviewed; reinventing them loses that work.

**2. The services behind Insights, Discover and the Home surfaces were never
deleted.** Only the `AppModel` extensions that bound them to the UI were
(`AppModel+Marketplace`, `AppModel+PluginUpdates`, `AppModel+BackupSync`), plus
`ToolingInsightsStore`, a 17-line wrapper. These are all present and compiling:

| Surface | Core service that still exists |
|---|---|
| Discover / Marketplace | `Marketplace`, `MarketplaceModels`, `MarketplaceProviders`, `MarketplaceGrading`, `MarketplaceSorting`, `MarketplaceProvenanceSignals`, `DeviceMarketplaceSnapshot` |
| Insights | `ToolingInsightsService`, `ToolingInsightsModels`, `LocalConversationScanner` |
| Needs your attention | `UpdateAvailability`, `UpdateAvailabilityEvaluator` |
| Risk and validation badges | `ContentRiskScanner`, `ConnectorValidator` |

They are live code with no caller. Restoring their screens means giving them a
caller again, not rebuilding them.

**3. The adapter between the two worlds already exists.** Those services consume
the pre-versioned domain types — `ToolingInsightsService.scan` takes `[Skill]`
and `[MarketplacePackage]`; `UpdateAvailabilityEvaluator` takes `Plugin` and
`MarketplacePackage`. `VersionedInventoryProjection` already produces exactly
those from a versioned document:

```swift
public enum VersionedInventoryProjection {
    public struct Inventory: Sendable, Equatable {
        public var skills: [Skill]
        public var mcpServers: [MCPServer]
        public var plugins: [Plugin]
    }
}
```

So a restored view can bind to `Inventory` roughly where it used to bind to
`AppModel`'s collections. This is the single most important thing to know before
starting: **do not write a new bridge, and do not change the surviving services
to speak the versioned types.**

## What the versioned side offers

`WorkspaceLaunch.open()` returns a `Workspace` holding every session:

| Session | Screen it belongs to |
|---|---|
| `library: WorkspaceLibrarySession` | Library, Projects — the read model |
| `presets: WorkspacePresetsSession?` | Presets |
| `deployment: WorkspaceDeploymentSession` | Install |
| `settings: WorkspaceSettingsSession` | App settings |
| `sync: WorkspaceSyncSession?` | Sync |
| `history: WorkspaceHistorySession` | History |
| `authoring: WorkspaceAuthoringSession` | Attach / author a source |
| `export: WorkspacePackageExportSession` | Export a package |
| `declarations: WorkspaceProjectDeclarationSession` | Project declarations |

`WorkspaceLibraryReadModel` is the presentation index. Per row it carries
`displayName`, `kind`, `ownership`, `sourceLabel`, `observedDescription`,
`includedChildren` (a plugin's own skills and servers), `requestedAssignments`,
`isAssignable`, `assignableReasons` and `nativeRoutes`; the model carries
`presets`, `projects`, `toolCount`, `nestedToolCount` and
`filteredRows(matching:)`.

Two properties of the read model that the old UI did not have to respect, and
which the restored UI must:

- **Assignment intent is not installation.** `requestedAssignments` records
  where someone asked for a tool. It must never be rendered as "installed".
  Installing stays a separate, reviewed step on the Install screen.
- **Ownership is authority, not a badge.** `trackedOnly` items are not
  assignable and carry `assignmentExplanation` saying why. Do not offer actions
  the authority forbids.

## The port map

Sizes are the originals at the pre-removal commit.

### Group A — data exists, rebind and go

| Old view | Lines | Binds to now |
|---|---|---|
| `SkillsView` | 1087 | `library` read model rows, `kind == .skill` |
| `PluginsView` | 526 | rows where `kind == .nativePlugin`/`.package`, `includedChildren` |
| `MCPServersView` | 971 | rows where `kind == .mcpServer`; `MCPRuntime` for live state |
| `ProjectsView` | 826 | `library.projects` + `declarations` |
| `SettingsView` | 796 | `settings` (already ported as `WorkspaceSettingsView`; restore the visual) |
| `ActivityView` | 405 | `history` + the store's activity journal |
| `CollectionsView` | 1079 | `presets` — collections became presets; check the vocabulary before porting |
| `ProfilesView` | 578 | `settings` layers |
| `SyncCenterView`, `SyncConduitView` | 542 | `sync` |
| `PlanReviewSheet`, `PendingRequestReviewSheet` | 580 | `OperationPlan` / pending requests |
| `ToolHiveWorkloadInspector` | 229 | `ToolHiveRuntimeInspection`, `ToolHiveLifecycleService` |

### Group B — service exists, needs a session and a projection

| Old view | Lines | Wire through |
|---|---|---|
| `OverviewView` (Home) | 558 | `VersionedInventoryProjection` + `UpdateAvailabilityEvaluator` + insights recommendations |
| `InsightsView` | 839 | `ToolingInsightsService.scan(...)` fed from the projection |
| `MarketplaceView` (Discover) | 1111 | `Marketplace` + `MarketplaceProviders` |
| `MarketplaceSignalViews` | 357 | `MarketplaceProvenanceSignals`, `MarketplaceGrading` |

Each of these needs a small `@Observable` session in `AgentToolingApp` in the
same shape as the existing ones (`WorkspacePresetsSession` is the clearest
model): hold the service, expose loaded state, `refresh()` off the main path,
never block the shell on a scan.

### Group C — chrome, mostly presentation

| Old view | Lines | Notes |
|---|---|---|
| `AppShellView`, `SidebarView`, `AppSection`, `AppNavigationState` | 667 | The sidebar grouping (Workspace / Utilities) and section identity |
| `CommandPalette` | 483 | ⌘K over the read model's `filteredRows(matching:)` |
| `ToolIdentityIcon`, `UpdateStateBadge`, `SectionHealth` | 231 | Identity tiles and status glyphs; `Components.swift` already has `KindTile`, `StatusGlyph`, `AttentionBanner` |
| `OnboardingWizard` and rows | 931 | Reconcile with the existing `WorkspaceOnboardingView` rather than restoring both |

### Group D — do not restore

`WorkspaceMigration*` (1398 lines across six files), `WorkspaceAuthorityLaunch`,
`WorkspacePreviewLaunch`, `ClientSelectionView`, `ClientVerdict`. The machinery
they drove is gone by design; a versioned workspace cannot have a pre-versioned
checkpoint to migrate.

`AccountsView` (404) and `CodexSkillCreatorSheet` (609) need a decision before
any work: the first depends on account state this build no longer keeps, the
second on `CodexSkillDraftRequestStore`, which was removed.

## Order

1. **Group C first.** The shell, sidebar, identity tiles and theme decide how
   everything else looks. Porting a screen before the chrome means porting it
   twice.
2. **Group A, largest first.** Skills, then Plugins, then MCP servers. These
   three are most of the app's daily use and need no new sessions.
3. **Group B.** Home last of the three, since it composes what Insights and
   Discover produce.
4. **Reconcile onboarding** once Home exists.

## Verification

`Tests/AgentToolingAppTests/WorkspaceShellRenderTests.swift` renders every shell
screen over a real workspace and fails on a blank frame; it carries a negative
control proving the blank-frame check can fail. **Add each restored screen to
it as it lands.** A screen that is not in that file is a screen nobody has
confirmed draws.

Beyond that, per screen:

- The full suite stays green (`swift test`).
- Actually launch it. `swift build --product AgentTooling` then
  `.build/debug/AgentTooling --workspace <scratch dir>` against a scratch root,
  so a first run cannot write into the real support directory. Capture the
  window by **window id**, not screen region — a stale build of this app may
  well be running, and both processes are named `AgentTooling`.
- No screen may present requested assignment as installation.

# UI restoration on the versioned store

Status: planned, not started. Revised 2026-09-09 after a verification pass
against `main` at `9272c5e`: every commit, line count, file and type named
below was checked against that tree. Nothing in it has been built.

## What happened

The versioned workspace replaced `WorkspaceStore` and `AppModel`. Removing them
took every screen that was bound to them: 53 files and 18,687 lines of
`AgentToolingApp`, including the whole of the previous shell — Home, Library,
Discover, Projects, Configurations, Apps, Insights, Activity, Settings — and 27
of the app target's test files with them.

What stands in their place is `WorkspaceShellView`: a seven-item sidebar
(Library, Projects, Presets, Install, App settings, Sync, History) over the
versioned read model. It is correct and it is testable, and it looks nothing
like the app it replaced. The identity tiles on rows, the brand-mark columns,
the ⓘ path popovers, the command palette, the sidebar client verdicts, the
menu-bar item, the app commands and the Home surfaces are gone.

The task is to bring the previous interface back on top of the versioned store.
This is a **port, not a revert**: the layouts are recoverable verbatim, the data
bindings are not.

## What survives, and why this is cheaper than it looks

Five facts decide the shape of the work.

**1. Every deleted view is one command away.** Nothing was rewritten in place;
the files were removed. `ba6e098` (#64) is the last commit that contains them —
the parent of `bb20246`, which removed them and was squash-merged to `main` as
`9272c5e` (#65).

```
git show ba6e098:apps/agent-tooling-macos/Sources/AgentToolingApp/SkillsView.swift
git ls-tree --name-only ba6e098 -- apps/agent-tooling-macos/Sources/AgentToolingApp/
```

Read the original before porting a screen. The layout, spacing, empty states and
copy are all there and were reviewed; reinventing them loses that work.

`ba6e098` is also the right *visual* base. The Tahoe design pass
(`docs/tooling-control-center-mockups/tahoe/design-system.md`) landed as #59,
and #64 evolved it further. The remote branch
`claude/frontend-design-refinement-34a2e2` is that already-merged work, seven
commits behind `main`; do not port from it. `AmbientBackdrop`, the drifting
mesh gradient the design document still describes, was removed on purpose in
#60. Leave it out.

**2. The theme and the chrome primitives survived.** `Theme.swift` (glass
backdrop, pane material, row selection, group-box style) is byte-identical to
`ba6e098`, `ClientBrandIcon.swift` is intact, the current screens already use
`.buttonStyle(.glass)` and `PageToolbar`, and `Components.swift` still defines
`KindTile`, `SymbolTile`, `StatusGlyph`, `AttentionBanner`,
`InventorySearchField` and `WorkspaceSegmentedPicker`. What was cut is the rest
of `Components.swift` (1,097 → 272 lines):

`ClientMarks`, `ClientDisc`, `SelectionRowBackground`, `StatusBadge`,
`InspectorHeader`, `PanelHeader`, `TitledCard`, `InfoRow`, `TagCloud`,
`CollectionPills`, `TagPills`, `FilterPill`, `TagFilterBar`, `EmptyStateView`,
`SelectionCheckbox`, `SelectionActionBar`, `LabeledValueRow`,
`CommandDisclosure`, `ClientStatusRows`, `SectionCaption`, `ToolingMatrixRow`,
`ToolingMatrixView`, `LocationText`, `PathInfoButton`, `CompactPathText`,
`TableClientMarks`.

None of them touched `AppModel`; they depend on `ClientState`, which still
exists. Restoring that file is the first step and the cheapest one: it is the
row grammar (tile · name · one clause · marks · verdict) and the ⓘ popover that
every other screen is built from.

**3. The services behind Insights, Discover and the Home surfaces were never
deleted.** Only the `AppModel` extensions that bound them to the UI were
(`AppModel+Marketplace`, `AppModel+PluginUpdates`, `AppModel+BackupSync`), plus
`ToolingInsightsStore`, a 17-line wrapper. These are all present and compiling.
The table names types, not files:

| Surface | Core types that still exist |
|---|---|
| Discover / Marketplace | `MarketplaceProvider`, `MarketplaceQuery`, `MarketplacePage` (`MarketplaceProviders.swift`); `MarketplacePackage`, `ToolingSource`, `NativeInstall` (`MarketplaceModels.swift`); `MarketplaceGrading`, `MarketplaceSorting`, `MarketplaceProvenanceClassifier`, `PackageClassificationVerdict`, `DeviceMarketplaceSnapshot` |
| Insights | `ToolingInsightsService.scan(...)` → `InsightsReport`, `ToolRecommendation`, `SkillUsageMetric`, `SkillQualityFinding`; `InsightScanOptions`; `LocalConversationScanner` |
| Needs your attention | `UpdateAvailability`, `UpdateAvailabilityEvaluator.evaluate(...)`, `UpdateAvailabilityEvaluator.catalogPackage(for:in:)` |
| Risk and validation badges | `ContentRiskScanner`, `ConnectorValidator`, `OperationPlanSafetyReview` |
| MCP test console | `MCPTestTarget`, `MCPTestConnectionPolicy`, `MCPLiveTool`, `MCPToolCallOutcome`, `MCPLiveObservation` (`MCPLiveTest.swift`) |
| MCP runtimes and ToolHive | `MCPRuntimeStatus`, `MCPRuntimeServer`, `RuntimeCapability`; `ToolHiveRuntimeInspection`, `ToolHiveLifecycleService`, `ToolHiveWorkloadStatus` |
| Skill authoring | `SkillDraft`, `MCPDraft`; `PastedDefinitionParser`, `PastedSkillImport`, `PastedMCPServerDraft`; `SkillRepositoryService`, `SkillRepositoryBinding`; `CodexSkillDraftService` (actor), `CodexSkillDraftRequest` |
| Review queue and journal | `PendingAgentRequest`, `PendingRequestQueueService`; `WorkspaceRevisionStore.activityJournal(as:default:)` and `recordOperationReceipt`; `OperationReceipt`; `ManagedInstallLedger`, `InstalledPackageDrift` |
| Client observation | `TargetObservation`, `InventoryCompiler`, `ClientExecutableLocator`, `HealthState`, `ClientState`; `WorkspacePreferences.enabledClients` |

They are live code with no caller. Restoring their screens means giving them a
caller again, not rebuilding them.

**4. The adapter between the two worlds already exists.** Those services consume
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

**5. The observation path survived too.** `WorkspaceFirstRun` takes
`[TargetObservation]` compiled by `InventoryCompiler`, and
`WorkspaceDeploymentSession` already calls `ClientExecutableLocator`. What the
old `runDoctor`, `clientVerdict` and `visibleTargetObservations` did is still
possible; nothing exposes it to a screen yet. See "What it does not offer yet".

## What the versioned side offers

`WorkspaceLaunch.open()` returns a `Workspace` holding every session:

| Session | Screen it belongs to |
|---|---|
| `library: WorkspaceLibrarySession` | Library, Projects — the read model; `reviewAssignments`, `reviewPreset`, `reviewRemoval`, `applyReviewedAssignments` for intent |
| `presets: WorkspacePresetsSession?` | Presets — the old Collections |
| `deployment: WorkspaceDeploymentSession` | Install — and the old Apps centre: `prepare()`, `plan`, `apply()`, `results`, `linkedDestinations`, `canApply` |
| `settings: WorkspaceSettingsSession` | App settings — the *effective native settings* inspector (layers, `managedPolicyPath`, editable rows). Not the old Configurations |
| `sync: WorkspaceSyncSession?` | Sync — Git and encrypted-folder transport between Macs. This is what the old Settings backup and encrypted-sync sections did |
| `history: WorkspaceHistorySession` | History — restore points only, not the activity journal |
| `authoring: WorkspaceAuthoringSession` | Attach or detach an authored skill folder |
| `export: WorkspacePackageExportSession` | Export one item as a folder — the old Collection sharing |
| `declarations: WorkspaceProjectDeclarationSession` | Project declarations and locks |

`WorkspaceLibraryReadModel` is the presentation index. Per row it carries
`displayName`, `kind`, `ownership`, `sourceLabel`, `parentPluginLabel`,
`observedDescription`, `includedChildren` (a plugin's own skills and servers),
`requestedAssignments`, `isAssignable`, `assignmentExplanation`,
`assignableReasons` and `nativeRoutes`; the model carries `presets`, `projects`,
`toolCount`, `nestedToolCount`, `rows(inProject:)`,
`assignedItemCount(inProject:)`, `globallyAssignedRows` and
`filteredRows(matching:)`.

Two properties of the read model that the old UI did not have to respect, and
which the restored UI must:

- **Assignment intent is not installation.** `requestedAssignments` records
  where someone asked for a tool. It must never be rendered as "installed".
  Installing stays a separate, reviewed step on the Install screen.
- **Ownership is authority, not a badge.** `trackedOnly` items are not
  assignable and carry `assignmentExplanation` saying why. Do not offer actions
  the authority forbids.

### What it does not offer yet

Four things the restored screens reach for have no session. They are small, and
they are the only genuinely new code in this plan:

| Missing | Old `AppModel` members | Build |
|---|---|---|
| Client observation and verdicts | `visibleTargetObservations`, `clientVerdict`, `runDoctor`, `isRunningDoctor`, `enabledClients`, `isClientEnabled`, `availableClients` | `WorkspaceDeviceSession`: run `InventoryCompiler` and `ClientExecutableLocator` off the main path, hold `[TargetObservation]`, derive one `ClientVerdict` per `ClientKind` (`healthy` / `attention` / `pending` / `unavailable`), own `WorkspacePreferences.enabledClients` — core has the type; nothing reads it |
| Activity | `visibleActivities`, `visibleOperationReceipts`, `visibleInstallDrift` | `WorkspaceActivitySession` over `activityJournal(as:default:)`, recorded `OperationReceipt`s and `ManagedInstallLedger` drift |
| Pending agent requests | `visiblePendingAgentRequests`, `acceptPendingRequest`, `rejectPendingRequest`, `refreshPendingRequests` | `WorkspaceRequestSession` over `PendingRequestQueueService` |
| Insights, Discover | `visibleInsightsReport`, `runInsightsScan`, `isScanningInsights`; `visibleMarketplacePackages`, `refreshMarketplace`, `visibleSources`, `addMarketplaceSource` | `WorkspaceInsightsSession`, `WorkspaceMarketplaceSession` (Group B) |

Model each on `WorkspacePresetsSession`: `@MainActor @Observable final class`,
`private(set)` state, `isBusy`, `errorMessage`, `refresh()` off the main path,
never block the shell on a scan. **Take the service as an `init` parameter typed
by a protocol**, so the render test can hand in a stub that returns canned data
and never touches the network, `~/.claude`, or a real client.

Three concepts have no versioned home and are **not** to be invented on the UI
side: tags (`allTags`, `tagAssignments`, `applyTagEdits`), project scan roots
and pinning (`projectScanRoots`, `setProjectPinned`), and connector inventory
(`visibleConnectors`, `Connector`). Port the screens without them and let the
empty state say so, or raise a schema change separately.

## Vocabulary traps

Four names changed meaning between the two models. Each of them caught the
first version of this plan.

| Old screen | Old meaning | Versioned equivalent |
|---|---|---|
| **Sync** — `SyncCenterView`, section `.syncCenter`, titled "Apps" | Push the configuration to the local clients; one verdict per client; pending agent requests; receipts | `deployment` + `WorkspaceDeviceSession` + `WorkspaceRequestSession`. **Not** `WorkspaceSyncSession` |
| **Sync** — the new `WorkspaceSyncView` | Git and encrypted-folder transport between Macs | What the old *Settings* backup and encrypted-sync sections did |
| **Configurations** — `ProfilesView`, `ToolingProfile` | Which plugins, servers and skills a scope requires; apply one | Assignments (`requestedAssignments`, `PortableDestination`) plus presets. **Not** `WorkspaceSettingsSession`, which explains native settings files |
| **Collections** — `CollectionsView` | A reusable shelf a Configuration includes; also tags | `presets`. Tags have no home |
| **Settings** — `SettingsView` | Backup, encrypted sync, managed policy, MCP runtimes and ToolHive, appearance, diagnostics | Split: `sync` (backup, encrypted sync), `settings` (managed policy), a runtimes pane over `MCPRuntimeStatus` and `ToolHiveRuntimeInspection`, and `AppearanceSettingsView`, which survived |

## Rebind reference

The `AppModel` members the deleted views used most, and what replaces each.
Members not listed here are screen-local and appear in the port map.

| Old `AppModel` member | Versioned replacement |
|---|---|
| `visibleSkills`, `visiblePlugins`, `visibleMCPServers` | `library.state?.library.rows` filtered by `kind` for lists; `VersionedInventoryProjection` → `Inventory` for the surviving services |
| `isInteractionLocked` | `isBusy` on the session in use |
| `lastError`, `presentError`, `dismissError` | `errorMessage` on the session in use |
| `workspacePath`, `repositoryPath` | The store container. Behind ⓘ only, never in a row |
| `pendingPlan`, `planInstall`, `planSkillAdoption`, `planPluginUpdate`, `planPluginRemoval`, `planMCPConfiguration`, `planMCPRemoval`, `planMarketplaceInstall`, `reviewComposedPlan` | Intent: `library.reviewAssignments` / `reviewRemoval` / `applyReviewedAssignments`. Writes: `deployment.prepare()` then `apply()` |
| `executePendingPlan`, `discardPendingPlan`, `isExecutingPlan` | `deployment.apply()`, `deployment.isBusy`; `deployment.plan` is a `WorkspaceDeploymentPlan` |
| `runSync`, `isSyncing`, `attentionCount` | `deployment.prepare()` / `apply()`; attention = plan steps + undecided sync conflicts + pending requests |
| `createSkill`, `updateSkill`, `updateSkillSource`, `skillSource` | `WorkspaceApplicationService.intakeStandaloneSkill`, `updateStandaloneSkill`, `skillContent(artifactID:revisionID:)`; `authoring.attach` / `detach` |
| `installSkillPlugin`, `adoptableSkillIDs`, `canAdoptSkill` | Assignment intent on the row; nothing installs from Library |
| `setSkillEnabled`, `isSkillEnabled` | `requestedAssignments[].desiredEnabled` through `reviewAssignments` |
| `collections`, `createCollection`, `setCollectionMembership`, `exportCollection` | `presets` (`WorkspacePresetsSession`, `WorkspaceLibraryPresetReadModel`); `export` |
| `profiles`, `activeProfileID`, `effectiveProfile`, `applyProfile` | No equivalent; see Configurations above |
| `visibleProjects`, `addProject`, `forgetProject` | `library.projects` (`WorkspaceLibraryProjectReadModel`); `declarations` |
| `pluginUpdateAvailability`, `pluginUpdateRoute` | `UpdateAvailabilityEvaluator.evaluate` over `Inventory.plugins` × the marketplace session's packages |
| `visibleOperationReceipts`, `visibleActivities`, `visibleInstallDrift` | `WorkspaceActivitySession` |
| `inspectToolHiveWorkload`, `toolHiveLogs` | `ToolHiveRuntimeInspection` |
| `isRefreshingMCPRuntimes`, `mcpRuntimeError` | `MCPRuntimeStatus` / `MCPRuntimeServer` |
| `backupConfiguration`, `encryptedSyncConfiguration`, `inspectBackup`, `importEncryptedSyncRecoveryKey` | `sync` — already in `WorkspaceSyncView` |
| `managedPolicies`, `importManagedPolicy` | `settings.managedPolicyPath`, `managedPolicyUnknown` |
| `safetyReviewAsync` | `OperationPlanSafetyReview` over an `OperationPlan` |
| `generateCodexSkillDraft`, `adoptCodexSkillDraft`, `loadCodexSkillDraftRequest`, `saveCodexSkillDraftRequest` | `CodexSkillDraftService`, `CodexSkillDraftRequest`; adoption lands through `intakeStandaloneSkill` |
| `linkSkillRepository`, `checkSkillRepositoryUpdate`, `planSkillRepositoryUpdate` | `SkillRepositoryService`, `SkillRepositoryBinding`; the document's `sources` and `subscriptions`; ownership `centralUpstream`. Confirm an update command exists before porting the button |
| `visibleAccountSurfaces`, `visibleConnectors`, `addConnector`, `markAccountSurfaceVerified` | `AccountSurface` survives; `Connector` does not — Group D |
| `onboarding*` | `WorkspaceOnboardingView`, `WorkspaceFirstRun` |

## The port map

Sizes are the originals at `ba6e098`. Every one of the 53 deleted files appears
exactly once below, plus the two survivors that were cut down.

### Group C — chrome, first

| Old view | Lines | Notes |
|---|---|---|
| `Components.swift`, the cut half | ~825 | Restore the symbols listed under fact 2 verbatim. No data binding. Do this before anything else |
| `AppSection`, `NavigationGroup`, `AppNavigationState` | 233 | Section identity, the three sidebar groups (untitled, Workspace, Utilities), deep links, the client filter |
| `AppShellView`, `SidebarView` | 434 | `NavigationSplitView` over `WorkspaceLaunch.Workspace`; the sidebar Clients block needs `WorkspaceDeviceSession`; sheets for plan review, pending request, onboarding and the palette |
| `AgentToolingApp.swift` (324 → 122) | ~200 | Lost `.commands` (⌘⇧R sync, ⌘⇧D check setup, ⌃⌘S sidebar) and the `MenuBarExtra` (Open, Check Setup, Review sync, Quit). Restore over `deployment` and the device session |
| `CommandPalette` | 483 | ⌘K over `filteredRows(matching:)`, sections, presets and projects; marketplace results once Discover has a session |
| `ToolIdentityIcon`, `UpdateStateBadge`, `SectionHealth` | 231 | Identity tiles and status glyphs |
| `WorkspaceDeviceSession` | new | See "What it does not offer yet". The sidebar and Home both block on it |
| `OnboardingWizard`, `OnboardingChoiceRow`, `OnboardingCopyIssuesView` | 931 | Reconcile with `WorkspaceOnboardingView` and `WorkspaceFirstRun` rather than restoring both. Do it after Home exists |

### Group A — data exists, rebind and go

| Old view | Lines | Binds to now |
|---|---|---|
| `SkillsView` | 1087 | `library` rows where `kind == .skill`; assignment through `library.reviewAssignments`; content through `skillContent` |
| `SkillEditorSheet`, `SkillSourceEditorSheet`, `SkillOrganization`, `SkillInventoryIndex` | 952 | `SkillDraft`; `intakeStandaloneSkill` / `updateStandaloneSkill`; `authoring` for attach and detach |
| `SkillRepositorySection` | 142 | `SkillRepositoryService`, `SkillRepositoryBinding`; see the rebind reference before porting the update button |
| `PasteImportSheet` | 420 | `PastedDefinitionParser` → `PastedSkillImport` / `PastedMCPServerDraft` → `intakeStandaloneSkill`. An MCP draft becomes assignment intent, never a write |
| `PluginsView`, `PluginInventoryIndex` | 554 | rows where `kind == .nativePlugin` / `.package`, `includedChildren`; updates through `UpdateAvailabilityEvaluator` once Discover has a session, "not checked" until then |
| `MCPServersView`, `MCPCapabilityToggles` | 1180 | rows where `kind == .mcpServer`; `nativeRoutes`; `MCPRuntimeStatus` and `RuntimeCapability` for live state; removal through `library.reviewRemoval` |
| `MCPTestConsoleView` | 1087 | `MCPTestConsoleModel` was self-contained over `MCPTestTarget`, `MCPTestConnectionPolicy`, `MCPLiveTool`, `MCPToolCallOutcome`. A pure rebind of its `MCPServer` input |
| `ToolHiveWorkloadInspector` | 229 | `ToolHiveRuntimeInspection`, `ToolHiveLifecycleService` |
| `ProjectsView` | 826 | `library.projects`, `rows(inProject:)`, `assignedItemCount(inProject:)` + `declarations`. No scan roots, no pinning |
| `SettingsView` | 796 | Split as in the vocabulary table. `WorkspaceSettingsView` and `WorkspaceSyncView` keep their logic and take the old visual |
| `CollectionsView`, `CollectionSharing` | 1143 | `presets` (`WorkspacePresetsView` keeps its logic); sharing → `export`. No tags |
| `SyncCenterView`, `SyncConduitView` | 542 | `deployment` (plan, apply, results, linked destinations) + device-session verdicts + `WorkspaceRequestSession`. Titled "Apps" |
| `PlanReviewSheet`, `PendingRequestReviewSheet` | 580 | `OperationPlan` with `OperationPlanSafetyReview`; `PendingAgentRequest`. `deployment.plan` is a `WorkspaceDeploymentPlan`, so the sheet presents the `OperationPlan`s the deployment session builds when it applies — find where before wiring it |
| `ActivityView` | 405 | `WorkspaceActivitySession` (journal, receipts, drift) + `history` for restore points |

### Group B — service exists, needs a session and a projection

| Old view | Lines | Wire through |
|---|---|---|
| `InsightsView` | 839 | `WorkspaceInsightsSession` → `ToolingInsightsService.scan(...)` fed from `VersionedInventoryProjection`; the "draft a skill" action → `CodexSkillDraftService` |
| `MarketplaceView`, `MarketplaceSignalViews` | 1468 | `WorkspaceMarketplaceSession` → `MarketplaceProvider`, `MarketplaceQuery`, `MarketplacePage`; `MarketplaceProvenanceClassifier`, `MarketplaceGrading`, `MarketplaceSorting`; install is assignment intent that lands on Install |
| `OverviewView` (Home) | 558 | Composes: library counts from the read model; "Needs your attention" from `UpdateAvailabilityEvaluator` over `Inventory.plugins` and the marketplace session's packages; "Recommended for you" from the insights report; the conduit from device-session verdicts and `deployment.plan`. Last, because it composes the other three |

### Group D — do not restore, or decide

`WorkspaceMigration*` (1,398 lines across six files), `WorkspaceAuthorityLaunch`,
`WorkspacePreviewLaunch`, `ClientSelectionView`, and `ClientVerdict.swift` (the
struct moves into `WorkspaceDeviceSession`; the `AppModel` extension has no
home). The machinery they drove is gone by design; a versioned workspace cannot
have a pre-versioned checkpoint to migrate.

`ProfilesView` (578): **do not restore as a screen.** Its job — what is required
where, and applying it — is now Projects, Install and presets. Its per-scope
matrix (`ToolingMatrixView`) is worth reusing inside Projects.

Two decisions, with a recommendation each:

- `CodexSkillCreatorSheet` (609): **restore.** `CodexSkillDraftService` and
  `CodexSkillDraftRequest` survived as public core types, the MCP server and the
  CLI still create draft requests, and the handbook documents the flow. Only the
  app-side `CodexSkillDraftRequestStore` went; the queue it fed is
  `PendingRequestQueueService`. Adoption lands through `intakeStandaloneSkill`.
- `AccountsView` (404) and `ConnectionsView`, `ConnectionSource`,
  `ConnectorInventoryCache` (367): **defer.** `AccountSurface` survives;
  `Connector` and its inventory do not. Bringing them back is a schema decision,
  not a port.

## Order and the parallel plan

The dependency graph is shallow. Everything depends on the chrome; Home depends
on Insights, Discover and the device session; nothing else depends on anything
else.

**Phase 0 — chrome, one agent, serial.** Components, sections, shell, sidebar,
app commands, the palette shell, `WorkspaceDeviceSession`. Every section gets
its own file under `Sections/` with a placeholder body that renders the
existing `Workspace*View` where one exists and a labelled empty state
otherwise, and every section is registered in `WorkspaceShellRenderTests`. When
this lands the app shows the old information architecture end to end, and the
shell file never changes again.

**Phase 1 — ports, in parallel, one worktree each.** An agent owns the files it
restores and the one `Sections/<Name>.swift` it fills in, nothing else. The
split below is largest first; pairs share list patterns:

1. Skills, its editor sheets, paste import, organisation, the repository section
2. MCP servers, the test console, capability toggles, the ToolHive inspector
3. Apps: `SyncCenterView`, the conduit, plan review, pending requests, `WorkspaceRequestSession`
4. Discover, the signal views, `WorkspaceMarketplaceSession`
5. Insights, `WorkspaceInsightsSession`
6. Plugins and Projects
7. Presets (the Collections visual and sharing) and the Settings split
8. Activity, `WorkspaceActivitySession`, and the command palette catalogue

**Phase 2 — composition.** Home; the onboarding reconciliation; the Codex skill
creator if restored.

Rules that keep eight worktrees mergeable: after Phase 0 no agent edits
`WorkspaceShellView`, `AppShellView`, `Components.swift` or the shared
render-test fixture. Fixture shapes a screen needs go in a
`Fixture+<Section>.swift` extension. New sessions take protocol-typed services.
Run `swift format -r -i Sources Tests` before every push.

## Verification

`Tests/AgentToolingAppTests/WorkspaceShellRenderTests.swift` renders every shell
screen over a real workspace and fails on a blank frame; it carries a negative
control proving the blank-frame check can fail. **Every section is in it from
Phase 0**, so a port that draws nothing fails the moment it replaces its
placeholder. Group B screens render from a stubbed service; a render test that
reaches the network or `~/.claude` is a bug.

Twenty-seven app-target test files went with the views. Bring back the ones
that test what you restore: `CommandPaletteCatalogTests`,
`AppNavigationStateTests`, `WorkspaceNavigationTests`, `ToolIdentityIconTests`,
`SkillOrganizationTests`, `SkillsLayoutRenderTests`,
`MCPToolArgumentBuilderTests`, `MCPCapabilitiesPaneRenderTests`,
`ToolHiveInspectorRenderTests`, `OnboardingWizardTests`. The suite went from
1,172 tests at #64 to 910 at #65; the restored screens should carry it back
over 1,000.

Beyond that, per screen, the gates CI runs (`.github/workflows/macos-app.yml`):

- `swift format lint --strict -r Sources Tests Package.swift`
- `swift test --disable-sandbox`, and the same under `--sanitize=thread`
- `swift build --configuration release -Xswiftc -warnings-as-errors`
- Actually launch it. `swift build --product AgentTooling` (about 40 seconds
  clean on an M-series Mac) then `.build/debug/AgentTooling --workspace <scratch dir>`
  against a scratch root, so a first run cannot write into the real support
  directory. Capture the window by **window id**, not screen region — a stale
  build of this app may well be running, and both processes are named
  `AgentTooling`.
- No screen may present requested assignment as installation.
- No primary row shows a file path; paths live behind `PathInfoButton` or
  `LocationText`. Rows are tile · name · one clause · marks · verdict.

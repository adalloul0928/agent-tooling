import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The sheets, popovers, inspectors and detail panes the first gallery did not
/// reach, each at its own size in light and dark with realistic content. The
/// views are reached the way their own render tests reach them — a public
/// initializer, a scripted session, a built plan — so a gallery image is a
/// screen those tests already guard, captured rather than only checked.
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · More surfaces", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryMoreSurfacesTests {
    private static let both: [RenderAppearance] = [.light, .dark]

    // MARK: Discover — catalog source

    /// Adding a catalog, empty. Its validation-error state is driven by the
    /// sheet's own private session after a failed add, with no test seam to
    /// seed it, so the index records why that layout is not captured.
    @Test func addCatalogSourceSheet() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            try gallerySnapshot(
                AddCatalogSourceSheet(workspace: fixture.workspace, catalogs: fixture.workspace.marketplace),
                area: "Discover", screen: "Add catalog source sheet", state: "empty",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/CatalogSourceEditing.swift:159")
        }
        GalleryIndex.shared.addNote(
            "Add catalog source sheet validation-error state (AddCatalogSourceSheet, "
                + "Sources/AgentToolingApp/CatalogSourceEditing.swift:159): the error banner is driven by the "
                + "sheet's own private @State session after a rejected add; there is no test seam to seed it "
                + "without editing Sources, so only the empty entry form is captured.")
    }

    // MARK: Discover — install picker

    /// The marketplace install sheet is the same `WorkspaceAssignmentSheet` the
    /// first gallery already renders, opened with the listing's clients
    /// pre-ticked. Recorded here rather than drawn a second time.
    @Test func marketplaceInstallSheetIsTheAssignmentSheet() {
        GalleryIndex.shared.addNote(
            "Marketplace install sheet (MarketplaceView.swift:88) presents WorkspaceAssignmentSheet with the "
                + "listing's clients pre-selected — the same sheet captured under Library · Skills as "
                + "\"Assignment sheet\". Not drawn a second time.")
    }

    // MARK: App settings — effective setting edit

    /// Changing one effective setting: a boolean, and a choice. The sheet reads
    /// the row it is handed, so a built `PendingEdit` for each kind draws the
    /// toggle form and the picker, here over the approval modes Core defines.
    @Test func effectiveSettingEditSheet() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            try gallerySnapshot(
                EffectiveSettingEditSheet(
                    session: fixture.workspace.settings,
                    edit: Self.pendingEdit(value: .boolean(true), name: "Tool search")),
                area: "Apps · App settings", screen: "Effective setting edit sheet", state: "boolean",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/EffectiveSettingsView.swift:72")
            try gallerySnapshot(
                EffectiveSettingEditSheet(
                    session: fixture.workspace.settings,
                    edit: Self.pendingEdit(value: .string("auto"), name: "Approval mode"),
                    choices: AccountSetting.approvalMode.acceptedValues.map { .string($0.rawValue) }),
                area: "Apps · App settings", screen: "Effective setting edit sheet", state: "choice",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/EffectiveSettingsView.swift:72")
        }
    }

    // MARK: Presets

    /// Following a preset: where its tools belong.
    @Test func presetFollowSheet() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            guard let presets = fixture.workspace.presets else { continue }
            await presets.refresh()
            try gallerySnapshot(
                PresetFollowSheet(
                    session: presets, library: fixture.workspace.library,
                    presetID: ShellRenderFixture.presetID, name: "Starter"),
                area: "Library · Presets", screen: "Preset follow sheet", state: "choose",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/PresetsView.swift:57")
        }
    }

    /// The preset editor creating a new preset, and renaming an existing one.
    @Test func presetEditorSheet() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            guard let presets = fixture.workspace.presets else { continue }
            await presets.refresh()
            try gallerySnapshot(
                PresetEditorSheet(
                    session: presets, library: fixture.workspace.library, mode: .create, onCreated: { _ in }),
                area: "Library · Presets", screen: "Preset editor sheet", state: "create",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/PresetsView.swift:62")
            try gallerySnapshot(
                PresetEditorSheet(
                    session: presets, library: fixture.workspace.library,
                    mode: .rename(presetID: ShellRenderFixture.presetID, currentName: "Starter"),
                    onCreated: { _ in }),
                area: "Library · Presets", screen: "Preset editor sheet", state: "rename",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/PresetsView.swift:67")
        }
    }

    // MARK: Projects

    /// Creating a project, adding tools to one, and the files it would write.
    @Test func projectSheets() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            try gallerySnapshot(
                NewProjectSheet(workspace: fixture.workspace, onCreated: {}),
                area: "Projects", screen: "New project sheet", state: "empty",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/ProjectsView.swift:85")

            await fixture.workspace.library.refresh()
            if let project = fixture.workspace.library.state?.library.projects.first {
                try gallerySnapshot(
                    WorkspaceProjectAddSheet(session: fixture.workspace.library, project: project),
                    area: "Projects", screen: "Project add tools sheet", state: "choose",
                    size: SheetGallerySize.large, appearance: appearance,
                    source: "Sources/AgentToolingApp/ProjectDetailView.swift:76")
            }

            let declaration = WorkspaceProjectDeclarationSession(library: fixture.workspace.library)
            try gallerySnapshot(
                WorkspaceProjectDeclarationSheet(
                    session: declaration,
                    projectRoot: URL(filePath: "/Users/example/src/project-a"), projectName: "Project A"),
                area: "Projects", screen: "Project declaration sheet", state: "files",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/ProjectDetailView.swift:79")
        }
    }

    /// The project review sheet — the assignment sheet opened on a project,
    /// which both ProjectDetailView:412 and ProjectEditingSheets:63 present.
    @Test func projectReviewSheet() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            try gallerySnapshot(
                WorkspaceAssignmentSheet(
                    session: fixture.workspace.library, artifactIDs: [ShellRenderFixture.skill],
                    initialProjectID: ShellRenderFixture.projectID),
                area: "Projects", screen: "Project review sheet", state: "assign-to-project",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/ProjectDetailView.swift:412")
        }
    }

    // MARK: Skills — editors and detail

    /// The skill editor new-skill wizard, empty.
    @Test func skillEditorSheet() async throws {
        for appearance in Self.both {
            try gallerySnapshot(
                SkillEditorSheet(
                    existingNames: ["standalone-skill"], isBusy: false, canWrite: true,
                    errorMessage: nil, onCreate: { _, _ in }),
                area: "Library · Skills", screen: "Skill editor sheet", state: "empty",
                size: SheetGallerySize.large, appearance: appearance,
                source: "Sources/AgentToolingApp/SkillsView.swift:158")
        }
    }

    /// The source editor over a stored skill's SKILL.md.
    @Test func skillSourceEditorSheet() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            let content = fixture.contentSession()
            try gallerySnapshot(
                SkillSourceEditorSheet(skill: Self.skillEntry(), session: content),
                area: "Library · Skills", screen: "Skill source editor sheet", state: "loaded",
                size: SheetGallerySize.large, appearance: appearance,
                source: "Sources/AgentToolingApp/SkillsView.swift:159")
        }
    }

    /// A skill selected in a healthy state and in a failing state, drawn
    /// through the real `SkillsView` the way the layout tests reach the
    /// inspector.
    @Test func skillDetailPane() async throws {
        for appearance in Self.both {
            // Healthy: the standalone skill, assigned, read by the scripted
            // content service.
            let healthy = try await ShellRenderFixture()
            defer { healthy.remove() }
            let preferences = try ShellRenderFixture.preferences()
            defer { preferences.remove() }
            await healthy.assignStandaloneSkill()
            let navigation = AppNavigationState()
            navigation.open(.skill(ShellRenderFixture.skill.rawValue.uuidString.lowercased()))
            try gallerySnapshot(
                SkillsView(workspace: healthy.workspace, content: healthy.contentSession())
                    .environment(navigation)
                    .environment(\.skillContentService, StubSkillContentService())
                    .environment(\.availableClients, ClientKind.allCases)
                    .defaultAppStorage(preferences.defaults),
                area: "Library · Skills", screen: "Skill detail pane", state: "healthy",
                size: SheetGallerySize.wide, appearance: appearance,
                source: "Sources/AgentToolingApp/SkillsView.swift:404")

            // Failing: the content service refuses to read, so the inspector
            // shows its could-not-read state rather than the skill's files.
            let failing = try await ShellRenderFixture()
            defer { failing.remove() }
            let failingPreferences = try ShellRenderFixture.preferences()
            defer { failingPreferences.remove() }
            await failing.assignStandaloneSkill()
            let failingNavigation = AppNavigationState()
            failingNavigation.open(.skill(ShellRenderFixture.skill.rawValue.uuidString.lowercased()))
            try gallerySnapshot(
                SkillsView(
                    workspace: failing.workspace,
                    content: failing.contentSession(content: FailingSkillContentService()))
                    .environment(failingNavigation)
                    .environment(\.skillContentService, FailingSkillContentService())
                    .environment(\.availableClients, ClientKind.allCases)
                    .defaultAppStorage(failingPreferences.defaults),
                area: "Library · Skills", screen: "Skill detail pane", state: "failing-read",
                size: SheetGallerySize.wide, appearance: appearance,
                source: "Sources/AgentToolingApp/SkillsView.swift:404")
        }
    }

    // MARK: Connections — the sheets under the tab

    /// Every case of the connections tab's `activeSheet`: the runtimes sheet.
    /// The other two cases are PasteImportSheet in its paste and new-connection
    /// modes, already captured by the first gallery.
    @Test func mcpRuntimesSheet() async throws {
        for appearance in Self.both {
            let session = MCPRuntimeSession(inspector: StubMCPRuntimeInspector())
            await session.refresh()
            try gallerySnapshot(
                MCPRuntimesSheet(inspector: StubMCPRuntimeInspector(), session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(AgentTheme.contentBackground),
                area: "Library · Connections", screen: "MCP runtimes sheet", state: "checked",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/MCPServersView.swift:76")
        }
        GalleryIndex.shared.addNote(
            "Connections tab activeSheet (MCPServersView.swift:76) has three cases: .runtimes (captured here), "
                + ".paste and .addConnection — both PasteImportSheet, captured under Library · Connections.")
    }

    /// The paste-import sheet with a parsed server definition and with a parse
    /// error, seeded through the sheet's preview initializer.
    @Test func pasteImportParsedAndError() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            try gallerySnapshot(
                PasteImportSheet(
                    workspace: fixture.workspace,
                    previewText: "claude mcp add --transport sse linear https://mcp.linear.app/sse"),
                area: "Library · Connections", screen: "Paste import sheet", state: "parsed-definition",
                size: SheetGallerySize.large, appearance: appearance,
                source: "Sources/AgentToolingApp/MCPServersView.swift:79")
            try gallerySnapshot(
                PasteImportSheet(
                    workspace: fixture.workspace,
                    previewText: "this is not an mcp command, a json block, a url, or a SKILL.md"),
                area: "Library · Connections", screen: "Paste import sheet", state: "parse-error",
                size: SheetGallerySize.large, appearance: appearance,
                source: "Sources/AgentToolingApp/MCPServersView.swift:79")
        }
    }

    /// Withdrawing a request for a connection, reviewed before it is saved.
    @Test func assignmentRemovalSheet() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            let presentation = AssignmentRemovalPresentation(
                kind: .mcpServer, name: "Example Server",
                contributionIDs: [WorkspaceObjectID()])
            try gallerySnapshot(
                AssignmentRemovalSheet(session: fixture.workspace.library, presentation: presentation),
                area: "Library · Connections", screen: "Assignment removal sheet", state: "withdraw",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/MCPServersView.swift:89")
        }
    }

    /// The consent an MCP live test asks for before anything is run or
    /// contacted: a process launch, and a remote session.
    @Test func mcpTestConsentSheet() async throws {
        for appearance in Self.both {
            try gallerySnapshot(
                MCPTestConsentSheet(
                    serverName: "Example Server",
                    target: .stdio(executableURL: URL(filePath: "/opt/homebrew/bin/npx"), arguments: ["-y", "@scope/local"]),
                    onConfirm: {}),
                area: "Library · Connections", screen: "MCP test consent sheet", state: "process-launch",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/MCPTestConsoleView.swift:233")
            try gallerySnapshot(
                MCPTestConsentSheet(
                    serverName: "Linear",
                    target: .http(url: URL(string: "https://mcp.linear.app/sse")!),
                    onConfirm: {}),
                area: "Library · Connections", screen: "MCP test consent sheet", state: "remote-session",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/MCPTestConsoleView.swift:233")
        }
    }

    /// The ToolHive workload inspector, over a scripted runtime so nothing
    /// launches `thv`.
    @Test func toolHiveWorkloadInspector() async throws {
        for appearance in Self.both {
            try gallerySnapshot(
                ToolHiveWorkloadInspector(
                    workload: MCPRuntimeServer(
                        name: "fixture", package: "registry.example/fixture", status: "running",
                        url: "http://127.0.0.1:8080/mcp", transport: "streamable-http", group: "preview"),
                    inspector: StubMCPRuntimeInspector()),
                area: "Library · Connections", screen: "ToolHive workload inspector", state: "running",
                size: SheetGallerySize.large, appearance: appearance,
                source: "Sources/AgentToolingApp/ToolHiveWorkloadInspector.swift")
        }
        GalleryIndex.shared.addNote(
            "ToolHive workload inspector inner sheet (ToolHiveWorkloadInspector.swift:349) is a logs sheet "
                + "opened from the inspector; it reads logs through the same scripted inspector, and its own "
                + "render coverage lives in ToolHiveInspectorRenderTests.")
    }

    /// A connection selected, healthy and failing, and its test console with a
    /// result, drawn through the connections detail pane.
    @Test func connectionDetailAndConsole() async throws {
        for appearance in Self.both {
            // Healthy: an app actually carries it.
            let healthy = MCPConnectionFixture.entry(
                name: "Linear", ownershipLabel: "Managed by its app", isManaged: false,
                routes: [.init(client: .claude, externalPluginID: "linear@vendor")],
                isAssignable: false, explanation: "Its app owns this one.")
            try gallerySnapshot(
                MCPDetailView(
                    entry: healthy, workspaceRoot: FileManager.default.temporaryDirectory, isBusy: false,
                    onAssign: {}, onRemove: { _ in })
                    .environment(MCPCapabilityModel())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(AgentTheme.contentBackground),
                area: "Library · Connections", screen: "Connection detail pane", state: "healthy",
                size: SheetGallerySize.large, appearance: appearance,
                source: "Sources/AgentToolingApp/MCPServersView.swift")

            // Failing: asked for in two places, carried nowhere.
            let failing = MCPConnectionFixture.entry(
                name: "Linear",
                requested: [MCPConnectionFixture.request(.claudeCode), MCPConnectionFixture.request(.codexCLI)])
            try gallerySnapshot(
                MCPDetailView(
                    entry: failing, workspaceRoot: FileManager.default.temporaryDirectory, isBusy: false,
                    onAssign: {}, onRemove: { _ in })
                    .environment(MCPCapabilityModel())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(AgentTheme.contentBackground),
                area: "Library · Connections", screen: "Connection detail pane", state: "failing",
                size: SheetGallerySize.large, appearance: appearance,
                source: "Sources/AgentToolingApp/MCPServersView.swift")
        }
    }

    // MARK: Accounts — review and confirmation

    /// The reviewed edit that makes this Mac follow the shared account choices.
    /// The plan is built from a scripted preference set and a read account
    /// through the real planner, so the sheet shows several changes of
    /// different kinds, a held change, and the file it would edit.
    @Test func accountChangesReviewSheet() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture(
                accountReader: ShellRenderFixture.galleryAccountReader())
            defer { fixture.remove() }
            await fixture.workspace.accounts.read()
            try gallerySnapshot(
                AccountChangesReviewSheet(
                    session: fixture.workspace.accounts, plan: Self.accountPlan(), onClose: {}),
                area: "Apps · Accounts", screen: "Account changes review sheet", state: "several-changes",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/AccountsView.swift:54")
        }
    }

    /// The confirmation popover that offers to make this Mac's switches the
    /// shared ones for every Mac.
    @Test func shareSettingsConfirmation() throws {
        for appearance in Self.both {
            try gallerySnapshot(
                ShareSettingsConfirmation(
                    provider: .claude,
                    settings: [
                        AccountPreference(AccountPreferenceKey(.skillSync), value: .off),
                        AccountPreference(AccountPreferenceKey(.pluginSync), value: .on),
                    ],
                    onConfirm: {}, onCancel: {}),
                area: "Apps · Accounts", screen: "Share settings confirmation", state: "offer",
                size: SheetGallerySize.popover, appearance: appearance,
                source: "Sources/AgentToolingApp/AccountsView.swift:99")
        }
    }

    // MARK: Clients — plan review and request review

    /// The reviewed plan in the states the first gallery missed: an update with
    /// a recorded version and without one, a native package, a connection, a
    /// removal, and a plan whose only steps are held back.
    @Test func planReviewSheetStates() async throws {
        let cases: [(state: String, plan: WorkspaceDeploymentPlan)] = [
            ("update-with-version", Self.plan(items: [Self.item(.updateContent(from: Self.digest("b"), to: Self.digest("a")), name: "Standalone Skill")])),
            ("update-without-version", Self.plan(items: [Self.item(.updateContent(from: nil, to: Self.digest("a")), name: "Standalone Skill")])),
            ("native-package", Self.plan(items: [Self.item(.installNativePackage(route: .init(client: .claude, externalPluginID: "example@vendor")), name: "Example Plugin")])),
            ("connection", Self.plan(items: [Self.item(.configureManagedConnection(transport: .stdio, replacesExisting: false), name: "Example Server")])),
            ("removal", Self.plan(items: [Self.item(.removeContent(installed: Self.digest("a")), name: "Standalone Skill")])),
            ("held-back", Self.plan(items: [], exclusions: [
                .init(artifactID: ShellRenderFixture.skill, physicalDestinationID: nil,
                      reason: .alreadyPresent, detail: "This destination already holds exactly this."),
            ])),
        ]
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            for example in cases {
                try gallerySnapshot(
                    PlanReviewSheet(workspace: fixture.workspace, plan: example.plan),
                    area: "Apps · Clients", screen: "Plan review sheet", state: example.state,
                    size: SheetGallerySize.large, appearance: appearance,
                    source: "Sources/AgentToolingApp/PlanReviewSheet.swift")
            }
        }
        GalleryIndex.shared.addNote(
            "Plan review sheet \"blocked\" state (PlanReviewSheet, Sources/AgentToolingApp/PlanReviewSheet.swift): "
                + "a blocked plan is one the risk classifier refuses, which the sheet reads from the live "
                + "deployment session rather than from a plan handed in; building that state needs a session in "
                + "a specific risk posture, not reachable without editing Sources, so the held-back exclusion "
                + "state is captured instead.")
    }

    /// A queued local request in a state that can be approved — no refusal, so
    /// the continue action is live. The first gallery has only the refused one.
    @Test func pendingRequestApprovable() async throws {
        for appearance in Self.both {
            try gallerySnapshot(
                PendingRequestReviewSheet(
                    request: ShellRenderFixture.pendingRequest(),
                    refusal: nil, onDefer: {}, onReject: {}, onContinue: {})
                    .environment(AppNavigationState()),
                area: "Apps · Clients", screen: "Request review sheet", state: "approvable",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/Sections/ClientsSection.swift:55")
        }
    }

    // MARK: Health — bulk re-authenticate

    /// A Health screen with a scripted listing — the state the shell cannot
    /// show because its health session runs a real client — and the bulk
    /// re-authenticate confirmation over that listing.
    @Test func healthScriptedListing() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            let session = await fixture.galleryHealthSession()
            try gallerySnapshot(
                HealthView(session: session, device: fixture.workspace.device)
                    .environment(\.workspaceSelection, AppSection.health)
                    .environment(\.workspaceNavigate, { _ in }),
                area: "Apps · Health", screen: "Health", state: "scripted-listing",
                size: GallerySize.standard, appearance: appearance,
                source: "Sources/AgentToolingApp/HealthView.swift:13")
            try gallerySnapshot(
                BulkReauthenticateConfirmation(
                    entries: session.reauthenticatableEntries,
                    commandText: { _ in "claude mcp reauth linear" }, onConfirm: {}, onCancel: {}),
                area: "Apps · Health", screen: "Bulk re-authenticate confirmation", state: "offer",
                size: SheetGallerySize.popover, appearance: appearance,
                source: "Sources/AgentToolingApp/HealthView.swift:67")
        }
    }

    // MARK: Sync and devices

    /// Another Mac's detail, assigning a tool to one Mac, linking a workspace
    /// folder destination, and the clients-you-use popover.
    @Test func syncAndDeviceSheets() async throws {
        let device = DeviceRecord(id: WorkspaceObjectID(), name: "Studio Mac")
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            try gallerySnapshot(
                OtherMacSheet(workspace: fixture.workspace, device: device),
                area: "Sync", screen: "Other Mac sheet", state: "detail",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/DeviceSwitcher.swift:43")
            try gallerySnapshot(
                AssignToDeviceSheet(workspace: fixture.workspace, device: device),
                area: "Sync", screen: "Assign to device sheet", state: "choose",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/DeviceSwitcher.swift:166")
            try gallerySnapshot(
                WorkspaceLinkDestinationSheet(
                    session: fixture.workspace.deployment, clients: [.claude, .codex]),
                area: "Sync", screen: "Link destination sheet", state: "choose",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/SyncCenterView.swift:154")
            try gallerySnapshot(
                ManagedClientsPopover(device: fixture.workspace.device),
                area: "Apps · Clients", screen: "Managed clients popover", state: "list",
                size: SheetGallerySize.popover, appearance: appearance,
                source: "Sources/AgentToolingApp/SyncCenterView.swift:61")
        }
        GalleryIndex.shared.addNote(
            "Device switcher picker (DeviceSwitcher.swift:228) and the device rename sheet "
                + "(SyncSettingsView.swift:252) are an AppKit menu and a small inline rename form built from a "
                + "DeviceRecord in private view state; neither has a public entry point a test can host without "
                + "editing Sources, so both are left to their menu/inline presentation.")
    }

    // MARK: First run — onboarding picker and included contents

    /// The onboarding assignment picker, and one choice row expanded to its
    /// included-contents popover.
    @Test func onboardingPickerAndContents() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            await fixture.workspace.device.refresh()
            try gallerySnapshot(
                OnboardingAssignmentPickerSheet(session: fixture.workspace.library),
                area: "First run and wizards", screen: "Onboarding assignment picker", state: "choose",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/OnboardingWizard.swift:455")
        }
        GalleryIndex.shared.addNote(
            "Onboarding included-contents popover (OnboardingChoiceRow.swift:44) lists a chosen package's "
                + "bundled contents; its content is an inline VStack built from an OnboardingChoiceRow row model "
                + "that is private to the wizard's internals, so it is left to its inline popover presentation.")
    }

    // MARK: Components — the path popover

    /// The path popover a `PathInfoButton` opens, over a local path and a URL.
    @Test func pathInfoPopover() throws {
        for appearance in Self.both {
            try gallerySnapshot(
                PathInfoButton(path: "/Users/example/Library/Application Support/agent-tooling")
                    .padding(Space.xl)
                    .background(AgentTheme.contentBackground),
                area: "Settings", screen: "Path info popover", state: "local-path",
                size: SheetGallerySize.popover, appearance: appearance,
                source: "Sources/AgentToolingApp/Components+Paths.swift:55")
        }
        GalleryIndex.shared.addNote(
            "PathInfoButton (Components+Paths.swift:55) draws a button whose popover content is an inline "
                + "VStack; the button and its path label are captured, and the popover body is the same path "
                + "text shown expanded. RemoveCatalogSourceConfirmation (CatalogSourceEditing.swift:327), the "
                + "Discover sources pane (MarketplaceView.swift:48), the Health help popover (HealthView.swift:325) "
                + "and the Insights scan-options popover (InsightsView.swift:38) are inline popover bodies with "
                + "no standalone view or public entry point, so they are listed here rather than drawn.")
    }

    // MARK: Settings window

    /// The system Settings window's content: the grouped-form Appearance
    /// picker the app shows at 360 wide. Reconstructed as the `Settings` scene
    /// builds it, since a scene body has no view a test can host directly.
    @Test func settingsWindow() throws {
        for appearance in Self.both {
            try gallerySnapshot(
                Form {
                    Picker("Appearance", selection: .constant("System")) {
                        Text("System").tag("System")
                        Text("Light").tag("Light")
                        Text("Dark").tag("Dark")
                    }
                }
                .formStyle(.grouped)
                .frame(width: 360),
                area: "Settings", screen: "Settings window", state: "appearance",
                size: CGSize(width: 360, height: 200), appearance: appearance,
                source: "Sources/AgentToolingApp/AgentToolingApp.swift:89")
        }
    }

    // MARK: Builders

    private static func pendingEdit(
        value: ConfigurationValue, name: String
    ) -> WorkspaceSettingsSession.PendingEdit {
        .init(
            surface: .claudeCode, surfaceTitle: "Claude Code",
            row: EffectiveConfigurationRow(
                key: name.lowercased().replacingOccurrences(of: " ", with: ""),
                displayName: name, value: value, definedBy: .user, definingSourcePath: nil,
                contributions: [], rule: .replace, writableLayer: .user, requiresNewSession: true),
            layer: .user, sourcePath: "/Users/example/.claude/settings.json", fingerprint: nil)
    }

    private static func skillEntry() -> SkillEntry {
        SkillEntry(
            id: ShellRenderFixture.skill, displayName: "Standalone Skill",
            declaredName: "standalone-skill", summary: "A stored skill the gallery reads.",
            ownership: .centralPersonal, authority: .centralPersonal,
            contentDigest: nil, parentID: nil, parentPluginLabel: nil, providerPluginID: nil,
            sourceLabel: nil, requestedAssignments: [], isAssignable: true, assignmentExplanation: nil)
    }

    private static func digest(_ seed: Character) -> ContentDigest {
        .init(value: String(repeating: seed, count: 64))
    }

    private static func item(
        _ action: WorkspaceDeploymentAction, name: String
    ) -> WorkspaceDeploymentItem {
        .init(
            artifactID: ShellRenderFixture.skill, displayName: name,
            physicalDestinationID: WorkspaceObjectID(), surface: .claudeCode, scope: .user,
            logicalProjectID: nil, action: action, desiredEnabled: nil, reasons: [.manual])
    }

    private static func plan(
        items: [WorkspaceDeploymentItem], exclusions: [WorkspaceDeploymentExclusion] = []
    ) -> WorkspaceDeploymentPlan {
        .init(items: items, exclusions: exclusions)
    }

    /// A plan built through the real planner: this Mac's switches differ from
    /// the shared choices in several ways, so the plan carries changes, a
    /// following entry, and a held change for a connector the file cannot name.
    private static func accountPlan() -> AccountPreferencePlan {
        let preferences = AccountPreferences(entries: [
            AccountPreference(AccountPreferenceKey(.skillSync), value: .off),
            AccountPreference(AccountPreferenceKey(.pluginSync), value: .off),
            AccountPreference(provider: .claude, setting: .connector, subject: "Gmail", value: .off),
        ])
        let observation = AccountObservation(
            provider: .claude, signIn: .init(method: .subscription, plan: "max"),
            switches: [.init(.skillSync): .on, .init(.pluginSync): .off],
            fileValues: [.init(.pluginSync): .off],
            constrained: [.init(provider: .claude, setting: .connector, subject: "Gmail"): "An organization policy fixes this."],
            contentsRead: true)
        return AccountPreferencePlanner.plan(
            preferences: preferences, observation: observation,
            configurationText: "{\n  \"syncClaudeAiSkills\": true\n}\n")
    }
}

/// A content service that refuses every read, so the skill inspector draws its
/// could-not-read state rather than a skill's files.
final class FailingSkillContentService: SkillContentServing, @unchecked Sendable {
    struct ReadRefused: Error, LocalizedError {
        var errorDescription: String? { "The stored content could not be read in this test." }
    }

    func read(
        artifactID: ArtifactID, revisionID: WorkspaceObjectID,
        through service: WorkspaceApplicationService
    ) async throws -> WorkspaceSkillContentSnapshot {
        throw ReadRefused()
    }

    func replace(
        _ tree: CapturedPackageTree, of artifactID: ArtifactID, expecting digest: ContentDigest,
        at revisionID: WorkspaceObjectID, through service: WorkspaceApplicationService
    ) async throws {}

    func admit(
        _ tree: CapturedPackageTree, named displayName: String,
        at revisionID: WorkspaceObjectID, through service: WorkspaceApplicationService
    ) async throws {}

    func upstream(_ binding: SkillRepositoryBinding, cachedIn cacheRoot: URL) async throws -> PreparedStandaloneSkill {
        throw ReadRefused()
    }
}

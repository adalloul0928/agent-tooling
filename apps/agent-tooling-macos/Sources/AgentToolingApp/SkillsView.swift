import AgentToolingCore
import AppKit
import SwiftUI

/// The Library's skills tab.
///
/// Two claims live side by side on every row and are never merged: the marks say
/// where the last check of this Mac actually found a skill, and the verdict says
/// where somebody asked for one. Asking for a skill is not having it, and this
/// screen never installs anything — where a skill is used is saved here, and
/// putting it into an app is reviewed on the Apps screen.
struct SkillsView: View {
    let workspace: WorkspaceLaunch.Workspace
    let content: SkillContentSession
    @AppStorage("skills.sourceOwnership") private var sourceOwnership = "{}"

    var body: some View {
        SkillsBrowser(
            workspace: workspace, content: content, sourceOwnership: $sourceOwnership,
            inventory: SkillInventoryIndex(
                library: workspace.library.state?.library,
                snapshot: workspace.library.state?.snapshot,
                observations: workspace.device.observations,
                ownershipJSON: sourceOwnership))
    }
}

struct SkillsBrowser: View {
    let workspace: WorkspaceLaunch.Workspace
    let content: SkillContentSession
    @Environment(AppNavigationState.self) var navigation
    @Environment(\.workspaceNavigate) var navigate
    @Environment(\.availableClients) var availableClients
    @Environment(\.skillDrafting) var skillDrafting
    @Environment(\.skillCreatorInstalling) var skillCreatorInstalling
    @Binding var sourceOwnership: String
    let inventory: SkillInventoryIndex

    @State var query = ""
    @AppStorage("skills.collapsedGroups") var collapsedGroupsJSON = "[]"
    @AppStorage("skills.grouping") var grouping = "None"
    @AppStorage("skills.groupingMigration") var groupingMigration = false
    @AppStorage("skills.category") var scope: SkillScope = .all
    @AppStorage("skills.marketplace") var marketplaceFilter = ""
    @AppStorage("skills.plugin") var pluginFilter = ""
    @AppStorage("skills.installation") var installationFilter = "All installations"
    @AppStorage("skills.maintenance") var maintenanceFilter = "All maintenance"
    @AppStorage("skills.client") var clientFilter: SkillClientFilter = .all
    @State var selectedID: ArtifactID?
    @State var isSelecting = false
    @State var selection: Set<ArtifactID> = []
    @State var creating = false
    /// The "New skill…" chooser: an assistant or the form.
    @State var choosingCreation = false
    @State var attaching = false
    @State var skillCreator: SkillCreatorPresentation?
    /// The skill the creator just admitted, held until its sheet has closed:
    /// choosing where a new skill is used is a second sheet, and two of them
    /// cannot be on screen at once.
    @State var createdBySkillCreator: SkillCreatorAdoption?
    @State var editingSource: SkillEntry?
    @State var assignment: AssignmentPresentation?
    @State var exporting: ExportPresentation?
    @State var refreshID = UUID()

    var body: some View {
        let listed = filteredSkills
        VStack(spacing: 0) {
            PageToolbar(title: "Skills", context: toolbarContext) {
                if isSelecting {
                    Button("Select all") { selection = assignableIDs.intersection(listed.map(\.id)) }
                        .buttonStyle(.glass)
                        .accessibilityHint("Selects every skill on this list that can be assigned")
                    Button("Done", systemImage: "checkmark.circle") { setSelecting(false) }.buttonStyle(.glass)
                } else {
                    Menu {
                        // Only switches the list into choosing; nothing opens.
                        Button("Choose several", systemImage: "checkmark.circle") { setSelecting(true) }
                            .disabled(workspace.library.isBusy || assignableIDs.isEmpty)
                        Button("Attach a folder you author…", systemImage: "folder.badge.plus") { attaching = true }
                            .disabled(workspace.library.isBusy || !canWrite)
                        Divider()
                        Button(ActionTitles.checkApps, systemImage: "arrow.clockwise") {
                            Task { await workspace.device.refresh() }
                        }
                        .disabled(workspace.device.isChecking)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .buttonStyle(.glass).accessibilityLabel("Skill actions")
                }
                Button {
                    navigate(.insights)
                } label: {
                    Label("Find opportunities", systemImage: "magnifyingglass")
                }
                .buttonStyle(.glass)
                .accessibilityHint("Opens Insights to scan recent work for useful skills, plugins, and connections")
                Button {
                    choosingCreation = true
                } label: {
                    Label("New skill…", systemImage: "plus")
                }
                .primaryActionStyle()
                .keyboardShortcut("n", modifiers: .command)
                .disabled(workspace.library.isBusy || !canWrite)
                .help("Create a skill with Claude Code, with Codex, or by hand")
            }

            filtersToolbar(skills: listed)
            Hairline()
            GeometryReader { proxy in
                if selectedSkill != nil {
                    HSplitView {
                        collectionPane(skills: listed)
                            .frame(
                                minWidth: Size.listPaneMin, idealWidth: proxy.size.width * Proportion.evenShare,
                                maxWidth: .infinity,
                                maxHeight: .infinity, alignment: .topLeading)
                        VStack(spacing: 0) {
                            InspectorHeader(title: "Skill details") { selectedID = nil }
                            detailPane
                        }
                        .frame(
                            minWidth: Size.detailPaneMin, idealWidth: proxy.size.width * Proportion.evenShare,
                            maxWidth: .infinity,
                            maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    collectionPane(skills: listed).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: refreshID) { await workspace.library.refresh() }
        // Choosing how decides nothing durable. An assistant stages a draft
        // and the form writes only when it is saved.
        .sheet(isPresented: $choosingCreation) {
            SkillCreationChooserSheet(managedClients: workspace.device.managedClients) { method in
                switch method {
                case .assistant(let client): openSkillCreator(client: client)
                case .manual: creating = true
                }
            }
        }
        .sheet(isPresented: $creating) {
            SkillEditorSheet(
                existingNames: inventory.skills.map(\.displayName) + inventory.skills.compactMap(\.declaredName),
                isBusy: content.isBusy, canWrite: canWrite, errorMessage: content.errorMessage
            ) { draft, assign in
                Task {
                    guard await content.create(from: draft) else { return }
                    creating = false
                    guard assign, let created = newestMatch(named: draft.name) else { return }
                    selectedID = created
                    workspace.library.discardReview()
                    assignment = .init(artifactIDs: [created])
                }
            }
        }
        .sheet(item: $editingSource) { skill in
            SkillSourceEditorSheet(skill: skill, session: content)
        }
        .sheet(item: $assignment) { presentation in
            WorkspaceAssignmentSheet(
                session: workspace.library, artifactIDs: presentation.artifactIDs,
                initialClients: presentation.initialClients)
        }
        .sheet(isPresented: $attaching) {
            WorkspaceAttachFolderSheet(session: workspace.authoring)
        }
        // The assistant writes only into an isolated draft folder. Nothing
        // reaches the library until the draft is accepted, and where a saved
        // skill is used is still asked separately, once this sheet has closed.
        .sheet(item: $skillCreator, onDismiss: finishSkillCreation) { presentation in
            SkillCreatorSheet(
                workspace: workspace,
                drafting: skillDrafting(workspace.skillDraftStagingRoot),
                installing: skillCreatorInstalling(workspace),
                client: presentation.client,
                pendingRequestID: presentation.requestID
            ) { artifactID, clients in
                createdBySkillCreator = SkillCreatorAdoption(artifactID: artifactID, clients: clients)
            }
        }
        .sheet(item: $exporting) { presentation in
            WorkspacePackageExportSheet(session: workspace.export, itemName: presentation.name)
                .task { await workspace.export.prepare(presentation.artifactID) }
        }
        .onChange(of: workspace.device.enabledClients) { _, _ in
            if let client = clientFilter.client, !workspace.device.isEnabled(client) { clientFilter = .all }
            clearUnavailableSourceFilters()
        }
        .onAppear {
            if !groupingMigration {
                grouping = SkillGrouping.migratedValue(grouping).rawValue
                groupingMigration = true
            }
            clearUnavailableSourceFilters()
            clearHiddenSelection()
            applyExternalNavigation()
        }
        .onChange(of: navigation.revision) { _, _ in applyExternalNavigation() }
        .onChange(of: inventory.skills) { _, _ in
            clearHiddenSelection()
            // A check or a saved assignment can take a row off the list. The bar
            // must never offer a count the review would not honour.
            if isSelecting { selection.formIntersection(assignableIDs) }
        }
        .onChange(of: listed.map(\.id)) { _, _ in clearHiddenSelection() }
        .onChange(of: selectedID) { _, _ in
            content.forget()
            guard let skill = selectedSkill else { return }
            Task { await content.load(skill) }
        }
    }

    var canWrite: Bool { workspace.library.access == .writable }

    // MARK: - Filters

    var extraFilterCount: Int {
        (installationFilter == "All installations" ? 0 : 1)
            + (maintenanceFilter == "All maintenance" ? 0 : 1)
            + (pluginFilter.isEmpty ? 0 : 1)
    }

    var ownershipPicker: some View {
        WorkspaceSegmentedPicker("Skill authorship", selection: $scope) {
            ForEach(SkillScope.allCases) { category in
                Text(category.rawValue).tag(category)
            }
        }
        .fixedSize()
        .help(
            "OpenAI & Anthropic shows skills supplied directly by those providers. General marketplace listings are not proof of authorship."
        )
    }

    var searchField: some View {
        InventorySearchField(placeholder: "Search skills", text: $query)
            .frame(minWidth: Size.searchFieldMin, idealWidth: Size.searchFieldIdeal, maxWidth: Size.fieldWide)
    }

    func filtersToolbar(skills: [SkillEntry]) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.xxl) {
                    ownershipPicker
                    Spacer(minLength: Space.xl)
                    searchField.frame(width: Size.searchFieldCompact)
                }
                VStack(alignment: .leading, spacing: Space.lg) {
                    ownershipPicker
                    searchField
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FlowLayout(spacing: Space.lg) {
                Menu {
                    Picker("Marketplace", selection: $marketplaceFilter) {
                        Text("All marketplaces").tag("")
                        ForEach(inventory.marketplaces) { source in Text(source.title).tag(source.id) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(marketplaceFilterTitle, systemImage: "storefront")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: Size.filterMenuLabelMax, alignment: .leading)
                }
                .fixedSize()
                .help("Marketplace: \(marketplaceFilterTitle)")
                Menu {
                    Picker("App", selection: $clientFilter) {
                        ForEach(SkillClientFilter.allCases.filter { workspace.device.isEnabled($0.client) }) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(clientFilter.rawValue, systemImage: "desktopcomputer")
                }
                .fixedSize()
                .help("Shows only skills the last check of this Mac found in one app")
                Menu {
                    Picker("Plugin", selection: $pluginFilter) {
                        Text("All plugins").tag("")
                        ForEach(inventory.plugins) { plugin in Text(plugin.title).tag(plugin.id) }
                    }
                    Picker("Installation", selection: $installationFilter) {
                        ForEach(["All installations", "Standalone", "Plugin"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Maintenance", selection: $maintenanceFilter) {
                        ForEach(["All maintenance", "Maintained here", "Maintained elsewhere"], id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    Label(
                        extraFilterCount == 0 ? "Filters" : "Filters (\(extraFilterCount))",
                        systemImage: "line.3.horizontal.decrease")
                }
                .fixedSize()
                Menu {
                    Picker("Group by", selection: $grouping) {
                        ForEach(SkillGrouping.allCases) { group in Text(group.rawValue).tag(group.rawValue) }
                    }
                    .pickerStyle(.inline)
                    if resolvedGrouping != .none {
                        Divider()
                        Button("Expand all") { saveCollapsedGroups([]) }
                        Button("Collapse all") { saveCollapsedGroups(Set(groupedSkills.map(\.id))) }
                    }
                } label: {
                    Label(
                        resolvedGrouping == .none ? "Group" : "Group: \(resolvedGrouping.rawValue)",
                        systemImage: "rectangle.3.group")
                }
                .fixedSize()
                if !marketplaceFilter.isEmpty || !pluginFilter.isEmpty || clientFilter != .all || extraFilterCount > 0 {
                    Button("Reset") { resetFilters() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                // Copies of one skill are one row, so they are one in the count.
                Text(CountNoun.skill.phrase(Set(skills.map(SkillInventoryIndex.copyKey(for:))).count))
                    .font(AgentFont.caption).foregroundStyle(.secondary).fixedSize()
            }
            .inventoryMenuStyle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WorkspaceLayout.pageInset).padding(.vertical, Space.lg)
    }

}

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

private struct SkillsBrowser: View {
    let workspace: WorkspaceLaunch.Workspace
    let content: SkillContentSession
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.workspaceNavigate) private var navigate
    @Environment(\.availableClients) private var availableClients
    @Environment(\.codexSkillDrafting) private var codexDrafting
    @Binding var sourceOwnership: String
    let inventory: SkillInventoryIndex

    @State private var query = ""
    @AppStorage("skills.collapsedGroups") private var collapsedGroupsJSON = "[]"
    @AppStorage("skills.grouping") private var grouping = "None"
    @AppStorage("skills.groupingMigration") private var groupingMigration = false
    @AppStorage("skills.category") private var scope: SkillScope = .all
    @AppStorage("skills.marketplace") private var marketplaceFilter = ""
    @AppStorage("skills.plugin") private var pluginFilter = ""
    @AppStorage("skills.installation") private var installationFilter = "All installations"
    @AppStorage("skills.maintenance") private var maintenanceFilter = "All maintenance"
    @AppStorage("skills.client") private var clientFilter: SkillClientFilter = .all
    @State private var selectedID: ArtifactID?
    @State private var isSelecting = false
    @State private var selection: Set<ArtifactID> = []
    @State private var creating = false
    @State private var attaching = false
    @State private var codexCreator: CodexCreatorPresentation?
    /// The skill the creator just admitted, held until its sheet has closed:
    /// choosing where a new skill is used is a second sheet, and two of them
    /// cannot be on screen at once.
    @State private var createdByCodex: CodexAdoption?
    @State private var editingSource: SkillEntry?
    @State private var assignment: AssignmentPresentation?
    @State private var exporting: ExportPresentation?
    @State private var refreshID = UUID()

    var body: some View {
        let listed = filteredSkills
        VStack(spacing: 0) {
            PageToolbar(title: "Skills", context: toolbarContext) {
                if isSelecting {
                    Button("Select All") { selection = assignableIDs.intersection(listed.map(\.id)) }
                        .buttonStyle(.glass)
                        .accessibilityHint("Selects every skill on this list that can be assigned")
                    Button("Done", systemImage: "checkmark.circle") { setSelecting(false) }.buttonStyle(.glass)
                } else {
                    Menu {
                        Button("Choose several…", systemImage: "checkmark.circle") { setSelecting(true) }
                            .disabled(workspace.library.isBusy || assignableIDs.isEmpty)
                        Button("New skill with Codex…", systemImage: "sparkles") { openCodexCreator() }
                            .disabled(workspace.library.isBusy || !canWrite || !workspace.device.isEnabled(.codex))
                            .help("Asks your signed-in Codex to write a skill you review before anything is saved")
                        Button("Attach a folder you author…", systemImage: "folder.badge.plus") { attaching = true }
                            .disabled(workspace.library.isBusy || !canWrite)
                        Divider()
                        Button("Check this Mac's apps", systemImage: "arrow.clockwise") {
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
                .accessibilityHint("Scans recent work for useful skills, plugins, and MCP servers")
                Button {
                    creating = true
                } label: {
                    Label("New skill…", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .tint(AgentTheme.selection)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(workspace.library.isBusy || !canWrite)
            }

            filtersToolbar(skills: listed)
            Divider()
            GeometryReader { proxy in
                if selectedSkill != nil {
                    HSplitView {
                        collectionPane(skills: listed)
                            .frame(
                                minWidth: 320, idealWidth: proxy.size.width / 2, maxWidth: .infinity,
                                maxHeight: .infinity, alignment: .topLeading)
                        VStack(spacing: 0) {
                            InspectorHeader(title: "Skill details") { selectedID = nil }
                            detailPane
                        }
                        .frame(
                            minWidth: 400, idealWidth: proxy.size.width / 2, maxWidth: .infinity,
                            maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    collectionPane(skills: listed).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: refreshID) { await workspace.library.refresh() }
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
        // Codex writes only into an isolated draft folder. Nothing reaches the
        // library until the draft is accepted, and where a saved skill is used
        // is still asked separately, once this sheet has closed.
        .sheet(item: $codexCreator, onDismiss: finishCodexCreation) { presentation in
            CodexSkillCreatorSheet(
                workspace: workspace,
                drafting: codexDrafting(workspace.skillDraftStagingRoot),
                pendingRequestID: presentation.requestID
            ) { artifactID, clients in
                createdByCodex = CodexAdoption(artifactID: artifactID, clients: clients)
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

    private var canWrite: Bool { workspace.library.access == .writable }

    // MARK: - Filters

    private var extraFilterCount: Int {
        (installationFilter == "All installations" ? 0 : 1)
            + (maintenanceFilter == "All maintenance" ? 0 : 1)
            + (pluginFilter.isEmpty ? 0 : 1)
    }

    private var ownershipPicker: some View {
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

    private var searchField: some View {
        InventorySearchField(placeholder: "Search skills", text: $query)
            .frame(minWidth: 180, idealWidth: 300, maxWidth: 420)
    }

    private func filtersToolbar(skills: [SkillEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    ownershipPicker
                    Spacer(minLength: 16)
                    searchField.frame(width: 220)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ownershipPicker
                    searchField
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FlowLayout(spacing: 12) {
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
                        .frame(maxWidth: 220, alignment: .leading)
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
                Text("\(skills.count) skills").font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            .inventoryMenuStyle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WorkspaceLayout.pageInset).padding(.vertical, 10)
    }

    // MARK: - List

    /// Resolved once per layout pass. Asking the index per row would make the
    /// cost of drawing the list grow with the square of a 250-skill library.
    private func collectionPane(skills: [SkillEntry]) -> some View {
        let assignable = assignableIDs
        let groups = SkillListPresentation.groups(
            skills: skills, grouping: resolvedGrouping, presentation: inventory.presentation(for:))
        let collapsed = query.isEmpty ? collapsedGroups : []
        return VStack(spacing: 0) {
            if let message = workspace.library.errorMessage, assignment == nil {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, WorkspaceLayout.pageInset).padding(.vertical, 10)
            }
            if skills.isEmpty {
                EmptyStateView(
                    symbol: query.isEmpty ? "doc.text" : "doc.text.magnifyingglass",
                    title: emptyStateTitle,
                    message: emptyStateMessage,
                    actionTitle: inventory.skills.isEmpty ? "Check this Mac's apps" : "Clear filters"
                ) {
                    performEmptyStateAction()
                }
            } else {
                GeometryReader { geometry in
                    let columns = SkillTableColumns(
                        width: geometry.size.width, selecting: isSelecting,
                        // A workspace built by scanning records no descriptions,
                        // so the column would be a screenful of dashes. It earns
                        // its width only once something in view has one.
                        describing: skills.contains { !$0.summary.isEmpty })
                    VStack(spacing: 0) {
                        header(columns)
                        Divider()
                        ScrollView {
                            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                                ForEach(groups) { group in
                                    let isCollapsed = collapsed.contains(group.id)
                                    Section {
                                        if resolvedGrouping == .none || !isCollapsed {
                                            ForEach(group.skills) { skill in
                                                row(skill, assignable: assignable.contains(skill.id), columns: columns)
                                            }
                                        }
                                    } header: {
                                        if resolvedGrouping != .none {
                                            groupHeader(group, isCollapsed: isCollapsed)
                                        }
                                    }
                                }
                            }
                            .padding(.bottom, isSelecting && !selection.isEmpty ? 72 : 0)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if isSelecting, !selection.isEmpty {
                SelectionActionBar(
                    count: selection.count,
                    actionTitle: "Choose where to use \(selection.count)…",
                    isActionEnabled: !workspace.library.isBusy && canWrite,
                    action: assignSelection,
                    clear: { selection = [] }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.18), value: selection.isEmpty)
        .paneMaterial()
    }

    private func header(_ columns: SkillTableColumns) -> some View {
        HStack(spacing: 12) {
            if isSelecting { Color.clear.frame(width: 20) }
            Text("Name").frame(width: columns.name, alignment: .leading)
            if columns.expanded {
                if columns.describing {
                    Text("Description").frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                Text("Plugin").frame(width: columns.plugin, alignment: .leading)
                Text("Source").frame(width: columns.marketplace, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            Text("Found in").frame(width: 72, alignment: .trailing)
            Text("Assigned").frame(width: columns.verdict, alignment: .trailing)
        }
        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).frame(height: 30)
        .background(AgentTheme.controlBackground.opacity(0.3))
    }

    private func row(_ skill: SkillEntry, assignable: Bool, columns: SkillTableColumns) -> some View {
        SkillCollectionRow(
            skill: skill,
            presentation: inventory.presentation(for: skill),
            observed: inventory.observedClients[skill.id] ?? [],
            selected: isSelecting ? selection.contains(skill.id) : skill.id == selectedID,
            selecting: isSelecting,
            isAssignable: assignable,
            columns: columns,
            activate: { activate(skill, isAssignable: assignable) }
        )
        .accessibilityValue(accessibilityValue(for: skill, isAssignable: assignable))
        .contextMenu {
            Button("Show details", systemImage: "info.circle") { selectedID = skill.id }
            if assignable {
                Button("Choose where to use it…", systemImage: "arrow.turn.up.right") {
                    workspace.library.discardReview()
                    assignment = .init(artifactIDs: [skill.id])
                }
                .disabled(!canWrite)
            }
            Divider()
            classificationActions([skill])
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let skill = selectedSkill {
            VStack(spacing: 0) {
                SkillDetailView(
                    skill: skill,
                    workspace: workspace,
                    content: content,
                    inventory: inventory,
                    availableClients: availableClients,
                    onEditSource: { editingSource = skill },
                    onAssign: {
                        workspace.library.discardReview()
                        assignment = .init(artifactIDs: [skill.id])
                    },
                    onExport: { exporting = .init(artifactID: skill.id, name: skill.displayName) },
                    onOpenPlugin: { id in navigation.openItem(id.rawValue.uuidString.lowercased(), in: .plugins) }
                )
                Divider()
                HStack {
                    Text(skill.installation).font(.caption).foregroundStyle(.secondary)
                    SkillInfoButton(text: inventory.classification(for: skill).reason, label: "Classification information")
                    Spacer()
                    Picker(
                        skill.providerPluginID == nil ? "Skill classification" : "Plugin classification",
                        selection: Binding(
                            get: { inventory.ownership[inventory.ownershipKey(for: skill)] ?? "automatic" },
                            set: { setOwnership($0, for: skill) })
                    ) {
                        Text("Automatic").tag("automatic")
                        Text("Unclassified").tag("unknown")
                        Text("My skills").tag("mine")
                        Text("Third-party skills").tag("thirdParty")
                    }
                    .labelsHidden().fixedSize().controlSize(.small).disabled(skill.isMaintainedHere)
                    .accessibilityLabel(skill.providerPluginID == nil ? "Skill classification" : "Plugin classification")
                }
                .padding(.horizontal, 22).padding(.vertical, 10)
            }
        } else {
            EmptyStateView(
                symbol: "doc.text", title: "Select a skill",
                message: "Choose a skill to see where it came from, where it was found, and where it is used.")
        }
    }

    // MARK: - Filtering

    private var filteredSkills: [SkillEntry] {
        inventory.skills.filter { skill in
            let origin = inventory.presentation(for: skill)
            return scope.matches(owner: inventory.owner(of: skill))
                && origin.matches(marketplace: marketplaceFilter, plugin: pluginFilter)
                && (installationFilter == "All installations" || installationFilter == skill.installation)
                && (maintenanceFilter == "All maintenance" || (maintenanceFilter == "Maintained here") == skill.isMaintainedHere)
                && clientFilter.matches(inventory.observedClients[skill.id] ?? [])
                && (query.isEmpty
                    || [skill.displayName, skill.declaredName ?? "", skill.summary, origin.pluginName ?? "", origin.marketplaceName ?? ""]
                        .joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
    }

    private var marketplaceFilterTitle: String {
        marketplaceFilter.isEmpty ? "All marketplaces" : SkillOrganization.SourceIdentity.title(marketplaceFilter)
    }

    private func clearUnavailableSourceFilters() {
        if !marketplaceFilter.isEmpty, !inventory.marketplaces.contains(where: { $0.id == marketplaceFilter }) {
            marketplaceFilter = ""
        }
        if !pluginFilter.isEmpty, !inventory.plugins.contains(where: { $0.id == pluginFilter }) { pluginFilter = "" }
    }

    private func setOwnership(_ value: String, for skill: SkillEntry) {
        var values = (try? JSONDecoder().decode([String: String].self, from: Data(sourceOwnership.utf8))) ?? [:]
        values[inventory.ownershipKey(for: skill)] = value == "automatic" ? nil : value
        if let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) {
            sourceOwnership = json
        }
    }

    private func classify(_ skills: [SkillEntry], as owner: String) {
        var values = (try? JSONDecoder().decode([String: String].self, from: Data(sourceOwnership.utf8))) ?? [:]
        for skill in skills where !skill.isMaintainedHere {
            values[inventory.ownershipKey(for: skill)] = owner == "automatic" ? nil : owner
        }
        if let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) {
            sourceOwnership = json
        }
    }

    @ViewBuilder
    private func classificationActions(_ skills: [SkillEntry]) -> some View {
        Button("Mark as My skills") { classify(skills, as: "mine") }
        Button("Mark as Third-party") { classify(skills, as: "thirdParty") }
        Button("Use automatic classification") { classify(skills, as: "automatic") }
        Button("Mark as Unclassified") { classify(skills, as: "unknown") }
    }

    // MARK: - Grouping

    private var collapsedGroups: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: Data(collapsedGroupsJSON.utf8))) ?? []
    }

    private func saveCollapsedGroups(_ groups: Set<String>) {
        if let data = try? JSONEncoder().encode(groups), let json = String(data: data, encoding: .utf8) {
            collapsedGroupsJSON = json
        }
    }

    private var resolvedGrouping: SkillGrouping { SkillGrouping.migratedValue(grouping) }

    private var groupedSkills: [SkillListGroup] {
        SkillListPresentation.groups(
            skills: filteredSkills, grouping: resolvedGrouping, presentation: inventory.presentation(for:))
    }

    private func groupHeader(_ group: SkillListGroup, isCollapsed: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                var collapsed = collapsedGroups
                if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                saveCollapsedGroups(collapsed)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold)).frame(width: 10)
                    Text(group.title).lineLimit(1)
                    if let subtitle = group.subtitle { Text(subtitle).foregroundStyle(.tertiary).lineLimit(1) }
                    Text("\(group.skills.count)").foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isCollapsed ? "Expand" : "Collapse") \(group.title)")
            Menu {
                classificationActions(group.skills)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Classify skills in this group without changing where they are used")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 13)
        .frame(height: 32)
        .background(AgentTheme.controlBackground.opacity(0.45))
    }

    // MARK: - Selection

    private var selectedSkill: SkillEntry? { inventory.skills.first { $0.id == selectedID } }

    /// Only a row the workspace says may be assigned, so selection never offers
    /// a row the review would have to drop.
    private var assignableIDs: Set<ArtifactID> {
        Set(inventory.skills.filter(\.isAssignable).map(\.id))
    }

    private func setSelecting(_ value: Bool) {
        isSelecting = value
        if !value { selection = [] }
    }

    private func activate(_ skill: SkillEntry, isAssignable: Bool) {
        guard isSelecting else {
            selectedID = skill.id
            return
        }
        guard isAssignable else { return }
        if selection.contains(skill.id) {
            selection.remove(skill.id)
        } else {
            selection.insert(skill.id)
        }
    }

    /// Selection survives a cancelled review so the choice does not have to be
    /// made again.
    private func assignSelection() {
        let requested = selection.intersection(assignableIDs)
        guard !requested.isEmpty else { return }
        workspace.library.discardReview()
        assignment = .init(artifactIDs: requested.sorted())
    }

    private func accessibilityValue(for skill: SkillEntry, isAssignable: Bool) -> String {
        guard isSelecting else { return skill.id == selectedID ? "Selected" : "" }
        if !isAssignable { return skill.assignmentExplanation ?? "Cannot be assigned" }
        return selection.contains(skill.id) ? "Selected to assign" : "Not selected"
    }

    private var toolbarContext: String {
        "\(inventory.skills.count) skills · \(inventory.mineCount) mine · \(inventory.unknownCount) unclassified"
    }

    private func clearHiddenSelection() {
        guard let selectedID, !filteredSkills.contains(where: { $0.id == selectedID }) else { return }
        self.selectedID = nil
    }

    // MARK: - Empty state

    private var emptyStateTitle: String { inventory.skills.isEmpty ? "No skills yet" : "No matching skills" }

    private var emptyStateMessage: String {
        if inventory.skills.isEmpty {
            return "Create a skill, attach a folder you already author in, or check this Mac's apps for skills you already have."
        }
        switch scope {
        case .provider:
            return
                "No matching skills supplied directly by OpenAI or Anthropic were found. Marketplace listings with an unknown publisher remain in All skills."
        case .mine:
            return
                "No matching skills are classified as yours. Select a skill in All skills to change its classification."
        case .thirdParty:
            return "No matching third-party skills were found. Skills whose publisher is not established remain in All skills."
        case .all:
            return "Try a different search or clear your filters."
        }
    }

    private func resetFilters() {
        marketplaceFilter = ""
        pluginFilter = ""
        installationFilter = "All installations"
        maintenanceFilter = "All maintenance"
        clientFilter = .all
    }

    private func performEmptyStateAction() {
        guard !inventory.skills.isEmpty else {
            Task { await workspace.device.refresh() }
            return
        }
        scope = .all
        query = ""
        resetFilters()
    }

    // MARK: - Routes

    private func newestMatch(named name: String) -> ArtifactID? {
        let identifier = (try? WorkspaceLibrary.normalizedIdentifier(name)) ?? name
        let display = SkillTemplate.displayName(for: identifier)
        return workspace.library.state?.library.rows.first {
            $0.kind == .skill && $0.displayName.caseInsensitiveCompare(display) == .orderedSame
        }?.artifactID
    }

    private func applyExternalNavigation() {
        if codexCreator == nil, let requestID = navigation.requestedSkillCreationID {
            navigation.consumeSkillCreationRequest(requestID)
            openCodexCreator(requestID: requestID)
        }
        let requested = navigation.requestedSkillID ?? navigation.requestedItemID
        guard let requested,
            let match = inventory.skills.first(where: { $0.id.rawValue.uuidString.lowercased() == requested })
        else { return }
        scope = .all
        query = ""
        resetFilters()
        selectedID = match.id
        navigation.consumeRequestedItem(requested)
    }

    /// Opens the creator, for a request somebody queued or for a blank one.
    private func openCodexCreator(requestID: UUID? = nil) {
        createdByCodex = nil
        codexCreator = .init(requestID: requestID)
    }

    /// The creator has closed. A skill it admitted is revealed and offered a
    /// destination; nothing is assigned until that second sheet is saved.
    private func finishCodexCreation() {
        guard let created = createdByCodex else { return }
        createdByCodex = nil
        selectedID = created.artifactID
        workspace.library.discardReview()
        assignment = .init(artifactIDs: [created.artifactID], initialClients: created.clients)
    }

    /// A skill the creator admitted, and the apps it was ticked for in "Use
    /// after review" — held until the creator's own sheet has closed, so the
    /// hand-off can offer the same apps again instead of a blank sheet.
    private struct CodexAdoption {
        let artifactID: ArtifactID
        let clients: Set<ClientKind>
    }

    private struct CodexCreatorPresentation: Identifiable {
        let id = UUID()
        /// The queued request this creator was opened for, when there was one.
        let requestID: UUID?
    }

    private struct AssignmentPresentation: Identifiable {
        let id = UUID()
        let artifactIDs: [ArtifactID]
        var initialClients: Set<ClientKind> = []
    }

    private struct ExportPresentation: Identifiable {
        let id = UUID()
        let artifactID: ArtifactID
        let name: String
    }
}

/// Which app's local state a list is scoped to. Filtering by an app narrows the
/// list to what the last check of this Mac found there; it never changes one.
private enum SkillClientFilter: String, CaseIterable, Identifiable {
    case all = "Any app"
    case claude = "Claude Code"
    case codex = "Codex"
    case gemini = "Gemini CLI"

    var id: String { rawValue }

    var client: ClientKind? {
        switch self {
        case .all: nil
        case .claude: .claude
        case .codex: .codex
        case .gemini: .gemini
        }
    }

    func matches(_ observed: Set<ClientKind>) -> Bool {
        guard let client else { return true }
        return observed.contains(client)
    }
}

private struct SkillTableColumns {
    let width: CGFloat
    let selecting: Bool
    /// Whether anything on this list has a description to put in one.
    let describing: Bool
    var expanded: Bool { width >= 940 }
    var verdict: CGFloat { expanded ? 96 : 78 }
    var name: CGFloat {
        guard expanded else { return max(140, width - 144 - verdict - (selecting ? 32 : 0)) }
        // With no description column the name takes the space back rather than
        // leaving a gap where one used to be.
        return describing ? min(300, width * 0.24) : min(520, width * 0.42)
    }
    var plugin: CGFloat { min(200, width * 0.17) }
    var marketplace: CGFloat { min(180, width * 0.15) }
}

private struct SkillCollectionRow: View {
    let skill: SkillEntry
    let presentation: SkillPresentation
    let observed: Set<ClientKind>
    let selected: Bool
    var selecting = false
    var isAssignable = false
    let columns: SkillTableColumns
    let activate: () -> Void

    private var summary: String {
        let value = skill.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["", ">-", ">", "|", "|-"].contains(value) ? "—" : value
    }

    /// Where it came from, in one clause, for the layout that has no room for
    /// the plugin and source columns.
    private var origin: String? {
        presentation.compactDescription ?? skill.parentPluginLabel ?? skill.sourceLabel
    }

    /// A caption line the narrow layout has to make room for.
    private var captionLines: Int {
        (columns.describing ? 1 : 0) + (origin == nil ? 0 : 1)
    }

    /// What has been asked for, never what is installed.
    private var verdict: String {
        let count = skill.requestedAssignments.filter(\.desiredPresence).count
        guard count > 0 else { return skill.isAssignable ? "Not assigned" : "Tracked" }
        return count == 1 ? "1 place" : "\(count) places"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: activate) {
                HStack(spacing: 12) {
                    if selecting {
                        SelectionCheckbox(selected: selected, enabled: isAssignable).frame(width: 20)
                    }
                    HStack(spacing: 9) {
                        KindTile(kind: .skill, size: 20, ghost: !skill.isMaintainedHere)
                            .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(skill.displayName).font(.callout.weight(.medium)).lineLimit(1)
                            if !columns.expanded {
                                if columns.describing {
                                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if let origin {
                                    Text(origin).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(origin)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: columns.name, alignment: .leading)
                    if columns.expanded {
                        if columns.describing {
                            Text(summary).font(.callout).foregroundStyle(.secondary)
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                .help(summary)
                        } else {
                            Spacer(minLength: 0)
                        }
                        Text(presentation.pluginName ?? skill.parentPluginLabel ?? "Standalone")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .frame(width: columns.plugin, alignment: .leading)
                        Text(presentation.marketplaceName ?? skill.sourceLabel ?? "—")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: columns.marketplace, alignment: .leading)
                            .help(presentation.marketplaceName ?? skill.sourceLabel ?? "No recorded source")
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(skill.displayName)
            ClientMarks(present: observed, size: 15)
                .frame(width: 72, alignment: .trailing)
            Text(verdict)
                .font(.caption).foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                .lineLimit(1)
                .frame(width: columns.verdict, alignment: .trailing)
                .help("Where this skill has been asked for. Installation is checked separately.")
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 16)
        .frame(height: columns.expanded ? 44 : [40, 48, 64][min(captionLines, 2)])
        .rowSelection(selected)
        .overlay(alignment: .bottom) { Divider().opacity(0.25) }
    }
}

private struct SkillDetailView: View {
    let skill: SkillEntry
    let workspace: WorkspaceLaunch.Workspace
    let content: SkillContentSession
    let inventory: SkillInventoryIndex
    let availableClients: [ClientKind]
    let onEditSource: () -> Void
    let onAssign: () -> Void
    let onExport: () -> Void
    let onOpenPlugin: (ArtifactID) -> Void

    private var upstream: SkillUpstreamBinding.Resolved? {
        SkillUpstreamBinding.resolve(skill, in: workspace.library.state?.snapshot.document)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                heading
                actions
                if let explanation = skill.assignmentExplanation {
                    Text(explanation)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !skill.summary.isEmpty {
                    Text(skill.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SkillRepositorySection(
                    skill: skill, binding: upstream?.binding, approvedRevision: upstream?.approvedRevision,
                    authoringPath: inventory.authoringPaths[skill.id], session: content)
                apps
                sourceFiles
            }
            .padding(22)
        }
    }

    private var heading: some View {
        HStack(spacing: 13) {
            KindTile(kind: .skill, size: 40, ghost: !skill.isMaintainedHere)
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.displayName).font(.system(size: 22, weight: .semibold))
                HStack(spacing: 6) {
                    Text(skill.ownership.libraryLabel)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    SkillInfoButton(
                        text: skill.isMaintainedHere
                            ? "The source is yours. Save an edit here, then review where the change should be used."
                            : "This skill is maintained where it came from. This library records that it exists and where it is used.",
                        label: "About maintenance")
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if skill.ownership == .centralPersonal, skill.hasCentralContent {
                Button("Edit Source…", systemImage: "doc.text", action: onEditSource)
                    .buttonStyle(.bordered)
                    .disabled(content.isBusy || !content.canWrite)
                    .accessibilityHint("Edits the complete SKILL.md while preserving scripts, references, and assets")
            }
            if skill.isAssignable {
                Button("Choose where to use it…", systemImage: "arrow.turn.up.right", action: onAssign)
                    .buttonStyle(.borderedProminent)
                    .tint(AgentTheme.selection)
                    .disabled(workspace.library.isBusy || workspace.library.access != .writable)
                    .accessibilityHint("Saves where this skill should be used. Installing is reviewed on the Apps screen")
            }
            if skill.hasCentralContent {
                Button("Export…", systemImage: "square.and.arrow.up", action: onExport)
                    .buttonStyle(.bordered)
            }
            if skill.ownership == .attachedAuthoring {
                Button("Stop managing this folder", systemImage: "folder.badge.minus") {
                    Task { await workspace.authoring.detach(skill.id, named: skill.displayName) }
                }
                .buttonStyle(.bordered)
                .disabled(workspace.authoring.isBusy || !workspace.authoring.canWrite)
                .help("Removes the registration. Nothing in the folder is changed.")
            }
            if let parent = skill.parentID {
                Button("Show plugin", systemImage: "puzzlepiece.extension") { onOpenPlugin(parent) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var apps: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(availableClients.enumerated()), id: \.element) { index, client in
                    HStack(spacing: 10) {
                        ClientBrandIcon(client: client, size: 18).frame(width: 24)
                        Text(client.rawValue).font(.callout.weight(.medium))
                        Spacer()
                        // A verdict only where there is one. "This app does not
                        // have it" is the ordinary case for most skills, so it
                        // gets a word rather than a mark that reads as a fault.
                        if let state = state(for: client) {
                            StatusBadge(state: state, text: detail(for: client))
                        } else {
                            Text(detail(for: client)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 9)
                    if index < availableClients.count - 1 { Divider() }
                }
                if availableClients.isEmpty {
                    Text("This Mac is not managing any apps.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            .padding(6)
        } label: {
            HStack(spacing: 6) {
                Text("Apps")
                SkillInfoButton(
                    text:
                        "Found means the last check of this Mac saw this skill in that app. Asked for means somebody saved that choice here; installing it is a separate, reviewed step on the Apps screen.",
                    label: "About app availability")
            }
        }
    }

    /// Found beats asked for: what is actually there is the stronger claim, and
    /// the two are never blended into one word. Nil is neither — an app that
    /// simply does not have this skill is not a problem to be flagged.
    private func state(for client: ClientKind) -> HealthState? {
        if inventory.observedClients[skill.id]?.contains(client) == true { return .healthy }
        return skill.requestedClients.contains(client) ? .pending : nil
    }

    private func detail(for client: ClientKind) -> String {
        let found = inventory.observedClients[skill.id]?.contains(client) == true
        let asked = skill.requestedClients.contains(client)
        switch (found, asked) {
        case (true, true): return "Found · asked for"
        case (true, false): return "Found here"
        case (false, true): return "Asked for, not found"
        case (false, false): return workspace.device.observations.isEmpty ? "Not checked yet" : "Not here"
        }
    }

    @ViewBuilder private var sourceFiles: some View {
        if content.isLoading {
            ProgressView("Reading the stored files…").controlSize(.small)
        } else if skill.hasCentralContent, content.loadedID != skill.id, let message = content.errorMessage {
            Text(message).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if content.loadedID == skill.id, !content.files.isEmpty {
            DisclosureGroup("Source files") {
                VStack(spacing: 0) {
                    ForEach(content.files, id: \.self) { file in
                        LabeledValueRow(file == "SKILL.md" ? "Definition" : "Bundled file") {
                            Text(file).font(.system(.caption, design: .monospaced))
                        }
                        if file != content.files.last { Divider() }
                    }
                }
            }
        } else if let path = inventory.authoringPaths[skill.id] ?? inventory.observedPaths[skill.id] {
            LabeledValueRow(skill.ownership == .attachedAuthoring ? "Your folder" : "Found at") {
                LocationText(path: path)
            }
            .standardPanel(cornerRadius: 13)
        }
    }
}

private struct SkillInfoButton: View {
    let text: String
    let label: String
    @State private var presented = false

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(text)
        .popover(isPresented: $presented) {
            Text(text).font(.callout).padding(14).frame(width: 290, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

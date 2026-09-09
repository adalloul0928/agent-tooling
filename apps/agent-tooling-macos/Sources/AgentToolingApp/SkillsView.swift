import AgentToolingCore
import AppKit
import SwiftUI

struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("skills.sourceOwnership") private var sourceOwnership = "{}"
    var navigate: ((AppSection) -> Void)?

    var body: some View {
        SkillsBrowser(
            navigate: navigate,
            sourceOwnership: $sourceOwnership,
            inventory: SkillInventoryIndex(
                skills: model.visibleSkills, plugins: model.visiblePlugins, observations: model.visibleTargetObservations,
                tagAssignments: model.tagAssignments, collections: model.collections,
                ownershipJSON: sourceOwnership, adoptableIDs: Set(model.adoptableSkillIDs)
            )
        )
    }
}

private struct SkillsBrowser: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    var navigate: ((AppSection) -> Void)?
    @State private var query = ""
    @AppStorage("skills.collapsedGroups") private var collapsedGroupsJSON = "[]"
    @AppStorage("skills.grouping") private var grouping = "None"
    @AppStorage("skills.groupingMigration") private var groupingMigration = false
    @AppStorage("skills.category") private var scope: SkillScope = .all
    @AppStorage("skills.marketplace") private var marketplaceFilter = ""
    @AppStorage("skills.plugin") private var pluginFilter = ""
    @AppStorage("skills.installation") private var installationFilter = "All installations"
    @AppStorage("skills.maintenance") private var maintenanceFilter = "All maintenance"
    @Binding var sourceOwnership: String
    let inventory: SkillInventoryIndex
    @AppStorage("skills.client") private var clientFilter: SkillClientFilter = .all
    @State private var tagFilter: Set<String> = []
    @State private var untaggedOnly = false
    @State private var selectedID = ""
    @State private var skillBeingEdited: Skill?
    @State private var skillBeingSourceEdited: Skill?
    @State private var codexCreatorPresented = false
    @State private var pasteImportPresented = false
    @State private var pendingCodexRequestID: UUID?
    @State private var installAfterCreator: CodexSkillInstallHandoff?
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var copyConfirmationPresented = false
    @State private var requestedCopies: Set<String> = []

    init(navigate: ((AppSection) -> Void)?, sourceOwnership: Binding<String>, inventory: SkillInventoryIndex) {
        self.navigate = navigate
        _sourceOwnership = sourceOwnership
        self.inventory = inventory
    }

    var body: some View {
        let listedSkills = filteredSkills
        VStack(spacing: 0) {
            PageToolbar(title: "Skills", context: toolbarContext) {
                if isSelecting {
                    Button("Select All") { selection = adoptableIDs.intersection(filteredSkills.map(\.id)) }
                        .buttonStyle(.glass)
                        .accessibilityHint("Selects every discovered skill currently listed")
                }
                if isSelecting {
                    Button("Done", systemImage: "checkmark.circle") { setSelecting(false) }.buttonStyle(.glass)
                } else {
                    Menu {
                        Button("Make personal copies…", systemImage: "doc.on.doc") { setSelecting(true) }
                            .disabled(model.isInteractionLocked || adoptableIDs.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis")
                    }.buttonStyle(.glass).accessibilityLabel("Skill actions")
                }
                Button {
                    navigate?(.insights)
                } label: {
                    Label("Find opportunities", systemImage: "magnifyingglass")
                }
                .buttonStyle(.glass)
                .accessibilityHint("Scans recent work for useful skills, plugins, and MCP servers")
                Button {
                    openCodexCreator()
                } label: {
                    Label(model.isClientEnabled(.codex) ? "New skill…" : "Import skill…", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .tint(AgentTheme.selection)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.isInteractionLocked)
            }

            filtersToolbar(skills: listedSkills)
            Divider()
            GeometryReader { proxy in
                if selectedSkill != nil {
                    HSplitView {
                        collectionPane(skills: listedSkills)
                            .frame(
                                minWidth: 320, idealWidth: proxy.size.width / 2, maxWidth: .infinity,
                                maxHeight: .infinity, alignment: .topLeading)
                        VStack(spacing: 0) {
                            InspectorHeader(title: "Skill details") { selectedID = "" }
                            detailPane
                        }
                        .frame(
                            minWidth: 400, idealWidth: proxy.size.width / 2, maxWidth: .infinity,
                            maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    collectionPane(skills: listedSkills).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

        }
        .sheet(isPresented: $pasteImportPresented) { PasteImportSheet { model.addMCPServer(from: $0) != nil } }
        .confirmationDialog("Make personal copies?", isPresented: $copyConfirmationPresented, titleVisibility: .visible) {
            Button("Review personal copies") {
                model.planSkillAdoption(skillIDs: requestedCopies)
                if model.pendingPlan != nil { setSelecting(false) }
            }
            Button("Cancel", role: .cancel) { requestedCopies = [] }
        } message: {
            Text(
                "These will be independently maintained versions. To keep receiving upstream updates, link the original repository instead."
            )
        }
        .onChange(of: model.enabledClients) { _, _ in
            if !model.isClientEnabled(clientFilter.client) { clientFilter = .all }
            clearUnavailableSourceFilters()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $skillBeingEdited) { skill in
            SkillEditorSheet(existingSkill: skill) { draft in
                if let updated = model.updateSkill(id: skill.id, from: draft) {
                    selectedID = updated.id
                    return true
                }
                return false
            }
            .environment(model)
        }
        .sheet(item: $skillBeingSourceEdited) { skill in
            SkillSourceEditorSheet(existingSkill: skill) { markdown in
                model.updateSkillSource(id: skill.id, markdown: markdown) != nil
            }
            .environment(model)
        }
        .sheet(
            isPresented: $codexCreatorPresented,
            onDismiss: {
                pendingCodexRequestID = nil
                let handoff = installAfterCreator
                installAfterCreator = nil
                DispatchQueue.main.async {
                    if let handoff {
                        model.planInstall(
                            skillID: handoff.skillID,
                            targets: handoff.targets,
                            includeFreshSessionCanary: true
                        )
                    }
                    applyExternalNavigation()
                }
            }
        ) {
            CodexSkillCreatorSheet(pendingRequestID: pendingCodexRequestID) { skill, targets in
                selectedID = skill.id
                installAfterCreator = CodexSkillInstallHandoff(skillID: skill.id, targets: targets)
            }
            .environment(model)
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
            // A scan or a completed adoption can take a row out of the batch.
            // The bar must never offer a count the plan would not honour.
            if isSelecting { selection.formIntersection(adoptableIDs) }
        }
        .onChange(of: listedSkills.map(\.id)) { _, _ in clearHiddenSelection() }
    }

    private var extraFilterCount: Int {
        (installationFilter == "All installations" ? 0 : 1)
            + (maintenanceFilter == "All maintenance" ? 0 : 1)
            + (tagFilter.isEmpty && !untaggedOnly ? 0 : 1)
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

    private func filtersToolbar(skills: [Skill]) -> some View {
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
                        ForEach(marketplaces, id: \.id) { source in Text(source.title).tag(source.id) }
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
                        ForEach(SkillClientFilter.allCases.filter { model.isClientEnabled($0.client) }) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(clientFilter.rawValue, systemImage: "desktopcomputer")
                }
                .fixedSize()
                Menu {
                    Picker("Plugin", selection: $pluginFilter) {
                        Text("All plugins").tag("")
                        ForEach(plugins, id: \.id) { plugin in
                            Text(plugin.title).tag(plugin.id)
                        }
                    }
                    Picker("Installation", selection: $installationFilter) {
                        ForEach(["All installations", "Standalone", "Plugin"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Maintenance", selection: $maintenanceFilter) {
                        ForEach(["All maintenance", "Maintained here", "Maintained elsewhere"], id: \.self) { Text($0).tag($0) }
                    }
                    if !skillTags.isEmpty {
                        Divider()
                        Toggle("Untagged only", isOn: $untaggedOnly)
                        ForEach(skillTags, id: \.self) { tag in
                            Toggle(
                                tag,
                                isOn: Binding(
                                    get: { tagFilter.contains(tag) },
                                    set: { enabled in
                                        if enabled {
                                            tagFilter.insert(tag)
                                            untaggedOnly = false
                                        } else {
                                            tagFilter.remove(tag)
                                        }
                                    }))
                        }
                    }
                } label: {
                    Label(extraFilterCount == 0 ? "Filters" : "Filters (\(extraFilterCount))", systemImage: "line.3.horizontal.decrease")
                }.fixedSize()
                Menu {
                    Picker("Group by", selection: $grouping) {
                        ForEach(SkillGrouping.allCases) { group in Text(group.rawValue).tag(group.rawValue) }
                    }.pickerStyle(.inline)
                    if resolvedGrouping != .none {
                        Divider()
                        Button("Expand all") { saveCollapsedGroups([]) }
                        Button("Collapse all") { saveCollapsedGroups(Set(groupedSkills.map(\.id))) }
                    }
                } label: {
                    Label(resolvedGrouping == .none ? "Group" : "Group: \(resolvedGrouping.rawValue)", systemImage: "rectangle.3.group")
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

    /// Resolved once per layout pass. Asking the model per row would make the
    /// cost of drawing the list grow with the square of a 250-skill inventory.
    private func collectionPane(skills: [Skill]) -> some View {
        let adoptable = adoptableIDs
        let groups = SkillListPresentation.groups(skills: skills, grouping: resolvedGrouping, presentation: presentation(for:))
        let collapsed = query.isEmpty ? collapsedGroups : []
        return VStack(spacing: 0) {

            if skills.isEmpty {
                EmptyStateView(
                    symbol: query.isEmpty ? "doc.text" : "doc.text.magnifyingglass",
                    title: emptyStateTitle,
                    message: emptyStateMessage,
                    actionTitle: emptyStateActionTitle,
                    isActionEnabled: isEmptyStateActionEnabled
                ) {
                    performEmptyStateAction()
                }
            } else {
                GeometryReader { geometry in
                    let columns = SkillTableColumns(width: geometry.size.width, selecting: isSelecting)
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            if isSelecting { Color.clear.frame(width: 20) }
                            Text("Name").frame(width: columns.name, alignment: .leading)
                            if columns.expanded {
                                Text("Description").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Plugin").frame(width: columns.plugin, alignment: .leading)
                                Text("Marketplace").frame(width: columns.marketplace, alignment: .leading)
                            } else {
                                Spacer(minLength: 0)
                            }
                            Text("Apps").frame(width: 72, alignment: .trailing)
                        }
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).frame(height: 30)
                        .background(AgentTheme.controlBackground.opacity(0.3))
                        Divider()
                        ScrollView {
                            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                                ForEach(groups) { group in
                                    let isCollapsed = collapsed.contains(group.id)
                                    Section {
                                        if resolvedGrouping == .none || !isCollapsed {
                                            ForEach(group.skills) { skill in
                                                SkillCollectionRow(
                                                    skill: skill,
                                                    presentation: presentation(for: skill),
                                                    selected: isSelecting ? selection.contains(skill.id) : skill.id == selectedID,
                                                    selecting: isSelecting,
                                                    isAdoptable: adoptable.contains(skill.id),
                                                    tags: inventory.tags[skill.id] ?? [],
                                                    collections: inventory.collectionNames[skill.id] ?? [],
                                                    columns: columns,
                                                    activate: { activate(skill, isAdoptable: adoptable.contains(skill.id)) },
                                                    filterClient: { client in
                                                        clientFilter = SkillClientFilter.allCases.first { $0.client == client } ?? .all
                                                    }
                                                )
                                                .accessibilityValue(
                                                    accessibilityValue(for: skill, isAdoptable: adoptable.contains(skill.id))
                                                )
                                                .contextMenu {
                                                    classificationActions([skill])
                                                }
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
                    actionTitle: "Make \(selection.count) personal \(selection.count == 1 ? "copy" : "copies")…",
                    isActionEnabled: !model.isInteractionLocked,
                    action: adoptSelection,
                    clear: { selection = [] }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.18), value: selection.isEmpty)
        .paneMaterial()
    }

    @ViewBuilder
    private var detailPane: some View {
        if let skill = selectedSkill {
            VStack(spacing: 0) {
                SkillDetailView(
                    skill: skill,
                    sourcePath: metadata(for: skill)?.path,
                    onEdit: { skillBeingEdited = skill },
                    onEditSource: { skillBeingSourceEdited = skill },
                    onInstall: { model.planInstall(skillID: skill.id) },
                    onAdopt: { requestCopies([skill.id]) }
                )
                Divider()
                HStack {
                    Text(installation(for: skill)).font(.caption).foregroundStyle(.secondary)
                    SkillInfoButton(text: classification(for: skill).reason, label: "Classification information")
                    Spacer()
                    Picker(
                        metadata(for: skill)?.providerPluginID == nil ? "Skill classification" : "Plugin classification",
                        selection: Binding(
                            get: { ownershipMap[ownershipKey(for: skill)] ?? "automatic" }, set: { setOwnership($0, for: skill) }
                        )
                    ) {
                        Text("Automatic").tag("automatic")
                        Text("Unclassified").tag("unknown")
                        Text("My skills").tag("mine")
                        Text("Third-party skills").tag("thirdParty")
                    }.labelsHidden().fixedSize().controlSize(.small).disabled(skill.owned)
                        .accessibilityLabel(
                            metadata(for: skill)?.providerPluginID == nil ? "Skill classification" : "Plugin classification")
                }.padding(.horizontal, 22).padding(.vertical, 10)
            }
        } else {
            EmptyStateView(
                symbol: "doc.text", title: "Select a skill",
                message: "Choose a skill to inspect its triggers, clients, source, and validation history.")
        }
    }

    private var skillTags: [String] { inventory.skillTags }

    private func matchesTagFilter(_ skill: Skill) -> Bool {
        let assigned = inventory.tags[skill.id] ?? []
        if untaggedOnly { return assigned.isEmpty }
        guard !tagFilter.isEmpty else { return true }
        return !tagFilter.isDisjoint(with: Set(assigned))
    }

    private var filteredSkills: [Skill] {
        inventory.skills.filter { skill in
            let origin = presentation(for: skill)
            return scope.matches(owner: ownership(for: skill))
                && origin.matches(marketplace: marketplaceFilter, plugin: pluginFilter)
                && (installationFilter == "All installations" || installationFilter == installation(for: skill))
                && (maintenanceFilter == "All maintenance" || (maintenanceFilter == "Maintained here") == skill.owned)
                && matchesTagFilter(skill)
                && clientFilter.matches(skill)
                && (query.isEmpty
                    || [skill.name, skill.displayName, skill.summary, origin.pluginName ?? "", origin.marketplaceName ?? ""]
                        .joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
    }

    private func presentation(for skill: Skill) -> SkillPresentation {
        inventory.presentations[skill.id] ?? SkillPresentation(pluginID: nil)
    }

    private var marketplaces: [(id: String, title: String)] { inventory.marketplaces }
    private var plugins: [(id: String, title: String)] { inventory.plugins }

    private var marketplaceFilterTitle: String {
        marketplaceFilter.isEmpty ? "All marketplaces" : ConnectionSource.title(marketplaceFilter)
    }

    private func clearUnavailableSourceFilters() {
        if !marketplaceFilter.isEmpty && !marketplaces.contains(where: { $0.id == marketplaceFilter }) { marketplaceFilter = "" }
        if !pluginFilter.isEmpty && !plugins.contains(where: { $0.id == pluginFilter }) { pluginFilter = "" }
    }

    private var ownershipMap: [String: String] { inventory.ownership }

    private func ownershipKey(for skill: Skill) -> String {
        SkillOrganization.ownershipKey(skillID: skill.id, pluginID: metadata(for: skill)?.providerPluginID)
    }

    private func ownership(for skill: Skill) -> String {
        classification(for: skill).owner
    }

    private func classification(for skill: Skill) -> SkillOrganization.Classification {
        inventory.classifications[skill.id]
            ?? SkillOrganization.classify(maintainedHere: skill.owned, pluginID: nil, override: nil)
    }

    private func setOwnership(_ value: String, for skill: Skill) {
        var values = (try? JSONDecoder().decode([String: String].self, from: Data(sourceOwnership.utf8))) ?? [:]
        values[ownershipKey(for: skill)] = value == "automatic" ? nil : value
        if let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) {
            sourceOwnership = json
        }
    }

    private func metadata(for skill: Skill) -> ObservedSkillMetadata? {
        inventory.metadata[skill.id]
    }

    private func installation(for skill: Skill) -> String {
        !skill.owned && metadata(for: skill)?.providerPluginID != nil ? "Plugin" : "Standalone"
    }

    private var collapsedGroups: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: Data(collapsedGroupsJSON.utf8))) ?? []
    }

    private func saveCollapsedGroups(_ groups: Set<String>) {
        if let data = try? JSONEncoder().encode(groups), let json = String(data: data, encoding: .utf8) {
            collapsedGroupsJSON = json
        }
    }

    private func classify(_ skills: [Skill], as owner: String) {
        var values = (try? JSONDecoder().decode([String: String].self, from: Data(sourceOwnership.utf8))) ?? [:]
        for skill in skills where !skill.owned { values[ownershipKey(for: skill)] = owner == "automatic" ? nil : owner }
        if let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) {
            sourceOwnership = json
        }
    }

    private var resolvedGrouping: SkillGrouping { SkillGrouping.migratedValue(grouping) }

    private var groupedSkills: [SkillListGroup] {
        SkillListPresentation.groups(skills: filteredSkills, grouping: resolvedGrouping, presentation: presentation(for:))
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
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(isCollapsed ? "Expand" : "Collapse") \(group.title)")
            Menu {
                classificationActions(group.skills)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Classify skills in this group without copying them")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 13)
        .frame(height: 32)
        .background(AgentTheme.controlBackground.opacity(0.45))
    }

    @ViewBuilder
    private func classificationActions(_ skills: [Skill]) -> some View {
        Button("Mark as My skills") { classify(skills, as: "mine") }
        Button("Mark as Third-party") { classify(skills, as: "thirdParty") }
        Button("Use automatic classification") { classify(skills, as: "automatic") }
        Button("Mark as Unclassified") { classify(skills, as: "unknown") }
    }

    private var selectedSkill: Skill? { inventory.skills.first { $0.id == selectedID } }

    /// Only a discovered skill the last setup check could place can be adopted,
    /// so selection mode never offers a row the plan would have to skip.
    private var adoptableIDs: Set<String> { inventory.adoptableIDs }

    private func setSelecting(_ value: Bool) {
        isSelecting = value
        if !value { selection = [] }
    }

    private func activate(_ skill: Skill, isAdoptable: Bool) {
        guard isSelecting else {
            selectedID = skill.id
            return
        }
        guard isAdoptable else { return }
        if selection.contains(skill.id) {
            selection.remove(skill.id)
        } else {
            selection.insert(skill.id)
        }
    }

    /// Selection survives a failed plan so the choice does not have to be made
    /// again; a prepared plan clears it because the review now owns the batch.
    private func adoptSelection() {
        let requested = selection.intersection(adoptableIDs)
        guard !requested.isEmpty else { return }
        requestCopies(requested)
    }

    private func requestCopies(_ ids: Set<String>) {
        requestedCopies = ids
        copyConfirmationPresented = true
    }

    private func accessibilityValue(for skill: Skill, isAdoptable: Bool) -> String {
        guard isSelecting else { return skill.id == selectedID ? "Selected" : "" }
        if !isAdoptable { return "Cannot be copied" }
        return selection.contains(skill.id) ? "Selected to copy" : "Not selected"
    }

    private var toolbarContext: String {
        "\(inventory.skills.count) discovered · \(inventory.mineCount) mine · \(inventory.unknownCount) unclassified"
    }

    private func clearHiddenSelection() {
        guard !filteredSkills.contains(where: { $0.id == selectedID }) else { return }
        selectedID = ""
    }

    private var emptyStateTitle: String { inventory.skills.isEmpty ? "No skills yet" : "No matching skills" }
    private var emptyStateMessage: String {
        if inventory.skills.isEmpty { return "Create a skill or check your apps to find existing skills." }
        switch scope {
        case .provider:
            return
                "No matching skills supplied directly by OpenAI or Anthropic were found. Marketplace listings with an unknown publisher remain in All skills."
        case .mine:
            return
                "No matching skills are classified as yours. Select a skill in All skills to change its classification. Copying it is not required."
        case .thirdParty:
            return "No matching third-party skills were found. Skills whose publisher is not established remain in All skills."
        case .all:
            return "Try a different search or clear your filters."
        }
    }
    private var emptyStateActionTitle: String { "Clear filters" }
    private var isEmptyStateActionEnabled: Bool { true }

    private func resetFilters() {
        marketplaceFilter = ""
        pluginFilter = ""
        installationFilter = "All installations"
        maintenanceFilter = "All maintenance"
        clientFilter = .all
        tagFilter = []
        untaggedOnly = false
    }

    private func performEmptyStateAction() {
        scope = .all
        query = ""
        resetFilters()
    }

    private func openCodexCreator(requestID: UUID? = nil) {
        guard model.isClientEnabled(.codex) else {
            pasteImportPresented = true
            return
        }
        installAfterCreator = nil
        pendingCodexRequestID = requestID
        codexCreatorPresented = true
    }

    private func applyExternalNavigation() {
        if let skillID = navigation.requestedSkillID,
            inventory.skills.contains(where: { $0.id == skillID })
        {
            performEmptyStateAction()
            selectedID = skillID
        }
        if !codexCreatorPresented, let requestID = navigation.requestedSkillCreationID {
            navigation.consumeSkillCreationRequest(requestID)
            openCodexCreator(requestID: requestID)
        }
    }
}

private struct CodexSkillInstallHandoff {
    var skillID: String
    var targets: Set<ClientKind>
}

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

    func matches(_ skill: Skill) -> Bool {
        guard let client else { return true }
        return skill.clients.contains { $0.client == client && $0.reportsLocalPresence }
    }
}

private struct SkillTableColumns {
    let width: CGFloat
    let selecting: Bool
    var expanded: Bool { width >= 880 }
    var name: CGFloat { expanded ? min(300, width * 0.24) : max(140, width - 144 - (selecting ? 32 : 0)) }
    var plugin: CGFloat { min(200, width * 0.17) }
    var marketplace: CGFloat { min(180, width * 0.15) }
}

private struct SkillCollectionRow: View {
    let skill: Skill
    let presentation: SkillPresentation
    let selected: Bool
    var selecting = false
    var isAdoptable = false
    var tags: [String] = []
    var collections: [String] = []
    let columns: SkillTableColumns
    let activate: () -> Void
    let filterClient: (ClientKind) -> Void

    private var summary: String {
        let value = skill.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["", ">-", ">", "|", "|-"].contains(value) ? "—" : value
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: activate) {
                HStack(spacing: 12) {
                    if selecting {
                        SelectionCheckbox(selected: selected, enabled: isAdoptable).frame(width: 20)
                    }
                    HStack(spacing: 9) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 14))
                            .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(skill.displayName).font(.callout.weight(.medium)).lineLimit(1)
                            if !columns.expanded {
                                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if let origin = presentation.compactDescription {
                                    Text(origin).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(origin)
                                }
                            }
                            if !tags.isEmpty || !collections.isEmpty {
                                HStack(spacing: 4) {
                                    CollectionPills(names: collections, selected: selected)
                                    TagPills(tags: tags, selected: selected)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }.frame(width: columns.name, alignment: .leading)
                    if columns.expanded {
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .help(summary)
                        Text(presentation.pluginName ?? "Standalone")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .frame(width: columns.plugin, alignment: .leading)
                            .help(presentation.pluginName ?? "Standalone skill")
                        Text(presentation.marketplaceName ?? "—")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .frame(width: columns.marketplace, alignment: .leading)
                            .help(presentation.marketplaceName ?? "No marketplace")
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(skill.displayName)
            HStack(spacing: 8) {
                ForEach(skill.clients.filter(\.reportsLocalPresence), id: \.client) { state in
                    Button {
                        filterClient(state.client)
                    } label: {
                        ClientBrandIcon(client: state.client, size: 16)
                            .frame(width: 24, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show skills in \(state.client.rawValue)")
                    .accessibilityLabel("Filter by \(state.client.rawValue)")
                }
            }.frame(width: 72, alignment: .trailing)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 16)
        .frame(height: tags.isEmpty && collections.isEmpty ? (columns.expanded ? 44 : (presentation.pluginID == nil ? 48 : 64)) : 78)
        .rowSelection(selected)
        .overlay(alignment: .bottom) { Divider().opacity(0.25) }
    }
}

private struct SkillDetailView: View {
    @Environment(AppModel.self) private var model
    let skill: Skill
    let sourcePath: String?
    let onEdit: () -> Void
    let onEditSource: () -> Void
    let onInstall: () -> Void
    let onAdopt: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 13) {
                    KindTile(kind: .skill, size: 40, ghost: !skill.owned)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(skill.displayName).font(.system(size: 22, weight: .semibold))
                        HStack(spacing: 6) {
                            Text(
                                skill.owned
                                    ? "Managed by you"
                                    : skill.repositoryBinding != nil
                                        ? "Following repository"
                                        : model.skillPluginID(skill.id) != nil ? "Managed with plugin" : "Source unknown"
                            )
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                            SkillInfoButton(
                                text: skill.owned
                                    ? "The source is maintained in this library. Save edits, then review updates to installed copies."
                                    : "This skill is maintained at its original source. Copying creates a separate version in this library; it is not required to install or use the skill.",
                                label: "About maintenance")
                        }.foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    if skill.owned, skill.authoringOrigin == .manual {
                        Button("Edit…", systemImage: "pencil", action: onEdit)
                            .buttonStyle(.bordered)
                            .disabled(model.isInteractionLocked)
                    } else if skill.owned {
                        Button("Edit Source…", systemImage: "doc.text", action: onEditSource)
                            .buttonStyle(.bordered)
                            .disabled(model.isInteractionLocked)
                            .accessibilityHint("Edits the complete SKILL.md while preserving scripts, references, and assets")
                    }
                    if skill.owned {
                        Button("Review Install…", systemImage: "arrow.down.circle") { onInstall() }
                            .buttonStyle(.borderedProminent)
                            .tint(AgentTheme.selection)
                            .disabled(model.isInteractionLocked)
                    } else if model.canAdoptSkill(id: skill.id) {
                        Button("Make personal copy…", systemImage: "doc.on.doc") { onAdopt() }
                            .buttonStyle(.bordered)
                            .disabled(model.isInteractionLocked)
                            .accessibilityHint("Creates a separately maintained copy after you review the plan")
                    }
                }

                Text(skill.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !skill.owned {
                    SkillRepositorySection(skill: skill)
                }

                GroupBox {

                    VStack(spacing: 12) {
                        ForEach(skill.clients, id: \.client) { state in
                            HStack {
                                Text(state.client.rawValue).font(.callout.weight(.medium))
                                Spacer()
                                if state.reportsLocalPresence {
                                    if let enabled = model.isSkillEnabled(skill.id, client: state.client) {
                                        let wholePlugin =
                                            state.client == .claude && model.skillPluginID(skill.id, client: state.client) != nil
                                        if wholePlugin {
                                            Text("Whole plugin").font(.caption).foregroundStyle(.secondary)
                                            SkillInfoButton(
                                                text:
                                                    "Claude controls these skills through their parent plugin. This switch affects every skill, MCP server, and hook in the bundle.",
                                                label: "Plugin switch scope")
                                        }
                                        Toggle(
                                            "Enable \(state.client.rawValue) \(wholePlugin ? "plugin" : "skill")",
                                            isOn: Binding(
                                                get: { enabled },
                                                set: { model.setSkillEnabled(skill.id, client: state.client, enabled: $0) }
                                            )
                                        )
                                        .toggleStyle(.switch).labelsHidden().fixedSize()
                                        .disabled(model.isInteractionLocked)
                                        .help(
                                            wholePlugin
                                                ? "Changes every skill and component in this Claude plugin"
                                                : "Changes this skill's native user-level availability")
                                    } else {
                                        SkillInfoButton(
                                            text:
                                                "Run Check setup to locate the installed skill. Unsupported configuration formats must be edited in the client.",
                                            label: "Availability unavailable")
                                    }
                                } else if skill.owned {
                                    Button("Add…") {
                                        model.planInstall(skillID: skill.id, targets: [state.client])
                                    }.disabled(model.isInteractionLocked)
                                } else if model.skillPluginID(skill.id) != nil {
                                    Button("Add plugin…") {
                                        Task { await model.installSkillPlugin(skill.id, client: state.client) }
                                    }.disabled(model.isInteractionLocked)
                                } else if [.claude, .codex].contains(state.client) {
                                    Button("Add…") {
                                        model.planDiscoveredSkillInstall(skill.id, client: state.client)
                                    }.disabled(model.isInteractionLocked)
                                }
                            }
                        }
                    }.padding(6)
                } label: {
                    HStack(spacing: 6) {
                        Text("Apps")
                        SkillInfoButton(
                            text:
                                "Changes apply to this Mac’s user settings. Restart the client after changes. Project or organization settings may override these preferences.",
                            label: "About app availability")
                    }
                }

                if !skill.triggers.isEmpty || !skill.negativeTrigger.isEmpty {
                    GroupBox("When it appears") {
                        VStack(spacing: 0) {
                            if !skill.triggers.isEmpty {
                                LabeledValueRow("Triggers") {
                                    TagCloud(tags: skill.triggers)
                                }
                            }
                            if !skill.triggers.isEmpty && !skill.negativeTrigger.isEmpty { Divider() }
                            if !skill.negativeTrigger.isEmpty {
                                LabeledValueRow("Doesn’t appear for") {
                                    Text(skill.negativeTrigger).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !skill.owned, let file = sourcePath {
                    Button("Show source", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
                    }.buttonStyle(.bordered)

                }

                DisclosureGroup("Source files") {
                    VStack(spacing: 0) {
                        LabeledValueRow("Bundle") { Text(skill.bundle).fontWeight(.medium) }
                        Divider()
                        ForEach(skill.files, id: \.self) { file in
                            LabeledValueRow(file.hasSuffix("SKILL.md") ? "Definition" : "Bundled file") {
                                LocationText(path: file)
                            }
                            if file != skill.files.last { Divider() }
                        }
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: skill.validationCount > 0 ? "checkmark.seal" : "circle.dashed")
                    Text(skill.validationCount > 0 ? "\(skill.validationCount) checks passed" : "Not checked")
                    SkillInfoButton(
                        text:
                            "These checks validate the skill definition in our library. They do not verify invocation or authentication in a live client session.",
                        label: "About validation")
                }.font(.caption).foregroundStyle(.secondary)

                if skill.owned {
                    Button("Reveal Source in Finder", systemImage: "folder") {
                        let source = URL(fileURLWithPath: model.workspacePath)
                            .appending(path: "library/packages/\(skill.bundle)/skills/\(skill.id)", directoryHint: .isDirectory)
                        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
                            model.presentError(
                                "The managed source for \(skill.displayName) is no longer available. Check setup again to refresh local state."
                            )
                            return
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([source])
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Reveal \(skill.displayName) source in Finder")
                    .disabled(model.isInteractionLocked)
                }
            }
            .padding(22)
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

struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = cursorX == 0 ? size.width : cursorX + spacing + size.width
            if cursorX > 0, nextWidth > maximumWidth {
                cursorY += rowHeight + spacing
                cursorX = size.width
                rowHeight = size.height
            } else {
                cursorX = nextWidth
                rowHeight = max(rowHeight, size.height)
            }
            measuredWidth = max(measuredWidth, cursorX)
        }
        return CGSize(width: proposal.width.map { min($0, measuredWidth) } ?? measuredWidth, height: cursorY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > bounds.minX, cursorX + size.width > bounds.maxX {
                cursorX = bounds.minX
                cursorY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: cursorX, y: cursorY), anchor: .topLeading, proposal: .unspecified)
            cursorX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

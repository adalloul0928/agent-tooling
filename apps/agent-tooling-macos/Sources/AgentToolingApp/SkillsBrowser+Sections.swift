import AgentToolingCore
import AppKit
import SwiftUI

extension SkillsBrowser {

    // MARK: - List

    /// Resolved once per layout pass. Asking the index per row would make the
    /// cost of drawing the list grow with the square of a 250-skill library.
    func collectionPane(skills: [SkillEntry]) -> some View {
        let assignable = assignableIDs
        let groups = SkillListPresentation.groups(
            skills: skills, grouping: resolvedGrouping, presentation: inventory.presentation(for:),
            copies: inventory.copies(of:))
        let collapsed = query.isEmpty ? collapsedGroups : []
        return VStack(spacing: 0) {
            if let message = workspace.library.errorMessage, assignment == nil {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(AgentFont.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, WorkspaceLayout.pageInset).padding(.vertical, Space.lg)
            }
            if skills.isEmpty {
                EmptyStateView(
                    symbol: query.isEmpty ? "doc.text" : "doc.text.magnifyingglass",
                    title: emptyStateTitle,
                    message: emptyStateMessage,
                    actionTitle: inventory.skills.isEmpty ? "New Skill…" : "Clear filters"
                ) {
                    performEmptyStateAction()
                }
            } else {
                GeometryReader { geometry in
                    let columns = SkillTableColumns(
                        width: geometry.size.width - WorkspaceLayout.pageInset * 2, selecting: isSelecting,
                        // A workspace built by scanning records no descriptions,
                        // so the column would be a screenful of dashes. It earns
                        // its width only once something in view has one.
                        describing: skills.contains { !$0.summary.isEmpty })
                    VStack(spacing: 0) {
                        header(columns)
                        Hairline()
                        ScrollView {
                            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                                ForEach(groups) { group in
                                    let isCollapsed = collapsed.contains(group.id)
                                    Section {
                                        if resolvedGrouping == .none || !isCollapsed {
                                            ForEach(group.skills) { skill in
                                                row(
                                                    skill, members: group.members(of: skill),
                                                    assignable: assignable.contains(skill.id), columns: columns)
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
        .animation(.snappy(duration: 0.18), value: selection.isEmpty)
        .collectionSurface()
        // Above the card's clip, so its shadow and rounded corners survive.
        .overlay(alignment: .bottom) {
            if isSelecting, !selection.isEmpty {
                SelectionActionBar(
                    count: selection.count,
                    actionTitle: "Install \(selection.count)…",
                    isActionEnabled: !workspace.library.isBusy && canWrite,
                    action: assignSelection,
                    clear: { selection = [] }
                )
                .padding(.bottom, WorkspaceLayout.pageInset + 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .paneMaterial()
    }

    func header(_ columns: SkillTableColumns) -> some View {
        HStack(spacing: Space.lg) {
            if isSelecting { Color.clear.frame(width: Size.glyphSlot) }
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
            Text("Found in").frame(width: Size.foundInColumn, alignment: .trailing)
            Text("Managed").frame(width: columns.verdict, alignment: .trailing)
                .help("Who manages each skill: you (with the apps this app placed it in), its plugin, or nobody here.")
        }
        .font(AgentFont.captionMedium).foregroundStyle(.secondary)
        .padding(.horizontal, Space.xl).frame(height: Size.compactRowHeight)
        .background(AgentTheme.fillSubtle)
    }

    /// One row for a skill and the copies of it in this section. The marks
    /// say where any of those copies was found, and the row stays selected
    /// while the detail pane shows any one of them.
    func row(_ skill: SkillEntry, members: [SkillEntry], assignable: Bool, columns: SkillTableColumns) -> some View {
        let everyCopy = inventory.copies(of: skill)
        let observed = members.reduce(into: Set<ClientKind>()) { $0.formUnion(inventory.observedClients[$1.id] ?? []) }
        return SkillCollectionRow(
            skill: skill,
            presentation: inventory.presentation(for: skill),
            observed: observed,
            management: inventory.management(of: skill),
            copies: SkillCopySummary(copies: everyCopy.count, versions: inventory.versions(among: everyCopy).count),
            moreSources: members.count - 1,
            selected: isSelecting ? selection.contains(skill.id) : members.contains { $0.id == selectedID },
            selecting: isSelecting,
            isAssignable: assignable,
            columns: columns,
            update: workspace.updates.availability(for: skill.id),
            activate: { activate(skill, isAssignable: assignable) }
        )
        .accessibilityValue(accessibilityValue(for: skill, isAssignable: assignable))
        .contextMenu {
            Button("Show details", systemImage: "info.circle") { selectedID = skill.id }
            if assignable {
                Button("Install…", systemImage: "arrow.down.circle") {
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
    var detailPane: some View {
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
                    onOpenPlugin: { id in navigation.openItem(id.rawValue.uuidString.lowercased(), in: .plugins) },
                    onSelectCopy: { id in selectedID = id }
                )
                Hairline()
                HStack {
                    Text(skill.installation).font(AgentFont.caption).foregroundStyle(.secondary)
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
                .padding(.horizontal, Space.xxxl).padding(.vertical, Space.lg)
            }
        } else {
            EmptyStateView(
                symbol: "doc.text", title: "Select a skill",
                message: "Choose a skill to see where it came from, where it was found, and where it is used.")
        }
    }

    // MARK: - Filtering

    var filteredSkills: [SkillEntry] {
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

    var marketplaceFilterTitle: String {
        marketplaceFilter.isEmpty ? "All marketplaces" : SkillOrganization.SourceIdentity.title(marketplaceFilter)
    }

    func clearUnavailableSourceFilters() {
        if !marketplaceFilter.isEmpty, !inventory.marketplaces.contains(where: { $0.id == marketplaceFilter }) {
            marketplaceFilter = ""
        }
        if !pluginFilter.isEmpty, !inventory.plugins.contains(where: { $0.id == pluginFilter }) { pluginFilter = "" }
    }

    func setOwnership(_ value: String, for skill: SkillEntry) {
        var values = (try? JSONDecoder().decode([String: String].self, from: Data(sourceOwnership.utf8))) ?? [:]
        values[inventory.ownershipKey(for: skill)] = value == "automatic" ? nil : value
        if let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) {
            sourceOwnership = json
        }
    }

    func classify(_ skills: [SkillEntry], as owner: String) {
        var values = (try? JSONDecoder().decode([String: String].self, from: Data(sourceOwnership.utf8))) ?? [:]
        for skill in skills where !skill.isMaintainedHere {
            values[inventory.ownershipKey(for: skill)] = owner == "automatic" ? nil : owner
        }
        if let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) {
            sourceOwnership = json
        }
    }

    @ViewBuilder
    func classificationActions(_ skills: [SkillEntry]) -> some View {
        Button("Mark as My skills") { classify(skills, as: "mine") }
        Button("Mark as Third-party") { classify(skills, as: "thirdParty") }
        Button("Use automatic classification") { classify(skills, as: "automatic") }
        Button("Mark as Unclassified") { classify(skills, as: "unknown") }
    }

    // MARK: - Grouping

    var collapsedGroups: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: Data(collapsedGroupsJSON.utf8))) ?? []
    }

    func saveCollapsedGroups(_ groups: Set<String>) {
        if let data = try? JSONEncoder().encode(groups), let json = String(data: data, encoding: .utf8) {
            collapsedGroupsJSON = json
        }
    }

    var resolvedGrouping: SkillGrouping { SkillGrouping.migratedValue(grouping) }

    var groupedSkills: [SkillListGroup] {
        SkillListPresentation.groups(
            skills: filteredSkills, grouping: resolvedGrouping, presentation: inventory.presentation(for:),
            copies: inventory.copies(of:))
    }

    func groupHeader(_ group: SkillListGroup, isCollapsed: Bool) -> some View {
        HStack(spacing: Space.md) {
            Button {
                var collapsed = collapsedGroups
                if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                saveCollapsedGroups(collapsed)
            } label: {
                HStack(spacing: Space.md) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(AgentFont.microSemibold).frame(width: Size.glyphSmall)
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
        .font(AgentFont.captionSemibold)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.lg)
        .frame(height: Size.compactRowHeight)
        .background(AgentTheme.fillSubtle)
    }

    // MARK: - Selection

    var selectedSkill: SkillEntry? { inventory.skills.first { $0.id == selectedID } }

    /// Only a row the workspace says may be assigned, so selection never offers
    /// a row the review would have to drop.
    var assignableIDs: Set<ArtifactID> {
        Set(inventory.skills.filter(\.isAssignable).map(\.id))
    }

    func setSelecting(_ value: Bool) {
        isSelecting = value
        if !value { selection = [] }
    }

    func activate(_ skill: SkillEntry, isAssignable: Bool) {
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
    func assignSelection() {
        let requested = selection.intersection(assignableIDs)
        guard !requested.isEmpty else { return }
        workspace.library.discardReview()
        assignment = .init(artifactIDs: requested.sorted())
    }

    func accessibilityValue(for skill: SkillEntry, isAssignable: Bool) -> String {
        guard isSelecting else { return skill.id == selectedID ? "Selected" : "" }
        if !isAssignable { return skill.assignmentExplanation ?? "Cannot be assigned" }
        return selection.contains(skill.id) ? "Selected to assign" : "Not selected"
    }

    var toolbarContext: String {
        "\(inventory.distinctCount) skills · \(inventory.mineCount) mine · \(inventory.unknownCount) unclassified"
    }

    func clearHiddenSelection() {
        guard let selectedID, !filteredSkills.contains(where: { $0.id == selectedID }) else { return }
        self.selectedID = nil
    }

    // MARK: - Empty state

    var emptyStateTitle: String { inventory.skills.isEmpty ? "No skills yet" : "No matching skills" }

    var emptyStateMessage: String {
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

    func resetFilters() {
        marketplaceFilter = ""
        pluginFilter = ""
        installationFilter = "All installations"
        maintenanceFilter = "All maintenance"
        clientFilter = .all
    }

    func performEmptyStateAction() {
        guard !inventory.skills.isEmpty else {
            // The button says "New skill…", so it creates one — checking this
            // Mac's apps stays one click away in the toolbar.
            choosingCreation = true
            return
        }
        scope = .all
        query = ""
        resetFilters()
    }

    // MARK: - Routes

    func newestMatch(named name: String) -> ArtifactID? {
        let identifier = (try? WorkspaceLibrary.normalizedIdentifier(name)) ?? name
        let display = SkillTemplate.displayName(for: identifier)
        return workspace.library.state?.library.rows.first {
            $0.kind == .skill && $0.displayName.caseInsensitiveCompare(display) == .orderedSame
        }?.artifactID
    }

    func applyExternalNavigation() {
        if skillCreator == nil, let requestID = navigation.requestedSkillCreationID {
            navigation.consumeSkillCreationRequest(requestID)
            openSkillCreator(requestID: requestID)
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

    /// Opens the creator: with a chosen assistant for a blank skill, or for a
    /// request somebody queued, whose payload names the assistant itself.
    func openSkillCreator(client: ClientKind? = nil, requestID: UUID? = nil) {
        createdBySkillCreator = nil
        skillCreator = .init(client: client, requestID: requestID)
    }

    /// The creator has closed. A skill it admitted is revealed and offered a
    /// destination; nothing is assigned until that second sheet is saved.
    func finishSkillCreation() {
        guard let created = createdBySkillCreator else { return }
        createdBySkillCreator = nil
        selectedID = created.artifactID
        workspace.library.discardReview()
        assignment = .init(artifactIDs: [created.artifactID], initialClients: created.clients)
    }

    /// A skill the creator admitted, and the apps it was ticked for in "Use
    /// after review" — held until the creator's own sheet has closed, so the
    /// hand-off can offer the same apps again instead of a blank sheet.
    struct SkillCreatorAdoption {
        let artifactID: ArtifactID
        let clients: Set<ClientKind>
    }

    struct SkillCreatorPresentation: Identifiable {
        let id = UUID()
        /// The assistant chosen for a blank skill. Nil when a queued request
        /// is opened: its payload says which assistant was asked.
        let client: ClientKind?
        /// The queued request this creator was opened for, when there was one.
        let requestID: UUID?
    }

    struct AssignmentPresentation: Identifiable {
        let id = UUID()
        let artifactIDs: [ArtifactID]
        var initialClients: Set<ClientKind> = []
    }

    struct ExportPresentation: Identifiable {
        let id = UUID()
        let artifactID: ArtifactID
        let name: String
    }
}

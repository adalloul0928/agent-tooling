import AgentToolingCore
import SwiftUI

/// The Library's Plugins tab: native plugins and centrally tracked plugin
/// packages, in the same master-detail shape the original screen used.
///
/// Update comparison waits for Discover's marketplace session, which a
/// different port is building; until then every plugin reports "not checked"
/// rather than a stale or invented answer. Removing a plugin from an app is a
/// reviewed change to this workspace's saved intent, never a write to the app
/// itself — that stays the Install screen's job.
struct PluginsView: View {
    let workspace: WorkspaceLaunch.Workspace
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.workspaceNavigate) private var navigate
    @State private var query = ""
    @State private var clientFilter: ClientKind?
    @State private var selection: Set<ArtifactID> = []
    @State private var stackClient: ClientKind = .claude
    @State private var refreshID = UUID()

    var body: some View {
        let inventory = PluginInventoryIndex(rows: libraryRows)
        let listed = filtered(inventory.rows)

        VStack(spacing: 0) {
            PageToolbar(title: "Plugins", context: toolbarContext(inventory)) {
                Button {
                    Task { await workspace.device.refresh() }
                } label: {
                    Label(workspace.device.isChecking ? "Checking…" : "Check plugins", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glassProminent)
                .tint(AgentTheme.selection)
                .disabled(workspace.device.isChecking)
            }

            if selection.isEmpty {
                collectionPane(rows: listed, inventory: inventory)
            } else {
                HSplitView {
                    collectionPane(rows: listed, inventory: inventory).frame(minWidth: 320, idealWidth: 600)
                    VStack(spacing: 0) {
                        InspectorHeader(title: "Plugin details") { selection = [] }
                        detailPane(inventory: inventory)
                    }.frame(minWidth: 400, idealWidth: 600)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if !workspace.device.isEnabled(stackClient), let first = availableClients.first { stackClient = first }
            consumeRequestedSelection(in: inventory.rows)
        }
        .task(id: refreshID) { await workspace.library.refresh() }
        .onChange(of: inventory.rows.map(\.artifactID)) { _, _ in pruneSelection(in: inventory.rows) }
        .onChange(of: listed.map(\.artifactID)) { _, _ in pruneSelection(in: inventory.rows) }
        .onChange(of: navigation.revision) { _, _ in consumeRequestedSelection(in: inventory.rows) }
        .onExitCommand { selection = [] }
    }

    // MARK: Collection

    private func collectionPane(rows: [WorkspaceLibraryReadModelRow], inventory: PluginInventoryIndex) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("App", selection: $clientFilter) {
                    Text("All apps").tag(nil as ClientKind?)
                    ForEach(availableClients) { client in Text(client.rawValue).tag(client as ClientKind?) }
                }.inventoryMenuStyle().fixedSize()
                Spacer()
                InventorySearchField(placeholder: "Search plugins", text: $query)
                    .frame(maxWidth: 420)
                    .accessibilityLabel("Search plugins")
            }
            .padding(.horizontal, WorkspaceLayout.pageInset)
            .padding(.vertical, WorkspaceLayout.contentTopInset)

            if rows.isEmpty {
                EmptyStateView(
                    symbol: "puzzlepiece.extension",
                    title: hasFilters ? "No matching plugins" : "No installed plugins",
                    message: !hasFilters
                        ? "Open Discover to browse plugins from your marketplaces and folders."
                        : "Try a different plugin or app.",
                    actionTitle: hasFilters ? "Clear filters" : "Open Discover"
                ) {
                    if hasFilters {
                        query = ""
                        clientFilter = nil
                    } else {
                        navigate(.marketplace)
                    }
                }
            } else {
                GeometryReader { geometry in
                    if geometry.size.width < 820 {
                        narrowTable(rows: rows)
                    } else {
                        wideTable(rows: rows, inventory: inventory)
                    }
                }
            }
        }
        .paneMaterial()
    }

    private func narrowTable(rows: [WorkspaceLibraryReadModelRow]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Plugin") { row in
                HStack(spacing: 12) {
                    pluginIcon(for: row, size: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(row.sourceLabel.map { "From \($0)" } ?? row.ownershipLabel)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.vertical, 8)
                }
            }.width(min: 190, ideal: 350)
            TableColumn("Managed by") { row in
                TableClientMarks(clients: availableClients, present: Set(row.nativeRoutes.map(\.client)))
            }.width(90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
    }

    private func wideTable(rows: [WorkspaceLibraryReadModelRow], inventory: PluginInventoryIndex) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { row in
                HStack(spacing: 12) {
                    pluginIcon(for: row, size: 30)
                    Text(row.displayName).font(.callout.weight(.medium))
                }.padding(.vertical, 8)
            }.width(min: 180, ideal: 250)
            TableColumn("Description") { row in
                let text = description(for: row)
                Text(text).foregroundStyle(.secondary).lineLimit(1).help(text)
            }.width(min: 120, ideal: 360)
            TableColumn("Source") { row in
                Text(row.sourceLabel ?? "Not recorded").foregroundStyle(.secondary).lineLimit(1)
            }.width(min: 120, ideal: 150)
            TableColumn("Skills") { row in
                Text("\(row.childCount)").monospacedDigit().foregroundStyle(.secondary)
            }.width(50)
            TableColumn("Managed by") { row in
                TableClientMarks(clients: availableClients, present: Set(row.nativeRoutes.map(\.client)))
            }.width(90)
            TableColumn("Updates") { row in
                let update = inventory.availability[row.artifactID] ?? .notChecked(reason: "Not checked yet.")
                if update.hasUpdate {
                    UpdateStateBadge(availability: update)
                } else {
                    Text(update.title).font(.caption).foregroundStyle(.secondary)
                }
            }.width(min: 110, ideal: 130)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func detailPane(inventory: PluginInventoryIndex) -> some View {
        let stack = stackedRows(in: inventory.rows)
        if stack.count > 1 {
            PluginStackPane(
                rows: stack,
                library: workspace.library,
                availableClients: availableClients,
                client: $stackClient,
                onClear: { selection = Set(stack.prefix(1).map(\.artifactID)) }
            )
        } else if let row = selectedRow(in: inventory.rows) {
            PluginDetailView(
                row: row,
                availability: inventory.availability[row.artifactID] ?? .notChecked(reason: "Not checked yet."),
                library: workspace.library
            )
        } else {
            EmptyStateView(
                symbol: "puzzlepiece.extension", title: "Select a plugin",
                message: "Inspect its bundled skills, the apps it belongs to, and its requested assignments.")
        }
    }

    // MARK: Data

    /// This Mac's apps this workspace manages, in the registry's own order —
    /// the set every marks glyph and picker in this screen draws from.
    private var availableClients: [ClientKind] {
        workspace.device.availableClients.filter(workspace.device.isEnabled)
    }

    private var libraryRows: [WorkspaceLibraryReadModelRow] {
        (workspace.library.state?.library.rows ?? []).filter { $0.kind == .nativePlugin || $0.kind == .package }
    }

    private func filtered(_ rows: [WorkspaceLibraryReadModelRow]) -> [WorkspaceLibraryReadModelRow] {
        rows
            .filter { row in
                (clientFilter == nil || row.nativeRoutes.contains { $0.client == clientFilter })
                    && (query.isEmpty || searchText(row).localizedCaseInsensitiveContains(query))
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func description(for row: WorkspaceLibraryReadModelRow) -> String {
        guard let observed = row.observedDescription, !observed.isEmpty else { return row.ownershipLabel }
        return observed
    }

    private func searchText(_ row: WorkspaceLibraryReadModelRow) -> String {
        ([row.displayName, row.sourceLabel ?? "", row.observedDescription ?? ""] + row.includedChildren.map(\.displayName))
            .joined(separator: " ")
    }

    private var hasFilters: Bool { !query.isEmpty || clientFilter != nil }

    private func toolbarContext(_ inventory: PluginInventoryIndex) -> String {
        "\(inventory.rows.count) plugin\(inventory.rows.count == 1 ? "" : "s")"
    }

    /// Several picks, one plan. Removing plugins one at a time means one review
    /// each; the stack makes it a single reviewed operation.
    private func stackedRows(in rows: [WorkspaceLibraryReadModelRow]) -> [WorkspaceLibraryReadModelRow] {
        rows.filter { selection.contains($0.artifactID) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func selectedRow(in rows: [WorkspaceLibraryReadModelRow]) -> WorkspaceLibraryReadModelRow? {
        guard let id = selection.first, selection.count == 1 else { return nil }
        return rows.first { $0.artifactID == id }
    }

    private func pruneSelection(in rows: [WorkspaceLibraryReadModelRow]) {
        let visible = Set(filtered(rows).map(\.artifactID))
        let kept = selection.intersection(visible)
        if kept != selection { selection = kept }
    }

    /// Answers a palette result that named one plugin row: `openItem(_:in:.plugins)`
    /// leaves the row's identifier on `AppNavigationState` for the screen it
    /// opens to pick up and clear, rather than the shell picking it for us.
    private func consumeRequestedSelection(in rows: [WorkspaceLibraryReadModelRow]) {
        guard let id = navigation.requestedItemID,
            let uuid = UUID(uuidString: id)
        else { return }
        let artifactID = ArtifactID(rawValue: uuid)
        guard rows.contains(where: { $0.artifactID == artifactID }) else { return }
        query = ""
        clientFilter = nil
        selection = [artifactID]
        navigation.consumeRequestedItem(id)
    }
}

/// A native route's identifier is the same catalog identity the original
/// `plugin.id` carried, so brand artwork still resolves for anything this
/// workspace found through a client's own plugin registry. A package with no
/// native route yet has no such identity to look up, so it falls back to the
/// plain kind tile rather than guessing.
@ViewBuilder
private func pluginIcon(for row: WorkspaceLibraryReadModelRow, size: CGFloat) -> some View {
    if let route = row.nativeRoutes.first {
        ToolIdentityIcon(packageID: route.externalPluginID, size: size)
    } else {
        KindTile(kind: .plugin, size: size)
    }
}

/// Removing several plugins from one app is one reviewed operation, or none: a
/// stack with nothing recorded for the chosen app is refused with the reason,
/// never partially planned.
private struct PluginStackPane: View {
    let rows: [WorkspaceLibraryReadModelRow]
    let library: WorkspaceLibrarySession
    let availableClients: [ClientKind]
    @Binding var client: ClientKind
    let onClear: () -> Void
    @State private var removal: RemovalRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    KindTile(kind: .plugin, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(rows.count) plugins selected").font(.title3.weight(.semibold))
                        Text("Remove their assignment to one app through one reviewed plan.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review removal plan", action: review)
                        .buttonStyle(.borderedProminent)
                        .tint(AgentTheme.selection)
                        .disabled(library.isBusy || contributionIDs.isEmpty)
                }

                if let error = library.errorMessage {
                    AttentionBanner(title: "This stack cannot be planned yet", message: error) {
                        Button("Keep one", action: onClear)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                } else if contributionIDs.isEmpty {
                    AttentionBanner(
                        title: "Nothing to remove for \(client.rawValue)",
                        message: "None of the selected plugins have a saved assignment for this app.")
                }

                GroupBox("Remove from") {
                    WorkspaceSegmentedPicker("App", selection: $client) {
                        ForEach(availableClients) { candidate in Text(candidate.rawValue).tag(candidate) }
                    }
                    .labelsHidden()
                    .padding(13)
                    .accessibilityLabel("App to remove from")
                }

                GroupBox("In this stack") {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            InfoRow(row.displayName, detail: row.ownershipLabel) {
                                pluginIcon(for: row, size: 26)
                            } trailing: {
                                ClientMarks(present: Set(row.nativeRoutes.map(\.client)), size: 13)
                            }
                            if row.id != rows.last?.id { Divider().opacity(0.35) }
                        }
                    }
                }
            }
            .padding(22)
        }
        .sheet(item: $removal) { request in
            WorkspaceAssignmentSheet(session: library, artifactIDs: request.artifactIDs)
        }
    }

    /// Assignment contributions the selected plugins actually carry for the
    /// chosen app. A plugin this workspace only observed, never assigned, has
    /// none — there is nothing here for a reviewed removal to take back.
    private var contributionIDs: [WorkspaceObjectID] {
        rows.flatMap { row in
            row.requestedAssignments.filter { $0.destination.surface.client == client }.map(\.id)
        }
    }

    private func review() {
        let ids = contributionIDs
        guard !ids.isEmpty else { return }
        Task {
            await library.reviewRemoval(contributionIDs: ids)
            if library.review != nil {
                removal = RemovalRequest(artifactIDs: rows.map(\.artifactID))
            }
        }
    }

    private struct RemovalRequest: Identifiable {
        let id = UUID()
        let artifactIDs: [ArtifactID]
    }
}

private struct PluginDetailView: View {
    let row: WorkspaceLibraryReadModelRow
    let availability: UpdateAvailability
    let library: WorkspaceLibrarySession
    @State private var removal: RemovalRequest?
    @State private var isAssigning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let message = library.errorMessage {
                    AttentionBanner(title: "This couldn't be saved", message: message)
                }
                managedByCard
                if !includedSkills.isEmpty {
                    includedSkillsCard
                }
                if !row.requestedAssignments.isEmpty {
                    requestedCard
                }
                updatesDisclosure
                originCard
            }
            .padding(22)
        }
        .sheet(item: $removal) { request in
            WorkspaceAssignmentSheet(session: library, artifactIDs: [row.artifactID])
                .task { await library.reviewRemoval(contributionIDs: request.contributionIDs) }
        }
        .sheet(isPresented: $isAssigning) {
            WorkspaceAssignmentSheet(session: library, artifactIDs: [row.artifactID])
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            pluginIcon(for: row, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.displayName).font(.system(size: 22, weight: .semibold))
                Text(row.sourceLabel ?? row.ownershipLabel).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if availability.hasUpdate { UpdateStateBadge(availability: availability) }
            Button("Assign…", systemImage: "arrow.turn.up.right") { isAssigning = true }
                .buttonStyle(.bordered)
                .disabled(library.isBusy || !row.isAssignable)
                .help(row.isAssignable ? "Choose where this plugin should be used." : (row.assignmentExplanation ?? ""))
        }
    }

    private var managedByCard: some View {
        GroupBox("Managed by") {
            VStack(spacing: 0) {
                if row.nativeRoutes.isEmpty {
                    Text("Not associated with a specific app yet.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(row.nativeRoutes.enumerated()), id: \.offset) { index, route in
                        HStack(spacing: 12) {
                            ClientDisc(client: route.client, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(route.client.rawValue).font(.callout.weight(.medium))
                                Text("Registered as \(route.externalPluginID)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let ids = contributionIDs(for: route.client), !ids.isEmpty {
                                Button("Remove…") { remove(contributionIDs: ids) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel("Remove \(row.displayName) from \(route.client.rawValue)")
                                    .disabled(library.isBusy)
                            } else {
                                Text("Not a saved assignment")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .help("This app reported the plugin itself; this workspace has no assignment for it to take back.")
                            }
                        }
                        .padding(12)
                        if index < row.nativeRoutes.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private var includedSkillsCard: some View {
        GroupBox("Included skills · updated with this plugin") {
            VStack(spacing: 0) {
                ForEach(includedSkills) { child in
                    HStack {
                        Text(child.displayName).font(.callout)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 38)
                    if child.id != includedSkills.last?.id { Divider() }
                }
            }
        }
    }

    private var requestedCard: some View {
        GroupBox("Requested for") {
            VStack(spacing: 0) {
                Text("These are saved choices. Installing them in an app is a separate, reviewed step.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(row.requestedAssignments) { assignment in
                    LabeledValueRow("\(assignment.destination.surface.displayName) · \(assignment.destination.scope.displayName)") {
                        Text(deviceScopeLabel(assignment.deviceScope)).foregroundStyle(.secondary)
                    }
                    if assignment.id != row.requestedAssignments.last?.id { Divider() }
                }
            }
        }
    }

    private var updatesDisclosure: some View {
        DisclosureGroup("Updates and revision") {
            LabeledValueRow(availability.title) {
                HStack(spacing: 8) {
                    StatusGlyph(state: availability.health, size: 14)
                    Text(availability.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var originCard: some View {
        GroupBox("Origin") {
            VStack(spacing: 0) {
                LabeledValueRow("Source") { Text(row.sourceLabel ?? "Not recorded").foregroundStyle(.secondary) }
                Divider()
                LabeledValueRow("Ownership") { Text(row.ownershipLabel).foregroundStyle(.secondary) }
            }
        }
    }

    private var includedSkills: [WorkspaceLibraryIncludedItem] {
        row.includedChildren.filter { $0.kind == .skill }
    }

    private func contributionIDs(for client: ClientKind) -> [WorkspaceObjectID]? {
        let ids = row.requestedAssignments.filter { $0.destination.surface.client == client }.map(\.id)
        return ids.isEmpty ? nil : ids
    }

    private func remove(contributionIDs: [WorkspaceObjectID]) {
        Task {
            await library.reviewRemoval(contributionIDs: contributionIDs)
            if library.review != nil {
                removal = RemovalRequest(contributionIDs: contributionIDs)
            }
        }
    }

    private struct RemovalRequest: Identifiable {
        let id = UUID()
        let contributionIDs: [WorkspaceObjectID]
    }
}

/// The device scope a saved assignment covers. Kept local to this file: the
/// generic library detail sheet in `WorkspaceLibraryView.swift` already spells
/// the same three words privately for its own sheet, and that privacy is
/// exactly why this file needs its own copy rather than sharing one.
private func deviceScopeLabel(_ scope: WorkspaceLibraryDeviceScope) -> String {
    switch scope {
    case .allEnrolledDevices: "All enrolled Macs"
    case .noDevices: "No Macs selected"
    case .thisDevice: "This Mac"
    case .thisAndOtherDevices: "This Mac and other Macs"
    case .otherDevices: "Other Macs"
    }
}

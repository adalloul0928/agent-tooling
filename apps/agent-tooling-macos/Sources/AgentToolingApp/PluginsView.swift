import AgentToolingCore
import SwiftUI

/// The Library's Plugins tab: native plugins and centrally tracked plugin
/// packages, in the same master-detail shape the original screen used.
///
/// Update comparison is `PluginUpdateEvaluation`, the same reading Home does,
/// over the catalog this Mac last kept — so the two screens cannot disagree
/// about a plugin, and before any catalog has been asked every row reports
/// "not checked" rather than a stale or invented answer. Removing a plugin from
/// an app is a reviewed change to this workspace's saved intent, never a write
/// to the app itself — that stays the Install screen's job.
struct PluginsView: View {
    let workspace: WorkspaceLaunch.Workspace
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.workspaceNavigate) private var navigate
    @State private var query = ""
    @State private var clientFilter: ClientKind?
    @State private var selection: Set<ArtifactID> = []
    // Presentation is separate from selection, the way Discover keeps them: a
    // closed inspector remembers what was selected without occupying half the
    // window, and Escape closes the pane rather than forgetting the row.
    @State private var showingDetails = false
    @State private var stackClient: ClientKind = .claude
    @State private var refreshID = UUID()

    var body: some View {
        let inventory = PluginInventoryIndex(rows: libraryRows)
        let updates = PluginUpdateEvaluation(state: workspace.library.state)
        let listed = filtered(inventory.rows)

        VStack(spacing: 0) {
            PageToolbar(title: "Plugins", context: toolbarContext(inventory)) {
                Button {
                    Task { await workspace.device.refresh() }
                } label: {
                    Label(workspace.device.isChecking ? "Checking…" : "Check plugins", systemImage: "arrow.clockwise")
                }
                .primaryActionStyle()
                .disabled(workspace.device.isChecking)
            }

            GeometryReader { proxy in
                Group {
                    if showingDetails, !selection.isEmpty {
                        HSplitView {
                            collectionPane(rows: listed, updates: updates)
                                .frame(minWidth: Size.listPaneMin, idealWidth: proxy.size.width * Proportion.listShare)
                            VStack(spacing: 0) {
                                InspectorHeader(title: "Plugin details") { showingDetails = false }
                                detailPane(inventory: inventory, updates: updates)
                            }
                            .frame(minWidth: Size.detailPaneMin, idealWidth: proxy.size.width * Proportion.detailShare)
                        }
                    } else {
                        collectionPane(rows: listed, updates: updates)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
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
        .onChange(of: selection) { _, changed in if !changed.isEmpty { showingDetails = true } }
        .onExitCommand { showingDetails = false }
    }

    // MARK: Collection

    private func collectionPane(
        rows: [WorkspaceLibraryReadModelRow],
        updates: PluginUpdateEvaluation
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                Picker("App", selection: $clientFilter) {
                    Text("All apps").tag(nil as ClientKind?)
                    ForEach(availableClients) { client in Text(client.rawValue).tag(client as ClientKind?) }
                }.inventoryMenuStyle().fixedSize()
                Spacer()
                InventorySearchField(placeholder: "Search plugins", text: $query)
                    .frame(maxWidth: Size.fieldWide)
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
                pluginList(rows: rows, updates: updates)
            }
        }
        .paneMaterial()
    }

    /// The rows live in a `List`, keeping native multiple selection and
    /// keyboard travel, and the columns are plain frames laid out by hand, the
    /// way every collection table does it (`CollectionColumns`).
    private func pluginList(rows: [WorkspaceLibraryReadModelRow], updates: PluginUpdateEvaluation) -> some View {
        GeometryReader { geometry in
            // The card's inner width, less the row's own insets.
            let columns = CollectionColumns(width: geometry.size.width - Space.xl * 2, layout: .plugins)
            // Leading, so the list keeps the header's leading edge even when
            // a row's columns cannot fit and both run past the card.
            VStack(alignment: .leading, spacing: 0) {
                Self.columnHeader(columns)
                List(rows, selection: $selection) { row in
                    PluginCollectionRow(
                        row: row,
                        update: updates.availability[row.artifactID] ?? .notChecked(reason: "Not checked yet."),
                        clients: availableClients,
                        columns: columns,
                        selected: selection.contains(row.artifactID)
                    )
                    .tag(row.artifactID)
                    .collectionTableRowChrome(selected: selection.contains(row.artifactID))
                    .accessibilityLabel(row.displayName)
                }
                .collectionListChrome()
            }
        }
        .collectionSurface()
    }

    /// The column titles, from the same widths as the rows under them. The
    /// narrow layout is the name and Managed by after one gap, the reserve
    /// `CollectionColumns.Layout.plugins` keeps.
    static func columnHeader(_ columns: CollectionColumns) -> some View {
        CollectionColumnHeader {
            Text(columns.expanded ? "Name" : "Plugin").frame(width: columns.name, alignment: .leading)
            if columns.expanded {
                Text("Description").frame(maxWidth: .infinity, alignment: .leading)
                Text("Source").frame(width: CollectionColumn.source, alignment: .leading)
                Text("Skills").frame(width: CollectionColumn.narrow, alignment: .trailing)
            }
            Text("Managed by").frame(width: CollectionColumn.clientMarks, alignment: .trailing)
            if columns.expanded {
                Text("Updates").frame(width: CollectionColumn.Plugins.updates, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func detailPane(inventory: PluginInventoryIndex, updates: PluginUpdateEvaluation) -> some View {
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
                availability: updates.availability[row.artifactID] ?? .notChecked(reason: "Not checked yet."),
                library: workspace.library,
                workspace: workspace
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
        workspace.device.managedClients
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

    private func searchText(_ row: WorkspaceLibraryReadModelRow) -> String {
        ([row.displayName, row.sourceLabel ?? "", row.observedDescription ?? ""] + row.includedChildren.map(\.displayName))
            .joined(separator: " ")
    }

    private var hasFilters: Bool { !query.isEmpty || clientFilter != nil }

    private func toolbarContext(_ inventory: PluginInventoryIndex) -> String {
        CountNoun.plugin.phrase(inventory.rows.count)
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
        // A pruned-empty selection has nothing to inspect; the flag follows.
        if kept.isEmpty, showingDetails { showingDetails = false }
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

/// One plugin on the Plugins table, laid out from the table's columns. Its
/// narrow layout is the name and the Managed by marks after one gap, exactly
/// what `CollectionColumns.Layout.plugins` reserves beside the name, so the
/// row fills the table's width and never pushes the marks past the card.
struct PluginCollectionRow: View {
    let row: WorkspaceLibraryReadModelRow
    let update: UpdateAvailability
    /// This Mac's managed apps, in the order every row draws their marks.
    let clients: [ClientKind]
    let columns: CollectionColumns
    let selected: Bool

    var body: some View {
        HStack(spacing: Space.lg) {
            HStack(spacing: Space.lg) {
                pluginIcon(for: row, size: Size.tile)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(row.displayName).font(AgentFont.bodyMedium).lineLimit(1)
                        .collectionRowForeground(selected: selected)
                    if !columns.expanded {
                        Text(row.sourceLabel.map { "From \($0)" } ?? row.ownershipLabel)
                            .font(AgentFont.caption).lineLimit(1)
                            .collectionRowForeground(selected: selected, secondary: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: columns.name, alignment: .leading)
            if columns.expanded {
                Text(description).font(AgentFont.body).lineLimit(1).help(description)
                    .collectionRowForeground(selected: selected, secondary: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.sourceLabel ?? "Not recorded").font(AgentFont.caption).lineLimit(1)
                    .collectionRowForeground(selected: selected, secondary: true)
                    .frame(width: CollectionColumn.source, alignment: .leading)
                Text("\(row.childCount)").font(AgentFont.caption.monospacedDigit())
                    .collectionRowForeground(selected: selected, secondary: true)
                    .frame(width: CollectionColumn.narrow, alignment: .trailing)
            }
            TableClientMarks(clients: clients, present: Set(row.nativeRoutes.map(\.client)), selected: selected)
                .frame(width: CollectionColumn.clientMarks, alignment: .trailing)
            if columns.expanded {
                Group {
                    if update.hasUpdate {
                        UpdateStateBadge(availability: update)
                    } else {
                        Text(update.title).font(AgentFont.caption).lineLimit(1)
                            .collectionRowForeground(selected: selected, secondary: true)
                    }
                }
                .frame(width: CollectionColumn.Plugins.updates, alignment: .leading)
            }
        }
        .padding(.vertical, Space.md)
    }

    private var description: String {
        guard let observed = row.observedDescription, !observed.isEmpty else { return row.ownershipLabel }
        return observed
    }
}

/// Withdrawing several plugins' requests for one app is one reviewed
/// operation, or none: a stack with nothing recorded for the chosen app is
/// refused with the reason, never partially planned. It is the "Stop asking…"
/// Connections offers, and like it uninstalls nothing.
private struct PluginStackPane: View {
    let rows: [WorkspaceLibraryReadModelRow]
    let library: WorkspaceLibrarySession
    let availableClients: [ClientKind]
    @Binding var client: ClientKind
    let onClear: () -> Void
    @State private var removal: AssignmentRemovalPresentation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack(spacing: Space.xl) {
                    KindTile(kind: .plugin, size: Size.tileLarge)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("\(CountNoun.plugin.phrase(rows.count)) selected").font(AgentFont.title)
                        Text("Stop asking for them in one app, through one reviewed plan.")
                            .font(AgentFont.body)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(ActionTitles.stopAsking, action: review)
                        .primaryActionStyle()
                        .disabled(library.isBusy || contributionIDs.isEmpty)
                }

                if let error = library.errorMessage {
                    AttentionBanner(title: "This stack cannot be planned yet", message: error) {
                        Button("Keep one", action: onClear)
                            .secondaryActionStyle()
                            .controlSize(.small)
                    }
                } else if contributionIDs.isEmpty {
                    AttentionBanner(
                        title: "Nothing asked for in \(client.rawValue)",
                        message: "None of the selected plugins have a saved assignment for this app.")
                }

                GroupBox("Stop asking in") {
                    WorkspaceSegmentedPicker("App", selection: $client) {
                        ForEach(availableClients) { candidate in Text(candidate.rawValue).tag(candidate) }
                    }
                    .labelsHidden()
                    .padding(Space.lg)
                    .accessibilityLabel("App to stop asking in")
                }

                GroupBox("In this stack") {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            InfoRow(row.displayName, detail: row.ownershipLabel) {
                                pluginIcon(for: row, size: Size.tile)
                            } trailing: {
                                ClientMarks(present: Set(row.nativeRoutes.map(\.client)), size: Size.brandMark)
                            }
                            if row.id != rows.last?.id { Hairline() }
                        }
                    }
                }
            }
            .padding(Space.xxxl)
        }
        .sheet(item: $removal) { request in
            AssignmentRemovalSheet(session: library, presentation: request)
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
        removal = .init(
            kind: .plugin,
            name: rows.count == 1 ? (rows.first?.displayName ?? "plugin") : CountNoun.plugin.phrase(rows.count),
            contributionIDs: ids)
    }

}

private struct PluginDetailView: View {
    let row: WorkspaceLibraryReadModelRow
    let availability: UpdateAvailability
    let library: WorkspaceLibrarySession
    var workspace: WorkspaceLaunch.Workspace?
    @State private var removal: AssignmentRemovalPresentation?
    @State private var isAssigning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                if let message = library.errorMessage {
                    AttentionBanner(title: "This couldn't be saved", message: message)
                }
                if let accountRoute {
                    AttentionBanner(
                        title: "This plugin comes from your claude.ai account",
                        message: "Claude Code loads it from the account as \(accountRoute). Add, remove and update it on claude.ai; turn it off on every Mac from Apps › Accounts.")
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
            .padding(Space.xxxl)
        }
        .sheet(item: $removal) { request in
            AssignmentRemovalSheet(session: library, presentation: request)
        }
        .sheet(isPresented: $isAssigning) {
            WorkspaceAssignmentSheet(session: library, artifactIDs: [row.artifactID])
        }
    }

    private var header: some View {
        HStack(spacing: Space.xl) {
            pluginIcon(for: row, size: Size.identityIconLarge)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(row.displayName).font(AgentFont.pageTitle)
                Text(row.sourceLabel ?? row.ownershipLabel).font(AgentFont.body).foregroundStyle(.secondary)
            }
            Spacer()
            if availability.hasUpdate { UpdateStateBadge(availability: availability) }
            Button("Assign…", systemImage: "arrow.turn.up.right") { isAssigning = true }
                .secondaryActionStyle()
                .disabled(library.isBusy || !row.isAssignable || accountRoute != nil)
                .help(accountRoute != nil
                    ? "An account plugin is placed by claude.ai, not by an assignment."
                    : row.isAssignable ? "Choose where this plugin should be used." : (row.assignmentExplanation ?? ""))
        }
    }

    private var managedByCard: some View {
        GroupBox("Managed by") {
            VStack(spacing: 0) {
                if row.nativeRoutes.isEmpty {
                    Text("Not associated with a specific app yet.")
                        .font(AgentFont.body).foregroundStyle(.secondary)
                        .padding(Space.xl)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(row.nativeRoutes.enumerated()), id: \.offset) { index, route in
                        HStack(spacing: Space.lg) {
                            ClientDisc(client: route.client, size: Size.disc)
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(route.client.rawValue).font(AgentFont.bodyMedium)
                                Text("Registered as \(route.externalPluginID)")
                                    .font(AgentFont.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let ids = contributionIDs(for: route.client), !ids.isEmpty {
                                Button(ActionTitles.stopAsking) { remove(contributionIDs: ids) }
                                    .secondaryActionStyle()
                                    .controlSize(.small)
                                    .accessibilityLabel("Stop asking for \(row.displayName) in \(route.client.rawValue)")
                                    .disabled(library.isBusy || ClaudeAccountSync.hasReservedOrigin(route.externalPluginID))
                            } else {
                                Text("Not a saved assignment")
                                    .font(AgentFont.caption).foregroundStyle(.secondary)
                                    .help("This app reported the plugin itself; this workspace has no assignment for it to take back.")
                            }
                        }
                        .padding(Space.lg)
                        if index < row.nativeRoutes.count - 1 { Hairline() }
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
                        Text(child.displayName).font(AgentFont.body)
                        Spacer()
                    }
                    .padding(.horizontal, Space.xl)
                    .frame(minHeight: Size.compactRowHeight)
                    if child.id != includedSkills.last?.id { Hairline() }
                }
            }
        }
    }

    private var requestedCard: some View {
        GroupBox("Requested for") {
            VStack(spacing: 0) {
                Text("These are saved choices. Installing them in an app is a separate, reviewed step.")
                    .font(AgentFont.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, Space.xl).padding(.top, Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(row.requestedAssignments) { assignment in
                    LabeledValueRow("\(assignment.destination.surface.displayName) · \(assignment.destination.scope.displayName)") {
                        if let workspace {
                            AssignmentDeviceScopeMenu(assignment: assignment, workspace: workspace)
                        } else {
                            Text(deviceScopeLabel(assignment.deviceScope)).foregroundStyle(.secondary)
                        }
                    }
                    if assignment.id != row.requestedAssignments.last?.id { Hairline() }
                }
            }
        }
    }

    private var updatesDisclosure: some View {
        DisclosureGroup("Updates and revision") {
            LabeledValueRow(availability.title) {
                HStack(spacing: Space.md) {
                    StatusGlyph(state: availability.health, size: Size.glyph)
                    Text(availability.detail)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
            }
        }
    }

    private var originCard: some View {
        GroupBox("Origin") {
            VStack(spacing: 0) {
                LabeledValueRow("Source") { Text(row.sourceLabel ?? "Not recorded").foregroundStyle(.secondary) }
                Hairline()
                LabeledValueRow("Ownership") { Text(row.ownershipLabel).foregroundStyle(.secondary) }
            }
        }
    }

    private var includedSkills: [WorkspaceLibraryIncludedItem] {
        row.includedChildren.filter { $0.kind == .skill }
    }

    /// A library recorded before account plugins were kept out of it can
    /// still hold a `<name>@synced` row. It is the account's: say so, and
    /// offer nothing that would ask Claude Code to install or remove it.
    private var accountRoute: String? {
        row.nativeRoutes.first { $0.client == .claude && ClaudeAccountSync.hasReservedOrigin($0.externalPluginID) }?.externalPluginID
    }

    private func contributionIDs(for client: ClientKind) -> [WorkspaceObjectID]? {
        let ids = row.requestedAssignments.filter { $0.destination.surface.client == client }.map(\.id)
        return ids.isEmpty ? nil : ids
    }

    private func remove(contributionIDs: [WorkspaceObjectID]) {
        removal = .init(kind: .plugin, name: row.displayName, contributionIDs: contributionIDs)
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

import AgentToolingCore
import SwiftUI

/// The Library's connections tab: every MCP server this workspace knows about,
/// where each one came from, and what one live test says it can actually do.
///
/// Two claims are kept apart here and never merged. What an app *has* is a
/// native route the workspace recorded from that app's own package list; what
/// somebody *asked for* is a requested assignment, which is a saved choice and
/// not an installation. The marks column only ever says the first; the second
/// gets its own words.
struct MCPServersView: View {
    let workspace: WorkspaceLaunch.Workspace
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.availableClients) private var availableClients
    @Environment(\.mcpRuntimeInspector) private var runtimeInspector

    @State private var query = ""
    @State private var clientFilter = MCPServersView.allApps
    @State private var ownershipFilter = ""
    @State private var pluginFilter = ""
    @State private var sourceFilter = ""
    @State private var filter: MCPFilter = .all
    @State private var selection: Set<String> = []
    // Presentation is separate from selection, the way Discover keeps them.
    @State private var showingDetails = false
    @State private var activeSheet: MCPSheet?
    @State private var assignment: MCPAssignmentPresentation?
    @State private var removal: MCPRemovalPresentation?
    @State private var refreshID = UUID()
    /// Recorded per-tool intent, shared by the row badge and the detail pane's
    /// capability switches.
    @State private var capabilities = MCPCapabilityModel()

    private static let allApps = "All apps"

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Connections", context: toolbarContext) {
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .disabled(workspace.library.isBusy)
                    .help("Read this workspace's library again")

                Button {
                    activeSheet = .runtimes
                } label: {
                    Label("Runtimes…", systemImage: "shippingbox")
                }
                .buttonStyle(.glass)
                .help("What this Mac runs MCP servers with. Reads only; nothing is started or stopped.")

                Button {
                    activeSheet = .paste
                } label: {
                    Label("Paste…", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.glass)
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .help("Read an mcp add command, a JSON block, a server URL, or a SKILL.md")

                Button {
                    activeSheet = .addConnection
                } label: {
                    Label("Add connection…", systemImage: "plus")
                }
                .buttonStyle(.glass)
                .disabled(workspace.library.access != .writable)
                .help(PasteImportSheet.serverIntakeExplanation)
            }

            serversBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .paste:
                PasteImportSheet(workspace: workspace)
            case .addConnection:
                PasteImportSheet(workspace: workspace, mode: .newConnection)
            case .runtimes:
                MCPRuntimesSheet(inspector: runtimeInspector)
            }
        }
        .sheet(item: $assignment) { presentation in
            WorkspaceAssignmentSheet(session: workspace.library, artifactIDs: presentation.artifactIDs)
        }
        .sheet(item: $removal) { presentation in
            AssignmentRemovalSheet(session: workspace.library, presentation: presentation)
        }
        .task(id: refreshID) { await workspace.library.refresh() }
        .task { capabilities.activate(workspaceRoot: workspaceRoot) }
        .onAppear(perform: consumeRequestedItem)
        .onChange(of: navigation.requestedItemID) { _, _ in consumeRequestedItem() }
        .onAppear(perform: consumeRequestedScreenRequest)
        .onChange(of: navigation.requestedScreenRequest) { _, _ in consumeRequestedScreenRequest() }
        .onChange(of: entries.map(\.id)) { _, _ in pruneSelection() }
        
        .environment(capabilities)
    }

    // MARK: - Panes

    @ViewBuilder
    private var serversBody: some View {
        GeometryReader { proxy in
            Group {
                if showingDetails, !selection.isEmpty {
                    HSplitView {
                        collectionPane.frame(minWidth: Size.listPaneMin, idealWidth: proxy.size.width * 0.55)
                        VStack(spacing: 0) {
                            InspectorHeader(title: "Connection details") { showingDetails = false }
                            detailPane
                        }
                        .frame(minWidth: Size.detailPaneMin, idealWidth: proxy.size.width * 0.45)
                    }
                } else {
                    collectionPane
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .onChange(of: selection) { _, changed in if !changed.isEmpty { showingDetails = true } }
        .onExitCommand { showingDetails = false }
    }

    private var collectionPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                Picker("App", selection: $clientFilter) {
                    Text(Self.allApps).tag(Self.allApps)
                    ForEach(availableClients, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                .inventoryMenuStyle().fixedSize()
                Spacer()
                InventorySearchField(placeholder: "Search connections", text: $query)
                    .frame(maxWidth: 420)
                    .accessibilityLabel("Search connections")
            }
            .padding(.horizontal, WorkspaceLayout.pageInset)
            .padding(.top, WorkspaceLayout.contentTopInset)

            VStack(alignment: .leading, spacing: Space.md) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.md) {
                        statusSelector
                        serverFilterMenu
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: Space.md) {
                        statusSelector
                        serverFilterMenu
                    }
                }
                if hasServerFilters { activeServerFilters }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WorkspaceLayout.pageInset)
            .padding(.bottom, Space.lg)
            .padding(.top, Space.md)

            if let message = workspace.library.errorMessage {
                AttentionBanner(title: "This workspace could not be read", message: message)
                    .padding(.horizontal, WorkspaceLayout.pageInset)
                    .padding(.bottom, Space.lg)
            }

            if filteredEntries.isEmpty {
                EmptyStateView(
                    symbol: "network",
                    title: emptyStateTitle,
                    message: emptyStateMessage,
                    actionTitle: emptyStateActionTitle,
                    action: performEmptyStateAction)
            } else {
                serverTable
                // Says plainly what this screen does not cover, so its absence
                // reads as a known gap rather than as a missing feature the
                // person should go looking for.
                Text("Account connectors — apps you sign into — are not tracked here yet.")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, WorkspaceLayout.pageInset)
                    .padding(.vertical, Space.lg)
            }
        }
        .paneMaterial()
    }

    /// The list lays its columns out by hand, the way every collection table
    /// does (`CollectionColumns`).
    private var serverTable: some View {
        GeometryReader { geometry in
            // The card's inner width, less the row's own insets.
            let columns = CollectionColumns(width: geometry.size.width - Space.xl * 2, layout: .connections)
            VStack(spacing: 0) {
                CollectionColumnHeader {
                    Text(columns.expanded ? "Name" : "Connection").frame(width: columns.name, alignment: .leading)
                    if columns.expanded {
                        Text("Managed by").frame(width: CollectionColumn.Connections.ownership, alignment: .leading)
                        Text("Plugin").frame(width: CollectionColumn.Connections.plugin, alignment: .leading)
                        Text("Source").frame(width: CollectionColumn.source, alignment: .leading)
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 0)
                    }
                    Text("App").frame(width: CollectionColumn.clientMarks, alignment: .leading)
                    if columns.expanded {
                        Text("Asked for").frame(width: CollectionColumn.Connections.requested, alignment: .leading)
                        Text("Tools").frame(width: CollectionColumn.Connections.tools, alignment: .leading)
                        Text("Status").frame(width: CollectionColumn.narrow, alignment: .center)
                    }
                }
                List(filteredEntries, selection: $selection) { entry in
                    serverRow(entry, columns: columns)
                        .tag(entry.id)
                        .collectionRowChrome(selected: selection.contains(entry.id))
                        .accessibilityLabel(entry.displayName)
                }
                .collectionListChrome()
            }
        }
        .collectionSurface()
    }

    private func serverRow(_ entry: MCPConnectionEntry, columns: CollectionColumns) -> some View {
        let selected = selection.contains(entry.id)
        return HStack(spacing: Space.lg) {
            HStack(spacing: Space.lg) {
                KindTile(kind: .mcpServer, size: Size.tile, ghost: !entry.isManaged)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(entry.displayName).font(AgentFont.bodyMedium).lineLimit(1)
                        .collectionRowForeground(selected: selected)
                    if !columns.expanded {
                        Text(entry.clause).font(AgentFont.caption).lineLimit(1)
                            .collectionRowForeground(selected: selected, secondary: true)
                    }
                }
                Spacer(minLength: 0)
                if !columns.expanded {
                    StatusGlyph(state: entry.verdict.state, size: Size.glyph, tint: selected ? AgentTheme.onSelection : nil)
                        .accessibilityHidden(false)
                        .accessibilityLabel(entry.verdict.text)
                }
            }
            .frame(width: columns.name, alignment: .leading)
            if columns.expanded {
                FilterPill(title: entry.ownershipLabel, isOn: ownershipFilter == entry.ownershipLabel) {
                    ownershipFilter = ownershipFilter == entry.ownershipLabel ? "" : entry.ownershipLabel
                }
                .frame(width: CollectionColumn.Connections.ownership, alignment: .leading)
                Group {
                    if let plugin = entry.parentPluginLabel {
                        FilterPill(title: plugin, isOn: pluginFilter == plugin) {
                            pluginFilter = pluginFilter == plugin ? "" : plugin
                        }
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .frame(width: CollectionColumn.Connections.plugin, alignment: .leading)
                Group {
                    if let source = entry.sourceLabel {
                        FilterPill(title: source, isOn: sourceFilter == source) {
                            sourceFilter = sourceFilter == source ? "" : source
                        }
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .frame(width: CollectionColumn.source, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
            TableClientMarks(clients: availableClients, present: entry.routedClients)
                .frame(width: CollectionColumn.clientMarks, alignment: .leading)
            if columns.expanded {
                Text(entry.requestedAssignments.isEmpty ? "—" : "\(entry.requestedAssignments.count)")
                    .font(AgentFont.caption.monospacedDigit())
                    .collectionRowForeground(selected: selected, secondary: true)
                    .help("Saved choices about where this connection should be used. Installation is checked separately.")
                    .frame(width: CollectionColumn.Connections.requested, alignment: .leading)
                Text(capabilities.summary(for: entry.id) ?? "—")
                    .font(AgentFont.caption.monospacedDigit())
                    .collectionRowForeground(selected: selected, secondary: true)
                    .frame(width: CollectionColumn.Connections.tools, alignment: .leading)
                StatusGlyph(state: entry.verdict.state, size: Size.glyph, tint: selected ? AgentTheme.onSelection : nil)
                    .accessibilityHidden(false)
                    .accessibilityLabel(entry.verdict.text)
                    .frame(width: CollectionColumn.narrow, alignment: .center)
            }
        }
        .padding(.vertical, Space.md)
    }

    @ViewBuilder
    private var detailPane: some View {
        if stackedEntries.count > 1 {
            MCPStackPane(
                entries: stackedEntries,
                isBusy: workspace.library.isBusy,
                onAssign: { assignment = .init(artifactIDs: assignableIDs(in: stackedEntries)) },
                onClear: { selection = Set(stackedEntries.prefix(1).map(\.id)) })
        } else if let entry = selectedEntry {
            MCPDetailView(
                entry: entry,
                workspaceRoot: workspaceRoot,
                isBusy: workspace.library.isBusy,
                onAssign: { assignment = .init(artifactIDs: [entry.artifactID]) },
                onRemove: { contributions in
                    removal = .init(name: entry.displayName, contributionIDs: contributions)
                })
        } else {
            EmptyStateView(
                symbol: "network", title: "Select a connection",
                message: "Inspect where it came from, where it was asked for, and what one live test says it offers.")
        }
    }

    // MARK: - Filter controls

    private var statusSelector: some View {
        WorkspaceSegmentedPicker("Connection status", selection: $filter) {
            ForEach(MCPFilter.allCases) { item in Text(item.rawValue).tag(item) }
        }
        .fixedSize()
    }

    private var hasServerFilters: Bool {
        !ownershipFilter.isEmpty || !pluginFilter.isEmpty || !sourceFilter.isEmpty
    }

    private var serverFilterMenu: some View {
        Menu {
            Picker("Managed by", selection: $ownershipFilter) {
                Text("Any authority").tag("")
                ForEach(Array(Set(entries.map(\.ownershipLabel))).sorted(), id: \.self) { Text($0).tag($0) }
            }
            Picker("Plugin", selection: $pluginFilter) {
                Text("All plugins").tag("")
                ForEach(Array(Set(entries.compactMap(\.parentPluginLabel))).sorted(), id: \.self) { Text($0).tag($0) }
            }
            Picker("Source", selection: $sourceFilter) {
                Text("Any source").tag("")
                ForEach(Array(Set(entries.compactMap(\.sourceLabel))).sorted(), id: \.self) { Text($0).tag($0) }
            }
        } label: {
            Label("Filters", systemImage: "line.3.horizontal.decrease")
        }
        .inventoryMenuStyle().fixedSize()
    }

    private var activeServerFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                if !ownershipFilter.isEmpty {
                    FilterPill(title: ownershipFilter, isOn: true) { ownershipFilter = "" }
                }
                if !pluginFilter.isEmpty {
                    FilterPill(title: pluginFilter, isOn: true) { pluginFilter = "" }
                }
                if !sourceFilter.isEmpty {
                    FilterPill(title: sourceFilter, isOn: true) { sourceFilter = "" }
                }
            }
        }
        .wrapsLines()
    }

    // MARK: - Data

    private var workspaceRoot: URL {
        workspace.store.databaseURL.deletingLastPathComponent()
    }

    /// Every MCP server in the library, including the ones a plugin brings with
    /// it, paired with the same item in the shape the live-test console speaks.
    private var entries: [MCPConnectionEntry] {
        guard let library = workspace.library.state?.library else { return [] }
        let projected = Dictionary(
            VersionedInventoryProjection.inventory(library).mcpServers.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var result: [MCPConnectionEntry] = []
        for row in library.rows {
            switch row.kind {
            case .mcpServer:
                let id = row.artifactID.rawValue.uuidString.lowercased()
                guard let server = projected[id] else { continue }
                result.append(
                    .init(
                        artifactID: row.artifactID, displayName: row.displayName,
                        ownershipLabel: row.ownershipLabel, isManaged: row.ownership.isManagedHere,
                        parentPluginLabel: row.parentPluginLabel, sourceLabel: row.sourceLabel,
                        observedDescription: row.observedDescription,
                        requestedAssignments: row.requestedAssignments, nativeRoutes: row.nativeRoutes,
                        isAssignable: row.isAssignable, assignmentExplanation: row.assignmentExplanation,
                        server: server,
                        definedBy: MCPDefinitionSources.found(named: row.declaredName, in: workspace.device.observations)))
            case .nativePlugin, .package:
                for child in row.includedChildren where child.kind == .mcpServer {
                    let id = child.artifactID.rawValue.uuidString.lowercased()
                    guard let server = projected[id] else { continue }
                    result.append(
                        .init(
                            artifactID: child.artifactID, displayName: child.displayName,
                            ownershipLabel: child.ownership.libraryLabel,
                            isManaged: child.ownership.isManagedHere,
                            parentPluginLabel: child.parentPluginLabel ?? row.displayName,
                            sourceLabel: row.sourceLabel, observedDescription: child.observedDescription,
                            requestedAssignments: child.requestedAssignments,
                            // A server inside a plugin usually carries no route
                            // of its own: the plugin holds it, and the app has
                            // the server because it has the plugin. Falling back
                            // to the plugin's routes says that, and only that —
                            // it is still presence, never a request.
                            nativeRoutes: child.nativeRoutes.isEmpty ? row.nativeRoutes : child.nativeRoutes,
                            // A plugin's own server is assigned by assigning the
                            // plugin; offering it separately would promise a
                            // change this workspace cannot make.
                            isAssignable: false,
                            assignmentExplanation:
                                "\(row.displayName) brings this connection with it. Assign the plugin to choose where it is used.",
                            server: server,
                            definedBy: MCPDefinitionSources.found(named: child.declaredName, in: workspace.device.observations)))
                }
            case .skill, .preset, .logicalProject:
                continue
            }
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var filteredEntries: [MCPConnectionEntry] {
        entries.filter { entry in
            let matchesOrigin =
                (ownershipFilter.isEmpty || ownershipFilter == entry.ownershipLabel)
                && (pluginFilter.isEmpty || pluginFilter == entry.parentPluginLabel)
                && (sourceFilter.isEmpty || sourceFilter == entry.sourceLabel)
            let matchesStatus =
                filter == .all
                || (filter == .inApp && !entry.routedClients.isEmpty)
                || (filter == .undecided && entry.needsADecision)
            let searchable = [
                entry.displayName, entry.observedDescription ?? "", entry.ownershipLabel,
                entry.parentPluginLabel ?? "", entry.sourceLabel ?? "",
            ].joined(separator: " ")
            let matchesClient =
                clientFilter == Self.allApps || entry.involvedClients.contains { $0.rawValue == clientFilter }
            return matchesClient && matchesOrigin && matchesStatus
                && (query.isEmpty || searchable.localizedCaseInsensitiveContains(query))
        }
    }

    /// Several picks become one review. Selecting more than one row swaps the
    /// detail pane for the stack, so the ending is a single assignment.
    private var stackedEntries: [MCPConnectionEntry] {
        entries.filter { selection.contains($0.id) }
    }

    private var selectedEntry: MCPConnectionEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return entries.first { $0.id == id }
    }

    private func assignableIDs(in entries: [MCPConnectionEntry]) -> [ArtifactID] {
        entries.filter(\.isAssignable).map(\.artifactID)
    }

    private var toolbarContext: String {
        let total = entries.count
        let routed = entries.filter { !$0.routedClients.isEmpty }.count
        let base = "\(CountNoun.connection.phrase(total)) · \(routed) in an app"
        return stackedEntries.count > 1 ? "\(base) · \(stackedEntries.count) selected" : base
    }

    // MARK: - Behaviour

    private func pruneSelection() {
        let kept = selection.intersection(entries.map(\.id))
        if kept != selection { selection = kept }
        // A pruned-empty selection has nothing to inspect; the flag follows.
        if kept.isEmpty, showingDetails { showingDetails = false }
    }

    /// Reveals one row a route named. Revealing selects it and does nothing else.
    private func consumeRequestedItem() {
        guard let requested = navigation.requestedItemID,
            entries.contains(where: { $0.id == requested })
        else { return }
        clearFilters()
        selection = [requested]
        navigation.consumeRequestedItem(requested)
    }

    /// Answers a palette request that names no row of its own. Both "Add MCP
    /// server" and "Paste to import" land here on the same sheet: there is no
    /// separate manual-entry form to send one of them to instead.
    private func consumeRequestedScreenRequest() {
        guard let requested = navigation.requestedScreenRequest, requested.section == .mcpServers else {
            return
        }
        switch requested {
        case .addMCPServer, .pasteImport: activeSheet = .paste
        case .selectMCPServer, .selectPlugin, .selectReceipt, .reviewChanges: break
        }
        navigation.consumeScreenRequest(requested)
    }

    private var emptyStateTitle: String {
        entries.isEmpty ? "No connections yet" : "No matching connections"
    }

    private var emptyStateMessage: String {
        entries.isEmpty
            ? "This workspace records the MCP servers your apps already have, the ones a plugin brings with it, "
                + "and the ones you write down here. Add a connection, paste a definition, or check this Mac's "
                + "apps from the Apps screen."
            : "Clear the search or change the filters."
    }

    private var emptyStateActionTitle: String {
        entries.isEmpty ? "Add connection…" : "Clear filters"
    }

    private func performEmptyStateAction() {
        if entries.isEmpty {
            activeSheet = .addConnection
        } else {
            clearFilters()
        }
    }

    private func clearFilters() {
        query = ""
        filter = .all
        clientFilter = Self.allApps
        ownershipFilter = ""
        pluginFilter = ""
        sourceFilter = ""
    }
}

// MARK: - Presentation state

private enum MCPSheet: String, Identifiable {
    case paste
    case addConnection
    case runtimes
    var id: String { rawValue }
}

private enum MCPFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case inApp = "In an app"
    case undecided = "Undecided"
    var id: String { rawValue }
}

private struct MCPAssignmentPresentation: Identifiable {
    let id = UUID()
    let artifactIDs: [ArtifactID]
}

/// A reviewed withdrawal of saved requests, for any kind of item.
struct AssignmentRemovalPresentation: Identifiable {
    let id = UUID()
    var kind: ToolingKind = .mcpServer
    let name: String
    let contributionIDs: [WorkspaceObjectID]
}

typealias MCPRemovalPresentation = AssignmentRemovalPresentation

// MARK: - Removal review

/// Withdrawing a request, reviewed before it is saved.
///
/// Nothing here touches a client: it removes the record that somebody wanted
/// this server in that app. What is already installed stays installed until the
/// Apps screen is asked to change it.
struct AssignmentRemovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: WorkspaceLibrarySession
    let presentation: AssignmentRemovalPresentation

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.lg) {
                KindTile(kind: presentation.kind, size: Size.tileLarge)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Stop asking for \(presentation.name)").font(AgentFont.title)
                    Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(Space.xxxl)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if let review = session.review {
                        TitledCard("What this changes") {
                            LabeledValueRow("Requests withdrawn") {
                                Text("\(review.preview.removals.count)").monospacedDigit()
                            }
                            if !review.preview.additions.isEmpty {
                                Hairline()
                                LabeledValueRow("Requests added") {
                                    Text("\(review.preview.additions.count)").monospacedDigit()
                                }
                            }
                        }
                    } else if session.isBusy {
                        ProgressView("Working out what this would change…")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }

                    if let message = session.errorMessage {
                        AttentionBanner(title: "This cannot be withdrawn", message: message)
                    }

                    Text(
                        "Removes the record that somebody wanted this \(presentation.kind == .mcpServer ? "connection" : "item") there. "
                            + "Nothing is uninstalled: what an app already has stays until the Apps screen is asked to change it."
                    )
                    .font(AgentFont.body)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
                }
                .padding(Space.xxxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Hairline()
            HStack {
                Spacer()
                Button("Cancel") {
                    session.discardReview()
                    dismiss()
                }
                .secondaryActionStyle()
                .keyboardShortcut(.cancelAction)
                Button("Stop asking") {
                    Task {
                        await session.applyReviewedAssignments()
                        if session.errorMessage == nil { dismiss() }
                    }
                }
                .primaryActionStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(session.review == nil || session.isBusy)
            }
            .padding(Space.xl)
        }
        .sheetSize(SheetSize.medium)
        .background(AgentTheme.contentBackground)
        .task { await session.reviewRemoval(contributionIDs: presentation.contributionIDs) }
    }

    private var subtitle: String {
        CountNoun("saved request").phrase(presentation.contributionIDs.count)
    }
}

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
    @State private var category = MCPServersView.serversCategory
    @State private var selection: Set<String> = []
    @State private var activeSheet: MCPSheet?
    @State private var assignment: MCPAssignmentPresentation?
    @State private var removal: MCPRemovalPresentation?
    @State private var refreshID = UUID()
    /// Recorded per-tool intent, shared by the row badge and the detail pane's
    /// capability switches.
    @State private var capabilities = MCPCapabilityModel()

    private static let allApps = "All apps"
    private static let serversCategory = "MCP servers"

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
            .environment(\.connectionCategory, $category)

            if category == Self.serversCategory {
                serversBody
            } else {
                EmptyStateView(
                    symbol: "link",
                    title: "Connectors have no home here yet",
                    message:
                        "A connector is an account an app signs into rather than a server this Mac runs. "
                        + "The versioned workspace has no place to record one, so Agent Tooling would have to "
                        + "invent the answer. It does not. MCP servers are on the other tab.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.contentBackground)
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
            MCPRemovalReviewSheet(session: workspace.library, presentation: presentation)
        }
        .task(id: refreshID) { await workspace.library.refresh() }
        .task { capabilities.activate(workspaceRoot: workspaceRoot) }
        .onAppear(perform: consumeRequestedItem)
        .onChange(of: navigation.requestedItemID) { _, _ in consumeRequestedItem() }
        .onAppear(perform: consumeRequestedScreenRequest)
        .onChange(of: navigation.requestedScreenRequest) { _, _ in consumeRequestedScreenRequest() }
        .onChange(of: entries.map(\.id)) { _, _ in pruneSelection() }
        .onExitCommand { selection = [] }
        .environment(capabilities)
    }

    // MARK: - Panes

    @ViewBuilder
    private var serversBody: some View {
        if selection.isEmpty {
            collectionPane
        } else {
            HSplitView {
                collectionPane.frame(minWidth: 320, idealWidth: 600)
                VStack(spacing: 0) {
                    InspectorHeader(title: "Server details") { selection = [] }
                    detailPane
                }
                .frame(minWidth: 400, idealWidth: 600)
            }
        }
    }

    private var collectionPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("App", selection: $clientFilter) {
                    Text(Self.allApps).tag(Self.allApps)
                    ForEach(availableClients, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                .inventoryMenuStyle().fixedSize()
                Spacer()
                InventorySearchField(placeholder: "Search servers", text: $query)
                    .frame(maxWidth: 420)
                    .accessibilityLabel("Search MCP servers")
            }
            .padding(.horizontal, WorkspaceLayout.pageInset)
            .padding(.top, WorkspaceLayout.contentTopInset)

            VStack(alignment: .leading, spacing: 9) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        statusSelector
                        serverFilterMenu
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 9) {
                        statusSelector
                        serverFilterMenu
                    }
                }
                if hasServerFilters { activeServerFilters }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WorkspaceLayout.pageInset)
            .padding(.bottom, 12)
            .padding(.top, 9)

            if let message = workspace.library.errorMessage {
                AttentionBanner(title: "This workspace could not be read", message: message)
                    .padding(.horizontal, WorkspaceLayout.pageInset)
                    .padding(.bottom, 12)
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
            }
        }
        .paneMaterial()
    }

    private var serverTable: some View {
        GeometryReader { geometry in
            if geometry.size.width < 1_050 {
                Table(filteredEntries, selection: $selection) {
                    TableColumn("Server") { entry in
                        HStack(spacing: 12) {
                            KindTile(kind: .mcpServer, size: 30, ghost: !entry.isManaged)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(entry.clause).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.vertical, 8)
                            Spacer(minLength: 4)
                            StatusGlyph(state: entry.verdict.state, size: 13)
                                .accessibilityHidden(false)
                                .accessibilityLabel(entry.verdict.text)
                        }
                    }
                    .width(min: 150, ideal: 280)
                    TableColumn("App") { entry in
                        TableClientMarks(clients: availableClients, present: entry.routedClients)
                    }
                    .width(70)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
            } else {
                Table(filteredEntries, selection: $selection) {
                    TableColumn("Name") { entry in
                        HStack(spacing: 12) {
                            KindTile(kind: .mcpServer, size: 30, ghost: !entry.isManaged)
                            Text(entry.displayName).font(.callout.weight(.medium)).lineLimit(1)
                        }
                        .padding(.vertical, 8)
                    }
                    .width(min: 170, ideal: 240)
                    TableColumn("Managed by") { entry in
                        FilterPill(title: entry.ownershipLabel, isOn: ownershipFilter == entry.ownershipLabel) {
                            ownershipFilter = ownershipFilter == entry.ownershipLabel ? "" : entry.ownershipLabel
                        }
                    }
                    .width(min: 130, ideal: 165)
                    TableColumn("Plugin") { entry in
                        if let plugin = entry.parentPluginLabel {
                            FilterPill(title: plugin, isOn: pluginFilter == plugin) {
                                pluginFilter = pluginFilter == plugin ? "" : plugin
                            }
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 130, ideal: 170)
                    TableColumn("Source") { entry in
                        if let source = entry.sourceLabel {
                            FilterPill(title: source, isOn: sourceFilter == source) {
                                sourceFilter = sourceFilter == source ? "" : source
                            }
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 110, ideal: 150)
                    TableColumn("App") { entry in
                        TableClientMarks(clients: availableClients, present: entry.routedClients)
                    }
                    .width(70)
                    TableColumn("Asked for") { entry in
                        Text(entry.requestedAssignments.isEmpty ? "—" : "\(entry.requestedAssignments.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("Saved choices about where this server should be used. Installation is checked separately.")
                    }
                    .width(75)
                    TableColumn("Tools") { entry in
                        Text(capabilities.summary(for: entry.id) ?? "—")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .width(100)
                    TableColumn("Status") { entry in
                        StatusGlyph(state: entry.verdict.state, size: 13)
                            .accessibilityHidden(false)
                            .accessibilityLabel(entry.verdict.text)
                    }
                    .width(50)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
            }
        }
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
                symbol: "network", title: "Select a server",
                message: "Inspect where it came from, where it was asked for, and what one live test says it offers.")
        }
    }

    // MARK: - Filter controls

    private var statusSelector: some View {
        WorkspaceSegmentedPicker("MCP server status", selection: $filter) {
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
            HStack(spacing: 6) {
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
        .fixedSize(horizontal: false, vertical: true)
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
                        server: server))
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
                                "\(row.displayName) brings this server with it. Assign the plugin to choose where it is used.",
                            server: server))
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
        let base = "\(total) \(total == 1 ? "server" : "servers") · \(routed) in an app"
        return stackedEntries.count > 1 ? "\(base) · \(stackedEntries.count) selected" : base
    }

    // MARK: - Behaviour

    private func pruneSelection() {
        let kept = selection.intersection(entries.map(\.id))
        if kept != selection { selection = kept }
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
        entries.isEmpty ? "No connections yet" : "No matching servers"
    }

    private var emptyStateMessage: String {
        entries.isEmpty
            ? "This workspace records the MCP servers your apps already have, the ones a plugin brings with it, "
                + "and the ones you write down here. Add a connection, paste a definition, or check this Mac's "
                + "apps from the Apps screen."
            : "Clear the search or change the filters."
    }

    private var emptyStateActionTitle: String {
        entries.isEmpty ? "Add connection…" : "Clear Filters"
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

// MARK: - Row model

/// One connection the workspace knows about.
///
/// `nativeRoutes` is what an app's own package list said; `requestedAssignments`
/// is what somebody asked for. They are separate fields here because they are
/// separate claims, and the screen must never spend one as the other.
struct MCPConnectionEntry: Identifiable, Equatable {
    let artifactID: ArtifactID
    let displayName: String
    let ownershipLabel: String
    /// False for items an app or a publisher owns; the tile goes quiet for them.
    let isManaged: Bool
    let parentPluginLabel: String?
    let sourceLabel: String?
    let observedDescription: String?
    let requestedAssignments: [WorkspaceLibraryRequestedAssignment]
    let nativeRoutes: [WorkspaceLibraryNativeRoute]
    let isAssignable: Bool
    let assignmentExplanation: String?
    /// The same item in the shape the live-test console and the capability
    /// switches speak, from `VersionedInventoryProjection`.
    let server: MCPServer

    var id: String { server.id }

    /// Apps whose own package list carries this server. Presence, not intent.
    var routedClients: Set<ClientKind> { Set(nativeRoutes.map(\.client)) }

    /// Apps this server is either in or asked for, for filtering only.
    var involvedClients: Set<ClientKind> {
        routedClients.union(requestedAssignments.compactMap(\.destination.surface.client))
    }

    var needsADecision: Bool {
        routedClients.isEmpty && requestedAssignments.isEmpty
    }

    /// The row's one clause: where it came from, and what carries it.
    var clause: String {
        [ownershipLabel, parentPluginLabel.map { "In \($0)" }, sourceLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var verdict: (state: HealthState, text: String) {
        if !routedClients.isEmpty {
            let names = routedClients.map(\.rawValue).sorted().joined(separator: ", ")
            return (.healthy, "In \(names)")
        }
        if !requestedAssignments.isEmpty {
            let count = requestedAssignments.count
            return (.pending, count == 1 ? "Asked for in one place" : "Asked for in \(count) places")
        }
        return (.pending, "Not asked for anywhere")
    }
}

extension WorkspaceLibraryOwnership {
    /// True when Agent Tooling holds this item's content, which is what decides
    /// whether the row's tile is drawn at full presence.
    var isManagedHere: Bool {
        switch self {
        case .centralPersonal, .centralUpstream, .attachedAuthoring: true
        case .nativeOwned, .trackedOnly: false
        }
    }

    /// What a row's clause calls this authority. Restored from the dead-view
    /// sweep: `WorkspaceLibraryView.swift` had no caller left and was deleted,
    /// but Skills, Plugins, Projects, the command palette catalog and Getting
    /// Started all still read this label, so it stays module-wide rather than
    /// going down with the screen it was declared beside.
    var libraryLabel: String {
        switch self {
        case .centralPersonal: "Personal library"
        case .centralUpstream: "From a repository"
        case .nativeOwned: "Managed by its app"
        case .attachedAuthoring: "Linked authoring folder"
        case .trackedOnly: "Tracked only"
        }
    }
}

extension WorkspaceLibraryReadModelRow {
    /// Same provenance as `WorkspaceLibraryOwnership.libraryLabel`, one row
    /// exception and all: a personal MCP server this workspace itself keeps
    /// configured is a connection, not a library entry, so its row says so.
    var ownershipLabel: String {
        kind == .mcpServer && ownership == .centralPersonal
            ? "Managed connection" : ownership.libraryLabel
    }
}

extension ArtifactKind {
    /// Same provenance as `WorkspaceLibraryOwnership.libraryLabel`; Getting
    /// Started still reads it for a row it draws before any screen owns one.
    var librarySymbol: String {
        switch self {
        case .skill: "doc.text"
        case .package, .nativePlugin: "puzzlepiece.extension"
        case .mcpServer: "server.rack"
        case .preset: "square.stack"
        case .logicalProject: "folder"
        }
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

struct MCPRemovalPresentation: Identifiable {
    let id = UUID()
    let name: String
    let contributionIDs: [WorkspaceObjectID]
}

// MARK: - Stack

/// Several picks, one review. It says exactly what will be reviewed and refuses
/// combinations this workspace cannot describe honestly in a single batch.
///
/// Module-internal rather than file-private so a render test can prove that a
/// stack containing something nobody may assign says so instead of offering it.
struct MCPStackPane: View {
    let entries: [MCPConnectionEntry]
    let isBusy: Bool
    let onAssign: () -> Void
    let onClear: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    KindTile(kind: .mcpServer, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(entries.count) servers selected").font(.title3.weight(.semibold))
                        Text("Review them as one assignment instead of one each.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review one assignment", action: onAssign)
                        .buttonStyle(.borderedProminent)
                        .tint(AgentTheme.selection)
                        .disabled(assignable.isEmpty || isBusy)
                }

                if assignable.count < entries.count {
                    AttentionBanner(
                        title: "Some of these cannot be assigned here",
                        message:
                            "\(entries.count - assignable.count) of \(entries.count) are owned by an app or a plugin, "
                            + "so this workspace has no say in where they are used. They stay out of the review."
                    ) {
                        Button("Keep one", action: onClear)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                TitledCard("In this stack", count: "\(entries.count)") {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        InfoRow(entry.displayName, detail: entry.clause) {
                            KindTile(kind: .mcpServer, size: 26, ghost: !entry.isManaged)
                        } trailing: {
                            StatusBadge(state: entry.verdict.state, text: entry.verdict.text)
                        }
                        if index < entries.count - 1 { Divider().opacity(0.35) }
                    }
                }

                Text(
                    "Saves where these servers should be used. Installing them in an app is a separate reviewed step "
                        + "on the Apps screen; nothing here writes to a client."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
        }
    }

    private var assignable: [MCPConnectionEntry] { entries.filter(\.isAssignable) }
}

// MARK: - Detail

/// Module-internal rather than file-private: this is the pane where a saved
/// request could most easily be mistaken for an installation, so a render test
/// gets to hold it to that.
struct MCPDetailView: View {
    let entry: MCPConnectionEntry
    let workspaceRoot: URL
    let isBusy: Bool
    let onAssign: () -> Void
    let onRemove: ([WorkspaceObjectID]) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if !entry.isAssignable, let explanation = entry.assignmentExplanation {
                    AttentionBanner(title: "This one is not yours to assign", message: explanation)
                }

                TitledCard("Where it was asked for", count: "\(entry.requestedAssignments.count)") {
                    if entry.requestedAssignments.isEmpty {
                        LabeledValueRow("Assignments") {
                            Text("Nobody has asked for this server anywhere yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ClientStatusRows(clients: entry.server.clients)
                    }
                }

                TitledCard("Origin") {
                    LabeledValueRow("Managed by") { Text(entry.ownershipLabel) }
                    if let plugin = entry.parentPluginLabel {
                        Divider().opacity(0.45)
                        LabeledValueRow("Plugin") { Text(plugin) }
                    }
                    if let source = entry.sourceLabel {
                        Divider().opacity(0.45)
                        LabeledValueRow("Source") { Text(source).lineLimit(1).truncationMode(.middle) }
                    }
                    ForEach(entry.nativeRoutes, id: \.client) { route in
                        Divider().opacity(0.45)
                        LabeledValueRow(route.client.rawValue) {
                            Text(route.externalPluginID)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    Divider().opacity(0.45)
                    LabeledValueRow("Workspace") {
                        LocationText(path: workspaceRoot.path(percentEncoded: false), label: "This Mac's workspace")
                    }
                }

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(
                        "How to reach \(entry.displayName) — its command or address, its transport and its "
                            + "credentials — lives in each app's own configuration file, not in this workspace. "
                            + "Agent Tooling records that the server exists and where it was asked for."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2)

                MCPServerCapabilitiesPane(server: entry.server)
            }
            .padding(22)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            KindTile(kind: .mcpServer, size: 40, ghost: !entry.isManaged)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName).font(.title3.weight(.semibold))
                Text(entry.observedDescription ?? entry.clause)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if entry.isAssignable {
                Button("Assign…", action: onAssign)
                    .buttonStyle(.borderedProminent)
                    .tint(AgentTheme.selection)
                    .disabled(isBusy)
            }
            if !entry.requestedAssignments.isEmpty {
                Menu("Stop asking…") {
                    ForEach(entry.requestedAssignments) { requested in
                        Button(requested.destination.surface.displayName, role: .destructive) {
                            onRemove([requested.id])
                        }
                    }
                    if entry.requestedAssignments.count > 1 {
                        Divider()
                        Button("Everywhere", role: .destructive) {
                            onRemove(entry.requestedAssignments.map(\.id))
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Stop asking for \(entry.displayName)")
                .disabled(isBusy)
            }
        }
    }
}

// MARK: - Removal review

/// Withdrawing a request, reviewed before it is saved.
///
/// Nothing here touches a client: it removes the record that somebody wanted
/// this server in that app. What is already installed stays installed until the
/// Apps screen is asked to change it.
struct MCPRemovalReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: WorkspaceLibrarySession
    let presentation: MCPRemovalPresentation

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                KindTile(kind: .mcpServer, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stop asking for \(presentation.name)").font(.title3.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(22)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let review = session.review {
                        TitledCard("What this changes") {
                            LabeledValueRow("Requests withdrawn") {
                                Text("\(review.preview.removals.count)").monospacedDigit()
                            }
                            if !review.preview.additions.isEmpty {
                                Divider().opacity(0.45)
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
                        "Removes the record that somebody wanted this server there. Nothing is uninstalled: what an "
                            + "app already has stays until the Apps screen is asked to change it."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") {
                    session.discardReview()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                Button("Stop asking") {
                    Task {
                        await session.applyReviewedAssignments()
                        if session.errorMessage == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AgentTheme.selection)
                .keyboardShortcut(.defaultAction)
                .disabled(session.review == nil || session.isBusy)
            }
            .padding(16)
        }
        .frame(width: 600, height: 480)
        .background(AgentTheme.contentBackground)
        .task { await session.reviewRemoval(contributionIDs: presentation.contributionIDs) }
    }

    private var subtitle: String {
        presentation.contributionIDs.count == 1
            ? "One saved request" : "\(presentation.contributionIDs.count) saved requests"
    }
}

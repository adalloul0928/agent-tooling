import AgentToolingCore
import SwiftUI

struct PluginsView: View {
    @Environment(AppModel.self) private var model
    let navigate: (AppSection) -> Void
    @Binding var request: ScreenRequest?
    @State private var connectorRecords: [DiscoveredConnectorRow] = []

    init(navigate: @escaping (AppSection) -> Void, request: Binding<ScreenRequest?> = .constant(nil)) {
        self.navigate = navigate
        _request = request
    }

    var body: some View {
        let plugins = model.visiblePlugins
        let scan = ConnectorInventoryRequest(
            workspacePath: model.workspacePath, plugins: plugins,
            scannedAt: model.visibleTargetObservations.map(\.lastScannedAt).max()
        )
        PluginsBrowser(
            navigate: navigate, request: $request,
            inventory: PluginInventoryIndex(
                plugins: plugins, connectors: connectorRecords, sources: model.visibleSources,
                packages: model.visibleMarketplacePackages
            )
        )
        .task(id: scan) {
            let records = await ConnectorInventoryCache.shared.records(for: scan)
            guard !Task.isCancelled else { return }
            connectorRecords = records
        }
    }
}

private struct PluginsBrowser: View {
    @Environment(AppModel.self) private var model
    let navigate: (AppSection) -> Void
    @Binding var request: ScreenRequest?
    let inventory: PluginInventoryIndex
    @State private var query = ""
    @State private var clientFilter = "All apps"
    @State private var selection: Set<String> = []
    @State private var stackClient: ClientKind = .claude
    @State private var stackError: String?

    init(navigate: @escaping (AppSection) -> Void, request: Binding<ScreenRequest?>, inventory: PluginInventoryIndex) {
        self.navigate = navigate
        _request = request
        self.inventory = inventory
    }

    var body: some View {
        let listedPlugins = filteredPlugins
        VStack(spacing: 0) {
            PageToolbar(title: "Plugins", context: toolbarContext) {
                Button {
                    Task { await model.refreshMarketplace() }
                } label: {
                    Label(model.isRefreshingMarketplace ? "Checking…" : "Check for updates", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.glass)
                .help(
                    "Refreshes catalog metadata and compares reported revisions. Use a plugin's update action to update it through its native app."
                )
                .disabled(model.isInteractionLocked)

                Button {
                    Task { await model.runDoctor() }
                } label: {
                    Label(model.isRunningDoctor ? "Checking…" : "Check plugins", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glassProminent)
                .tint(AgentTheme.selection)
                .disabled(model.isInteractionLocked)
            }

            if selection.isEmpty {
                collectionPane(plugins: listedPlugins)
            } else {
                HSplitView {
                    collectionPane(plugins: listedPlugins).frame(minWidth: 320, idealWidth: 600)
                    VStack(spacing: 0) {
                        InspectorHeader(title: "Plugin details") { selection = [] }
                        detailPane
                    }.frame(minWidth: 400, idealWidth: 600)
                }
            }

        }
        .onAppear {
            if !model.isClientEnabled(stackClient), let first = model.availableClients.first { stackClient = first }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            pruneSelection()
            consumeRequest()
        }
        .onChange(of: inventory.plugins) { _, _ in pruneSelection() }
        .onChange(of: listedPlugins.map(\.id)) { _, _ in pruneSelection() }
        .onChange(of: request) { _, _ in consumeRequest() }
        .onExitCommand { selection = [] }
    }

    private func consumeRequest() {
        guard let request else { return }
        if case .selectPlugin(let id) = request, inventory.plugins.contains(where: { $0.id == id }) {
            query = ""
            clientFilter = "All apps"
            selection = [id]
        }
        self.request = nil
    }

    private func collectionPane(plugins: [Plugin]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("App", selection: $clientFilter) {
                    Text("All apps").tag("All apps")
                    ForEach(model.availableClients, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }.inventoryMenuStyle().fixedSize()
                Spacer()
                InventorySearchField(placeholder: "Search plugins", text: $query)
                    .frame(maxWidth: 420)
                    .accessibilityLabel("Search plugins")
            }
            .padding(.horizontal, WorkspaceLayout.pageInset)
            .padding(.vertical, WorkspaceLayout.contentTopInset)

            if plugins.isEmpty {
                EmptyStateView(
                    symbol: "puzzlepiece.extension",
                    title: hasFilters ? "No matching plugins" : "No installed plugins",
                    message: !hasFilters
                        ? "Open Discover to browse plugins from your marketplaces and folders."
                        : "Try a different plugin, marketplace, or included skill.",
                    actionTitle: hasFilters ? "Clear filters" : "Open Discover"
                ) {
                    if hasFilters {
                        query = ""
                        clientFilter = "All apps"
                    } else {
                        navigate(.marketplace)
                    }
                }
            } else {
                GeometryReader { geometry in
                    if geometry.size.width < 820 {
                        Table(plugins, selection: $selection) {
                            TableColumn("Plugin") { plugin in
                                HStack(spacing: 12) {
                                    ToolIdentityIcon(packageID: plugin.id, size: 30)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(plugin.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(ConnectionSource(plugin.id).marketplaceTitle.map { "From \($0)" } ?? plugin.summary)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }.padding(.vertical, 8)
                                }
                            }.width(min: 190, ideal: 350)
                            TableColumn("Managed by") { plugin in
                                TableClientMarks(
                                    clients: model.availableClients,
                                    present: Set(plugin.clients.filter(\.reportsLocalPresence).map(\.client)))
                            }.width(90)
                        }
                        .tableStyle(.inset(alternatesRowBackgrounds: false))
                        .scrollContentBackground(.hidden)
                    } else {
                        Table(plugins, selection: $selection) {
                            TableColumn("Name") { plugin in
                                HStack(spacing: 12) {
                                    ToolIdentityIcon(packageID: plugin.id, size: 30)
                                    Text(plugin.name).font(.callout.weight(.medium))
                                }.padding(.vertical, 8)
                            }.width(min: 180, ideal: 250)
                            TableColumn("Description") { plugin in
                                Text(plugin.summary).foregroundStyle(.secondary).lineLimit(1).help(plugin.summary)
                            }.width(min: 120, ideal: 360)
                            TableColumn("Marketplace") { plugin in
                                Text(ConnectionSource(plugin.id).marketplaceTitle ?? "Not recorded")
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }.width(min: 120, ideal: 150)
                            TableColumn("Skills") { plugin in
                                Text("\(plugin.skills.count)").monospacedDigit().foregroundStyle(.secondary)
                            }.width(50)
                            TableColumn("Managed by") { plugin in
                                TableClientMarks(
                                    clients: model.availableClients,
                                    present: Set(plugin.clients.filter(\.reportsLocalPresence).map(\.client)))
                            }.width(90)
                            TableColumn("Updates") { plugin in
                                let update = availability(for: plugin)
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
                }
            }
        }
        .paneMaterial()
    }

    @ViewBuilder
    private var detailPane: some View {
        if stackedPlugins.count > 1 {
            PluginStackPane(
                plugins: stackedPlugins,
                client: $stackClient,
                error: stackError,
                onReview: reviewStack,
                onClear: { selection = Set(stackedPlugins.prefix(1).map(\.id)) }
            )
        } else if let plugin = selectedPlugin {
            PluginDetailView(plugin: plugin, availability: availability(for: plugin)).environment(model)
        } else {
            EmptyStateView(
                symbol: "puzzlepiece.extension", title: "Select a plugin",
                message: "Inspect its contents, app parity, source revision, and configuration assignments.")
        }
    }

    private func availability(for plugin: Plugin) -> UpdateAvailability {
        inventory.availability[plugin.id] ?? .notChecked(reason: "Check for updates to compare this plugin.")
    }

    private var toolbarContext: String {
        "\(inventory.plugins.count) plugins"
    }

    private var hasFilters: Bool { !query.isEmpty || clientFilter != "All apps" }

    /// Several picks, one plan. Removing plugins one at a time means one review
    /// each; the stack makes it a single reviewed operation.
    private var stackedPlugins: [Plugin] {
        inventory.plugins
            .filter { selection.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func reviewStack() {
        do {
            let plan = try StackedPlanBuilder.pluginRemovalPlan(
                plugins: stackedPlugins,
                client: stackClient,
                packages: model.visibleMarketplacePackages
            )
            stackError = model.reviewComposedPlan(plan) ? nil : model.lastError
        } catch {
            stackError = error.localizedDescription
        }
    }

    private var displayPlugins: [Plugin] { inventory.plugins }

    private var filteredPlugins: [Plugin] {
        displayPlugins.filter { plugin in
            (clientFilter == "All apps" || plugin.clients.contains { $0.client.rawValue == clientFilter && $0.reportsLocalPresence })
                && (query.isEmpty
                    || [
                        plugin.name, plugin.summary, plugin.source, ConnectionSource(plugin.id).marketplaceTitle ?? "",
                        plugin.skills.joined(separator: " "),
                    ]
                    .joined(separator: " ")
                    .localizedCaseInsensitiveContains(query))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedPlugin: Plugin? {
        guard let id = selection.first, selection.count == 1 else { return nil }
        return displayPlugins.first { $0.id == id }
    }

    private func pruneSelection() {
        let visible = filteredPlugins.map(\.id)
        let kept = selection.intersection(visible)
        if kept != selection {
            selection = kept
        }
        stackError = nil
    }
}

/// Removing several plugins is one reviewed operation, or none: a selection
/// without a verified removal route for the chosen app is refused with the
/// reason, never partially planned.
private struct PluginStackPane: View {
    @Environment(AppModel.self) private var model
    let plugins: [Plugin]
    @Binding var client: ClientKind
    let error: String?
    let onReview: () -> Void
    let onClear: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    KindTile(kind: .plugin, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(plugins.count) plugins selected").font(.title3.weight(.semibold))
                        Text("Remove them through one reviewed plan.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review removal plan", action: onReview)
                        .buttonStyle(.borderedProminent)
                        .tint(AgentTheme.selection)
                        .disabled(model.isInteractionLocked)
                }

                if let error {
                    AttentionBanner(title: "This stack cannot be planned yet", message: error) {
                        Button("Keep one", action: onClear)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                GroupBox("Remove from") {
                    WorkspaceSegmentedPicker("App", selection: $client) {
                        ForEach(model.availableClients) { candidate in Text(candidate.rawValue).tag(candidate) }
                    }
                    .labelsHidden()
                    .padding(13)
                    .accessibilityLabel("App to remove from")
                }

                GroupBox("In this stack") {
                    VStack(spacing: 0) {
                        ForEach(plugins) { plugin in
                            InfoRow(plugin.name, detail: "\(plugin.skills.count) skills · \(plugin.scope)") {
                                ToolIdentityIcon(packageID: plugin.id, size: 26)
                            } trailing: {
                                ClientMarks(present: Set(plugin.clients.filter(\.reportsLocalPresence).map(\.client)), size: 13)
                            }
                            if plugin.id != plugins.last?.id { Divider().opacity(0.35) }
                        }
                    }
                }
            }
            .padding(22)
        }
    }
}

private struct PluginDetailView: View {
    @Environment(AppModel.self) private var model
    let plugin: Plugin
    let availability: UpdateAvailability

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ToolIdentityIcon(packageID: plugin.id, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plugin.name).font(.system(size: 22, weight: .semibold))
                        Text(plugin.summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if availability.hasUpdate { UpdateStateBadge(availability: availability) }
                }

                GroupBox("Managed by") {
                    VStack(spacing: 0) {
                        ForEach(plugin.clients) { client in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 12) {
                                    ClientDisc(client: client.client, size: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(client.client.rawValue).font(.callout.weight(.medium))
                                        Text(client.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    StatusGlyph(state: client.state, size: 14)
                                    if client.reportsLocalPresence {
                                        Button("Remove…") {
                                            Task { await model.planPluginRemoval(pluginID: plugin.id, client: client.client) }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityLabel("Remove \(plugin.name) from \(client.client.rawValue)")
                                        .disabled(model.isInteractionLocked)
                                    }
                                }
                                if let route = model.pluginUpdateRoute(pluginID: plugin.id, client: client.client) {
                                    HStack(alignment: .top, spacing: 12) {
                                        Text("Installation and updates stay in \(client.client.rawValue).")
                                            .font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                        Button(route.actionTitle) {
                                            model.planPluginUpdate(pluginID: plugin.id, client: client.client)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .help(route.detail)
                                        .accessibilityLabel(
                                            "\(route.canUpdateHere ? "Review update for" : "Update") \(plugin.name) in \(client.client.rawValue)"
                                        )
                                        .disabled(model.isInteractionLocked)
                                    }
                                }
                            }
                            .padding(12)
                            if client.id != plugin.clients.last?.id { Divider() }
                        }
                        if !plugin.clients.isEmpty { Divider() }
                        LabeledValueRow("Installed revision") {
                            Text(plugin.revision).font(.system(.caption, design: .monospaced))
                        }
                    }
                }

                if !plugin.skills.isEmpty {
                    GroupBox("Included skills · updated with this plugin") {
                        VStack(spacing: 0) {
                            ForEach(sortedSkills, id: \.self) { skill in
                                HStack {
                                    Text(skill).font(.callout)
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 38)
                                if skill != sortedSkills.last { Divider() }
                            }
                        }
                    }
                }

                if !enabledProfileNames.isEmpty {
                    GroupBox("Enabled by configurations") {
                        VStack(spacing: 0) {
                            ForEach(enabledProfileNames, id: \.self) { profile in
                                LabeledValueRow(profile) {
                                    Label("Enabled", systemImage: "checkmark").foregroundStyle(.secondary)
                                }
                                if profile != enabledProfileNames.last { Divider() }
                            }
                        }
                    }
                }

                DisclosureGroup("Updates and revision") {
                    VStack(spacing: 0) {
                        LabeledValueRow(availability.title) {
                            HStack(spacing: 8) {
                                StatusGlyph(state: availability.health, size: 14)
                                Text(availability.detail)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Divider()
                        LabeledValueRow("Last checked") {
                            HStack(spacing: 10) {
                                Text(lastCheckedText).foregroundStyle(.secondary)
                                Button(model.isRefreshingMarketplace ? "Checking…" : "Check again") {
                                    Task { await model.refreshMarketplace() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(model.isInteractionLocked)
                            }
                        }
                    }
                }

                GroupBox("Origin") {
                    VStack(spacing: 0) {
                        if let marketplace = ConnectionSource(plugin.id).marketplaceTitle {
                            LabeledValueRow("Marketplace") { Text(marketplace).foregroundStyle(.secondary) }
                            Divider()
                        }
                        LabeledValueRow("Found in") {
                            if plugin.source.hasPrefix("/") || plugin.source.contains("://") {
                                LocationText(path: plugin.source)
                            } else {
                                Text(plugin.source).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        LabeledValueRow("Scope") { Text(plugin.scope).foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(22)
        }
    }

    private var enabledProfileNames: [String] {
        let identifiers = Set([
            plugin.id,
            plugin.name,
            plugin.id.split(separator: "@", maxSplits: 1).first.map(String.init) ?? plugin.id,
        ])
        return model.profiles.compactMap { profile in
            let effective = model.effectiveProfile(for: profile.id) ?? profile
            return effective.enabledPlugins.contains(where: identifiers.contains) ? profile.name : nil
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var sortedSkills: [String] {
        plugin.skills.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Says when the comparison happened, so "up to date" is always dated.
    private var lastCheckedText: String {
        let candidates = [
            UpdateAvailabilityEvaluator.trackedSource(for: plugin, in: model.visibleSources)?.lastRefreshedAt,
            UpdateAvailabilityEvaluator.catalogPackage(for: plugin, in: model.visibleMarketplacePackages)
                .flatMap { package in model.visibleSources.first { $0.id == package.sourceID }?.lastRefreshedAt },
        ]
        guard let date = candidates.compactMap({ $0 }).max() else { return "Not checked yet" }
        return date.formatted(.relative(presentation: .named))
    }
}

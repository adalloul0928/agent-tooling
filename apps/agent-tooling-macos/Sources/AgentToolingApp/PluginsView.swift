import AgentToolingCore
import SwiftUI

struct PluginsView: View {
    @Environment(AppModel.self) private var model
    let navigate: (AppSection) -> Void
    @Binding var request: ScreenRequest?
    @State private var query = ""
    @State private var clientFilter = "All apps"
    @State private var connectorRecords: [DiscoveredConnectorRow] = []
    @State private var selection: Set<String> = []
    @State private var stackClient: ClientKind = .claude
    @State private var stackError: String?

    init(navigate: @escaping (AppSection) -> Void, request: Binding<ScreenRequest?> = .constant(nil)) {
        self.navigate = navigate
        _request = request
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Plugins", context: toolbarContext) {
                Button {
                    Task { await model.refreshMarketplace() }
                } label: {
                    Label(model.isRefreshingMarketplace ? "Checking…" : "Check for updates", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .help("Re-reads every reviewed catalog and source, then compares revisions")
                .disabled(model.isInteractionLocked)

                Button {
                    Task { await model.runDoctor() }
                } label: {
                    Label(model.isRunningDoctor ? "Checking…" : "Check plugins", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInteractionLocked)
            }

            if selection.isEmpty {
                collectionPane
            } else {
                HSplitView {
                    collectionPane.frame(minWidth: 320, idealWidth: 600)
                    VStack(spacing: 0) {
                        HStack {
                            Text("Plugin details").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { selection = [] } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).help("Close details")
                        }.padding(16)
                        Divider()
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
        .onChange(of: model.visiblePlugins) { _, _ in pruneSelection() }
        .onChange(of: filteredPlugins.map(\.id)) { _, _ in pruneSelection() }
        .onChange(of: request) { _, _ in consumeRequest() }
        .onExitCommand { selection = [] }
        .task(id: model.visiblePlugins) { connectorRecords = ConnectorInventory.records(plugins: model.visiblePlugins) }
    }

    private func consumeRequest() {
        guard let request else { return }
        if case .selectPlugin(let id) = request, model.visiblePlugins.contains(where: { $0.id == id }) {
            query = ""
            selection = [id]
        }
        self.request = nil
    }

    private var collectionPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("App", selection: $clientFilter) {
                    Text("All apps").tag("All apps")
                    ForEach(model.availableClients, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }.fixedSize()
                Spacer()
                TextField("Search plugins", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search plugins")
            }
            .padding(12)

            if filteredPlugins.isEmpty {
                EmptyStateView(
                    symbol: "puzzlepiece.extension",
                    title: query.isEmpty ? "No installed plugins" : "No matching plugins",
                    message: query.isEmpty
                        ? "Open Marketplace to browse native catalogs or add a reviewed local source."
                        : "Try a different plugin name, source, or included skill.",
                    actionTitle: query.isEmpty ? "Open Marketplace" : "Clear Search"
                ) {
                    if query.isEmpty { navigate(.marketplace) } else { query = "" }
                }
            } else {
                Table(filteredPlugins, selection: $selection) {
                    TableColumn("Name") { plugin in
                        Label(plugin.name, systemImage: "puzzlepiece.extension")
                            .font(.callout.weight(.medium))
                    }.width(min: 180, ideal: 250)
                    TableColumn("Description") { plugin in
                        Text(plugin.summary).foregroundStyle(.secondary).lineLimit(1).help(plugin.summary)
                    }.width(min: 120, ideal: 360)
                    TableColumn("Skills") { plugin in
                        Text("\(plugin.skills.count)").monospacedDigit().foregroundStyle(.secondary)
                    }.width(50)
                    TableColumn("Apps") { plugin in
                        TableClientMarks(clients: model.availableClients, present: Set(plugin.clients.filter(\.reportsLocalPresence).map(\.client)))
                    }.width(70)
                    TableColumn("Updates") { plugin in
                        UpdateStateBadge(availability: availability(for: plugin))
                    }.width(min: 110, ideal: 130)
                }
                .tableStyle(.inset)

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
        UpdateAvailabilityEvaluator.evaluate(plugin: plugin, sources: model.visibleSources, packages: model.visibleMarketplacePackages)
    }

    private var toolbarContext: String {
        "\(model.visiblePlugins.count) plugins"
    }

    /// Several picks, one plan. Removing plugins one at a time means one review
    /// each; the stack makes it a single reviewed operation.
    private var stackedPlugins: [Plugin] {
        model.visiblePlugins
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

    private var displayPlugins: [Plugin] {
        model.visiblePlugins.map { original in
            var plugin = original
            if let connector = connectorRecords.first(where: { $0.pluginID == plugin.id }) {
                plugin.name = connector.name
                plugin.summary = connector.summary
            }
            return plugin
        }
    }

    private var filteredPlugins: [Plugin] {
        displayPlugins.filter { plugin in
            (clientFilter == "All apps" || plugin.clients.contains { $0.client.rawValue == clientFilter && $0.reportsLocalPresence })
                && (query.isEmpty
                || [plugin.name, plugin.summary, plugin.source, plugin.skills.joined(separator: " ")]
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

private struct PluginCollectionRow: View {
    let plugin: Plugin
    let availability: UpdateAvailability
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            KindTile(kind: .plugin, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text("\(plugin.skills.count) skills · \(plugin.scope)")
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            UpdateStateBadge(availability: availability)
            ClientMarks(present: Set(plugin.clients.filter(\.reportsLocalPresence).map(\.client)))
        }
        .padding(.vertical, 6)
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
                    Picker("App", selection: $client) {
                        ForEach(model.availableClients) { candidate in Text(candidate.rawValue).tag(candidate) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .padding(13)
                    .accessibilityLabel("App to remove from")
                }

                GroupBox("In this stack") {
                    VStack(spacing: 0) {
                        ForEach(plugins) { plugin in
                            InfoRow(plugin.name, detail: "\(plugin.skills.count) skills · \(plugin.scope)") {
                                KindTile(kind: .plugin, size: 26)
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
                    KindTile(kind: .plugin, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plugin.name).font(.title3.weight(.semibold))
                        Text(plugin.summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    UpdateStateBadge(availability: availability, showsWhenCurrent: true)
                }

                GroupBox("Updates") {
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

                GroupBox("Installed in") {
                    VStack(spacing: 0) {
                        ForEach(plugin.clients) { client in
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
                    GroupBox("Included skills") {
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

                GroupBox("Source") {
                    VStack(spacing: 0) {
                        LabeledValueRow("Location") {
                            LocationText(path: plugin.source)
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

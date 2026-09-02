import AgentToolingCore
import SwiftUI

struct PluginsView: View {
    @Environment(AppModel.self) private var model
    let navigate: (AppSection) -> Void
    @State private var query = ""
    @State private var selectedID = ""

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Plugins", context: "\(model.plugins.count) installed") {
                Button {
                    Task { await model.runDoctor() }
                } label: {
                    Label(model.isRunningDoctor ? "Checking…" : "Check plugins", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInteractionLocked)
            }

            GeometryReader { proxy in
                HSplitView {
                    collectionPane.frame(
                        minWidth: 350, idealWidth: 420, maxWidth: 500, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                        alignment: .topLeading)
                    detailPane.frame(
                        minWidth: 540, maxWidth: .infinity, minHeight: proxy.size.height, maxHeight: proxy.size.height,
                        alignment: .topLeading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { selectFirstVisiblePluginIfNeeded() }
        .onChange(of: model.plugins) { _, _ in selectFirstVisiblePluginIfNeeded() }
        .onChange(of: filteredPlugins.map(\.id)) { _, _ in selectFirstVisiblePluginIfNeeded() }
    }

    private var collectionPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
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
                List(filteredPlugins, selection: $selectedID) { plugin in
                    PluginCollectionRow(plugin: plugin, selected: selectedID == plugin.id)
                        .tag(plugin.id)
                        .listRowBackground(SelectionRowBackground(selected: selectedID == plugin.id))
                        .accessibilityLabel(plugin.name)
                        .accessibilityValue(plugin.id == selectedID ? "Selected" : "")
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .paneMaterial()
    }

    @ViewBuilder
    private var detailPane: some View {
        if let plugin = selectedPlugin {
            PluginDetailView(plugin: plugin).environment(model)
        } else {
            EmptyStateView(
                symbol: "puzzlepiece.extension", title: "Select a plugin",
                message: "Inspect its contents, app parity, source revision, and configuration assignments.")
        }
    }

    private var filteredPlugins: [Plugin] {
        model.plugins.filter { plugin in
            query.isEmpty
                || [plugin.name, plugin.summary, plugin.source, plugin.skills.joined(separator: " ")]
                    .joined(separator: " ")
                    .localizedCaseInsensitiveContains(query)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedPlugin: Plugin? { model.plugins.first { $0.id == selectedID } }

    private func selectFirstVisiblePluginIfNeeded() {
        guard !filteredPlugins.contains(where: { $0.id == selectedID }) else { return }
        selectedID = filteredPlugins.first?.id ?? ""
    }
}

private struct PluginCollectionRow: View {
    let plugin: Plugin
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
            ClientMarks(present: Set(plugin.clients.filter(\.reportsLocalPresence).map(\.client)))
        }
        .padding(.vertical, 6)
    }
}

private struct PluginDetailView: View {
    @Environment(AppModel.self) private var model
    let plugin: Plugin

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

}

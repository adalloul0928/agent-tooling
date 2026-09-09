import AgentToolingCore
import SwiftUI

/// A declaration is inventory evidence, not proof of an authenticated account.
struct DiscoveredConnectorRow: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let pluginID: String
    let clients: [ClientState]
    var pluginName: String? = nil
}

enum ConnectorInventory {
    /// While a new scan is loading, only show cached declarations whose parent
    /// is still visible. Client states come from that current parent snapshot.
    static func visibleRecords(_ records: [DiscoveredConnectorRow], plugins: [Plugin]) -> [DiscoveredConnectorRow] {
        let parents = Dictionary(plugins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return records.compactMap { record in
            guard let plugin = parents[record.pluginID] else { return nil }
            return DiscoveredConnectorRow(
                id: record.id, name: record.name, summary: record.summary, pluginID: record.pluginID, clients: plugin.clients,
                pluginName: ConnectionSource.pluginName(plugin.name, identifier: plugin.id)
            )
        }
    }

    static func records(plugins: [Plugin], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [DiscoveredConnectorRow] {
        plugins.flatMap { plugin -> [DiscoveredConnectorRow] in
            var roots: [URL] = []
            if plugin.source.hasPrefix("/") { roots.append(URL(fileURLWithPath: plugin.source)) }
            let parts = plugin.id.split(separator: "@").map(String.init)
            if parts.count == 2, parts.allSatisfy({ !$0.contains("/") && !$0.contains("..") }) {
                let cache = home.appending(path: ".codex/plugins/cache/\(parts[1])/\(parts[0])")
                let versions = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
                roots += versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
                    .prefix(20)
            }
            for root in roots {
                guard let manifest = object(root.appending(path: ".codex-plugin/plugin.json")),
                    let appsPath = manifest["apps"] as? String,
                    !appsPath.hasPrefix("/"), !appsPath.split(separator: "/").contains(".."),
                    let apps = object(root.appending(path: appsPath))?["apps"] as? [String: Any]
                else { continue }
                let interface = manifest["interface"] as? [String: Any]
                let name = ConnectionSource.pluginName(interface?["displayName"] as? String ?? plugin.name, identifier: plugin.id)
                let summary = interface?["shortDescription"] as? String ?? manifest["description"] as? String ?? plugin.summary
                return apps.keys.sorted().map {
                    DiscoveredConnectorRow(
                        id: "\(plugin.id):\($0)", name: apps.count == 1 ? name : "\(name) · \($0)",
                        summary: summary, pluginID: plugin.id, clients: plugin.clients,
                        pluginName: ConnectionSource.pluginName(plugin.name, identifier: plugin.id))
                }
            }
            return []
        }
    }

    private static func object(_ url: URL) -> [String: Any]? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= 1_048_576,
            let data = try? Data(contentsOf: url)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

struct MCPServersView: View {
    @Environment(AppModel.self) private var model
    @Binding var request: ScreenRequest?
    @State private var category = "MCP servers"
    @State private var connectors: [DiscoveredConnectorRow] = []
    @State private var loadedConnectorRequest: ConnectorInventoryRequest?
    @State private var query = ""
    @State private var client = "All apps"
    @State private var selected: String?

    init(request: Binding<ScreenRequest?> = .constant(nil)) { _request = request }

    var body: some View {
        let pluginSnapshot = model.visiblePlugins
        let scan = ConnectorInventoryRequest(
            workspacePath: model.workspacePath, plugins: pluginSnapshot,
            scannedAt: model.visibleTargetObservations.map(\.lastScannedAt).max()
        )
        let currentConnectors = ConnectorInventory.visibleRecords(connectors, plugins: pluginSnapshot)
        let listedConnectors = filtered(currentConnectors)
        VStack(spacing: 0) {
            if category == "MCP servers" {
                DirectMCPServersView(request: $request)
            } else {
                PageToolbar(title: "Connectors", context: "\(currentConnectors.count) found in local plugins") {}
                HStack {
                    Picker("App", selection: $client) {
                        Text("All apps").tag("All apps")
                        ForEach(model.availableClients, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                    }.inventoryMenuStyle().fixedSize()
                    Spacer()
                    InventorySearchField(placeholder: "Search connectors", text: $query).frame(maxWidth: 420)
                }.padding(.horizontal, WorkspaceLayout.pageInset).padding(.vertical, WorkspaceLayout.contentTopInset)
                if currentConnectors.isEmpty && loadedConnectorRequest != scan {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.regular)
                        Text("Reading local connectors…").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if listedConnectors.isEmpty {
                    EmptyStateView(
                        symbol: "link", title: query.isEmpty ? "No connectors found" : "No matching connectors",
                        message: query.isEmpty
                            ? "Connectors declared by your local plugins appear here. Check account access in the app that owns the connection."
                            : "Try a different connector, plugin, or marketplace.")
                } else if let record = listedConnectors.first(where: { $0.id == selected }) {
                    HSplitView {
                        connectorTable(records: listedConnectors).frame(minWidth: 320)
                        VStack(spacing: 0) {
                            InspectorHeader(title: "Connector details") { selected = nil }
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    HStack(spacing: 14) {
                                        ToolIdentityIcon(packageID: record.pluginID, size: 44)
                                        Text(record.name).font(.title2.weight(.semibold))
                                        Spacer()
                                    }
                                    Text(record.summary).foregroundStyle(.secondary)
                                    GroupBox("Origin") {
                                        VStack(spacing: 0) {
                                            LabeledValueRow("Plugin") { Text(pluginName(for: record)) }
                                            if let marketplace = ConnectionSource(record.pluginID).marketplaceTitle {
                                                Divider()
                                                LabeledValueRow("Marketplace") { Text(marketplace) }
                                            }
                                        }
                                    }
                                    GroupBox("Account access") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("Not checked").font(.callout.weight(.medium))
                                            Text("This plugin declares a connector. Check sign-in, permissions, and access in its app.")
                                                .font(.callout).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    }
                                }.padding(22)
                            }
                        }.frame(minWidth: 400, idealWidth: 600)
                    }
                } else {
                    connectorTable(records: listedConnectors)
                }
            }
        }
        .environment(\.connectionCategory, $category)
        .task(id: scan) {
            let records = await ConnectorInventoryCache.shared.records(for: scan)
            guard !Task.isCancelled else { return }
            connectors = records
            loadedConnectorRequest = scan
        }
        .onChange(of: request) { _, value in if value != nil { category = "MCP servers" } }
        .onExitCommand { selected = nil }
    }

    private func filtered(_ records: [DiscoveredConnectorRow]) -> [DiscoveredConnectorRow] {
        records.filter { record in
            (client == "All apps" || record.clients.contains { $0.client.rawValue == client && $0.reportsLocalPresence })
                && (query.isEmpty
                    || [
                        record.name, record.summary, pluginName(for: record),
                        ConnectionSource(record.pluginID).marketplaceTitle ?? "",
                    ].joined(separator: " ")
                        .localizedCaseInsensitiveContains(query))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func connectorTable(records: [DiscoveredConnectorRow]) -> some View {
        GeometryReader { geometry in
            Table(records, selection: $selected) {
                TableColumn("Connector") { record in
                    HStack(spacing: 12) {
                        ToolIdentityIcon(packageID: record.pluginID, size: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name).font(.callout.weight(.medium)).lineLimit(1)
                            if geometry.size.width < 900 {
                                Text(pluginName(for: record)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }.padding(.vertical, 8)
                }.width(min: 160, ideal: 240)
                if geometry.size.width >= 900 {
                    TableColumn("Plugin") { Text(pluginName(for: $0)).foregroundStyle(.secondary).lineLimit(1) }
                        .width(min: 120, ideal: 180)
                    TableColumn("Marketplace") {
                        Text(ConnectionSource($0.pluginID).marketplaceTitle ?? "Not recorded").foregroundStyle(.secondary).lineLimit(1)
                    }.width(min: 120, ideal: 160)
                    TableColumn("Account") { _ in Text("Not checked").foregroundStyle(.secondary) }.width(100)
                }
                TableColumn("Apps") {
                    TableClientMarks(clients: model.availableClients, present: Set($0.clients.filter(\.reportsLocalPresence).map(\.client)))
                }.width(70)
            }.tableStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
        }
    }

    private func pluginName(for record: DiscoveredConnectorRow) -> String {
        record.pluginName ?? ConnectionSource(record.pluginID).pluginTitle ?? "Not recorded"
    }
}

/// Consistent list-first navigation for collections, configurations, and projects.
struct BrowserDetailLayout<Browser: View, Detail: View>: View {
    @Binding var selection: String
    let title: String
    @ViewBuilder let browser: () -> Browser
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        Group {
            if selection.isEmpty {
                browser()
            } else {
                HSplitView {
                    browser().frame(minWidth: 320, idealWidth: 600)
                    VStack(spacing: 0) {
                        InspectorHeader(title: title) { selection = "" }
                        detail()
                    }.frame(minWidth: 400, idealWidth: 600)
                }
            }
        }.onExitCommand { selection = "" }
    }
}

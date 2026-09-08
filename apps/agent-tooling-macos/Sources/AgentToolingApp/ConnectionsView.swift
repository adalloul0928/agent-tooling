import AgentToolingCore
import SwiftUI

/// A declaration is inventory evidence, not proof of an authenticated account.
struct DiscoveredConnectorRow: Identifiable {
    let id: String
    let name: String
    let summary: String
    let pluginID: String
    let clients: [ClientState]
}

enum ConnectorInventory {
    static func records(plugins: [Plugin], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [DiscoveredConnectorRow] {
        plugins.flatMap { plugin -> [DiscoveredConnectorRow] in
            var roots: [URL] = []
            if plugin.source.hasPrefix("/") { roots.append(URL(fileURLWithPath: plugin.source)) }
            let parts = plugin.id.split(separator: "@").map(String.init)
            if parts.count == 2, parts.allSatisfy({ !$0.contains("/") && !$0.contains("..") }) {
                let cache = home.appending(path: ".codex/plugins/cache/\(parts[1])/\(parts[0])")
                let versions = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
                roots += versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }.prefix(20)
            }
            for root in roots {
                guard let manifest = object(root.appending(path: ".codex-plugin/plugin.json")),
                    let appsPath = manifest["apps"] as? String,
                    !appsPath.hasPrefix("/"), !appsPath.split(separator: "/").contains(".."),
                    let apps = object(root.appending(path: appsPath))?["apps"] as? [String: Any]
                else { continue }
                let interface = manifest["interface"] as? [String: Any]
                let name = interface?["displayName"] as? String ?? plugin.name
                let summary = interface?["shortDescription"] as? String ?? manifest["description"] as? String ?? plugin.summary
                return apps.keys.sorted().map {
                    DiscoveredConnectorRow(id: "\(plugin.id):\($0)", name: apps.count == 1 ? name : "\(name) · \($0)",
                                    summary: summary, pluginID: plugin.id, clients: plugin.clients)
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
    @State private var query = ""
    @State private var client = "All apps"
    @State private var selected: String?

    init(request: Binding<ScreenRequest?> = .constant(nil)) { _request = request }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach(["Connectors", "MCP servers"], id: \.self) { tab in
                    Button { category = tab } label: {
                        Text(tab).font(.callout.weight(category == tab ? .semibold : .regular))
                            .foregroundStyle(category == tab ? Color.primary : Color.secondary)
                            .padding(.vertical, 12)
                            .overlay(alignment: .bottom) {
                                if category == tab { Rectangle().fill(Color.accentColor).frame(height: 2) }
                            }
                    }.buttonStyle(.plain)
                }
                Spacer()
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help("Connectors are account connections discovered through plugins. MCP servers are configured directly. This list is not a complete inventory of your cloud accounts.")
            }.padding(.horizontal, 20)
            Divider()
            if category == "MCP servers" {
                DirectMCPServersView(request: $request)
            } else {
                PageToolbar(title: "Connections", context: "\(connectors.count) connector declarations") {}
                HStack {
                    Picker("App", selection: $client) {
                        Text("All apps").tag("All apps")
                        ForEach(model.availableClients, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                    }.fixedSize()
                    Spacer()
                    TextField("Search connectors", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                }.padding(16)
                if filtered.isEmpty {
                    EmptyStateView(symbol: "link", title: "No connectors found",
                                   message: "Only connector declarations found in installed plugins appear here. Cloud account connections are not scanned.")
                } else if let record = filtered.first(where: { $0.id == selected }) {
                    HSplitView {
                        connectorTable.frame(minWidth: 320)
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Text(record.name).font(.title2.weight(.semibold))
                                Spacer()
                                Button { selected = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                                    .help("Close details")
                            }
                            Text(record.summary).foregroundStyle(.secondary)
                            LabeledContent("Type", value: "Account connector")
                            LabeledContent("Plugin", value: record.pluginID)
                            LabeledContent("Account", value: "Not checked")
                                .help("The installed declaration does not confirm sign-in, permissions, or live tool access. Manage the account connection in its client.")
                            Spacer()
                        }.padding(24).frame(minWidth: 400)
                    }
                } else { connectorTable }
            }
        }
        .task(id: model.visiblePlugins) { connectors = ConnectorInventory.records(plugins: model.visiblePlugins) }
        .onChange(of: request) { _, value in if value != nil { category = "MCP servers" } }
        .onExitCommand { selected = nil }
    }

    private var filtered: [DiscoveredConnectorRow] {
        connectors.filter { record in
            (client == "All apps" || record.clients.contains { $0.client.rawValue == client && $0.reportsLocalPresence })
            && (query.isEmpty || "\(record.name) \(record.summary) \(record.pluginID)".localizedCaseInsensitiveContains(query))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var connectorTable: some View {
        Table(filtered, selection: $selected) {
            TableColumn("Name") { Label($0.name, systemImage: "link").font(.callout.weight(.medium)) }
                .width(min: 150, ideal: 220)
            TableColumn("Description") { Text($0.summary).foregroundStyle(.secondary).lineLimit(1).help($0.summary) }
                .width(min: 140, ideal: 320)
            TableColumn("Plugin") { Text($0.pluginID).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 140, ideal: 220)
            TableColumn("Apps") { TableClientMarks(clients: model.availableClients, present: Set($0.clients.filter(\.reportsLocalPresence).map(\.client))) }
                .width(70)
            TableColumn("Account") { _ in Text("Not checked").foregroundStyle(.secondary) }
                .width(100)
        }.tableStyle(.inset)
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
                        HStack {
                            Text(title).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { selection = "" } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).help("Close details")
                        }.padding(16)
                        Divider()
                        detail()
                    }.frame(minWidth: 400, idealWidth: 600)
                }
            }
        }.onExitCommand { selection = "" }
    }
}

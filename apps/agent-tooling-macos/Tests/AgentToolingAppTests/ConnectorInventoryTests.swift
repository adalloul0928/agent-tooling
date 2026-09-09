import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

@Suite("Connector declarations")
struct ConnectorInventoryTests {
    @Test func readsDisplayNameAndDoesNotInferConnectorsFromOpaqueIDs() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appending(path: ".codex/plugins/cache/catalog/app-example/4.1.0")
        try FileManager.default.createDirectory(at: root.appending(path: ".codex-plugin"), withIntermediateDirectories: true)
        try Data(#"{"apps":"./.app.json","interface":{"displayName":"Spotify","shortDescription":"Music"}}"#.utf8)
            .write(to: root.appending(path: ".codex-plugin/plugin.json"))
        let plugin = Plugin(
            id: "app-example@catalog", name: "App Example", summary: "", source: "Codex plugin inventory",
            scope: "This Mac", revision: "", skills: [], profiles: [], clients: [], installed: true)
        #expect(ConnectorInventory.records(plugins: [plugin], home: home).isEmpty)
        try Data(#"{"apps":{"app-example":{"id":"registered-example"}}}"#.utf8).write(to: root.appending(path: ".app.json"))
        let records = ConnectorInventory.records(plugins: [plugin], home: home)
        #expect(records.count == 1)
        #expect(records.first?.name == "Spotify")
        #expect(records.first?.pluginID == plugin.id)
        #expect(records.first?.summary == "Music")
    }

    @Test func refusesManifestPathTraversal() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: ".codex-plugin"), withIntermediateDirectories: true)
        try Data(#"{"apps":"../outside.json"}"#.utf8).write(to: home.appending(path: ".codex-plugin/plugin.json"))
        let plugin = Plugin(
            id: "test", name: "Test", summary: "", source: home.path,
            scope: "This Mac", revision: "", skills: [], profiles: [], clients: [], installed: true)
        #expect(ConnectorInventory.records(plugins: [plugin], home: home).isEmpty)
    }

    @Test func sharedCacheReusesNavigationSnapshotAndRefreshesAfterAnotherScan() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appending(path: "package")
        try FileManager.default.createDirectory(at: root.appending(path: ".codex-plugin"), withIntermediateDirectories: true)
        let manifest = root.appending(path: ".codex-plugin/plugin.json")
        try Data(#"{"apps":"apps.json","interface":{"displayName":"First"}}"#.utf8).write(to: manifest)
        try Data(#"{"apps":{"fixture":{}}}"#.utf8).write(to: root.appending(path: "apps.json"))
        let plugin = Plugin(
            id: "fixture", name: "Fixture", summary: "", source: root.path,
            scope: "User", revision: "", skills: [], profiles: [], clients: [], installed: true
        )
        let cache = ConnectorInventoryCache()
        let first = ConnectorInventoryRequest(workspacePath: home.path, plugins: [plugin], scannedAt: .distantPast, home: home)
        let records = await cache.records(for: first)
        #expect(records.first?.name == "First")
        try Data(#"{"apps":"apps.json","interface":{"displayName":"Changed"}}"#.utf8).write(to: manifest)
        #expect(await cache.records(for: first) == records)
        let refreshed = ConnectorInventoryRequest(workspacePath: home.path, plugins: [plugin], scannedAt: .now, home: home)
        #expect(await cache.records(for: refreshed).first?.name == "Changed")
        let deselected = ConnectorInventoryRequest(workspacePath: home.path, plugins: [], scannedAt: refreshed.scannedAt, home: home)
        #expect(await cache.records(for: deselected).isEmpty)
    }

    @Test func pendingRefreshCannotShowRemovedPluginsOrOldClientStates() {
        let claude = ClientState(client: .claude, state: .healthy, detail: "Installed", isInstalled: true)
        let codex = ClientState(client: .codex, state: .healthy, detail: "Installed", isInstalled: true)
        let cached = [
            DiscoveredConnectorRow(id: "kept", name: "Kept", summary: "", pluginID: "kept", clients: [claude, codex]),
            DiscoveredConnectorRow(id: "removed", name: "Removed", summary: "", pluginID: "removed", clients: [claude]),
        ]
        let currentPlugin = Plugin(
            id: "kept", name: "Current parent name", summary: "", source: "", scope: "User", revision: "",
            skills: [], profiles: [], clients: [codex], installed: true
        )
        let visible = ConnectorInventory.visibleRecords(cached, plugins: [currentPlugin])
        #expect(visible.map(\.id) == ["kept"])
        #expect(visible.first?.clients == [codex])
        #expect(visible.first?.pluginName == "Current parent name")
        #expect(ConnectorInventory.visibleRecords(cached, plugins: []).isEmpty)
    }
}

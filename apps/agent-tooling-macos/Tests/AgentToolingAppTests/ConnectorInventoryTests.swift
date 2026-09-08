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
        let plugin = Plugin(id: "app-example@catalog", name: "App Example", summary: "", source: "Codex plugin inventory",
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
        let plugin = Plugin(id: "test", name: "Test", summary: "", source: home.path,
                            scope: "This Mac", revision: "", skills: [], profiles: [], clients: [], installed: true)
        #expect(ConnectorInventory.records(plugins: [plugin], home: home).isEmpty)
    }
}

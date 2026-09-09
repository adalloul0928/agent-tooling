import Foundation
import Observation
import Synchronization
import Testing

@testable import AgentToolingCore

@MainActor
struct VisibleInventoryTests {
    @Test func cachedReadsStillObserveInventoryAndClientChanges() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = try fixture.model()
        model.skills = [skill("review", clients: [.codex, .claude])]
        #expect(model.visibleSkills.count == 1)

        let changed = Mutex(false)
        withObservationTracking {
            #expect(model.visibleSkills[0].displayName == "review")
        } onChange: { changed.withLock { $0 = true } }
        model.skills[0].displayName = "Updated review"
        #expect(changed.withLock { $0 })
        #expect(model.visibleSkills[0].displayName == "Updated review")

        let clientChanged = Mutex(false)
        withObservationTracking {
            #expect(model.visibleSkills[0].clients.count == 2)
        } onChange: { clientChanged.withLock { $0 = true } }
        model.enabledClients = [.claude]
        #expect(clientChanged.withLock { $0 })
        #expect(model.visibleSkills[0].clients.map(\.client) == [.claude])
        model.enabledClients = []
        #expect(model.visibleSkills.isEmpty)
        #expect(model.skills[0].clients.count == 2, "Client filtering must retain the original inventory")
        model.enabledClients = [.codex]
        #expect(model.visibleSkills[0].clients.map(\.client) == [.codex])
    }

    @Test func nestedInventoryEditsAndWholeReplacementRefreshProjections() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = try fixture.model()
        let clients = [ClientState(client: .codex, state: .healthy, detail: "Found", isInstalled: true)]
        model.plugins = [Plugin(id: "bundle", name: "Bundle", summary: "", source: "Local", scope: "User", revision: "1", skills: [], profiles: [], clients: clients, installed: true)]
        model.mcpServers = [MCPServer(id: "server", name: "Server", summary: "", endpoint: "https://example.com/mcp", transport: .http, authentication: "None", scope: "User", clients: clients)]
        #expect(model.visiblePlugins[0].revision == "1")
        #expect(model.visibleMCPServers[0].aggregateState == .healthy)
        model.plugins[0].revision = "2"
        model.mcpServers[0].clients[0].state = .attention
        #expect(model.visiblePlugins[0].revision == "2")
        #expect(model.visibleMCPServers[0].aggregateState == .attention)
        model.plugins = []
        model.mcpServers = []
        #expect(model.visiblePlugins.isEmpty)
        #expect(model.visibleMCPServers.isEmpty)
    }

    @Test func sourceAccountAndActivityProjectionsFollowClientSelection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = try fixture.model()
        // Initial workspace includes client catalog and account surfaces.
        #expect(model.visibleSources.contains { $0.kind == .openAIPluginDirectory })
        #expect(model.visibleAccountSurfaces.contains { $0.surface.client == .codex })
        model.activities = [ActivityReceipt(kind: .configuration, title: "Codex setup", detail: "Checked", date: .now, state: .healthy)]
        #expect(model.visibleActivities.count == 1)
        model.enabledClients = [.claude]
        #expect(!model.visibleSources.contains { $0.kind == .openAIPluginDirectory })
        #expect(!model.visibleAccountSurfaces.contains { $0.surface.client == .codex })
        #expect(model.visibleActivities.isEmpty)
        model.activities[0].title = "Claude setup"
        #expect(model.visibleActivities.count == 1)
        #expect(model.activities.count == 1)
    }

    private func skill(_ id: String, clients: [ClientKind]) -> Skill {
        Skill(id: id, name: id, displayName: id, summary: "", bundle: "Standalone", scope: "User", owned: false, triggers: [], negativeTrigger: "", files: [], clients: clients.map { ClientState(client: $0, state: .healthy, detail: "Found", isInstalled: true) }, validationCount: 0)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "visible-inventory-\(UUID())")
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
        @MainActor func model() throws -> AppModel {
            try AppModel(store: WorkspaceStore(rootURL: root.appending(path: "store")), homeURL: root.appending(path: "home"))
        }
    }
}

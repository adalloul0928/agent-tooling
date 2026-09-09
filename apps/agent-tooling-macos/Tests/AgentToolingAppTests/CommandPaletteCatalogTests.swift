import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

@Suite("Command palette catalog and sidebar health")
@MainActor
struct CommandPaletteCatalogTests {
    private func makeModel(snapshot: WorkspaceSnapshot? = nil) throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agent-tooling-palette-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        if let snapshot {
            try store.save(snapshot, for: "workspace.snapshot")
        }
        return try AppModel(store: store, homeURL: home)
    }

    private func addServer(_ model: AppModel, name: String, endpoint: String = "https://mcp.example.com/mcp") throws {
        var draft = MCPDraft()
        draft.name = name
        draft.endpoint = endpoint
        draft.transport = .http
        let server = try #require(model.addMCPServer(from: draft))
        #expect(server.id == name)
        model.discardPendingPlan()
    }

    @Test("Unchecked clients disappear from search and account destinations")
    func excludesUncheckedClients() throws {
        let model = try makeModel()
        #expect(model.setClientEnabled(.gemini, enabled: false))
        let items = CommandPaletteCatalog.items(for: model)
        #expect(!items.contains { $0.outcome == .openClient(.gemini) })
        #expect(!items.contains { $0.title.localizedCaseInsensitiveContains("gemini") })
        #expect(items.contains { $0.outcome == .openClient(.claude) })
        #expect(model.setClientEnabled(.gemini, enabled: true))
        #expect(CommandPaletteCatalog.items(for: model).contains { $0.outcome == .openClient(.gemini) })
    }

    @Test("Indexes every screen, the shell actions, and the named objects")
    func indexesScreensActionsAndObjects() throws {
        let model = try makeModel()
        try addServer(model, name: "linear")

        let items = CommandPaletteCatalog.items(for: model)

        for section in AppSection.allCases {
            #expect(items.contains { $0.outcome == .navigate(section) })
        }
        for client in ClientKind.allCases {
            #expect(items.contains { $0.outcome == .openClient(client) })
        }
        #expect(items.contains { $0.outcome == .runDoctor })
        #expect(items.contains { $0.outcome == .runSync })
        #expect(items.contains { $0.outcome == .screenRequest(.pasteImport) })
        #expect(items.contains { $0.outcome == .screenRequest(.addMCPServer) })
        #expect(items.contains { $0.title == "Local Library" })
        #expect(items.contains { $0.outcome == .screenRequest(.selectMCPServer("linear")) })
        let profile = try #require(model.profiles.first)
        let source = try #require(model.sources.first)
        let account = try #require(model.accountSurfaces.first)
        #expect(items.contains { $0.outcome == .screenRequest(.selectProfile(profile.id)) })
        #expect(items.contains { $0.outcome == .screenRequest(.selectMarketplaceSource(source.id)) })
        #expect(items.contains { $0.outcome == .screenRequest(.selectAccount(account.id)) })
    }

    @Test("New workspace names remain searchable alongside established route names")
    func workspaceNamesAndLegacyRoutesRemainSearchable() throws {
        let items = CommandPaletteCatalog.items(for: try makeModel())
        for (route, title) in [(AppSection.overview, "Home"), (.skills, "Library"), (.marketplace, "Discover"), (.syncCenter, "Apps")] {
            let item = try #require(items.first { $0.id == "section.\(route.id)" })
            #expect(item.title == title)
            #expect(item.keywords.contains(route.rawValue))
        }
    }

    @Test("Receipt results deep-link to the exact saved receipt")
    func receiptResultsTargetExactObjects() throws {
        let receipt = ActivityReceipt(
            kind: .configuration,
            title: "Applied configuration",
            detail: "Reviewed local change",
            date: .now,
            state: .healthy
        )
        let model = try makeModel(snapshot: WorkspaceSnapshot(activities: [receipt]))

        let items = CommandPaletteCatalog.items(for: model)

        #expect(items.contains { $0.outcome == .screenRequest(.selectReceipt(receipt.id)) })
    }

    @Test("Typing a name selects the object; typing an action reaches the action")
    func rankingReachesObjectsAndActions() throws {
        let model = try makeModel()
        try addServer(model, name: "linear")
        let items = CommandPaletteCatalog.items(for: model)

        let byName = CommandPaletteMatcher.rank(items, query: "linear")
        #expect(byName.first?.outcome == .screenRequest(.selectMCPServer("linear")))

        let byAction = CommandPaletteMatcher.rank(items, query: "check setup")
        #expect(byAction.first?.outcome == .runDoctor)

        #expect(CommandPaletteMatcher.rank(items, query: "zzzznothing").isEmpty)
    }

    @Test("A screen with nothing to report has no sidebar dot")
    func sidebarStaysQuietWhenThereIsNothingToReport() throws {
        let model = try makeModel()

        #expect(model.sectionHealth(for: .overview) == nil)
        #expect(model.sectionHealth(for: .plugins) == nil)
        #expect(model.sectionHealth(for: .mcpServers) == nil)
        #expect(model.sectionHealth(for: .skills) == nil)
    }

    @Test("A server waiting for its plan colours the MCP row")
    func sidebarReportsWaitingServers() throws {
        let model = try makeModel()
        try addServer(model, name: "linear")

        #expect(model.sectionHealth(for: .mcpServers) == .pending)
        #expect(model.sectionHealth(for: .accounts) == .pending)
    }

    @Test("A screen request names the screen that answers it")
    func screenRequestsCarryTheirScreen() {
        #expect(ScreenRequest.addMCPServer.section == .mcpServers)
        #expect(ScreenRequest.pasteImport.section == .mcpServers)
        #expect(ScreenRequest.selectMCPServer("linear").section == .mcpServers)
        #expect(ScreenRequest.selectPlugin("release-tools").section == .plugins)
        #expect(ScreenRequest.selectProfile("local-library").section == .profiles)
        #expect(ScreenRequest.selectMarketplaceSource(UUID()).section == .marketplace)
        #expect(ScreenRequest.selectAccount(UUID()).section == .accounts)
        #expect(ScreenRequest.selectReceipt(UUID()).section == .activity)
    }
}

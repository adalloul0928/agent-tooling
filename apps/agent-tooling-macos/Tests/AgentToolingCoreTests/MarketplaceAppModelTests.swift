import Foundation
import Testing

@testable import AgentToolingCore

private struct MarketplaceTestRunner: CommandRunning {
    func run(executable _: String, arguments _: [String], currentDirectory _: URL?) async throws -> CommandOutput {
        CommandOutput(status: 127, standardOutput: "", standardError: "not installed")
    }
}

private struct MarketplaceTestProvider: MarketplaceProvider {
    let id = "test.registry"
    let displayName = "Test Registry"
    let page: MarketplacePage?
    let error: MarketplaceProviderError?

    init(page: MarketplacePage) {
        self.page = page
        self.error = nil
    }

    init(error: MarketplaceProviderError) {
        self.page = nil
        self.error = error
    }

    func search(_: MarketplaceQuery) async throws -> MarketplacePage {
        if let error { throw error }
        return page ?? MarketplacePage(packages: [])
    }
}

@Suite("Marketplace integration")
struct MarketplaceAppModelTests {
    @Test @MainActor func refreshMergesRemoteProviderResultsAndRecordsSourceState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let package = MarketplacePackage(
            id: "mcp-registry:example@1.0.0",
            name: "example/server",
            publisher: "example",
            summary: "Fixture",
            sourceName: "Official MCP Registry",
            revision: "1.0.0",
            components: [.mcpServer],
            supportedClients: Set(ClientKind.allCases),
            hasExecutableContent: true,
            location: "https://example.com/server"
        )
        let provider = MarketplaceTestProvider(page: MarketplacePage(packages: [package]))
        let model = try AppModel(
            store: store,
            runner: MarketplaceTestRunner(),
            homeURL: root.appending(path: "home", directoryHint: .isDirectory),
            marketplaceProviders: [provider]
        )

        await model.refreshMarketplace()

        #expect(model.marketplacePackages.contains(where: { $0.id == package.id }))
        let registry = try #require(model.sources.first(where: { $0.kind == .mcpRegistry }))
        #expect(registry.lastRefreshedAt != nil)
        #expect(registry.trustSummary.contains("1 server loaded"))
    }

    @Test @MainActor func unavailableRemoteProviderDoesNotDiscardOtherMarketplaceState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let provider = MarketplaceTestProvider(error: .httpStatus(503))
        let model = try AppModel(
            store: store,
            runner: MarketplaceTestRunner(),
            homeURL: root.appending(path: "home", directoryHint: .isDirectory),
            marketplaceProviders: [provider]
        )

        await model.refreshMarketplace()

        let registry = try #require(model.sources.first(where: { $0.kind == .mcpRegistry }))
        #expect(registry.trustSummary.contains("Unavailable"))
        #expect(model.activities.first?.state == .attention)
        #expect(model.lastError == nil)
    }

    @Test @MainActor func standaloneMCPRecommendationBuildsAnMCPConfigurationPlan() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory))
        let package = MarketplacePackage(
            id: "mcp-registry:browser-tools@1.0.0",
            name: "browser-tools",
            publisher: "fixture",
            summary: "Fixture browser MCP server",
            sourceName: "Official MCP Registry",
            components: [.mcpServer],
            supportedClients: [.codex],
            location: "https://example.invalid/browser-tools",
            nativeInstalls: [
                NativeInstall(
                    client: .codex,
                    executable: "codex",
                    arguments: ["mcp", "add", "browser-tools"],
                    removalArguments: ["mcp", "remove", "browser-tools"],
                    detail: "Configure the server through Codex's native MCP manager."
                )
            ]
        )
        let model = try AppModel(
            store: store,
            runner: MarketplaceTestRunner(),
            homeURL: root.appending(path: "home", directoryHint: .isDirectory),
            marketplaceProviders: [MarketplaceTestProvider(page: MarketplacePage(packages: [package]))]
        )

        await model.refreshMarketplace()
        model.planMarketplaceInstall(packageID: package.id, client: .codex)

        #expect(model.pendingPlan?.kind == .configureMCP)
        #expect(model.pendingPlan?.steps.first?.executable == "codex")
        #expect(model.pendingPlan?.steps.first?.arguments == ["mcp", "add", "browser-tools"])
    }

    @Test @MainActor func retainsValidatedRecommendationMetadataWithoutPreparingAnInstall() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        let store = try WorkspaceStore(rootURL: workspace)
        let package = MarketplacePackage(
            id: "mcp-registry:search-only@1.0.0",
            name: "search-only",
            publisher: "fixture",
            summary: "A search-only recommendation fixture.",
            sourceName: "Official MCP Registry",
            revision: "1.0.0",
            components: [.mcpServer],
            supportedClients: [.codex],
            hasExecutableContent: true,
            location: "https://example.invalid/search-only",
            isInstalled: true,
            nativeInstalls: [
                NativeInstall(
                    client: .codex,
                    executable: "codex",
                    arguments: ["mcp", "add", "search-only"],
                    detail: "Configure through Codex's native MCP manager.",
                    isInstalled: true
                )
            ]
        )
        let model = try AppModel(
            store: store,
            runner: MarketplaceTestRunner(),
            homeURL: root.appending(path: "home", directoryHint: .isDirectory)
        )

        #expect(model.retainMarketplaceRecommendation(package, expectedPackageID: package.id))

        let retained = try #require(model.marketplacePackages.first(where: { $0.id == package.id }))
        #expect(!retained.isInstalled)
        #expect(retained.nativeInstalls.first?.isInstalled == false)
        #expect(model.pendingPlan == nil)

        let reloaded = try AppModel(
            store: WorkspaceStore(rootURL: workspace),
            runner: MarketplaceTestRunner(),
            homeURL: root.appending(path: "home", directoryHint: .isDirectory)
        )
        #expect(reloaded.marketplacePackages.contains(where: { $0.id == package.id }))
    }
}

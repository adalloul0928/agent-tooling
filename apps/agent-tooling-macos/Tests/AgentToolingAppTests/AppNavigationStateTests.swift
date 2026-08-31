import AgentToolingCore
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp

@Suite("External navigation request queue")
struct AppNavigationStateTests {
    @Test("Brand icons are available as a compiled catalog or source assets")
    func brandIconsAreAvailableAcrossSwiftToolchains() {
        if ClientBrandAssets.hasCompiledCatalog {
            return
        }

        for client in ClientKind.allCases {
            #expect(ClientBrandAssets.image(for: client, colorScheme: .light) != nil)
            #expect(ClientBrandAssets.image(for: client, colorScheme: .dark) != nil)
        }
    }

    @Test("Queues distinct skill requests in FIFO order")
    @MainActor
    func queuesSkillRequestsInFIFOOrder() {
        let navigation = AppNavigationState()
        let first = UUID()
        let second = UUID()

        navigation.open(.skillCreationRequest(first))
        navigation.open(.skillCreationRequest(second))
        navigation.open(.skillCreationRequest(first))

        #expect(navigation.requestedSection == .skills)
        #expect(navigation.requestedSkillCreationID == first)

        navigation.consumeSkillCreationRequest(second)
        #expect(navigation.requestedSkillCreationID == first)

        navigation.consumeSkillCreationRequest(first)
        #expect(navigation.requestedSkillCreationID == second)

        navigation.consumeSkillCreationRequest(second)
        #expect(navigation.requestedSkillCreationID == nil)
    }

    @Test("An explicit navigation route clears pending creation requests")
    @MainActor
    func explicitNavigationClearsPendingRequests() {
        let navigation = AppNavigationState()
        navigation.open(.skillCreationRequest(UUID()))

        navigation.open(.section(.activity))

        #expect(navigation.requestedSection == .activity)
        #expect(navigation.requestedSkillCreationID == nil)
    }

    @Test("Marketplace recommendations select a package without approving an install")
    @MainActor
    func marketplaceRecommendationNavigation() {
        let navigation = AppNavigationState()
        navigation.openMarketplacePackage("mcp-registry:example@1.0.0")

        #expect(navigation.requestedSection == .marketplace)
        #expect(navigation.requestedMarketplacePackageID == "mcp-registry:example@1.0.0")
        #expect(navigation.requestedSkillCreationID == nil)
    }

    @Test("Search-only marketplace metadata is retained before deep-linking")
    @MainActor
    func marketplaceRecommendationHandoff() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(
            store: WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory)),
            homeURL: root.appending(path: "home", directoryHint: .isDirectory)
        )
        let package = marketplacePackage(id: "mcp-registry:example@1.0.0")
        let recommendation = ToolRecommendation(
            id: "marketplace:\(package.id)",
            kind: .mcpServer,
            title: package.name,
            summary: package.summary,
            rationale: "Fixture recommendation",
            confidence: .medium,
            supportingConversationCount: 2,
            marketplacePackageID: package.id,
            marketplacePackage: package,
            sourceName: package.sourceName
        )
        let navigation = AppNavigationState()

        navigation.openMarketplaceRecommendation(recommendation, using: model)

        #expect(model.marketplacePackages.contains(where: { $0.id == package.id }))
        #expect(model.pendingPlan == nil)
        #expect(navigation.requestedSection == .marketplace)
        #expect(navigation.requestedMarketplacePackageID == package.id)
    }

    @Test("A stale recommendation without package metadata opens Marketplace safely")
    @MainActor
    func staleMarketplaceRecommendationFallback() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(
            store: WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory)),
            homeURL: root.appending(path: "home", directoryHint: .isDirectory)
        )
        let recommendation = ToolRecommendation(
            id: "marketplace:stale",
            kind: .plugin,
            title: "Stale package",
            summary: "No embedded catalog record remains.",
            rationale: "Fixture recommendation",
            confidence: .exploratory,
            supportingConversationCount: 2,
            marketplacePackageID: "mcp-registry:stale@1.0.0"
        )
        let navigation = AppNavigationState()

        navigation.openMarketplaceRecommendation(recommendation, using: model)

        #expect(model.marketplacePackages.isEmpty)
        #expect(model.pendingPlan == nil)
        #expect(navigation.requestedSection == .marketplace)
        #expect(navigation.requestedMarketplacePackageID == nil)
    }

    private func marketplacePackage(id: String) -> MarketplacePackage {
        MarketplacePackage(
            id: id,
            name: "example/server",
            publisher: "fixture",
            summary: "A marketplace handoff fixture.",
            sourceName: "Official MCP Registry",
            revision: "1.0.0",
            components: [.mcpServer],
            supportedClients: [.codex],
            location: "https://example.invalid/server"
        )
    }
}

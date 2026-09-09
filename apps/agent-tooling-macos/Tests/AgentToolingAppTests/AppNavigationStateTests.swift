import AgentToolingCore
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp

@Suite("External navigation request queue")
struct AppNavigationStateTests {
    @Test("Client navigation keeps an exact scope until All Clients is chosen")
    @MainActor
    func clientScopeIsDurableAndExplicitlyCleared() {
        let navigation = AppNavigationState()

        navigation.openClient(.codex)

        #expect(navigation.requestedSection == .syncCenter)
        #expect(navigation.selectedClient == .codex)
        navigation.consumeRequestedSection(.overview)
        #expect(navigation.requestedSection == .syncCenter)
        navigation.consumeRequestedSection(.syncCenter)
        #expect(navigation.requestedSection == nil)
        #expect(navigation.selectedClient == .codex)

        navigation.showAllClients()

        #expect(navigation.requestedSection == .syncCenter)
        #expect(navigation.selectedClient == nil)
    }

    @Test("A general Sync route means All Clients")
    @MainActor
    func generalSyncRouteClearsClientScope() {
        let navigation = AppNavigationState()
        navigation.openClient(.gemini)

        navigation.open(.section(.sync))

        #expect(navigation.requestedSection == .syncCenter)
        #expect(navigation.selectedClient == nil)
    }

    @Test("Brand icons are available as a compiled catalog or source assets")
    @MainActor
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

        navigation.openSkillCreationRequest(first)
        navigation.openSkillCreationRequest(second)
        navigation.openSkillCreationRequest(first)

        #expect(navigation.requestedSection == .skills)
        #expect(navigation.requestedSkillCreationID == first)

        navigation.consumeSkillCreationRequest(second)
        #expect(navigation.requestedSkillCreationID == first)

        navigation.consumeSkillCreationRequest(first)
        #expect(navigation.requestedSkillCreationID == second)

        navigation.consumeSkillCreationRequest(second)
        #expect(navigation.requestedSkillCreationID == nil)
    }

    @Test("Queues external review requests independently in FIFO order")
    @MainActor
    func queuesPendingRequestsInFIFOOrder() {
        let navigation = AppNavigationState()
        let first = UUID()
        let second = UUID()

        navigation.open(.pendingRequest(first))
        navigation.open(.pendingRequest(second))
        navigation.open(.pendingRequest(first))

        #expect(navigation.requestedPendingRequestID == first)
        navigation.consumePendingRequest(second)
        #expect(navigation.requestedPendingRequestID == first)
        navigation.consumePendingRequest(first)
        #expect(navigation.requestedPendingRequestID == second)
        navigation.consumePendingRequest(second)
        #expect(navigation.requestedPendingRequestID == nil)
    }

    @Test("An explicit navigation route clears pending creation requests")
    @MainActor
    func explicitNavigationClearsPendingRequests() {
        let navigation = AppNavigationState()
        navigation.open(.pendingRequest(UUID()))

        navigation.open(.section(.activity))

        #expect(navigation.requestedSection == .activity)
        #expect(navigation.requestedSkillCreationID == nil)
        #expect(navigation.requestedPendingRequestID == nil)
    }

    @Test("Marketplace recommendations select a package without approving an install")
    @MainActor
    func marketplaceRecommendationNavigation() {
        let navigation = AppNavigationState()
        navigation.openMarketplacePackage("mcp-registry:example@1.0.0")

        #expect(navigation.requestedSection == .marketplace)
        #expect(navigation.requestedMarketplacePackageID == "mcp-registry:example@1.0.0")
        #expect(navigation.requestedSkillCreationID == nil)

        navigation.consumeMarketplacePackage("stale")
        #expect(navigation.requestedMarketplacePackageID == "mcp-registry:example@1.0.0")
        navigation.consumeMarketplacePackage("mcp-registry:example@1.0.0")
        #expect(navigation.requestedMarketplacePackageID == nil)
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

import Foundation

@testable import AgentToolingApp
@testable import AgentToolingCore

/// What Home needs beyond the shared fixture: the three sessions it composes,
/// each already holding a scripted answer.
///
/// Home is the one screen that says something about every other screen, so a
/// render of it that reached the real services would open a socket, read this
/// Mac's chat history and its review queue, and draw a different page on every
/// machine. These stand in for all three.
extension ShellRenderFixture {
    /// The listing the fixture's `Example Plugin` came from, with the catalog
    /// reporting something newer.
    ///
    /// The identity matters: `claude:example@vendor` is the same native route
    /// the fixture's plugin carries, which is the only thing that lets an
    /// update be attached to that row rather than to a namesake.
    nonisolated static var heldPackageAwaitingUpdate: MarketplacePackage {
        var package = catalogPackage(
            id: "claude:example@vendor", name: "Example Plugin",
            summary: "The plugin this workspace already holds, listed by the catalog it came from.")
        package.updateStatus = .updateAvailable
        return package
    }

    /// Home's three sessions, each having already read what a test scripted for
    /// it, so a render draws the composed page rather than its loading states.
    ///
    /// Nothing here reaches a catalog, a transcript or the real queue: the
    /// catalog answers from memory, the report is handed over as one this Mac
    /// had already kept, and the queue is a list.
    func homeSessions(
        packages: [MarketplacePackage] = [ShellRenderFixture.heldPackageAwaitingUpdate],
        keptReport: InsightsReport? = ShellRenderFixture.insightsReport(),
        queued: [PendingAgentRequest] = [ShellRenderFixture.pendingRequest()]
    ) async -> HomeSessions {
        let catalog = WorkspaceMarketplaceSession(
            providers: packages.isEmpty ? [] : [StubMarketplaceProvider(packages: packages)],
            service: workspace.service, library: workspace.library, store: store)
        await catalog.refresh()
        let insightsService = StubInsightsServices(
            answer: keptReport ?? ShellRenderFixture.insightsReport(), restored: keptReport)
        let insights = WorkspaceInsightsSession(
            library: workspace.library, homeRoot: home, services: insightsService)
        let requests = WorkspaceRequestSession(
            store: store, library: workspace.library, device: workspace.device,
            queue: StubPendingRequestQueue(requests: queued))
        await requests.refresh()
        return HomeSessions(
            catalog: catalog, insights: insights, requests: requests, insightsService: insightsService)
    }

    /// The three sessions plus the scan behind the insights one, so a test can
    /// also check that drawing Home never asked for a scan.
    @MainActor struct HomeSessions {
        let catalog: WorkspaceMarketplaceSession
        let insights: WorkspaceInsightsSession
        let requests: WorkspaceRequestSession
        let insightsService: StubInsightsServices
    }
}

import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Discover draws its catalogs, and draws nothing from the network.
///
/// The workspace is opened with a stub catalog through the same parameter the
/// app's own launch takes, so a screen that reached past it — to the registry,
/// to `~/.claude`, to a client's own tool — would be reaching somewhere this
/// suite deliberately does not go.
@Suite("Discover renders")
@MainActor
struct DiscoverSectionRenderTests {
    @Test func theShellDrawsDiscover() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(renderShell(.marketplace, fixture: fixture))
    }

    /// The catalog has answered before this frame, so the packages, their
    /// provenance and the library match are all on screen rather than a
    /// loading state that would pass the blank-frame check on its own.
    @Test func discoverDrawsTheListingsACatalogAnswered() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        // The workspace's own session, which is the one the screen draws: a
        // catalog answered once is what Discover and Home both read.
        let session = fixture.workspace.marketplace
        await session.refresh()
        #expect(session.packages.count == 2)

        try expectDrawn(
            MarketplaceView(workspace: fixture.workspace, session: session)
                .environment(AppNavigationState()))
    }

    /// Every catalog failed and nothing came back, so Discover leads with the
    /// attention banner naming the failures rather than a bare empty grid.
    @Test func discoverDrawsTheEmptyStateBannerWhenEveryCatalogFailed() async throws {
        let fixture = try await ShellRenderFixture(
            marketplaceProviders: [StubMarketplaceProvider(displayName: "Broken catalog", fails: true)])
        defer { fixture.remove() }
        let session = fixture.workspace.marketplace
        await session.refresh()
        #expect(session.packages.isEmpty)
        #expect(session.catalogFailures.isEmpty == false)

        try expectDrawn(
            MarketplaceView(workspace: fixture.workspace, session: session)
                .environment(AppNavigationState()))
    }

    /// Some catalogs answered and one did not, so the grid is real and the
    /// shortfall is a one-line note above it rather than a banner.
    @Test func discoverDrawsTheOneLineNoteWhenSomeCatalogsFailed() async throws {
        let fixture = try await ShellRenderFixture(
            marketplaceProviders: [
                StubMarketplaceProvider(packages: [ShellRenderFixture.unheldPackage]),
                StubMarketplaceProvider(id: "stub.broken", displayName: "Broken catalog", fails: true),
            ])
        defer { fixture.remove() }
        let session = fixture.workspace.marketplace
        await session.refresh()
        #expect(session.packages.isEmpty == false)
        #expect(session.catalogFailures.isEmpty == false)

        try expectDrawn(
            MarketplaceView(workspace: fixture.workspace, session: session)
                .environment(AppNavigationState()))
    }
}

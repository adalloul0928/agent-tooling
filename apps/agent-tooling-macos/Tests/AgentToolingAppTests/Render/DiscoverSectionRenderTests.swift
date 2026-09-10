import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Discover draws its catalogs, and draws nothing from the network.
///
/// Both tests hand the screen a stub catalog through the same environment key
/// the app uses, so a screen that reached past it — to the registry, to
/// `~/.claude`, to a client's own tool — would be reaching somewhere this suite
/// deliberately does not go.
@Suite("Discover renders")
@MainActor
struct DiscoverSectionRenderTests {
    @Test func theShellDrawsDiscover() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(
            renderShell(.marketplace, fixture: fixture)
                .environment(\.marketplaceProviders, { _ in [StubMarketplaceProvider()] }))
    }

    /// The catalog has answered before this frame, so the packages, their
    /// provenance and the library match are all on screen rather than a
    /// loading state that would pass the blank-frame check on its own.
    @Test func discoverDrawsTheListingsACatalogAnswered() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let session = WorkspaceMarketplaceSession(
            providers: [StubMarketplaceProvider()], service: fixture.workspace.service,
            library: fixture.workspace.library, store: fixture.store)
        await session.refresh()
        #expect(session.packages.count == 2)

        try expectDrawn(
            MarketplaceView(workspace: fixture.workspace, session: session)
                .environment(AppNavigationState()))
    }
}

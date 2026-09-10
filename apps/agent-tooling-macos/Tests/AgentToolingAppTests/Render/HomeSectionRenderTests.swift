import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Home draws the page it composes, and composes it from nothing it went and
/// fetched itself.
///
/// Every service behind this screen is stubbed through the same environment
/// keys the app uses, so a render that reached a catalog, this Mac's chat
/// history or its real review queue would be reaching somewhere this suite
/// deliberately does not go.
@Suite("Home renders")
@MainActor
struct HomeSectionRenderTests {
    @Test func theShellDrawsHome() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let insights = StubInsightsServices(answer: ShellRenderFixture.insightsReport())

        try expectDrawn(renderShell(.overview, fixture: fixture).homeStubs(insights: insights))

        // Opening Home is not a scan: nothing reads history until asked, and
        // asking stays a decision made on Insights.
        #expect(insights.scanCount == 0)
    }

    /// The composed page: a checked Mac, a report Insights kept, a catalog that
    /// says one held plugin has something newer, and a request nobody has
    /// decided. Each of those is drawn by a different part of the screen.
    @Test func homeDrawsWhatTheOtherScreensProduced() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        let sessions = await fixture.homeSessions()

        try expectDrawn(fixture.overview(sessions))

        // The blank-frame check passes on the chrome alone, so what the other
        // screens produced has to be shown to have changed something: a Home
        // that quietly dropped all of it draws what an empty Home draws.
        let composed = try rasterize(fixture.overview(sessions))
        let bare = try rasterize(
            fixture.overview(await fixture.homeSessions(packages: [], keptReport: nil, queued: [])))
        #expect(
            composed.tiffRepresentation != bare.tiffRepresentation,
            "what the other screens produced changed nothing on Home")
    }

    /// An empty workspace on an unchecked Mac still has to be a page: the
    /// counts read zero, the recommendation panel says what to do instead, and
    /// nothing claims to have checked anything.
    @Test func homeDrawsBeforeAnythingHasBeenCheckedOrScanned() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let sessions = await fixture.homeSessions(packages: [], keptReport: nil, queued: [])

        try expectDrawn(fixture.overview(sessions))
    }

    /// Home is taller than the window it opens in, so a window-sized render
    /// leaves its last sections below the fold and a screenshot of the running
    /// app cannot reach them. This lays the page out at its full height and
    /// checks the part a person has to scroll to, on its own.
    @Test func thePartOfHomeBelowTheFoldDrawsToo() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.device.refresh()
        let sessions = await fixture.homeSessions()

        try expectDrawnBelowTheFold(fixture.overview(sessions, height: 1_900))
    }

    // MARK: - What the page says

    /// Before any catalog has been asked, no plugin has an update verdict of
    /// any kind — "not checked" is not news, and Home shows none of it.
    @Test func noCatalogMeansNoUpdateNews() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        let evaluation = PluginUpdateEvaluation(state: fixture.workspace.library.state)
        let news = evaluation.rowsWithUpdates(in: fixture.rows)

        #expect(evaluation.hasCheckedACatalog == false)
        #expect(evaluation.availability[ShellRenderFixture.plugin]?.hasUpdate == false)
        #expect(evaluation.availability[ShellRenderFixture.plugin]?.isUnverified == true)
        #expect(news.isEmpty)
    }

    /// A catalog listing is attached to the row by the native route it shares
    /// with it, never by a name — the projected plugin's own identifier is this
    /// workspace's artifact ID, which no catalog has ever published.
    @Test func aCatalogUpdateLandsOnTheRowThatSharesItsRoute() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let sessions = await fixture.homeSessions()

        let evaluation = PluginUpdateEvaluation(
            state: fixture.workspace.library.state,
            packages: sessions.catalog.packages, sources: sessions.catalog.sources)

        #expect(evaluation.hasCheckedACatalog)
        #expect(evaluation.availability[ShellRenderFixture.plugin]?.hasUpdate == true)
        #expect(evaluation.rowsWithUpdates(in: fixture.rows).map(\.artifactID) == [ShellRenderFixture.plugin])
    }

    /// A listing published under a different identity is a different package,
    /// however much of its name it shares.
    @Test func aNamesakeListingIsNotThisPlugin() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        var namesake = ShellRenderFixture.catalogPackage(
            id: "claude:example@someone-else", name: "Example Plugin",
            summary: "A different publisher's package with the same name.")
        namesake.updateStatus = .updateAvailable

        let evaluation = PluginUpdateEvaluation(
            state: fixture.workspace.library.state, packages: [namesake],
            sources: [ShellRenderFixture.checkedSource()])

        #expect(evaluation.availability[ShellRenderFixture.plugin]?.hasUpdate == false)
    }

    // MARK: - What the sidebar says

    /// A Mac nobody has checked earns no glyph. Marking a row as needing
    /// attention on no evidence reads exactly like a fault the app went and
    /// established, and the same workspace has one the moment a check finds an
    /// app missing — so this is the difference the check makes, not a screen
    /// that never speaks.
    @Test func nothingIsMarkedUntilThisMacHasBeenChecked() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.library.reviewAssignments(
            artifactIDs: [ShellRenderFixture.skill],
            destinations: [.init(surface: .codexCLI, scope: .user, deviceIDs: [fixture.store.deviceID])])
        await fixture.workspace.library.applyReviewedAssignments()

        let unchecked = SectionHealth.observed(
            library: fixture.workspace.library.state?.library, device: fixture.workspace.device)

        #expect(fixture.workspace.device.observations.isEmpty)
        #expect(unchecked[.skills] != .attention)
        #expect(unchecked[.plugins] != .attention)
        #expect(unchecked[.mcpServers] != .attention)
    }

    /// Once a check has found an app missing, the library says so: the tools
    /// asked for in that app are the ones its absence stops, and the library is
    /// where those asks live.
    @Test func anAppTheCheckCouldNotReachMarksTheLibrary() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        await fixture.workspace.library.reviewAssignments(
            artifactIDs: [ShellRenderFixture.skill],
            destinations: [.init(surface: .codexCLI, scope: .user, deviceIDs: [fixture.store.deviceID])])
        await fixture.workspace.library.applyReviewedAssignments()
        await fixture.workspace.device.refresh()

        let health = SectionHealth.observed(
            library: fixture.workspace.library.state?.library, device: fixture.workspace.device)

        // The stub check finds Claude Code and does not find Codex.
        #expect(fixture.workspace.device.verdict(for: .codex).state == .attention)
        #expect(health[.skills] == .attention)
    }
}

extension ShellRenderFixture {
    /// The library rows a test compares an evaluation against.
    fileprivate var rows: [WorkspaceLibraryReadModelRow] { workspace.library.state?.library.rows ?? [] }

    /// A source this Mac has actually refreshed, so an evaluation counts as
    /// having asked a catalog even when no listing matched.
    nonisolated static func checkedSource() -> ToolingSource {
        ToolingSource(
            name: "Stub catalog", kind: .claudeMarketplace, location: "https://example.com/catalog",
            lastRefreshedAt: .now, lastRevision: "1.4.0", trustSummary: "Reviewed")
    }

    /// Home on its own, with the environment the shell would have given it.
    fileprivate func overview(_ sessions: HomeSessions, height: CGFloat = shellWindowSize.height) -> some View {
        OverviewView(
            workspace: workspace, catalog: sessions.catalog, insights: sessions.insights,
            requests: sessions.requests
        )
        .frame(width: shellWindowSize.width, height: height)
        .environment(AppNavigationState())
    }
}

extension View {
    /// Every service Home reads, scripted. Without these the shell would open
    /// this Mac's own review queue, read its kept report and ask a catalog.
    fileprivate func homeStubs(
        insights: StubInsightsServices,
        packages: [MarketplacePackage] = [ShellRenderFixture.heldPackageAwaitingUpdate],
        queued: [PendingAgentRequest] = []
    ) -> some View {
        environment(\.insightsServices, { _ in insights })
            .environment(\.marketplaceProviders, { _ in [StubMarketplaceProvider(packages: packages)] })
            .environment(\.pendingRequestQueue, StubPendingRequestQueue(requests: queued))
    }
}

/// The harness's blank-frame check, applied only to what is below one window's
/// worth of the page — so a section that lays out to nothing where nobody can
/// see it fails here rather than being reported by whoever scrolls down.
@MainActor
private func expectDrawnBelowTheFold(
    _ view: some View,
    _ location: SourceLocation = #_sourceLocation
) throws {
    let host = NSHostingView(rootView: AnyView(view))
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()

    let fold = shellWindowSize.height
    #expect(host.bounds.height > fold, "the page was not laid out taller than a window", sourceLocation: location)
    // A hosting view draws top-down, but an unflipped one would put the last
    // section at the origin, so the rectangle is chosen rather than assumed.
    let below = CGRect(
        x: 0, y: host.isFlipped ? fold : 0, width: host.bounds.width,
        height: host.bounds.height - fold)
    let bitmap = try #require(
        host.bitmapImageRepForCachingDisplay(in: below),
        "the page produced no drawable area below the fold", sourceLocation: location)
    host.cacheDisplay(in: below, to: bitmap)
    #expect(
        distinctColours(in: bitmap) > 4, "the part of the page below the fold drew a blank frame",
        sourceLocation: location)
}

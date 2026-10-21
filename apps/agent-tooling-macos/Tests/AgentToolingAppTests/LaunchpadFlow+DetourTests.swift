import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Join's detour picked up again (D23). Join's path reaches Let your apps ask
/// only as You joined's detour, so a join that stopped there, left for later,
/// quit, or relaunched by Move to Applications…, comes back on the detour:
/// the footer at Arrivals 2 of 3, Back to You joined, its review returning
/// there, and the walk still reaching Done. A Start here walk picked up at
/// Let your apps ask, and a revisit of it on a Mac that joined, are as they
/// were.
@Suite("Launchpad flow · Join's detour picked up again", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadFlowDetourTests {
    /// Connect it here too, then Go to Home: the record is left for later at
    /// Let your apps ask. Home's Resume opens the detour again; its review
    /// returns to You joined, and the walk goes on to Done.
    @Test func aJoinLeftForLaterOnTheDetourResumesOnItAndFinishes() async throws {
        let fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .cedarJoined)
        defer { sample.remove() }
        LaunchpadArrivalsScreen.connectHere(flow)
        #expect(flow.isDetour)
        flow.requestClose()
        #expect(flow.leaveMoment == .afterCommit)
        flow.leave()
        #expect(flow.pendingHandOff == .overview)
        let left = try #require(fixture.savedRecord(for: sample.workspace))
        #expect(left.state == .deferred)
        #expect(left.path == .join)
        #expect(left.cursor == .ask)

        // Home's Resume row.
        let resumed = fixture.flow(.resume(.ask), workspace: sample.workspace)
        expectOnTheDetour(resumed)

        // Its review returns to You joined.
        try pressPrimary(resumed)
        await waitUntil { resumed.presentedReview != nil }
        #expect(resumed.reviewReturn == .arrivals)
        resumed.advance()
        #expect(resumed.step == .arrivals)
        #expect(!resumed.isDetour)
        #expect(resumed.presentedReview == nil)
        #expect(fixture.savedRecord(for: sample.workspace)?.cursor == .arrivals)

        // On to Done, leaving what arrived for Home.
        let arrivals = try #require(LaunchpadArrivalsScreen.arrivals(for: resumed))
        await arrivals.load()
        let installLater = try #require(LaunchpadStageView.footer(for: resumed).secondary)
        #expect(installLater.title == LaunchpadCopy.Join.installLater)
        installLater.action()
        #expect(resumed.step == .assistant)
        try pressPrimary(resumed)
        #expect(resumed.step == .behave)
        try pressPrimary(resumed)
        #expect(resumed.step == .done)
        #expect(resumed.info.capsules == .init(reached: 3, total: 3))
        resumed.finish(handOffTo: .overview)
        let finished = try #require(fixture.savedRecord(for: sample.workspace))
        #expect(finished.state == .finished)
        #expect(finished.path == .join)
    }

    /// Move to Applications… from the detour leaves the record in progress
    /// at Let your apps ask. The copy the move relaunches carries on there,
    /// on the detour, and its review returns to You joined.
    @Test func aJoinRelaunchedByTheMoveCarriesOnOnTheDetour() async throws {
        var fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let volume = fixture.world.home.root.appending(path: "Volumes/Agent Tooling", directoryHint: .isDirectory)
        let image = HelperBundle.onDiskImage(volume.appending(path: HelperBundle.name, directoryHint: .isDirectory), volume: volume)
        fixture.environment.installation = { image }
        let (flow, sample) = try await fixture.flow(at: .cedarJoined)
        defer { sample.remove() }
        LaunchpadArrivalsScreen.connectHere(flow)
        LaunchpadMoveModel.open(from: flow)
        #expect(flow.step == .move)
        let moving = try #require(fixture.savedRecord(for: sample.workspace))
        #expect(moving.state == .inProgress)
        #expect(moving.path == .join)
        #expect(moving.cursor == .ask)

        // The moved copy opens from Applications, as a quit or a crash on the
        // detour would reopen it too.
        let applications = fixture.world.home.root.appending(path: "Applications", directoryHint: .isDirectory)
        fixture.environment.installation = { HelperBundle.inApplications(applications) }
        let launch = AppLaunchStateTests.launch(fixture)
        #expect(launch.phase == .setup)
        #expect(launch.pendingEntry == .continueFirstRun(.ask))
        await launch.openExisting()
        let relaunched = try #require(launch.flow)
        #expect(relaunched.entry == .continueFirstRun(.ask))
        expectOnTheDetour(relaunched)

        try pressPrimary(relaunched)
        await waitUntil { relaunched.presentedReview != nil }
        #expect(relaunched.reviewReturn == .arrivals)
        relaunched.advance()
        #expect(relaunched.step == .arrivals)
        #expect(!relaunched.isDetour)
        let workspace = try #require(relaunched.workspace)
        #expect(fixture.savedRecord(for: workspace)?.cursor == .arrivals)
    }

    /// Back from a detour picked up again goes to You joined, off the detour.
    @Test func backFromADetourPickedUpAgainGoesToYouJoined() async throws {
        let fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .cedarJoined)
        defer { sample.remove() }
        LaunchpadArrivalsScreen.connectHere(flow)

        let resumed = fixture.flow(.continueFirstRun(.ask), workspace: sample.workspace)
        expectOnTheDetour(resumed)
        resumed.goBack()
        #expect(resumed.step == .arrivals)
        #expect(!resumed.isDetour)
        #expect(resumed.info.footerName == LaunchpadCopy.Footer.stepArrivals)
    }

    /// A Start here walk picked up at Let your apps ask is no detour: Put in
    /// apps, 3 of 5, Back to Put tools in apps.
    @Test func aStartHereWalkPickedUpAtLetYourAppsAskIsNoDetour() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterPlace)
        for entry: SetupEntry in [.continueFirstRun(.ask), .resume(.ask)] {
            let flow = fixture.flow(entry, workspace: sample.workspace)
            #expect(flow.path == .startHere, "\(entry)")
            #expect(!flow.isDetour, "\(entry)")
            #expect(flow.info.footerName == LaunchpadCopy.Footer.stepPutInApps, "\(entry)")
            #expect(flow.info.capsules == .init(reached: 3, total: 5), "\(entry)")
            #expect(flow.info.back == .place, "\(entry)")
        }
    }

    /// Home's Connect Agent Tooling row on a Mac that joined is a revisit:
    /// one step, no capsules and no Back, its review's Continue going to
    /// Home.
    @Test func aRevisitOfLetYourAppsAskOnAMacThatJoinedStaysARevisit() async throws {
        let fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let sample = try await fixture.sample(.cedarJoined)
        defer { sample.remove() }

        let revisit = fixture.flow(.revisit(.ask), workspace: sample.workspace)
        #expect(revisit.path == .join)
        #expect(!revisit.isDetour)
        #expect(revisit.info.footerName == LaunchpadCopy.Footer.stepPutInApps)
        #expect(revisit.info.capsules == nil)
        #expect(revisit.info.back == nil)
        try pressPrimary(revisit)
        await waitUntil { revisit.presentedReview != nil }
        #expect(revisit.reviewReturn == nil)
        revisit.advance()
        #expect(revisit.pendingHandOff == .overview)
    }

    // MARK: - Helpers

    /// Let your apps ask as You joined's detour: Arrivals, 2 of 3, Back to
    /// You joined.
    private func expectOnTheDetour(_ flow: LaunchpadFlow, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(flow.step == .ask, sourceLocation: sourceLocation)
        #expect(flow.path == .join, sourceLocation: sourceLocation)
        #expect(flow.isDetour, sourceLocation: sourceLocation)
        #expect(flow.info.footerName == LaunchpadCopy.Footer.stepArrivals, sourceLocation: sourceLocation)
        #expect(flow.info.capsules == .init(reached: 2, total: 3), sourceLocation: sourceLocation)
        #expect(flow.info.back == .arrivals, sourceLocation: sourceLocation)
    }

    /// Presses the current step's primary, as the footer's button does.
    private func pressPrimary(_ flow: LaunchpadFlow, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary, sourceLocation: sourceLocation)
        #expect(primary.isEnabled, "\(flow.step)'s primary is disabled", sourceLocation: sourceLocation)
        primary.action()
    }
}

import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Done (S22) draws at the stage's size in both appearances: the sample
/// world's Juniper, Cedar after its join, and an empty Mac. Drawing it checks
/// no app, runs nothing and writes nothing; the Checkup card's count arriving
/// after the stage laid out leaves its window as it was.
@Suite("Launchpad Done renders", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadDoneRenderTests {
    @Test(arguments: [RenderAppearance.light, .dark])
    func juniperDoneDraws(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await Self.juniperAtDone(fixture)
        let head = try fixture.head(of: sample.workspace)
        let checks = (fixture.observer.fullChecks, fixture.observer.scopedChecks.count)

        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)

        #expect(try fixture.head(of: sample.workspace) == head)
        #expect(fixture.observer.fullChecks == checks.0)
        #expect(fixture.observer.scopedChecks.count == checks.1)
        #expect(sample.workspace.health.lastCheckedAt == nil)
        // Only Go to Home or Open Checkup finishes the record.
        #expect(fixture.savedRecord(for: sample.workspace)?.state == .inProgress)
    }

    @Test(arguments: [RenderAppearance.light, .dark])
    func anEmptyMacsDoneDraws(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture(.emptyMac)
        defer { fixture.remove() }
        let flow = fixture.flow()
        try await flow.commitStartHere(observations: [], seed: LaunchpadSeed(chosen: []))
        flow.go(to: .done)
        await LaunchpadDoneScreen.model(flow).appear(flow)

        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)

        let summary = try #require(Self.summary(flow))
        #expect(summary.title == "All set")
        #expect(summary.tiles.allSatisfy { $0.state == .absent })
    }

    /// Under Reduce Motion, Done is drawn in its final state at once: the
    /// tiles already shown, every check already drawn.
    @Test func underReduceMotionDoneDrawsItsFinalFrame() async throws {
        let fixture = try await LaunchpadFixture(motion: .reduced)
        defer { fixture.remove() }
        let (flow, _) = try await Self.juniperAtDone(fixture)

        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: .light)
        #expect(flow.environment.motion == .reduced)
    }

    @Test func cedarsDoneDraws() async throws {
        let fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .cedarJoined)
        defer { sample.remove() }
        flow.go(to: .done)
        await LaunchpadDoneScreen.model(flow).appear(flow)

        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: .dark)

        let summary = try #require(Self.summary(flow))
        #expect(summary.tiles.map(\.state) == [.read, .read, .absent, .absent])
    }

    /// The Checkup card reads "Checking…" while the audit Done runs, then its
    /// count: the change happens in place, and the stage keeps its window.
    @Test func theAuditReturningKeepsTheStageInItsWindow() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, _) = try await fixture.flow(at: .afterInstall)
        flow.go(to: .done)
        let model = LaunchpadDoneScreen.model(flow)
        #expect(Self.summary(flow)?.leftForLater.last?.title == "Checking…")

        let layout = try await LateContentHarness.heightAfterChange(
            fixture.stage(flow), windowSize: WindowSize.stage, styleMask: LateContentHarness.stageWindowStyle
        ) {
            await model.appear(flow)
        }

        #expect(model.auditSettled)
        #expect(Self.summary(flow)?.leftForLater.last?.title == "4 things left on Checkup")
        #expect(layout.hostHeight == layout.windowHeight)
    }

    /// Done's footer offers exactly Open Checkup and Go to Home: no Back, no
    /// Set up later, so ⎋ and ⌘[ stay on Done.
    @Test func theFooterOffersOpenCheckupAndGoToHome() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await Self.juniperAtDone(fixture)
        let footer = LaunchpadStageView.footer(for: flow)

        #expect(footer.primary?.title == "Go to Home")
        #expect(footer.primary?.key == .return)
        #expect(footer.secondary?.title == "Open Checkup")
        guard case .none = footer.later else {
            Issue.record("Done offers a later slot")
            return
        }
        #expect(flow.info.back == nil)
        flow.goBack()
        flow.escape()
        #expect(flow.step == .done)

        footer.secondary?.action()
        #expect(flow.pendingHandOff == .checkup)
        #expect(fixture.savedRecord(for: sample.workspace)?.items.count == 7)
    }

    // MARK: - Helpers

    /// Juniper's walk at Done: the sample world after the install, with
    /// Other Macs' publish as that step records it, the audit settled.
    static func juniperAtDone(_ fixture: LaunchpadFixture) async throws -> (LaunchpadFlow, LaunchpadSample) {
        let (flow, sample) = try await fixture.flow(at: .afterInstall)
        flow.outcomes.sync = .init(address: FinishSetupFixture.remote, publishedAt: ClientHomeFixture.now, upToDate: true)
        flow.go(to: .done)
        await LaunchpadDoneScreen.model(flow).appear(flow)
        return (flow, sample)
    }

    static func summary(_ flow: LaunchpadFlow) -> LaunchpadDoneSummary? {
        let model = LaunchpadDoneScreen.model(flow)
        return LaunchpadDoneSummary.inputs(flow, model: model)
            .map(LaunchpadDoneSummary.init)
    }
}

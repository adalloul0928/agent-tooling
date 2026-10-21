import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// ⌘Q while the review installs: the panel's progress says "Stopping after
/// this step…" (§6) until the step under way has finished, and VoiceOver
/// hears it, where it went on saying "Installing 2 of 4…".
@Suite("Scoped plan review · a quit while installing", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct ScopedPlanReviewQuitTests {
    @Test func aQuitSaysTheInstallStopsAfterTheStepItIsOn() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterAsk)
        let review = ScopedPlanReview(
            workspace: sample.workspace, scope: .wholePlan, deviceName: "Juniper", libraryDecisions: flow.decisions)
        flow.presentReview(review, returnTo: nil)
        await review.prepare()
        let gate = GatedCommandRunner()
        fixture.scriptReviewCommands(in: sample.workspace, runner: gate)

        let install = Task { await review.install() }
        await gate.waitUntilCalled()
        #expect(review.progressLine == "Installing 2 of 4…")

        let quit = Task { await review.interrupt() }
        await waitUntil { review.progressLine == LaunchpadCopy.Footer.stoppingAfterStep }
        #expect(review.progressAnnouncement == "Stopping after this step…")
        gate.release()
        await quit.value
        await install.value

        #expect(review.progressLine == nil)
    }
}

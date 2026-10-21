import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// The stage audit is the one Done and Home keep: when another audit is
/// already under way (the review's after an install, a late sign-in's, the
/// shell's on a rerun), it waits for that one to end and then audits, rather
/// than counting the other's older reading as its own.
@Suite("Launchpad flow · the stage audit", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadFlowStageAuditTests {
    @Test func anAuditUnderWayIsWaitedForAndThenTheStageAudits() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterRead)
        let setup = sample.workspace.setup
        let gate = GatedCommandRunner()
        defer { gate.release() }
        fixture.setup.searchPathGate = gate
        let keptBefore = fixture.setup.keepCalls

        // An audit that asks the login shell, held there.
        let other = Task { await setup.audit(scansIfUnchecked: false, asksLoginShell: true, readsAccounts: false) }
        await gate.waitUntilCalled()
        #expect(setup.isAuditing)
        var stageAudited = false
        let stage = Task {
            await flow.runStageAudit()
            stageAudited = true
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!stageAudited, "the stage audit waits for the one under way")

        gate.release()
        #expect(await other.value)
        await stage.value

        #expect(stageAudited)
        #expect(fixture.setup.keepCalls == keptBefore + 2, "both audits ran, the stage's after the other")
        #expect(!setup.isAuditing)
    }
}

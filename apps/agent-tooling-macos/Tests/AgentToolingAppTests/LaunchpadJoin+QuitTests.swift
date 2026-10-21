import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// ⌘Q on You joined while the sign-in reads the join started are still out:
/// the join is stoppable until they land, and a quit stops them, so no
/// command they started outlives the app (§10 item 5).
@Suite("Launchpad join · a quit after joining", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadJoinQuitTests {
    @Test func aQuitOnYouJoinedStopsTheSignInReadsStillOut() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let signIn = GatedCommandRunner()
        defer { signIn.release() }
        let cedar = try await JoinCedar(signInGate: signIn)
        defer { cedar.remove() }
        let (flow, model) = await cedar.joinStage()
        model.update(address: juniper.address)
        await model.check.checkNow(model.request)

        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        await waitUntil { flow.step == .arrivals }
        await signIn.waitUntilCalled(times: 2)

        #expect(model.phase == .joined)
        #expect(!model.signIn.isFinished)
        #expect(model.interruption == .stoppable)
        #expect(flow.interruption == .stoppable)

        await flow.prepareToQuit()

        await waitUntil { signIn.cancelledCalls == 2 }
        #expect(model.signIn.isFinished)
        #expect(model.interruption == .idle)
    }
}

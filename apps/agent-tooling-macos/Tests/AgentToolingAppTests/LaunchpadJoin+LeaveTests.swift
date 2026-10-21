import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Leaving J01 while it offers Finish joining: this Mac's store for the
/// library is on disk and the record says so, so FooterConfirm does not say
/// nothing is written. It says the join stopped and is offered again, and
/// Quit setup writes nothing more (D32).
@Suite("Launchpad join · leaving a join that stopped", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadJoinLeaveTests {
    @Test func finishJoiningAtLaunchSaysTheJoinIsOfferedAgain() async throws {
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        let flow = cedar.fixture.flow(.finishJoin(WorkspaceObjectID()))

        flow.requestClose()

        #expect(flow.isConfirmingLeave)
        #expect(flow.leaveMoment == .unfinishedJoin)
        let confirm = FooterConfirm(moment: flow.leaveMoment, keepGoing: {}, leave: {})
        #expect(
            confirm.sentence == "Joining stopped before it finished. Agent Tooling offers Finish joining when it next opens.")
        #expect(confirm.leaveTitle == "Quit setup")
        flow.leave()
        #expect(flow.quitRequested)
        #expect(flow.pendingHandOff == nil)
    }

    @Test func aJoinThatStoppedPastItsStoreThisSessionSaysSoToo() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        cedar.runner.refusesPushes = true
        let (flow, model) = await cedar.joinStage()
        #expect(flow.leaveMoment == .beforeCommit, "nothing is on disk before the join")
        model.update(address: juniper.address)
        await model.check.checkNow(model.request)
        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        await waitUntil { model.phase == .editing }
        guard case .finish = model.mode else {
            Issue.record("a late failure did not offer Finish joining")
            return
        }

        #expect(flow.leaveMoment == .unfinishedJoin)
    }
}

import Testing

@testable import AgentToolingApp

@Suite("Setup stage lifecycle", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SetupStageLifecycleTests {
    @Test func reopeningAfterHandOffRestoresVisibleContentWithoutAppearanceEvents() async throws {
        let fixture = try await LaunchpadFixture(motion: .reduced)
        defer { fixture.remove() }
        _ = try await fixture.sample(.afterRead)
        let recorder = AppLaunchStateTests.Recorder()
        let launch = AppLaunchStateTests.launch(fixture, recorder: recorder)
        await launch.openExisting()
        let first = try #require(launch.flow)
        let firstID = launch.stagePresentationID
        let opener = WindowOpener { _ in }
        var presentation = SetupStagePresentation()
        launch.stageAppeared(openWindow: opener)
        #expect(presentation.opacity(for: firstID) == 1)

        first.leave()
        launch.handOff(to: try #require(first.pendingHandOff), openWindow: opener)
        presentation.leave(firstID)
        #expect(launch.phase == .ready)
        #expect(presentation.opacity(for: firstID) == 0)
        launch.closeStage(presentationID: firstID)
        #expect(recorder.closedWindows == [.setup])
        #expect(recorder.closedKeyWindows == 0)

        // A SwiftUI Window can retain its root without either appearance
        // callback. Reentry must replace the ended flow and its fade anyway.
        launch.presentStage(.rerun, openWindow: opener)
        let reopened = try #require(launch.flow)
        let reopenedID = launch.stagePresentationID
        #expect(reopened !== first)
        #expect(reopenedID != firstID)
        #expect(reopened.entry == .rerun)
        #expect(reopened.step == .apps)
        #expect(reopened.pendingHandOff == nil)
        #expect(presentation.opacity(for: reopenedID) == 1)

        // Raising an active walk keeps it; an old close callback must not
        // clear that new walk or its window state.
        launch.presentStage(.revisit(.ask), openWindow: opener)
        #expect(launch.flow === reopened)
        #expect(launch.stagePresentationID == reopenedID)
        launch.stageKeyChanged(true)
        launch.closeStage(presentationID: firstID)
        #expect(recorder.closedWindows == [.setup])
        launch.stageDisappeared(presentationID: firstID)
        #expect(launch.flow === reopened)
        #expect(launch.isStageOpen)
        #expect(launch.isStageKey)

        launch.stageDisappeared(presentationID: reopenedID)
        #expect(launch.flow == nil)
        #expect(!launch.isStageOpen)
        #expect(!launch.isStageKey)

        // An actual key-window event is enough to reopen a retained root;
        // a second onAppear is not required to report its presence.
        launch.presentStage(.rerun, openWindow: opener)
        launch.stageKeyChanged(true)
        #expect(launch.isStageOpen)
        #expect(launch.stagePresentationID != reopenedID)
        #expect(presentation.opacity(for: launch.stagePresentationID) == 1)
    }
}

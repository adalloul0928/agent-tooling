import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// The shell's launch work right after the stage hands off, with the hints
/// the hand-off itself gives (plan §2.5). Only a walk that read this Mac's
/// apps and audited them in this launch skips the shell's check and audit:
/// Start here's own read, or a join that read the apps it chose. A first run
/// carried on from an earlier launch, and Finish joining, read nothing, so
/// the shell checks every app and audits as on any launch, also after an
/// install on the stage re-checked the apps it touched.
@Suite("Shell launch sequence · after the hand-off", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct ShellLaunchSequenceHandOffTests {
    // MARK: Walks that read the apps

    /// Start here's own hand-off: the read the stage made is this launch's
    /// check, and the stage's audit its audit.
    @Test func aFirstRunsOwnHandOffChecksNothingAgain() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let launch = AppLaunchStateTests.launch(fixture)
        #expect(launch.pendingEntry == .firstRun)
        let flow = try #require(launch.flow)
        flow.choosePath(.startHere)
        try await flow.commitStartHere(observations: fixture.orderedObservations, seed: fixture.seed)
        #expect(flow.hasReadTheApps)
        launch.didCommit(try #require(flow.workspace))
        let audits = fixture.setup.searchPathCalls

        let shell = try handOff(launch, from: flow)
        #expect(shell.hints == ShellLaunchHints(justHandedOff: true))
        await runLaunchWork(shell)

        #expect(fixture.observer.fullChecks == 0, "the stage's read is this launch's check")
        #expect(fixture.setup.searchPathCalls == audits, "the stage's audit is this launch's audit")
        #expect(shell.workspace.device.hasCheckedThisLaunch)
    }

    /// A join from the form read the apps it chose, and its store holds
    /// that read: the shell checks nothing again either.
    @Test func aJoinThatReadTheAppsChecksNothingAgain() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        let launch = AppLaunchStateTests.launch(cedar.fixture)
        let flow = try #require(launch.flow)
        flow.choosePath(.join)
        let model = cedar.model(in: flow)
        await model.load()
        model.update(address: juniper.address)
        await model.check.checkNow(model.request)
        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        await waitUntil { flow.step == .arrivals }
        #expect(flow.hasReadTheApps)
        launch.didCommit(try #require(flow.workspace))
        let audits = cedar.fixture.setup.searchPathCalls

        let shell = try handOff(launch, from: flow)
        #expect(shell.hints == ShellLaunchHints(justHandedOff: true))
        await runLaunchWork(shell)

        #expect(cedar.fixture.observer.fullChecks == 0)
        #expect(cedar.fixture.setup.searchPathCalls == audits)
    }

    /// With the main window closed while it ran, a rerun whose read updated
    /// the library hands that read to the shell it opens; a revisit, which
    /// reads nothing, does not.
    @Test func aRerunThatReadTheAppsHandsOffItsReadAndARevisitNone() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let launch = try await AppLaunchStateTests.libraryLaunch(fixture, recorder: AppLaunchStateTests.Recorder())
        let opener = WindowOpener { _ in }

        launch.presentStage(.rerun, openWindow: opener)
        let rerun = try #require(launch.flow)
        await rerun.adoptRead(observations: fixture.orderedObservations)
        #expect(rerun.hasReadTheApps)
        let afterRerun = try handOff(launch, from: rerun)
        #expect(afterRerun.hints == ShellLaunchHints(justHandedOff: true))
        launch.stageDisappeared()

        launch.presentStage(.revisit(.ask), openWindow: opener)
        let revisit = try #require(launch.flow)
        #expect(revisit !== rerun)
        #expect(!revisit.hasReadTheApps)
        let afterRevisit = try handOff(launch, from: revisit)
        #expect(afterRevisit.hints == ShellLaunchHints())
    }

    // MARK: Walks that read nothing

    /// A first run carried on at launch, past its commit: nothing was read
    /// in this launch, so the shell checks every app and audits over that
    /// check, as Check my apps each time Agent Tooling opens says.
    @Test func aContinuedFirstRunsShellChecksAndAuditsAsAnyLaunch() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        _ = try await fixture.sample(.afterRead)
        let launch = AppLaunchStateTests.launch(fixture)
        #expect(launch.pendingEntry == .continueFirstRun(.found))
        await launch.openExisting()
        let flow = try #require(launch.flow)
        #expect(!flow.hasReadTheApps)
        let audits = fixture.setup.searchPathCalls

        let shell = try handOff(launch, from: flow)
        #expect(shell.hints == ShellLaunchHints())
        await runLaunchWork(shell)

        #expect(fixture.observer.fullChecks == 1)
        #expect(fixture.setup.searchPathCalls == audits + 1, "the audit runs, with the login shell")
        #expect(shell.workspace.device.hasCheckedThisLaunch)
    }

    /// The same, after an install on the stage re-checked the one app it
    /// touched (D29): that re-check is not this launch's check.
    @Test func aContinuedFirstRunsShellChecksEveryAppAfterAStageInstall() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        _ = try await fixture.sample(.afterRead)
        let launch = AppLaunchStateTests.launch(fixture)
        await launch.openExisting()
        let flow = try #require(launch.flow)
        let workspace = try #require(flow.workspace)
        await workspace.device.refresh(only: [.claude])
        #expect(fixture.observer.scopedChecks == [[.claude]])
        #expect(!workspace.device.hasCheckedThisLaunch)
        let audits = fixture.setup.searchPathCalls

        let shell = try handOff(launch, from: flow)
        await runLaunchWork(shell)

        #expect(fixture.observer.fullChecks == 1)
        #expect(fixture.setup.searchPathCalls == audits + 1)
    }

    /// Finish joining, at the launch after a join stopped past its store,
    /// reads nothing from the apps: the shell checks them and audits.
    @Test func aFinishJoiningShellChecksAndAuditsAsAnyLaunch() async throws {
        let juniper = try await JoinPublishedJuniper.make()
        defer { juniper.remove() }
        let cedar = try await JoinCedar()
        defer { cedar.remove() }
        // A join that stops after its store: every push is refused.
        cedar.runner.refusesPushes = true
        let (stopped, stoppedModel) = await cedar.joinStage()
        stoppedModel.update(address: juniper.address)
        await stoppedModel.check.checkNow(stoppedModel.request)
        try #require(LaunchpadStageView.footer(for: stopped).primary).action()
        await waitUntil { stoppedModel.phase == .editing }
        guard case .finish(let workspaceID) = stoppedModel.mode else {
            Issue.record("a late failure did not offer Finish joining")
            return
        }
        cedar.runner.refusesPushes = false

        // The next launch.
        let launch = AppLaunchStateTests.launch(cedar.fixture)
        #expect(launch.pendingEntry == .finishJoin(workspaceID))
        let flow = try #require(launch.flow)
        let model = cedar.model(in: flow)
        await model.load()
        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        await waitUntil { flow.step == .arrivals }
        // The hand-over ends with the stage audit; the model's work is over
        // once nothing is left for it to stop.
        await model.interrupt()
        #expect(!flow.hasReadTheApps)
        let checks = cedar.fixture.observer.fullChecks
        let audits = cedar.fixture.setup.searchPathCalls

        let shell = try handOff(launch, from: flow)
        #expect(shell.hints == ShellLaunchHints())
        await runLaunchWork(shell)

        #expect(cedar.fixture.observer.fullChecks == checks + 1)
        #expect(cedar.fixture.setup.searchPathCalls == audits + 1)
    }

    // MARK: - Helpers

    /// FooterConfirm's Go to Home, then the hand-off: the shell the main
    /// window opens gets this library and the hand-off's hints.
    private func handOff(
        _ launch: AppLaunchState, from flow: LaunchpadFlow, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (workspace: WorkspaceLaunch.Workspace, hints: ShellLaunchHints) {
        flow.leave()
        let section = try #require(flow.pendingHandOff, sourceLocation: sourceLocation)
        launch.handOff(to: section, openWindow: WindowOpener { _ in })
        let workspace = try #require(launch.readyWorkspace, sourceLocation: sourceLocation)
        return (workspace, launch.shellStart.hints)
    }

    /// The launch work as the shell decides and runs it.
    private func runLaunchWork(_ shell: (workspace: WorkspaceLaunch.Workspace, hints: ShellLaunchHints)) async {
        let device = shell.workspace.device
        let policy = LaunchWorkPolicy.decide(
            status: shell.workspace.setupProgress.status, preferences: device.preferences, hints: shell.hints,
            checkedThisLaunch: device.hasCheckedThisLaunch)
        await policy.run(on: shell.workspace, syncPass: {})
    }
}

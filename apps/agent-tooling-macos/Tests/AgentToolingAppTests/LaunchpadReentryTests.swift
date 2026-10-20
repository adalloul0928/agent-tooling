import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Every way into the stage, from a launch and from a shell that is up: a
/// first launch, a first run left in progress, an unfinished join, and Set up
/// this Mac…, Resume and the rows that revisit one step once the main window
/// owns the app. A resumed first run stays left for later until Done (D20),
/// and quitting in the middle of a rerun leaves the record exactly as it was.
@Suite("Launchpad re-entry", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadReentryTests {
    // MARK: - From a launch

    @Test func aLaunchWithNoLibraryOpensTheStageOnWelcome() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let launch = AppLaunchStateTests.launch(fixture)

        #expect(launch.phase == .setup)
        #expect(launch.pendingEntry == .firstRun)
        let flow = try #require(launch.flow)
        #expect(flow.step == .welcome)
        #expect(flow.path == nil)
        #expect(!fixture.hasWorkspace)
    }

    @Test func aLaunchWithAFirstRunInProgressCarriesOnAtItsCursor() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterLibrary)
        #expect(fixture.savedRecord(for: sample.workspace)?.state == .inProgress)

        let launch = AppLaunchStateTests.launch(fixture)

        #expect(launch.phase == .setup)
        #expect(launch.pendingEntry == .continueFirstRun(.place))
        // The library opens, and the walk carries on over it.
        await launch.openExisting()
        let flow = try #require(launch.flow)
        #expect(flow.step == .place)
        #expect(flow.path == .startHere)
        #expect(flow.isPostCommit)
        #expect(launch.phase == .setup)
    }

    /// A join that stopped after its store was made opens J01's Finish
    /// joining at the next launch.
    @Test func aLaunchAfterAJoinStoppedHalfwayOpensFinishJoining() async throws {
        let fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let workspaceID = WorkspaceObjectID()
        let container = fixture.support.appending(
            path: "workspaces-v1/\(workspaceID.rawValue.uuidString.lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try LiveSetupProgressStore(container: container)
            .save(.started(path: .join, cursor: .join, now: ClientHomeFixture.now))

        let launch = AppLaunchStateTests.launch(fixture)

        #expect(launch.phase == .setup)
        #expect(launch.pendingEntry == .finishJoin(workspaceID))
        let flow = try #require(launch.flow)
        #expect(flow.step == .join)
        #expect(flow.path == .join)
    }

    // MARK: - From a shell that is up

    /// Set up this Mac… (the palette, the app menu, Settings › General, Apps
    /// and agent-tooling://setup all ask for `.rerun`): Your apps, with no
    /// fork and no Back, over the library as it is.
    @Test func setUpThisMacOpensYourAppsWithNoForkAndNoBack() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let launch = try await Self.ready(fixture)

        launch.presentStage(.rerun, openWindow: WindowOpener { _ in })

        let flow = try #require(launch.flow)
        #expect(flow.entry == .rerun)
        #expect(flow.path == .rerun)
        #expect(flow.step == .apps)
        #expect(flow.info.back == nil)
        #expect(flow.isPostCommit)
        // A second Set up this Mac… while it is open never replaces it.
        flow.go(to: .reads)
        launch.presentStage(.rerun, openWindow: WindowOpener { _ in })
        #expect(launch.flow === flow)
        #expect(flow.step == .reads)
    }

    /// Home's rows that revisit one step: Move, Connect Agent Tooling and
    /// Connect your other Macs. One step, no capsules, no Back, and its
    /// primary hands off writing nothing.
    @Test(arguments: [LaunchpadStep.move, .ask, .macs])
    func aRowThatRevisitsOneStepOpensOnlyThatStep(step: LaunchpadStep) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let launch = try await Self.ready(fixture)
        let workspace = try #require(launch.workspace)
        let before = fixture.savedRecord(for: workspace)

        launch.presentStage(.revisit(step), openWindow: WindowOpener { _ in })

        let flow = try #require(launch.flow)
        #expect(flow.step == step)
        #expect(flow.info.capsules == nil)
        #expect(flow.info.back == nil)
        #expect(flow.leaveMoment == .rerun)
        flow.leave()
        #expect(flow.pendingHandOff == .overview)
        #expect(fixture.savedRecord(for: workspace) == before)
    }

    /// Home's Resume reopens a first run left for later at its cursor, on its
    /// own path. It stays left for later as it moves, its cursor following,
    /// and leaving again keeps it so; only Done finishes it.
    @Test func resumingKeepsTheSetupLeftForLaterUntilDone() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterInstall)
        let workspace = sample.workspace
        workspace.setupProgress.deferSetup(at: .assistant, now: ClientHomeFixture.now)
        let launch = AppLaunchStateTests.launch(fixture)
        await launch.openExisting()
        #expect(launch.phase == .ready)

        launch.presentStage(.resume(.assistant), openWindow: WindowOpener { _ in })
        let flow = try #require(launch.flow)
        #expect(flow.step == .assistant)
        #expect(flow.path == .startHere)
        #expect(flow.leaveMoment == .afterCommit)

        try Self.press(flow)
        #expect(flow.step == .behave)
        var record = try #require(fixture.savedRecord(for: workspace))
        #expect(record.state == .deferred)
        #expect(record.cursor == .behave)

        flow.leave()
        record = try #require(fixture.savedRecord(for: workspace))
        #expect(record.state == .deferred)
        #expect(record.cursor == .behave)
        #expect(SetupStatus(record) == .deferred(.behave, path: .startHere, seenPreferences: true))

        // Resumed again, it carries on to Done.
        let again = LaunchpadFlow(entry: .resume(.behave), environment: fixture.environment, workspace: workspace)
        try Self.press(again)
        #expect(again.step == .macs)
        try Self.press(again)
        #expect(again.step == .done)
        #expect(fixture.savedRecord(for: workspace)?.state == .deferred)
        await LaunchpadDoneScreen.model(again).appear(again)
        try Self.press(again)
        #expect(fixture.savedRecord(for: workspace)?.state == .finished)
        #expect(fixture.savedRecord(for: workspace)?.path == .startHere)
    }

    /// ⌘Q in the middle of a rerun stops what it can, waits out what it
    /// cannot, and leaves the record, written by the setup that finished,
    /// byte for byte as it was (D20).
    @Test func aQuitInTheMiddleOfARerunLeavesTheRecordAsItWas() async throws {
        let signIn = GatedCommandRunner()
        let fixture = try await LaunchpadFixture(signInGate: signIn)
        defer { fixture.remove() }
        let launch = try await Self.ready(fixture)
        let workspace = try #require(launch.workspace)
        let file = workspace.store.databaseURL.deletingLastPathComponent().appending(path: SetupProgressRecord.fileName)
        let before = try Data(contentsOf: file)

        launch.presentStage(.rerun, openWindow: WindowOpener { _ in })
        let flow = try #require(launch.flow)
        try Self.press(flow)
        #expect(flow.step == .reads)
        let read = LaunchpadReadSession.of(flow)
        try Self.press(flow)
        await waitUntil { read.phase == .finished }
        // The read is adopted; its sign-in reads are still out.
        #expect(launch.terminationPlan() != .now)

        await launch.prepareToTerminate(launch.terminationPlan())

        #expect(flow.interruption == .idle)
        #expect(try Data(contentsOf: file) == before)
        #expect(workspace.setupProgress.record == LiveSetupProgressStore(container: file.deletingLastPathComponent()).load())
        signIn.release()
    }

    /// A rerun on a workspace made before Launchpad, quit half way: still no
    /// record at all.
    @Test func aQuitInTheMiddleOfARerunOnALegacyWorkspaceWritesNoRecord() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await WorkspaceLaunch.create(
            observations: fixture.orderedObservations, preferences: fixture.seed.preferences, supportRoot: fixture.support,
            homeRoot: fixture.home, beforeRecord: { _ in }, services: fixture.environment.sessions)
        let launch = AppLaunchStateTests.launch(fixture)
        await launch.openExisting()
        #expect(launch.phase == .ready)

        launch.presentStage(.rerun, openWindow: WindowOpener { _ in })
        let flow = try #require(launch.flow)
        try Self.press(flow)
        let read = LaunchpadReadSession.of(flow)
        try Self.press(flow)
        await waitUntil { read.phase == .finished && read.signIn.isFinished }
        try Self.press(flow)
        #expect(flow.step == .found)

        await launch.prepareToTerminate(launch.terminationPlan())

        #expect(fixture.savedRecord(for: workspace) == nil)
        #expect(workspace.setupProgress.status == .legacy)
    }

    // MARK: - Helpers

    /// A launch on a Mac whose setup finished: the main window owns it.
    private static func ready(_ fixture: LaunchpadFixture) async throws -> AppLaunchState {
        let sample = try await fixture.sample(.afterRead)
        sample.workspace.setupProgress.finish(items: FinishSetupItem.allCases, now: ClientHomeFixture.now)
        let launch = AppLaunchStateTests.launch(fixture)
        await launch.openExisting()
        #expect(launch.phase == .ready)
        return launch
    }

    private static func press(_ flow: LaunchpadFlow, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let primary = try #require(LaunchpadStageView.footer(for: flow).primary, sourceLocation: sourceLocation)
        #expect(primary.isEnabled, "\(flow.step)'s primary is disabled", sourceLocation: sourceLocation)
        primary.action()
    }
}

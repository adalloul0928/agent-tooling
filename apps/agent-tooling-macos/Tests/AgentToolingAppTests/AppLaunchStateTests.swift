import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Who owns a launch, and what changes hands at the hand-off (plan §2.1,
/// §2.6): every row of the launch table, read from real files in a scratch
/// support folder; the windows' launch behaviours and the menu-bar item per
/// phase; the hand-off's order; the stage's flow surviving a second request;
/// the library never created by opening; a closed main window opening again
/// from the Dock, a link and the menu-bar item; quitting, ⌘W and ⎋; the
/// defaults suite; and the launch arguments.
@Suite("App launch state", .timeLimit(.minutes(5)))
@MainActor
struct AppLaunchStateTests {
    // MARK: - The launch table

    @Test func aMacWithNoLibraryOpensOnTheStageAlone() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let recorder = Recorder()
        let launch = Self.launch(fixture, recorder: recorder)

        #expect(launch.phase == .setup)
        #expect(launch.pendingEntry == .firstRun)
        #expect(launch.flow?.step == .welcome)
        #expect(launch.ownsLaunch)
        #expect(launch.mainPresence == .suppressed)
        #expect(launch.stagePresence == .presented)
        #expect(launch.readyWorkspace == nil)
        #expect(launch.commandWorkspace == nil)
        #expect(launch.menuBarItems == [.showSetup, .divider, .quit])

        // Opening never creates: the stage's read is the only way to a library.
        await launch.openExisting()
        #expect(launch.phase == .setup)
        #expect(!fixture.hasWorkspace)
        #expect(fixture.firstReads.started.isEmpty)
        #expect(fixture.observer.fullChecks == 0)
    }

    @Test func aCopyThatShouldMoveOpensOnBeforeYouStart() async throws {
        let bundle = URL(filePath: "/private/var/folders/xy/AppTranslocation/Agent Tooling.app", directoryHint: .isDirectory)
        let fixture = try await LaunchpadFixture(
            installation: AgentToolingInstallation(
                bundleURL: bundle, location: .translocated(bundle),
                mcpHelperURL: bundle.appending(path: "Contents/Helpers/agent-tooling-mcp"), cliHelperURL: nil,
                isAdHocSigned: false))
        defer { fixture.remove() }

        let launch = Self.launch(fixture)

        #expect(launch.phase == .setup)
        #expect(launch.flow?.step == .move)
    }

    @Test func aJoinThatStoppedBeforeItsRecordOpensFinishJoining() async throws {
        let fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        let orphan = WorkspaceObjectID()
        try Self.plantSetupRecord(.started(path: .join, cursor: .join), workspace: orphan, in: fixture.support)
        // A Start here store left before its record is left as it is.
        try Self.plantSetupRecord(.started(path: .startHere, cursor: .found), workspace: WorkspaceObjectID(), in: fixture.support)

        let launch = Self.launch(fixture)

        #expect(launch.phase == .setup)
        #expect(launch.pendingEntry == .finishJoin(orphan))
        #expect(launch.flow?.entry == .finishJoin(orphan))
        #expect(launch.flow?.step == .join)
        #expect(launch.flow?.path == .join)
        #expect(launch.mainPresence == .suppressed)
        #expect(!fixture.hasWorkspace)
    }

    @Test func twoStoppedJoinsAreNotGuessedBetween() async throws {
        let fixture = try await LaunchpadFixture(.cedar)
        defer { fixture.remove() }
        for _ in 0..<2 {
            try Self.plantSetupRecord(.started(path: .join, cursor: .join), workspace: WorkspaceObjectID(), in: fixture.support)
        }

        let launch = Self.launch(fixture)

        #expect(launch.pendingEntry == .firstRun)
        #expect(launch.flow?.step == .welcome)
    }

    @Test func aRecordThisBuildCannotReadShowsTheUnreadableScreen() async throws {
        let cases: [(String, (URL) throws -> Void, AppLaunchState.UnreadableReason)] = [
            ("newer", { try Data(#"{"formatVersion":2}"#.utf8).write(to: $0) }, .newerFormat),
            ("damaged", { try Data("not json at all".utf8).write(to: $0) }, .damaged),
            (
                "unreadable", { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
                .io(WorkspaceLocatorError.unreadable.localizedDescription)
            ),
        ]
        for (name, plant, reason) in cases {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            try plant(fixture.support.appending(path: WorkspaceLocator.recordFileName))

            let launch = Self.launch(fixture)

            #expect(launch.phase == .unreadable(reason), "\(name)")
            #expect(launch.ownsLaunch, "\(name)")
            #expect(launch.flow == nil, "\(name)")
            #expect(launch.mainPresence == .suppressed, "\(name)")
            #expect(launch.stagePresence == .presented, "\(name)")
            #expect(launch.menuBarItems == [.showSetup, .divider, .quit], "\(name)")
            await launch.openExisting()
            #expect(launch.phase == .unreadable(reason), "\(name)")
        }
    }

    @Test func aFirstRunLeftInProgressCarriesOnInTheStage() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        _ = try await fixture.sample(.afterRead)
        let launch = Self.launch(fixture)

        #expect(launch.phase == .setup)
        #expect(launch.pendingEntry == .continueFirstRun(.found))
        #expect(launch.mainPresence == .suppressed)
        #expect(launch.menuBarItems == [.showSetup, .divider, .quit])

        await launch.openExisting()

        let flow = try #require(launch.flow)
        #expect(flow.entry == .continueFirstRun(.found))
        #expect(flow.step == .found)
        #expect(flow.isPostCommit)
        #expect(launch.phase == .setup)
        #expect(launch.readyWorkspace == nil)
        #expect(launch.commandWorkspace == nil)
    }

    @Test func aCursorFromBeforeTheLibraryCarriesOnAfterIt() {
        let now = ClientHomeFixture.now
        #expect(AppLaunchState.resumeStep(.started(path: .startHere, cursor: .library, now: now)) == .library)
        #expect(AppLaunchState.resumeStep(.started(path: .startHere, cursor: .reads, now: now)) == .found)
        #expect(AppLaunchState.resumeStep(.started(path: .join, cursor: .join, now: now)) == .arrivals)
        var noCursor = SetupProgressRecord.started(path: .join, cursor: .arrivals, now: now)
        noCursor.cursor = nil
        #expect(AppLaunchState.resumeStep(noCursor) == .arrivals)
    }

    @Test(arguments: [LibraryRecord.none, .deferred, .finished, .newer])
    func aLibraryWithNothingToCarryOnOpensTheMainWindow(record: LibraryRecord) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterRead)
        let container = sample.workspace.store.databaseURL.deletingLastPathComponent()
        let recordURL = container.appending(path: SetupProgressRecord.fileName)
        switch record {
        case .none: try FileManager.default.removeItem(at: recordURL)
        case .deferred: sample.workspace.setupProgress.deferSetup(at: .library, now: ClientHomeFixture.now)
        case .finished: sample.workspace.setupProgress.finish(items: FinishSetupItem.allCases, now: ClientHomeFixture.now)
        case .newer:
            var newer = SetupProgressRecord.started(path: .startHere, cursor: .found, now: ClientHomeFixture.now)
            newer.formatVersion = SetupProgressRecord.currentFormatVersion + 1
            try LiveSetupProgressStore(container: container).save(newer)
        }

        let launch = Self.launch(fixture)
        #expect(launch.phase == .opening)
        #expect(!launch.ownsLaunch)
        #expect(launch.mainPresence == .automatic)
        #expect(launch.stagePresence == .suppressed)
        #expect(launch.menuBarItems == [.opening, .divider, .quit])

        await launch.openExisting()

        #expect(launch.phase == .ready)
        #expect(launch.readyWorkspace != nil)
        #expect(launch.commandWorkspace != nil)
        #expect(launch.flow == nil)
        #expect(
            launch.menuBarItems == [
                .openAgentTooling, .divider, .checkApps(checking: false), .reviewChanges(preparing: false), .divider, .quit,
            ])
    }

    enum LibraryRecord: String, CaseIterable, Sendable {
        case none
        case deferred
        case finished
        case newer
    }

    /// A record whose store cannot be opened fails to open, and Try again
    /// tries again: neither creates a store or a library.
    @Test func openingAndTryingAgainNeverCreateALibrary() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let locator = try WorkspaceLocator(root: fixture.support)
        let record = WorkspaceLocator.Record(workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID())
        try locator.write(record)
        let container = locator.containerDirectory(for: record)

        let launch = Self.launch(fixture)
        #expect(launch.phase == .opening)
        await launch.openExisting()

        guard case .failed = launch.phase else {
            Issue.record("a store that is not there opened: \(launch.phase)")
            return
        }
        #expect(launch.menuBarItems == [.couldNotOpen, .tryAgain, .divider, .quit])
        #expect(launch.mainPresence == .automatic)
        await launch.tryAgain()
        guard case .failed = launch.phase else {
            Issue.record("Try again opened a store that is not there: \(launch.phase)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: container.path(percentEncoded: false)))
        #expect(launch.workspace == nil)
    }

    @Test func openingAMacWithNoLibraryRefusesRatherThanCreates() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }

        await #expect(throws: WorkspaceLaunch.OpenError.noLibrary) {
            _ = try await WorkspaceLaunch.open(
                supportRoot: fixture.support, homeRoot: fixture.home, services: fixture.environment.sessions)
        }
        #expect(!fixture.hasWorkspace)
        #expect(
            !FileManager.default.fileExists(atPath: fixture.support.appending(path: "workspaces-v1").path(percentEncoded: false)))
    }

    @Test func tryAgainReadsTheRecordAgain() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let recordURL = fixture.support.appending(path: WorkspaceLocator.recordFileName)
        try FileManager.default.createDirectory(at: recordURL, withIntermediateDirectories: true)
        let launch = Self.launch(fixture)
        guard case .unreadable(.io) = launch.phase else {
            Issue.record("expected an unreadable record, got \(launch.phase)")
            return
        }

        // The disk reads now: nothing is there, so it is a first run.
        try FileManager.default.removeItem(at: recordURL)
        launch.unreadableActions.tryAgain()
        await waitUntil { launch.phase == .setup }

        #expect(launch.pendingEntry == .firstRun)
        #expect(launch.flow?.step == .welcome)
    }

    // MARK: - The hand-off

    @Test func theHandOffFlipsThePhaseBeforeTheMainWindowOpens() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        _ = try await fixture.sample(.afterRead)
        let recorder = Recorder()
        let launch = Self.launch(fixture, recorder: recorder)
        await launch.openExisting()
        let flow = try #require(launch.flow)
        let workspace = try #require(flow.workspace)
        launch.didCommit(workspace)
        #expect(launch.phase == .setup)
        #expect(launch.readyWorkspace == nil)

        // Links that arrived while setup ran: a section, a review another Mac
        // asked for, and a skill to create.
        let request = UUID()
        let creation = UUID()
        for link in ["agent-tooling://checkup", "agent-tooling://requests/\(request)", "agent-tooling://skills/create/\(creation)"] {
            launch.queueLinkDuringSetup(try #require(URL(string: link)))
        }
        #expect(launch.navigation.requestedSection == .skills)

        // FooterConfirm's Go to Home: the record keeps the cursor, then the
        // window hands off.
        flow.leave()
        #expect(flow.pendingHandOff == .overview)
        let opened = Recorded<(AppWindow, AppLaunchState.Phase)>()
        launch.handOff(to: .overview, openWindow: WindowOpener { window in opened.values.append((window, launch.phase)) })

        #expect(opened.values.map(\.0) == [.main])
        #expect(opened.values.map(\.1) == [.ready])
        #expect(recorder.broughtForward.last == .main)
        #expect(launch.phase == .ready)
        #expect(!launch.ownsLaunch)
        #expect(launch.mainPresence == .automatic)
        #expect(launch.stagePresence == .suppressed)
        #expect(launch.readyWorkspace != nil)
        // A walk carried on from an earlier launch read nothing in this one,
        // so the shell checks and audits as on any launch.
        #expect(launch.shellStart == .init(section: .overview, hints: ShellLaunchHints()))
        // The hand-off's section wins over the queued one; the queues stay.
        #expect(launch.navigation.requestedSection == nil)
        #expect(launch.navigation.requestedPendingRequestID == request)
        #expect(launch.navigation.requestedSkillCreationID == creation)
        #expect(fixture.savedRecord(for: workspace)?.state == .deferred)

        // The first shell takes the hints; the next one opens as any other.
        launch.shellAppeared()
        #expect(launch.shellLaunchHints == ShellLaunchHints())
        #expect(launch.shellStart == .init(section: .overview, hints: ShellLaunchHints()))

        // The stage closes after it: the walk is over, and nothing stays to
        // own the app.
        launch.stageAppeared(openWindow: WindowOpener { _ in })
        #expect(launch.stagePresentedOverShell)
        launch.stageDisappeared()
        #expect(launch.flow == nil)
        #expect(launch.stageHasNothingToShow)
        #expect(!launch.stagePresentedOverShell)
    }

    @Test func doneHandsOffToTheSectionItNames() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        _ = try await fixture.sample(.afterRead)
        let launch = Self.launch(fixture)
        await launch.openExisting()
        let flow = try #require(launch.flow)

        flow.finish(handOffTo: .checkup)
        launch.handOff(to: try #require(flow.pendingHandOff), openWindow: WindowOpener { _ in })

        #expect(launch.initialSection == .checkup)
        #expect(!launch.shellStart.hints.justHandedOff, "a walk carried on from an earlier launch read nothing")
        #expect(fixture.savedRecord(for: try #require(launch.readyWorkspace))?.state == .finished)
    }

    @Test func aReentryHandsBackToTheShellThatIsOpen() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterRead)
        sample.workspace.setupProgress.finish(items: FinishSetupItem.allCases, now: ClientHomeFixture.now)
        let recorder = Recorder()
        let launch = Self.launch(fixture, recorder: recorder)
        await launch.openExisting()
        launch.shellAppeared()
        let revision = launch.navigation.revision

        let opened = Recorded<AppWindow>()
        let opener = WindowOpener { opened.values.append($0) }
        launch.presentStage(.rerun, openWindow: opener)
        let flow = try #require(launch.flow)
        #expect(flow.entry == .rerun)
        #expect(flow.step == .apps)
        #expect(opened.values == [.setup])
        launch.stageAppeared(openWindow: opener)
        #expect(launch.stagePresentedOverShell)

        // A second Set up this Mac… while the stage is open brings it forward
        // and never replaces the walk on it.
        launch.presentStage(.revisit(.ask), openWindow: opener)
        #expect(launch.flow === flow)
        #expect(launch.pendingEntry == .rerun)

        flow.leave()
        launch.handOff(to: try #require(flow.pendingHandOff), openWindow: opener)
        #expect(launch.navigation.requestedSection == .overview)
        #expect(launch.navigation.revision == revision + 1)
        #expect(launch.shellLaunchHints == ShellLaunchHints())
        // Leaving a rerun writes nothing.
        #expect(fixture.savedRecord(for: sample.workspace)?.path == .startHere)
        #expect(fixture.savedRecord(for: sample.workspace)?.state == .finished)

        // Once the stage has closed, the next request starts afresh.
        launch.stageDisappeared()
        launch.presentStage(.revisit(.ask), openWindow: opener)
        let next = try #require(launch.flow)
        #expect(next !== flow)
        #expect(next.entry == .revisit(.ask))
        #expect(next.step == .ask)
    }

    @Test func setupKeepsItsWalkWhenAskedToShowTheStage() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let recorder = Recorder()
        let launch = Self.launch(fixture, recorder: recorder)
        let flow = try #require(launch.flow)
        let opened = Recorded<AppWindow>()

        launch.presentStage(.rerun, openWindow: WindowOpener { opened.values.append($0) })
        launch.presentStage(launch.pendingEntry, openWindow: WindowOpener { opened.values.append($0) })

        #expect(launch.flow === flow)
        #expect(launch.pendingEntry == .firstRun)
        #expect(opened.values == [.setup, .setup])
        #expect(recorder.broughtForward == [.setup, .setup])
        // The stage's window closing while setup owns the app keeps the walk.
        launch.stageAppeared(openWindow: WindowOpener { _ in })
        launch.stageDisappeared()
        #expect(launch.flow === flow)
    }

    // MARK: - Links, the Dock and the commands

    @Test func linksWhileSetupOwnsTheAppWaitForTheShell() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let recorder = Recorder()
        let launch = Self.launch(fixture, recorder: recorder)

        launch.openLink(try #require(URL(string: "agent-tooling://checkup")))

        #expect(launch.navigation.requestedSection == .checkup)
        #expect(recorder.broughtForward == [.setup])
        #expect(launch.phase == .setup)
    }

    @Test func theDockBringsTheStageWhileSetupOwnsTheAppAndMainAfter() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        _ = try await fixture.sample(.afterRead)
        let recorder = Recorder()
        let launch = Self.launch(fixture, recorder: recorder)
        let opened = Recorded<AppWindow>()
        launch.stageAppeared(openWindow: WindowOpener { opened.values.append($0) })

        #expect(!launch.reopen(hasVisibleWindows: false))
        #expect(!launch.reopen(hasVisibleWindows: true))
        #expect(opened.values == [.setup, .setup])

        await launch.openExisting()
        let flow = try #require(launch.flow)
        flow.leave()
        launch.handOff(to: .overview, openWindow: WindowOpener { opened.values.append($0) })
        launch.stageDisappeared()
        opened.values = []

        #expect(launch.reopen(hasVisibleWindows: true))
        #expect(!launch.reopen(hasVisibleWindows: false))
        #expect(opened.values == [.main])
    }

    /// The everyday launch, on a Mac with its library: no stage is shown, so
    /// the main window's root is the first to hand in an opener. Once the
    /// person has closed the main window, the Dock and a link open it again;
    /// before any window has handed one in, a Dock click leaves it to
    /// SwiftUI's own reopen rather than doing nothing.
    @Test func aClosedMainWindowOpensAgainOnALaunchThatNeverShowedTheStage() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let recorder = Recorder()
        let launch = try await Self.libraryLaunch(fixture, recorder: recorder)

        #expect(launch.reopen(hasVisibleWindows: false))

        let opened = Recorded<AppWindow>()
        launch.mainAppeared(openWindow: WindowOpener { opened.values.append($0) })
        // The person closed it; the Dock opens it again.
        #expect(!launch.reopen(hasVisibleWindows: false))
        #expect(opened.values == [.main])
        // With a window showing, AppKit goes on as it would.
        #expect(launch.reopen(hasVisibleWindows: true))
        #expect(opened.values == [.main])
        // A link the shell takes opens it too, on what the link names.
        launch.openLink(try #require(URL(string: "agent-tooling://checkup")))
        #expect(opened.values == [.main, .main])
        #expect(launch.navigation.requestedSection == .checkup)
        // Never the stage.
        #expect(!recorder.broughtForward.contains(.setup))
    }

    /// The menu-bar item's Open Agent Tooling and Review Changes… hand in the
    /// menu's own opener: a main window that is showing comes forward, and
    /// one the person closed opens again, on any launch.
    @Test func theMenuBarOpensTheMainWindowWhetherOrNotItIsShowing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let recorder = Recorder()
        let launch = try await Self.libraryLaunch(fixture, recorder: recorder)
        let menu = Recorded<AppWindow>()
        let opener = WindowOpener { menu.values.append($0) }

        // Closed: bringing it forward finds nothing, so the menu opens it.
        launch.bringMainForward(openWindow: opener)
        #expect(recorder.broughtForward == [.main])
        #expect(menu.values == [.main])
        #expect(recorder.activations == 1)
        // The menu's opener is kept, so the Dock opens it through it too.
        #expect(!launch.reopen(hasVisibleWindows: false))
        #expect(menu.values == [.main, .main])

        // Showing: it comes forward, and nothing opens a second one.
        recorder.showing = [.main]
        launch.reviewChanges(openWindow: opener)
        #expect(menu.values == [.main, .main])
        #expect(recorder.broughtForward == [.main, .main, .main])
        #expect(launch.navigation.requestedScreenRequest == .reviewChanges)
    }

    @Test func reviewChangesReopensTheClosedMainWindow() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let recorder = Recorder()
        let launch = try await Self.libraryLaunch(fixture, recorder: recorder)
        let opened = Recorded<AppWindow>()
        launch.mainAppeared(openWindow: WindowOpener { opened.values.append($0) })
        launch.shellDisappeared()

        launch.reviewChanges()

        #expect(opened.values == [.main])
        #expect(recorder.broughtForward == [.main])
        #expect(recorder.activations == 1)
        #expect(launch.navigation.requestedScreenRequest == .reviewChanges)
    }

    @Test func theCommandsActOnlyOnAReadyLibraryAwayFromTheStage() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let sample = try await fixture.sample(.afterRead)
        let launch = Self.launch(fixture)
        launch.stageKeyChanged(true)
        #expect(launch.commandWorkspace == nil)

        await launch.openExisting()
        let flow = try #require(launch.flow)
        flow.leave()
        launch.handOff(to: .overview, openWindow: WindowOpener { _ in })
        launch.stageKeyChanged(false)
        #expect(launch.commandWorkspace != nil)
        launch.stageKeyChanged(true)
        #expect(launch.commandWorkspace == nil)
        #expect(launch.readyWorkspace?.store.workspaceID == sample.workspace.store.workspaceID)
    }

    // MARK: - ⌘Q, ⌘W and ⎋

    @Test func quittingWaitsForWhatIsRunning() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let launch = Self.launch(fixture)
        let flow = try #require(launch.flow)
        #expect(launch.terminationPlan() == .now)
        #expect(AppLifecycleDelegate.reply(for: .now) == .terminateNow)

        let read = RunningModel(.stoppable)
        _ = flow.model(for: .reads) { read }
        #expect(launch.terminationPlan() == .afterStopping)
        #expect(AppLifecycleDelegate.reply(for: .afterStopping) == .terminateLater)
        await launch.prepareToTerminate(.afterStopping)
        #expect(read.interrupted == 1)

        let publish = RunningModel(.finishing(LaunchpadCopy.Footer.publishing))
        _ = flow.model(for: .macs) { publish }
        #expect(launch.terminationPlan() == .afterFinishing)
        #expect(AppLifecycleDelegate.reply(for: .afterFinishing) == .terminateLater)
        await launch.prepareToTerminate(.afterFinishing)
        #expect(publish.interrupted == 1)
        // While it finishes, ⎋ and FooterConfirm's buttons do nothing.
        flow.escape()
        #expect(!flow.isConfirmingLeave)
    }

    /// Stopping can find work that has just begun to finish: a join past its
    /// last chance to stop as ⌘Q lands. The quit waits that out too, with no
    /// limit, so it never leaves half a change.
    @Test func quittingWaitsOutWorkThatBeginsFinishingAsItIsStopped() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let launch = Self.launch(fixture)
        let flow = try #require(launch.flow)
        let join = RunningModel(.stoppable, then: [.finishing(LaunchpadCopy.Footer.finishingJoin), .idle])
        _ = flow.model(for: .join) { join }

        let plan = launch.terminationPlan()
        #expect(plan == .afterStopping)
        await launch.prepareToTerminate(plan)

        // Stopped, then waited out as the finishing work it had become.
        #expect(join.interrupted == 2)
        #expect(join.interruption == .idle)
    }

    @Test func commandWAndTheCloseButtonAskBeforeTheStageCloses() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let recorder = Recorder()
        let launch = Self.launch(fixture, recorder: recorder)
        let flow = try #require(launch.flow)

        launch.stageKeyChanged(true)
        launch.closeKeyWindow()
        #expect(flow.isConfirmingLeave)
        #expect(recorder.closedKeyWindows == 0)
        flow.keepGoing()

        launch.requestStageClose()
        #expect(flow.isConfirmingLeave)
        flow.keepGoing()

        // A sheet over the stage (S08's) keeps the stage key, but ⌘W closes
        // it as a sheet: FooterConfirm never opens under it.
        recorder.sheetIsKey = true
        launch.closeKeyWindow()
        #expect(!flow.isConfirmingLeave)
        #expect(recorder.closedKeyWindows == 1)
        recorder.sheetIsKey = false

        // Another window closes as it would.
        launch.stageKeyChanged(false)
        launch.closeKeyWindow()
        #expect(recorder.closedKeyWindows == 2)
        #expect(recorder.terminated == 0)
    }

    @Test func escapeOnWelcomeAsksAndQuitSetupQuitsWritingNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let recorder = Recorder()
        let launch = Self.launch(fixture, recorder: recorder)
        let flow = try #require(launch.flow)

        flow.escape()
        #expect(flow.isConfirmingLeave)
        #expect(flow.leaveMoment == .beforeCommit)
        flow.escape()
        #expect(!flow.isConfirmingLeave)

        flow.escape()
        flow.leave()
        #expect(flow.quitRequested)
        launch.quit()
        #expect(recorder.terminated == 1)
        #expect(!fixture.hasWorkspace)
    }

    @Test func theUnreadableScreenQuitsAndShowsTheSupportFolder() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let record = fixture.support.appending(path: WorkspaceLocator.recordFileName)
        try Data("not json at all".utf8).write(to: record)
        let recorder = Recorder()
        let launch = Self.launch(fixture, recorder: recorder)
        #expect(launch.phase == .unreadable(.damaged))

        launch.unreadableActions.showInFinder()
        #expect(recorder.revealed.map { $0.map(\.path) } == [[record.path]])

        // The red button and ⌘W have nothing to ask: there is no walk.
        launch.requestStageClose()
        #expect(recorder.terminated == 1)
        launch.unreadableActions.quit()
        #expect(recorder.terminated == 2)
    }

    // MARK: - Preferences and arguments

    @Test func theAppsPreferencesLiveInTheDefaultsSuite() async throws {
        let scratch = try ScratchDefaults("agent-tooling-tests")
        defer { scratch.remove() }
        let suite = scratch.suite
        let defaults = scratch.defaults
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let launch = Self.launch(fixture, arguments: ["--defaults-suite", suite])
        #expect(launch.context.defaultsSuite == suite)
        let standardBefore = UserDefaults.standard.object(forKey: AppPreferenceKey.appearance) as? String
        defaults.set(AppAppearance.dark.rawValue, forKey: AppPreferenceKey.appearance)
        defaults.set(false, forKey: AppPreferenceKey.showMenuBarItem)

        // The launch resolves the suite once; the App's preferences and every
        // window's root share that one store.
        #expect(AppPreferences.appearance(launch.defaults).wrappedValue == AppAppearance.dark.rawValue)
        #expect(AppPreferences.showMenuBarItem(launch.defaults).wrappedValue == false)
        let collapsed = AppPreferences.sidebarCollapsed(launch.defaults)
        collapsed.wrappedValue = true
        #expect(defaults.bool(forKey: AppPreferenceKey.sidebarCollapsed))
        #expect(UserDefaults.standard.object(forKey: AppPreferenceKey.appearance) as? String == standardBefore)

        // Every window's root keeps the screens' own preferences there too.
        let probe = PreferenceProbe()
        let host = NSHostingView(rootView: PreferenceProbeView(probe: probe).launchPreferences(launch.defaults))
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        #expect(probe.appearance == AppAppearance.dark.rawValue)
        // No suite: the app's own domain.
        #expect(LaunchContext(arguments: ["AgentTooling"]).defaults == .standard)
        #expect(Self.launch(fixture).defaults == .standard)
    }

    @Test func theLaunchArgumentsAreReadOnce() throws {
        let context = LaunchContext(arguments: [
            "AgentTooling", "--workspace", "/tmp/qa/ws", "--home", "/tmp/qa/home", "--section", "checkup", "--request",
            "reviewChanges", "--defaults-suite", "qa-1", "--after-move", "4242", "/Volumes/Agent Tooling",
            "--installation-override", "disk-image", "--applications-folder", "/tmp/qa/Apps",
        ])
        #expect(context.workspaceRoot == URL(fileURLWithPath: "/tmp/qa/ws"))
        #expect(context.homeRoot == URL(fileURLWithPath: "/tmp/qa/home"))
        #expect(context.section == .checkup)
        #expect(context.request == .reviewChanges)
        #expect(context.defaultsSuite == "qa-1")
        #expect(
            context.afterMove == .init(pid: 4242, volume: URL(fileURLWithPath: "/Volumes/Agent Tooling", isDirectory: true)))
        #expect(context.installationOverride == .diskImage)
        #expect(context.applicationsFolder == URL(fileURLWithPath: "/tmp/qa/Apps", isDirectory: true))

        // A rehearsal's flags are honoured only beside --workspace.
        let ordinary = LaunchContext(arguments: [
            "AgentTooling", "--installation-override", "disk-image", "--applications-folder", "/tmp/qa/Apps",
        ])
        #expect(ordinary.installationOverride == nil)
        #expect(ordinary.applicationsFolder == nil)
        #expect(ordinary.afterMove == nil)

        // A copy that ran from no disk image has none to eject, and a flag
        // after --after-move is never taken as its pid or its volume.
        #expect(LaunchContext(arguments: ["AgentTooling", "--after-move", "4242"]).afterMove == .init(pid: 4242, volume: nil))
        let noVolume = LaunchContext(arguments: ["AgentTooling", "--after-move", "4242", "--workspace", "/tmp/qa/ws"])
        #expect(noVolume.afterMove == .init(pid: 4242, volume: nil))
        #expect(noVolume.workspaceRoot == URL(fileURLWithPath: "/tmp/qa/ws"))
        let noPid = LaunchContext(arguments: ["AgentTooling", "--after-move", "--workspace", "/tmp/qa/ws"])
        #expect(noPid.afterMove == nil)
        #expect(noPid.workspaceRoot == URL(fileURLWithPath: "/tmp/qa/ws"))
    }

    @Test func aRehearsalSaysWhereThisCopyRunsFrom() throws {
        let folder = try TemporaryFolder("installation-override")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let bundle = folder.url.appending(path: "Agent Tooling.app", directoryHint: .isDirectory)
        let helper = bundle.appending(path: "Contents/Helpers/agent-tooling-mcp")
        try write(helper, "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path(percentEncoded: false))
        let inspected = AgentToolingInstallation(
            bundleURL: bundle, location: .developmentBuild, mcpHelperURL: nil, cliHelperURL: nil, isAdHocSigned: false)
        let workspace = folder.url.appending(path: "ws").path(percentEncoded: false)
        func context(_ where: String, _ extra: [String] = []) -> LaunchContext {
            LaunchContext(arguments: ["AgentTooling", "--workspace", workspace, "--installation-override", `where`] + extra)
        }

        let diskImage = context("disk-image").installation(inspected: inspected)
        #expect(diskImage.offersMove)
        #expect(diskImage.mcpHelperURL == helper)
        #expect(diskImage.bundleURL == bundle)

        let applications = folder.url.appending(path: "Apps", directoryHint: .isDirectory)
        let installed = context("applications", ["--applications-folder", applications.path(percentEncoded: false)])
            .installation(inspected: inspected)
        #expect(Self.folder(of: installed.location)?.path == applications.path)
        #expect(!installed.offersMove)
        #expect(installed.registrableHelperPath == helper.path(percentEncoded: false))

        #expect(context("translocated").installation(inspected: inspected).offersMove)
        let elsewhere = context("elsewhere").installation(inspected: inspected)
        #expect(Self.folder(of: elsewhere.location)?.path == folder.url.path)
        if case .elsewhere = elsewhere.location {} else { Issue.record("expected elsewhere, got \(elsewhere.location)") }
        #expect(context("development").installation(inspected: inspected).location == .developmentBuild)
        // No override: inspection's answer, untouched.
        #expect(LaunchContext(arguments: ["AgentTooling", "--workspace", workspace]).installation(inspected: inspected) == inspected)
    }

    @Test func theLiveLaunchAppliesARehearsalsOverride() throws {
        let folder = try TemporaryFolder("live-launch")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let support = folder.url.appending(path: "support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let context = LaunchContext(arguments: [
            "AgentTooling", "--workspace", support.path(percentEncoded: false), "--home",
            folder.url.appending(path: "home").path(percentEncoded: false), "--installation-override", "elsewhere",
        ])

        let launch = AppLaunchState.live(context: context)

        #expect(launch.phase == .setup)
        let location = launch.environment.installation().location
        if case .elsewhere = location {} else { Issue.record("expected elsewhere, got \(location)") }
        #expect(Self.folder(of: location)?.path == Bundle.main.bundleURL.deletingLastPathComponent().path)
        #expect(launch.environment.supportRoot == support.standardizedFileURL)
    }

    // MARK: - Helpers

    /// The folder a location names, for the locations that name one.
    static func folder(of location: AgentToolingInstallation.Location) -> URL? {
        switch location {
        case .applications(let folder), .elsewhere(let folder): folder
        case .translocated, .diskImage, .developmentBuild: nil
        }
    }

    /// A launch over the fixture's support folder and home, with the stage's
    /// scripted environment and the app's own actions recorded.
    static func launch(
        _ fixture: LaunchpadFixture, arguments extra: [String] = [], recorder: Recorder = Recorder()
    ) -> AppLaunchState {
        let context = LaunchContext(
            arguments: [
                "AgentTooling", "--workspace", fixture.support.path(percentEncoded: false), "--home",
                fixture.home.path(percentEncoded: false),
            ] + extra)
        return AppLaunchState(context: context, environment: fixture.environment, system: recorder.system)
    }

    /// A launch on a Mac whose library is set up: the main window owns it.
    static func libraryLaunch(_ fixture: LaunchpadFixture, recorder: Recorder) async throws -> AppLaunchState {
        let sample = try await fixture.sample(.afterRead)
        sample.workspace.setupProgress.finish(items: FinishSetupItem.allCases, now: ClientHomeFixture.now)
        let opened = Self.launch(fixture, recorder: recorder)
        await opened.openExisting()
        #expect(opened.phase == .ready)
        return opened
    }

    /// A setup record in a workspace container that has no store and no
    /// library record pointing at it: what a stopped join, or a crash before
    /// a Start here's record, leaves.
    static func plantSetupRecord(_ record: SetupProgressRecord, workspace: WorkspaceObjectID, in support: URL) throws {
        let container = support.appending(path: "workspaces-v1", directoryHint: .isDirectory)
            .appending(path: workspace.rawValue.uuidString.lowercased(), directoryHint: .isDirectory)
        try LiveSetupProgressStore(container: container).save(record)
    }

    /// What a closure was handed, in order.
    @MainActor
    final class Recorded<Value> {
        var values: [Value] = []
    }

    /// The app's own actions, recorded instead of done.
    @MainActor
    final class Recorder {
        var terminated = 0
        var revealed: [[URL]] = []
        var activations = 0
        var broughtForward: [AppWindow] = []
        var closedKeyWindows = 0
        var closedWindows: [AppWindow] = []
        /// The windows on screen, which bringing forward finds. A window
        /// not in it is closed: it opens again only through an opener.
        var showing: Set<AppWindow> = []
        /// Whether the key window is a sheet.
        var sheetIsKey = false

        var system: LaunchSystem {
            LaunchSystem(
                terminate: { [self] in terminated += 1 },
                reveal: { [self] in revealed.append($0) },
                activate: { [self] in activations += 1 },
                bringForward: { [self] window in
                    broughtForward.append(window)
                    return showing.contains(window)
                },
                closeKeyWindow: { [self] in closedKeyWindows += 1 },
                closeWindow: { [self] in closedWindows.append($0) },
                keyWindowIsSheet: { [self] in sheetIsKey })
        }
    }
}

/// Work a step keeps running, standing in for a read, a join or a publish.
/// Each interrupt moves it on to the next of the states it was given; with
/// none left, it stays as it is.
@MainActor
private final class RunningModel: LaunchpadInterruptible {
    private(set) var interruption: LaunchpadInterruption
    private(set) var interrupted = 0
    private var next: [LaunchpadInterruption]

    init(_ interruption: LaunchpadInterruption, then next: [LaunchpadInterruption] = []) {
        self.interruption = interruption
        self.next = next
    }

    func interrupt() async {
        interrupted += 1
        if !next.isEmpty { interruption = next.removeFirst() }
    }
}

/// What a view under a window root reads from the app's preferences.
@MainActor
private final class PreferenceProbe {
    var appearance: String?
}

private struct PreferenceProbeView: View {
    let probe: PreferenceProbe
    @AppStorage(AppPreferenceKey.appearance) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        probe.appearance = appearance
        return Color.clear.frame(width: 10, height: 10)
    }
}

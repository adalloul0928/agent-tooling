import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Exercises every setup re-entry control and deep link. Existing workspaces
/// enter at Your apps without clearing pending review/creation requests. Setup
/// links received during first run wait until hand-off without reopening setup.
/// The five-minute limit accommodates serialized main-actor work in parallel tests.
@Suite("Re-entry routes", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct ReentryRoutesTests {
    /// The link that asks for the stage from outside the app.
    static var setupLink: URL {
        get throws { try #require(URL(string: "agent-tooling://setup")) }
    }

    // MARK: - The link

    @Test func aSetupLinkAsksForTheStageAndClearsNothing() throws {
        let navigation = AppNavigationState()
        let review = UUID()
        let creation = UUID()
        navigation.openClient(.codex)
        navigation.open(.pendingRequest(review))
        navigation.openSkillCreationRequest(creation)
        let waiting = Waiting(navigation)
        let revision = navigation.revision

        #expect(navigation.open(url: try Self.setupLink))

        #expect(navigation.requestedSetup == .rerun)
        #expect(navigation.revision == revision + 1)
        #expect(Waiting(navigation) == waiting)
        #expect(navigation.requestedPendingRequestID == review)
        #expect(navigation.requestedSkillCreationID == creation)

        // A second link while the first waits asks for the same stage once,
        // and a route to a screen after it keeps it: the shell lands on the
        // screen and opens the stage over it.
        navigation.open(url: try Self.setupLink)
        navigation.open(.section(.checkup))
        #expect(navigation.requestedSetup == .rerun)
        #expect(navigation.requestedSection == .checkup)

        navigation.consumeSetupRequest()
        #expect(navigation.requestedSetup == nil)
        #expect(navigation.requestedSection == .checkup)
    }

    /// The shell opens the stage a link asked for once it is up, takes the
    /// request off the queue, and stays on the screen it was showing; a link
    /// that arrives while it is up opens the stage again.
    @Test func theShellOpensTheStageALinkAskedFor() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let navigation = AppNavigationState()
        let review = UUID()
        navigation.open(.pendingRequest(review))
        // The Apps route was already delivered; its review still waits while Settings is open.
        navigation.consumeRequestedSection(.syncCenter)
        navigation.open(url: try Self.setupLink)
        let opened = AppLaunchStateTests.Recorded<SetupEntry>()

        let probe = AccessibilityProbe(
            AppShellView(workspace: fixture.workspace, initialSection: .settings, navigation: navigation)
                .environment(\.openSetup) { opened.values.append($0) })
        defer { probe.close() }

        #expect(opened.values == [.rerun])
        #expect(navigation.requestedSetup == nil)
        #expect(navigation.requestedPendingRequestID == review)
        #expect(probe.contains(LaunchpadCopy.Reentry.runSetupAgain), "the shell left the screen it opened on")

        navigation.open(url: try Self.setupLink)
        probe.settle()
        #expect(opened.values == [.rerun, .rerun])
        #expect(navigation.requestedSetup == nil)
    }

    /// The link, end to end: the main window takes it, and the stage opens at
    /// Your apps over the shell.
    @Test func aSetupLinkOpensTheStageAtYourApps() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let recorder = AppLaunchStateTests.Recorder()
        let launch = try await Self.readyLaunch(fixture, on: "overview", recorder: recorder)
        let review = UUID()
        launch.navigation.open(.pendingRequest(review))
        let probe = Self.mainWindow(launch)
        defer { probe.close() }

        launch.openLink(try Self.setupLink)
        probe.settle()

        Self.expectTheStageAtYourApps(launch, recorder)
        #expect(launch.navigation.requestedSetup == nil)
        #expect(launch.navigation.requestedPendingRequestID == review)
    }

    /// A setup link that arrives while a first run is on the stage waits with
    /// the other links, and goes with the hand-off: the shell the hand-off
    /// opens never opens the stage again. A review another Mac asked for
    /// still waits.
    @Test func aSetupLinkDuringAFirstRunDoesNotReopenTheStageAfterTheHandOff() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        _ = try await fixture.sample(.afterRead)
        let recorder = AppLaunchStateTests.Recorder()
        let launch = AppLaunchStateTests.launch(fixture, recorder: recorder)
        await launch.openExisting()
        let flow = try #require(launch.flow)
        launch.didCommit(try #require(flow.workspace))
        let review = UUID()
        launch.queueLinkDuringSetup(try #require(URL(string: "agent-tooling://requests/\(review)")))
        launch.queueLinkDuringSetup(try Self.setupLink)
        #expect(launch.navigation.requestedSetup == .rerun)

        flow.leave()
        launch.handOff(to: try #require(flow.pendingHandOff), openWindow: WindowOpener { _ in })
        #expect(launch.navigation.requestedSetup == nil)
        #expect(launch.navigation.requestedPendingRequestID == review)
        // The stage fades and closes; then the shell comes up. Were the stage
        // asked for again, it would only be brought forward.
        launch.stageAppeared(openWindow: WindowOpener { _ in })
        launch.stageDisappeared()
        recorder.showing = [.setup, .main]
        let shown = recorder.broughtForward.count
        let probe = Self.mainWindow(launch)
        defer { probe.close() }

        #expect(launch.isShellOpen)
        #expect(launch.flow == nil, "the shell opened the stage again")
        #expect(!recorder.broughtForward.dropFirst(shown).contains(.setup))
        #expect(launch.navigation.requestedPendingRequestID == review)
    }

    // MARK: - The controls

    /// Apps' toolbar: Set up this Mac…, which says what it does.
    @Test func appsSetUpThisMacOpensTheStageAtYourApps() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let recorder = AppLaunchStateTests.Recorder()
        let launch = try await Self.readyLaunch(fixture, on: "syncCenter", recorder: recorder)
        let probe = Self.mainWindow(launch)
        defer { probe.close() }
        let revision = launch.navigation.revision

        let button = try #require(probe.button(ActionTitles.setUpThisMacCommand(.palette)))
        #expect(button.help == LaunchpadCopy.Reentry.opensAtYourApps)
        #expect(probe.press(ActionTitles.setUpThisMacCommand(.palette)))

        Self.expectTheStageAtYourApps(launch, recorder)
        #expect(launch.navigation.revision == revision, "pressing it reached into the navigation queue")
    }

    /// Settings › General: Run setup again, whose button is Set up this Mac….
    @Test func settingsRunSetupAgainOpensTheStageAtYourApps() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let recorder = AppLaunchStateTests.Recorder()
        let launch = try await Self.readyLaunch(fixture, on: "settings", recorder: recorder)
        let review = UUID()
        launch.navigation.open(.pendingRequest(review))
        // The Apps route was already delivered; its review still waits while Settings is open.
        launch.navigation.consumeRequestedSection(.syncCenter)
        let probe = Self.mainWindow(launch)
        defer { probe.close() }

        #expect(probe.contains(LaunchpadCopy.Reentry.settingsCard))
        #expect(probe.contains(LaunchpadCopy.Reentry.runSetupAgain))
        #expect(probe.contains(LaunchpadCopy.Reentry.opensAtYourApps))
        // VoiceOver reads the row's words and its button, not its glyph's name.
        #expect(!probe.contains(SetUpThisMacButton.symbol))
        #expect(probe.press(ActionTitles.setUpThisMacCommand(.palette)))

        Self.expectTheStageAtYourApps(launch, recorder)
        #expect(launch.navigation.requestedPendingRequestID == review)
    }

    /// The palette: Set up this Mac…, from the sidebar's search.
    @Test func thePalettesSetUpThisMacOpensTheStageAtYourApps() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let recorder = AppLaunchStateTests.Recorder()
        let launch = try await Self.readyLaunch(fixture, on: "overview", recorder: recorder)
        let review = UUID()
        launch.navigation.open(.pendingRequest(review))
        let probe = Self.mainWindow(launch)
        defer { probe.close() }

        #expect(probe.press("Search everything"))
        #expect(probe.press(ActionTitles.setUpThisMacCommand(.palette) + ", ", prefix: true))
        // The palette hands its choice to the shell on the main actor's next
        // turn, which this test holds until it yields.
        await Task.yield()
        probe.settle()

        Self.expectTheStageAtYourApps(launch, recorder)
        #expect(launch.navigation.requestedPendingRequestID == review)
    }

    /// The app menu: Set Up This Mac…, once the main window owns the app.
    /// While a first run is on the stage it is off, and pressing it leaves
    /// the walk where it is.
    @Test func theAppMenusSetUpThisMacOpensTheStageAtYourApps() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let quiet = AppLaunchStateTests.Recorder()
        let firstRun = AppLaunchStateTests.launch(fixture, recorder: quiet)
        let walk = try #require(firstRun.flow)
        let during = AccessibilityProbe(SetUpThisMacCommand(launch: firstRun), size: Self.commandSize)
        #expect(during.button(ActionTitles.setUpThisMacCommand(.menu))?.isEnabled == false)
        during.press(ActionTitles.setUpThisMacCommand(.menu))
        during.close()
        #expect(quiet.broughtForward.isEmpty)
        #expect(firstRun.flow === walk)
        #expect(walk.step == .welcome)

        let recorder = AppLaunchStateTests.Recorder()
        let launch = try await Self.readyLaunch(fixture, on: "overview", recorder: recorder)
        let review = UUID()
        launch.navigation.open(.pendingRequest(review))
        let probe = AccessibilityProbe(SetUpThisMacCommand(launch: launch), size: Self.commandSize)
        defer { probe.close() }

        #expect(probe.button(ActionTitles.setUpThisMacCommand(.menu))?.isEnabled == true)
        #expect(probe.press(ActionTitles.setUpThisMacCommand(.menu)))

        Self.expectTheStageAtYourApps(launch, recorder)
        #expect(launch.navigation.requestedPendingRequestID == review)
    }

    // MARK: - Helpers

    /// What a route may leave as it was: every request waiting in the queue.
    struct Waiting: Equatable {
        let section: AppSection?
        let skill: String?
        let item: String?
        let screen: ScreenRequest?
        let package: String?
        let client: ClientKind?
        let review: UUID?
        let creation: UUID?

        @MainActor init(_ navigation: AppNavigationState) {
            section = navigation.requestedSection
            skill = navigation.requestedSkillID
            item = navigation.requestedItemID
            screen = navigation.requestedScreenRequest
            package = navigation.requestedMarketplacePackageID
            client = navigation.selectedClient
            review = navigation.requestedPendingRequestID
            creation = navigation.requestedSkillCreationID
        }
    }

    /// The room the app menu's one item is drawn in here.
    static let commandSize = CGSize(width: 320, height: 80)

    /// A Mac whose library is set up, opened on `section`, with both windows
    /// on screen already, so showing either brings it forward and opens no
    /// window of its own.
    static func readyLaunch(
        _ fixture: LaunchpadFixture, on section: String, recorder: AppLaunchStateTests.Recorder
    ) async throws -> AppLaunchState {
        let sample = try await fixture.sample(.afterRead)
        sample.workspace.setupProgress.finish(items: FinishSetupItem.allCases, now: ClientHomeFixture.now)
        recorder.showing = [.setup, .main]
        let launch = AppLaunchStateTests.launch(fixture, arguments: ["--section", section], recorder: recorder)
        await launch.openExisting()
        #expect(launch.phase == .ready)
        #expect(launch.flow == nil)
        return launch
    }

    /// The main window's root, as the app hosts it, over `launch`.
    static func mainWindow(_ launch: AppLaunchState) -> AccessibilityProbe {
        AccessibilityProbe(MainWindowRoot(launch: launch), size: WindowSize.minimum)
    }

    /// The stage came forward at Your apps, on a walk of its own over the
    /// library, with no fork.
    static func expectTheStageAtYourApps(
        _ launch: AppLaunchState, _ recorder: AppLaunchStateTests.Recorder,
        _ location: SourceLocation = #_sourceLocation
    ) {
        #expect(launch.flow?.entry == .rerun, sourceLocation: location)
        #expect(launch.flow?.step == .apps, sourceLocation: location)
        #expect(launch.flow?.workspace != nil, sourceLocation: location)
        #expect(launch.pendingEntry == .rerun, sourceLocation: location)
        #expect(recorder.broughtForward.last == .setup, sourceLocation: location)
        #expect(launch.phase == .ready, sourceLocation: location)
    }
}

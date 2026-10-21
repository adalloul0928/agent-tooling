import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Captures Home's setup card states and the main window's loading/error states
/// at 1440 × 900. The hidden-card sidebar chip is captured separately because
/// the shell capture cannot draw it. Enabled by `AGENT_TOOLING_SCREEN_GALLERY`.
@Suite("Gallery · Launchpad shell", .serialized, .enabled(if: GalleryOutput.isOn), .timeLimit(.minutes(5)))
@MainActor
struct GalleryLaunchpadShellTests {
    private static let both: [RenderAppearance] = [.light, .dark]
    private static let homeSource = "Sources/AgentToolingApp/OverviewView.swift"
    private static let rootSource = "Sources/AgentToolingApp/Launchpad/AppWindowRoots.swift"

    @Test func homeAsTheStageHandsOff() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let workspace = try await ShellGalleryWalk.handedOff(fixture)
            try Self.snap(ShellGalleryWalk.shell(workspace), "3 of 7 done", appearance)
        }
    }

    @Test func homeAfterAFirstRunLeftForLater() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let sample = try await fixture.sample(.afterLibrary)
            sample.workspace.setupProgress.deferSetup(at: .place, now: ClientHomeFixture.now)
            #expect(sample.workspace.setupProgress.status == .deferred(.place, path: .startHere, seenPreferences: false))
            try Self.snap(ShellGalleryWalk.shell(sample.workspace), "left for later at Put in apps", appearance)
        }
    }

    @Test func homeWithEveryRowDone() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let workspace = try await ShellGalleryWalk.handedOff(fixture)
            // The record's own rows, each ticked where it is done, as the
            // tracker ticks them.
            let items = try #require(workspace.setupProgress.record?.items)
            for item in items {
                workspace.setupProgress.tick(item, place: item.canonicalPlace, now: FinishSetupFixture.doneAt)
            }
            try Self.snap(ShellGalleryWalk.shell(workspace), "every row done", appearance)
        }
    }

    @Test func homeWithTheCopyKeptOutsideApplications() async throws {
        let outside = FinishSetupServices(
            installation: { home in
                let bundle = home.appending(path: "Downloads/Agent Tooling.app", directoryHint: .isDirectory)
                return AgentToolingInstallation(
                    bundleURL: bundle, location: .elsewhere(bundle.deletingLastPathComponent()),
                    mcpHelperURL: bundle.appending(path: "Contents/Helpers/agent-tooling-mcp"), cliHelperURL: nil,
                    isAdHocSigned: false)
            },
            raycast: { _ in .appOnly })
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let workspace = try await ShellGalleryWalk.handedOff(fixture)
            // The card reads where the copy runs in a task once it shows, and
            // only then adds the Move row: the capture waits for the row.
            try await galleryShellSnapshot(
                ShellGalleryWalk.shell(workspace, services: outside), area: "Launchpad", screen: Self.homeScreen,
                state: "outside Applications", size: GallerySize.standard, appearance: appearance, source: Self.homeSource
            ) { probe in
                probe.elements.contains { $0.label.contains(LaunchpadCopy.FinishSetup.moveTitle) }
            }
        }
    }

    @Test func homeWithTheCardHidden() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let workspace = try await ShellGalleryWalk.handedOff(fixture)
            workspace.setupProgress.setChecklistHidden(true, now: FinishSetupFixture.doneAt)
            try Self.snap(
                ShellGalleryWalk.shell(workspace), "card hidden", appearance,
                note: "the card's chip sits in the sidebar, which this capture cannot draw; P01 sidebar chip draws it")
        }
    }

    @Test func homeOnAWorkspaceMadeBeforeSetup() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            var preferences = fixture.seed.preferences
            preferences.assistantRuns = nil
            let workspace = try await WorkspaceLaunch.create(
                observations: fixture.orderedObservations, preferences: preferences, supportRoot: fixture.support,
                homeRoot: fixture.home, beforeRecord: { _ in }, services: fixture.environment.sessions)
            await workspace.library.refresh()
            #expect(workspace.setupProgress.status == .legacy)
            try Self.snap(ShellGalleryWalk.shell(workspace), "made before setup, the notice", appearance)
        }
    }

    /// The main window while the library opens: `MainWindowRoot` itself, for a
    /// launch whose library record names a store, captured before the open
    /// can land (the main actor is busy drawing the window), then let finish.
    @Test func theMainWindowWhileTheLibraryOpens() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let locator = try WorkspaceLocator(root: fixture.support)
            try locator.write(WorkspaceLocator.Record(workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID()))
            let launch = AppLaunchStateTests.launch(fixture)
            try #require(launch.phase == .opening)
            try galleryShellSnapshot(
                MainWindowRoot(launch: launch), area: "Launchpad", screen: Self.mainScreen, state: "opening",
                appearance: appearance, source: Self.rootSource)
            #expect(launch.phase == .opening, "the library opened before its capture, which shows \(launch.phase)")
            await launch.openExisting()
        }
    }

    /// The main window when this Mac's library record was read but its
    /// library would not open: a launch whose record names a store that is
    /// not there, after its open.
    @Test func theMainWindowWhenTheLibraryWouldNotOpen() async throws {
        for appearance in Self.both {
            let fixture = try await LaunchpadFixture()
            defer { fixture.remove() }
            let locator = try WorkspaceLocator(root: fixture.support)
            try locator.write(WorkspaceLocator.Record(workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID()))
            let launch = AppLaunchStateTests.launch(fixture)
            await launch.openExisting()
            guard case .failed = launch.phase else {
                Issue.record("a store that is not there opened: \(launch.phase)")
                return
            }
            try galleryShellSnapshot(
                MainWindowRoot(launch: launch), area: "Launchpad", screen: Self.mainScreen, state: "could not open",
                appearance: appearance, source: Self.rootSource)
        }
    }

    // MARK: - Helpers

    /// The index's names for the two windows; their files are `p01-home-…`
    /// and `main-window-…`, after the mockup's `14-p01-home`.
    private static let homeScreen = "P01 Home"
    private static let mainScreen = "Main window"

    /// Home at the main window's size, in the Launchpad area beside the
    /// stage's screens.
    private static func snap(
        _ view: some View, _ state: String, _ appearance: RenderAppearance, note: String? = nil
    ) throws {
        try galleryShellSnapshot(
            view, area: "Launchpad", screen: homeScreen, state: state, size: GallerySize.standard, appearance: appearance,
            source: homeSource, note: note)
    }
}

/// The walk to Home the shell's captures start from.
@MainActor
private enum ShellGalleryWalk {
    /// Juniper after its install, walked through Done's Go to Home, holding
    /// what P01 draws: shared just now, and the four project folders its read
    /// counted in Claude Code's history.
    static func handedOff(_ fixture: LaunchpadFixture) async throws -> WorkspaceLaunch.Workspace {
        let (flow, sample) = try await fixture.flow(at: .afterInstall)
        flow.outcomes.sync = .init(
            address: FinishSetupFixture.remote, publishedAt: ClientHomeFixture.now, upToDate: true)
        sample.workspace.setupProgress.recordEvidence { $0.projectFolderCount = 4 }
        flow.go(to: .done)
        await LaunchpadDoneScreen.model(flow).appear(flow)
        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        #expect(flow.pendingHandOff == .overview)
        return sample.workspace
    }

    /// The shell on Home, still, at the sample world's clock, reading nothing
    /// of this Mac.
    static func shell(
        _ workspace: WorkspaceLaunch.Workspace, services: FinishSetupServices = FinishSetupFixture.services
    ) -> some View {
        AppShellView(workspace: workspace, initialSection: .overview)
            .environment(\.snapshotNow, ClientHomeFixture.now)
            .environment(\.stageMotion, .still)
            .environment(\.finishSetupServices, services)
            .environment(\.skillTrialOpening) { _ in RecordingSkillTrialOpening(available: []) }
    }
}

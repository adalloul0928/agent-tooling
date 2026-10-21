import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// The stage's window and the screens WP0c draws in it: Welcome, the
/// unreadable screen in each of its three states, and the stage window's root
/// for each phase a launch can give it, in light and dark, at the stage's
/// size; the window's own configuration, with a sheet and a child window over
/// it; the main window's root handing the launch its opener; and the Kiro
/// mark the stage's tiles draw, at the optical size of the other apps' marks.
@Suite("Launchpad window renders", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct LaunchpadWindowRenderTests {
    // MARK: - Welcome

    @Test(arguments: [RenderAppearance.light, .dark])
    func welcomeDraws(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        #expect(flow.step == .welcome)

        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
        // The keyboard on Join's row: the primary follows it.
        LaunchpadWelcomeScreen.choice(flow).focus(.join)
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)
        // FooterConfirm before the commit point.
        flow.requestClose()
        try expectDrawn(fixture.stage(flow), size: WindowSize.stage, appearance: appearance)

        // Drawing Welcome reads nothing, runs nothing and writes nothing.
        #expect(fixture.firstReads.started.isEmpty)
        #expect(fixture.signIn.shellProbes == 0)
        #expect(fixture.observer.fullChecks == 0)
        #expect(!fixture.hasWorkspace)
    }

    /// Welcome's two rows are where the eye and the keyboard decide, so the
    /// image must change when the keyboard moves from one to the other.
    @Test func movingTheKeyboardMovesTheHighlightAndThePrimary() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let flow = fixture.flow()
        let start = try rasterize(fixture.stage(flow), size: WindowSize.stage).tiffRepresentation

        LaunchpadWelcomeScreen.choice(flow).focus(.join)
        let join = try rasterize(fixture.stage(flow), size: WindowSize.stage).tiffRepresentation

        #expect(start != join)
        #expect(LaunchpadStageView.footer(for: flow).primary?.title == LaunchpadCopy.Welcome.joinPrimary)
    }

    /// Under Reduce Motion the knobs are drawn at rest and nothing staggers
    /// in: Welcome's first frame is already its last, the one a still draws.
    @Test func underReduceMotionWelcomeDrawsItsFinalFrameAtOnce() async throws {
        let still = try await LaunchpadFixture(motion: .still)
        defer { still.remove() }
        let reduced = try await LaunchpadFixture(motion: .reduced)
        defer { reduced.remove() }

        let atRest = try rasterize(still.stage(still.flow()), size: WindowSize.stage)
        let first = try rasterize(reduced.stage(reduced.flow()), size: WindowSize.stage)

        // The mark, the places, the words and the rows; not the footer, whose
        // glass may still be settling in either capture.
        let expected = Self.contentSamples(of: atRest)
        let drawn = Self.contentSamples(of: first)
        let differing = zip(drawn, expected).filter { $0 != $1 }.count
        #expect(drawn.count == expected.count && differing == 0, "\(differing) of \(expected.count) samples differ")
    }

    // MARK: - The unreadable screen

    @Test(arguments: [RenderAppearance.light, .dark])
    func everyUnreadableStateDraws(appearance: RenderAppearance) throws {
        let reasons: [AppLaunchState.UnreadableReason] = [
            .newerFormat, .damaged, .io(WorkspaceLocatorError.unreadable.localizedDescription),
        ]
        for reason in reasons {
            try expectDrawn(LaunchpadUnreadableScreen(reason: reason), size: WindowSize.stage, appearance: appearance)
        }
    }

    // MARK: - The stage's window

    /// The window's root shows what the launch gave it: Welcome for a first
    /// run, the unreadable screen for a record that cannot be read, and a
    /// quiet stage while a first run's library opens to carry on.
    @Test(arguments: [RenderAppearance.light, .dark])
    func theStageWindowShowsWhatTheLaunchOwns(appearance: RenderAppearance) async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let firstRun = AppLaunchStateTests.launch(fixture)
        try expectDrawn(SetupStageWindow(launch: firstRun), size: WindowSize.stage, appearance: appearance)

        let unreadable = try await LaunchpadFixture()
        defer { unreadable.remove() }
        try Data("not json at all".utf8).write(to: unreadable.support.appending(path: WorkspaceLocator.recordFileName))
        let damaged = AppLaunchStateTests.launch(unreadable)
        #expect(damaged.phase == .unreadable(.damaged))
        try expectDrawn(SetupStageWindow(launch: damaged), size: WindowSize.stage, appearance: appearance)

        let carrying = try await LaunchpadFixture()
        defer { carrying.remove() }
        _ = try await carrying.sample(.afterRead)
        let opening = AppLaunchStateTests.launch(carrying)
        #expect(opening.flow == nil)
        try expectDrawn(SetupStageWindow(launch: opening), size: WindowSize.stage, appearance: appearance)
        await opening.openExisting()
        #expect(opening.flow?.step == .found)
        try expectDrawn(SetupStageWindow(launch: opening), size: WindowSize.stage, appearance: appearance)
    }

    /// SwiftUI sizes the stage's window to its content and the title bar's
    /// safe area above it: the stage is exactly 860 × 640 from the window's
    /// top edge, with nothing under the footer.
    @Test func theStagesWindowIsExactlyTheStage() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let launch = AppLaunchStateTests.launch(fixture)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: WindowSize.stage), styleMask: LateContentHarness.stageWindowStyle,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let host = NSHostingView(rootView: SetupStageWindow(launch: launch))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        Self.settle(window)

        #expect(host.fittingSize == WindowSize.stage)
        #expect(window.frame.size == WindowSize.stage)
        // The title bar takes its band from the top of the stage, which the
        // stage's drag band fills.
        #expect(window.contentLayoutRect.height == WindowSize.stage.height - SetupStageWindow.titleBarHeight)
    }

    /// The setup role turns zoom, full screen and tabs off, stamps the
    /// stage's identifier, sends the red button to FooterConfirm instead of
    /// closing the window, reports key changes, and puts it all back when the
    /// view updates. The window's delegate is never touched.
    @Test func theSetupRoleConfiguresTheStagesWindow() throws {
        let probe = ConfiguratorProbe()
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: WindowSize.stage), styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = WindowDelegateMarker()
        window.delegate = delegate
        window.contentView = NSHostingView(rootView: ConfiguratorHost(probe: probe, role: .setup))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        Self.settle(window)

        #expect(window.identifier == AppWindow.setup.identifier)
        #expect(window.standardWindowButton(.zoomButton)?.isEnabled == false)
        #expect(window.collectionBehavior.contains(.fullScreenNone))
        #expect(window.tabbingMode == .disallowed)
        #expect(window.delegate === delegate)

        try Self.press(window.standardWindowButton(.closeButton))
        #expect(probe.closes == 1)
        #expect(window.isVisible)

        // SwiftUI may rebuild the title bar's buttons: an update re-applies.
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        window.collectionBehavior.remove(.fullScreenNone)
        window.standardWindowButton(.closeButton)?.target = window
        window.standardWindowButton(.closeButton)?.action = #selector(NSWindow.performClose(_:))
        probe.tick += 1
        Self.settle(window)
        #expect(window.standardWindowButton(.zoomButton)?.isEnabled == false)
        #expect(window.collectionBehavior.contains(.fullScreenNone))
        try Self.press(window.standardWindowButton(.closeButton))
        #expect(probe.closes == 2)
        #expect(window.delegate === delegate)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(probe.keys.last == true)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(probe.keys.last == false)

        // A sheet over the stage (S08's) is the stage's: while it is key, the
        // stage is, so the app's commands stay off.
        let sheet = Self.window(CGSize(width: 320, height: 200))
        window.beginSheet(sheet)
        defer { window.endSheet(sheet) }
        #expect(sheet.sheetParent === window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: sheet)
        #expect(probe.keys.last == true)
        // A window of its own is not.
        let other = Self.window(CGSize(width: 320, height: 200))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: sheet)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        #expect(probe.keys.last == false)
        // A child window over it, as a popover's is, is the stage's too.
        let child = Self.window(CGSize(width: 200, height: 120))
        window.addChildWindow(child, ordered: .above)
        defer { window.removeChildWindow(child) }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: child)
        #expect(probe.keys.last == true)
        #expect(window.delegate === delegate)
    }

    /// The main window's root hands the launch its opener as it appears, on a
    /// launch that never showed the stage, so a Dock click opens the main
    /// window again once the person has closed it.
    @Test func theMainWindowHandsTheLaunchItsOpenerAsItAppears() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        // A library whose store will not open: the main window says why, and
        // draws nothing heavier.
        let locator = try WorkspaceLocator(root: fixture.support)
        try locator.write(WorkspaceLocator.Record(workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID()))
        let launch = AppLaunchStateTests.launch(fixture)
        await launch.openExisting()
        guard case .failed = launch.phase else {
            Issue.record("a store that is not there opened: \(launch.phase)")
            return
        }
        #expect(launch.reopen(hasVisibleWindows: false), "no window has handed in an opener yet")

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: WindowSize.minimum),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainWindowRoot(launch: launch))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        Self.settle(window)

        #expect(!launch.reopen(hasVisibleWindows: false), "the main window's root handed in no opener")
    }

    /// The main role is the main window's as it always was: its identifier,
    /// and nothing of the stage's.
    @Test func theMainRoleLeavesTheMainWindowAsItWas() throws {
        let probe = ConfiguratorProbe()
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: WindowSize.stage),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ConfiguratorHost(probe: probe, role: .main))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        Self.settle(window)

        #expect(window.identifier == AppWindow.main.identifier)
        #expect(window.standardWindowButton(.zoomButton)?.isEnabled == true)
        #expect(!window.collectionBehavior.contains(.fullScreenNone))
        // AppKit's own close: the button still asks the window.
        #expect(window.standardWindowButton(.closeButton)?.target === window)
    }

    // MARK: - Helpers

    /// What a click on `button` does: its action, sent to its target. A
    /// title-bar button's `performClick` stops the test process's main run
    /// loop, which ends the whole run, so the action is sent as the click
    /// would send it.
    private static func press(_ button: NSButton?) throws {
        let button = try #require(button)
        let action = try #require(button.action)
        #expect(NSApp.sendAction(action, to: button.target, from: button))
    }

    private static func settle(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// A plain window that stays alive once it is closed.
    private static func window(_ size: CGSize) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The colours on a grid over the stage's content, between the drag band
    /// and the footer.
    static func contentSamples(of bitmap: NSBitmapImageRep) -> [UInt32] {
        let scale = CGFloat(bitmap.pixelsHigh) / WindowSize.stage.height
        let top = Int(StageLayout.Grid.contentTop * scale)
        let bottom = Int(StageLayout.Grid.lastLine * scale)
        var samples: [UInt32] = []
        for y in stride(from: top, to: bottom, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                samples.append(
                    UInt32(colour.alphaComponent * 255) << 24 | UInt32(colour.redComponent * 255) << 16
                        | UInt32(colour.greenComponent * 255) << 8 | UInt32(colour.blueComponent * 255))
            }
        }
        return samples
    }

}

/// What a configured window reported.
@MainActor @Observable
private final class ConfiguratorProbe {
    var tick = 0
    var closes = 0
    var keys: [Bool] = []
}

/// A view that configures its window, and redraws when the probe ticks so
/// the configurator updates.
private struct ConfiguratorHost: View {
    let probe: ConfiguratorProbe
    let role: AppWindow

    var body: some View {
        Text("\(probe.tick)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                WindowConfigurator(
                    role: role, onCloseButton: { probe.closes += 1 }, onKeyChange: { probe.keys.append($0) }))
    }
}

/// A delegate the window had before the configurator saw it.
@MainActor
private final class WindowDelegateMarker: NSObject, NSWindowDelegate {}

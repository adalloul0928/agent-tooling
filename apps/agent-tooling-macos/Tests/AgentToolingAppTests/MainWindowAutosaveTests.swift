import AgentToolingCore
import AgentToolingTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Verifies scratch launches do not write window frames or split-view dividers
/// to app defaults. AppKit ignores custom preference suites for autosave, so tests
/// use unique SwiftUI-style window names and remove their keys afterward. Includes
/// the loading-to-shell transition that changes toolbar layout.
@Suite("Main window · a scratch run's frames", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct MainWindowAutosaveTests {
    @Test func aScratchRunWritesNoFrameIntoTheAppsDefaults() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let suite = fixture.support.appending(path: "scratch-run-defaults.plist").path(percentEncoded: false)
        let names = Names()
        defer { names.forget() }

        let window = try await Self.mainWindow(fixture, arguments: ["--defaults-suite", suite], names: names)
        defer { window.orderOut(nil) }

        #expect(window.frameAutosaveName.isEmpty, "the window still saves its frame as \(window.frameAutosaveName)")
        #expect(Self.splitViews(in: window).allSatisfy { $0.autosaveName == nil }, "a split view still saves its dividers")
        #expect(names.written.isEmpty, "the scratch run wrote \(names.written) into the app's own defaults")
    }

    /// The same window in an ordinary launch keeps both names, and AppKit
    /// writes under them: what the scratch run's check would see if the
    /// window kept saving.
    @Test func anOrdinaryLaunchKeepsSavingItsFrames() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let names = Names()
        defer { names.forget() }

        let window = try await Self.mainWindow(fixture, arguments: [], names: names)
        defer { window.orderOut(nil) }

        #expect(window.frameAutosaveName == names.frame)
        #expect(names.written.contains("NSWindow Frame \(names.frame)"), "AppKit wrote no frame: \(names.written)")
        #expect(
            names.written.contains("NSSplitView Subview Frames \(names.split)"), "AppKit wrote no dividers: \(names.written)")
    }

    // MARK: - Helpers

    /// This run's own autosave names, and what was written under them.
    private final class Names {
        let frame = "agent-tooling-autosave-test-\(UUID().uuidString)"
        var split: String { "\(frame), SidebarNavigationSplitView" }

        /// The keys in the test runner's own defaults that carry this run's
        /// names.
        var written: [String] {
            UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.contains(frame) }.sorted()
        }

        func forget() {
            for key in written { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// A launch with `arguments` on a Mac that has a library, its main
    /// window's root in a window named as a scene's: shown while the library
    /// opens, then with the shell, its split view named as a scene's, then
    /// resized twice, the way a person drags it.
    private static func mainWindow(_ fixture: LaunchpadFixture, arguments: [String], names: Names) async throws -> NSWindow {
        let sample = try await fixture.sample(.afterRead)
        sample.workspace.setupProgress.finish(items: FinishSetupItem.allCases, now: ClientHomeFixture.now)
        let launch = AppLaunchStateTests.launch(fixture, arguments: arguments)
        try #require(launch.phase == .opening)

        let size = WindowSize.standard
        let host = NSHostingView(rootView: MainWindowRoot(launch: launch).launchPreferences(launch.defaults))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(names.frame)
        window.contentView = host
        window.orderFrontRegardless()
        settle()
        // The open could not land while the window drew: the main actor was
        // busy drawing it.
        try #require(launch.phase == .opening, "the library opened before its window drew")

        await launch.openExisting()
        try #require(launch.phase == .ready)
        settle()
        let split = try #require(splitViews(in: window).first, "the shell drew no split view")
        split.autosaveName = names.split
        for grown in [CGSize(width: size.width + 40, height: size.height + 20), size] {
            window.setFrame(CGRect(origin: window.frame.origin, size: grown), display: true)
            settle()
        }
        return window
    }

    private static func splitViews(in window: NSWindow) -> [NSSplitView] {
        func found(in view: NSView) -> [NSSplitView] {
            ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(found)
        }
        return window.contentView.map(found) ?? []
    }

    /// Lets the main run loop turn, so AppKit's own saves land.
    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }
}

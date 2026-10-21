import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Detects window-height changes after late content arrives. AppKit may measure
/// hosted minimum height at zero width, expanding content beyond the window.
/// Hosts, settles, updates and remeasures both resizable shell and fixed-size
/// setup windows.
@MainActor
enum LateContentHarness {
    /// The main window, as `LateContentLayoutTests` has always measured it.
    static let mainWindowSize = CGSize(width: 1_440, height: 860)
    static let mainWindowStyle: NSWindow.StyleMask = [.titled, .closable, .resizable, .fullSizeContentView]
    /// The setup stage: titled, fixed, its content under the title bar.
    static let stageWindowStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]

    /// AppKit may constrain the requested size to the display. The settled
    /// content height is the bound that both the window and hosted view must
    /// keep when `change` introduces more content.
    static func heightAfterChange(
        _ view: some View,
        windowSize: CGSize = mainWindowSize,
        styleMask: NSWindow.StyleMask = mainWindowStyle,
        change: () async -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> (hostHeight: CGFloat, windowHeight: CGFloat) {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: windowSize),
            styleMask: styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: AnyView(view))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        spin(0.3)
        host.layoutSubtreeIfNeeded()
        let windowHeight = window.contentRect(forFrameRect: window.frame).height
        try #require(windowHeight > 0, "the window has no content area", sourceLocation: sourceLocation)
        #expect(
            host.frame.height == windowHeight, "the screen did not fit the window before the change",
            sourceLocation: sourceLocation)
        await change()
        spin(0.5)
        host.layoutSubtreeIfNeeded()
        #expect(
            window.contentRect(forFrameRect: window.frame).height == windowHeight, "the late content resized the window",
            sourceLocation: sourceLocation)
        return (host.frame.height, windowHeight)
    }

    private static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

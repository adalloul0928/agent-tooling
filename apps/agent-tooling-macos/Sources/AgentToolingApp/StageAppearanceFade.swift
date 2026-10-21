import AppKit
import QuartzCore
import SwiftUI

/// Crossfades the setup window when its appearance changes, including under
/// Reduce Motion. An `Anchor` identifies the content layer; relayout and drawing
/// occur in the same Core Animation transaction. Without an anchor, appearance
/// changes immediately.
@MainActor
final class StageAppearanceFade {
    /// The window the stage is drawn in, once the anchor is in one.
    weak var window: NSWindow?

    /// The key the fade is found under on the content layer: Core Animation
    /// files every transition under this one, whatever key it is added with.
    static let transitionKey = kCATransition

    /// Makes `appearance` the stage's, running `record` (which keeps the
    /// choice) inside the fade.
    func apply(_ appearance: AppAppearance, record: () -> Void) {
        guard let window, let content = window.contentView else {
            record()
            return
        }
        content.wantsLayer = true
        let fade = CATransition()
        fade.type = .fade
        fade.duration = StageLayout.Behave.appearanceFade
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        content.layer?.add(fade, forKey: Self.transitionKey)
        window.appearance = appearance.nsAppearance
        record()
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// Tells `fade` the window it is drawn in. Takes no room and no events.
    struct Anchor: NSViewRepresentable {
        let fade: StageAppearanceFade

        func makeNSView(context: Context) -> AnchorView {
            let view = AnchorView()
            view.fade = fade
            return view
        }

        func updateNSView(_ nsView: AnchorView, context: Context) {
            nsView.fade = fade
            fade.window = nsView.window
        }
    }

    final class AnchorView: NSView {
        weak var fade: StageAppearanceFade?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            fade?.window = window
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension AppAppearance {
    /// The appearance a window is drawn in for this choice, or nil to follow
    /// macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension StageLayout.Behave {
    /// How long an appearance change crossfades the stage: the length of
    /// `AgentMotion.quick`, which a Core Animation fade cannot read from the
    /// animation itself. `LaunchpadPreferencesRenderTests` holds the two
    /// equal, so a change to `quick` that this copy misses fails there
    /// (until the motion tokens publish the duration on its own).
    static let appearanceFade: TimeInterval = 0.12
}

import AppKit
import Foundation
import SwiftUI
import Testing

/// A view in a real window, read and pressed the way VoiceOver reads and
/// presses it: through its accessibility elements.
///
/// A render test says a screen drew; this says what it offers, by the names a
/// person hears, and does what pressing one of them does, so a test can follow
/// a route from the control a person uses to where it lands. The window stays
/// up until `close()`, so a test can press, wait and look again.
@MainActor
final class AccessibilityProbe {
    /// One element: what it is called, what kind of thing it is, the text
    /// it shows (a static text's words are its value), its help, whether it
    /// can be used now, and where it sits on screen.
    struct Element {
        let label: String
        let role: NSAccessibility.Role?
        let value: String?
        let help: String?
        let isEnabled: Bool
        /// The element's frame in screen coordinates, as VoiceOver's cursor
        /// outlines it.
        let frame: CGRect
        fileprivate let node: AnyObject
    }

    private let window: NSWindow

    /// Hosts `view` at `size` in a window on screen, and lets it settle.
    init(_ view: some View, size: CGSize = shellWindowSize) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(
            contentRect: host.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        settle()
    }

    /// Reads `window` as it stands, without showing or settling it: a window
    /// something else made and shows. Its `close()` takes that window off
    /// screen.
    init(reading window: NSWindow) {
        self.window = window
    }

    /// Takes the window off screen.
    func close() {
        window.orderOut(nil)
    }

    /// Lets the main run loop turn, so what an action or a change started
    /// lands before the next look.
    func settle(for seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Every element in the window's content, depth first.
    var elements: [Element] {
        Self.whileRead {
            var found: [Element] = []
            if let content = window.contentView { Self.collect(content, depth: 0, into: &found) }
            return found
        }
    }

    /// Whether any element is called, or shows, `text`.
    func contains(_ text: String) -> Bool {
        elements.contains { $0.label == text || $0.value == text }
    }

    /// The first button called `label`.
    func button(_ label: String) -> Element? {
        elements.first { $0.role == .button && $0.label == label }
    }

    /// Presses the first button called `label`, or whose name starts with
    /// `label` when `prefix` is set, as VoiceOver's press does, then lets the
    /// window settle. Says whether a button was found and took the press.
    @discardableResult
    func press(_ label: String, prefix: Bool = false) -> Bool {
        let pressed = Self.whileRead {
            var found: [Element] = []
            if let content = window.contentView { Self.collect(content, depth: 0, into: &found) }
            let button = found.first { element in
                element.role == .button && (prefix ? element.label.hasPrefix(label) : element.label == label)
            }
            return button?.node.accessibilityPerformPress?() ?? false
        }
        settle()
        return pressed
    }

    /// Temporarily enables the private accessibility switch used by VoiceOver so
    /// SwiftUI exposes hosted elements. Checks selectors before KVC: an unknown key
    /// raises an Objective-C exception Swift cannot catch. Restores the switch after
    /// probing; unavailable selectors record an issue and skip enhancement.
    private static func whileRead<Value>(_ read: () -> Value) -> Value {
        let application = NSApplication.shared
        guard enhancedInterfaceSwitch.allSatisfy({ application.responds(to: $0) }) else {
            Issue.record("AXEnhancedUserInterface is not settable on this macOS")
            return read()
        }
        let key = "accessibilityEnhancedUserInterface"
        let before = application.value(forKey: key)
        application.setValue(true, forKey: key)
        defer { application.setValue(before, forKey: key) }
        return read()
    }

    /// The getter and setter key-value coding finds for the enhanced
    /// interface's key.
    private static let enhancedInterfaceSwitch = [
        NSSelectorFromString("isAccessibilityEnhancedUserInterface"),
        NSSelectorFromString("setAccessibilityEnhancedUserInterface:"),
    ]

    /// The elements under `object`, read by name: SwiftUI's own elements
    /// answer the accessibility messages without adopting the protocol that
    /// declares them, so each is asked as an object.
    private static func collect(_ object: Any, depth: Int, into found: inout [Element]) {
        guard depth < 80 else { return }
        let node = object as AnyObject
        let label = textAttribute(node, named: "accessibilityLabel") ?? textAttribute(node, named: "accessibilityTitle") ?? ""
        found.append(
            Element(
                label: label, role: node.accessibilityRole?() ?? nil, value: textAttribute(node, named: "accessibilityValue"),
                help: textAttribute(node, named: "accessibilityHelp"), isEnabled: node.isAccessibilityEnabled?() ?? true,
                frame: node.accessibilityFrame?() ?? .zero, node: node))
        for child in (node.accessibilityChildren?() ?? nil) ?? [] {
            collect(child, depth: depth + 1, into: &found)
        }
    }

    /// SwiftUI can return attributed text for selectors AppKit declares as NSString.
    /// Read the object before bridging so both representations keep their words.
    static func textAttribute(_ object: AnyObject, named name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard let node = object as? NSObject, node.responds(to: selector) else { return nil }
        let value = node.perform(selector)?.takeUnretainedValue()
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String
    }
}

import AppKit
import Foundation
import SwiftUI

/// The actual accessibility tree from a laid-out SwiftUI window. Critical
/// controls and recovery text must be reachable, not merely paint some pixels.
struct ShellAccessibilityElement {
    let identifier: String?
    let label: String?
    let value: String?
    let role: String?
    let isEnabled: Bool
}

@MainActor
func accessibilitySnapshot(_ view: some View) -> [ShellAccessibilityElement] {
    // SwiftUI lazily creates its virtual elements when an accessibility
    // client asks for the enhanced interface. This affects this test process
    // only; no system preference or assistive technology is changed.
    let application = NSApplication.shared
    application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
    let host = NSHostingView(rootView: AnyView(view.frame(width: shellWindowSize.width, height: shellWindowSize.height)))
    host.frame = CGRect(origin: .zero, size: shellWindowSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    host.layoutSubtreeIfNeeded()

    var elements: [ShellAccessibilityElement] = []
    var visited = Set<ObjectIdentifier>()
    func collect(_ object: Any) {
        // SwiftUI's virtual AccessibilityNode objects expose the documented
        // accessibility getters without declaring NSAccessibilityProtocol
        // conformance. KVC boxes Boolean getters and preserves these nodes.
        guard let item = object as? NSObject,
            visited.insert(ObjectIdentifier(item)).inserted
        else { return }
        func value(_ key: String, selector: String? = nil) -> Any? {
            guard item.responds(to: NSSelectorFromString(selector ?? key)) else { return nil }
            return item.value(forKey: key)
        }
        elements.append(
            .init(
                identifier: value("accessibilityIdentifier") as? String,
                label: value("accessibilityLabel") as? String,
                value: value("accessibilityValue") as? String,
                role: value("accessibilityRole") as? String,
                isEnabled: value("accessibilityEnabled", selector: "isAccessibilityEnabled") as? Bool ?? false))
        for child in value("accessibilityChildren") as? [Any] ?? [] { collect(child) }
    }
    collect(host)
    return elements
}

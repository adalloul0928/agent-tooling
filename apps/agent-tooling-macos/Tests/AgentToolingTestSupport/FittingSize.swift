import AppKit
import SwiftUI

/// The size a view lays itself out at when nothing constrains it, for a test
/// that measures a primitive against its own few points rather than against a
/// window: the view is hosted on its own at `fixedSize()`.
///
/// Nil when the view lays out to nothing in either direction, so a suite can
/// `#require` the size; this target cannot import Testing itself.
@MainActor
public func fittingSize(of view: some View) -> CGSize? {
    let host = NSHostingView(rootView: AnyView(view.fixedSize()))
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    return size.width > 0 && size.height > 0 ? size : nil
}

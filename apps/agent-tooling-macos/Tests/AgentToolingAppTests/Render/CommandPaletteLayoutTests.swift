import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp

/// Opening the palette must not move the page under it. The shift this guards
/// against only shows in a window with a toolbar: with hit testing switched
/// off on the split view itself, the detail column dropped its toolbar inset
/// and the whole page jumped up under the title bar.
@MainActor
struct CommandPaletteLayoutTests {
    @Test func openingThePaletteLeavesThePageWhereItWas() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let closed = try titleTop(render(fixture, palette: false))
        let open = try titleTop(render(fixture, palette: true))
        #expect(abs(closed - open) <= 2, "the page moved by \(open - closed) px when the palette opened")
    }

    /// The shell in a titled, full-size-content window with a toolbar, as the
    /// app shows it; the borderless harness window has no inset to lose.
    private func render(_ fixture: ShellRenderFixture, palette: Bool) throws -> NSBitmapImageRep {
        let size = shellWindowSize
        let view = AppShellView(workspace: fixture.workspace, initialSection: .overview, paletteVisible: palette)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "palette-layout")
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// The first row, from the top, with anything drawn in the strip where the
    /// page title sits. The toolbar strip above it is empty there; the first
    /// mark is the top of "Home". The scrim dims the row evenly, so contrast
    /// within the row finds the title whether or not the palette is open.
    private func titleTop(_ bitmap: NSBitmapImageRep) throws -> Int {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let x0 = Int(Double(width) * 0.24)
        let x1 = Int(Double(width) * 0.30)
        for y in 0..<(height / 4) {
            var low = 1.0
            var high = 0.0
            for x in stride(from: x0, to: x1, by: 2) {
                let c = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let lum = Double(0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent)
                low = min(low, lum)
                high = max(high, lum)
            }
            if high - low > 0.15 { return y }
        }
        throw NoTitle()
    }

    private struct NoTitle: Error {}
}

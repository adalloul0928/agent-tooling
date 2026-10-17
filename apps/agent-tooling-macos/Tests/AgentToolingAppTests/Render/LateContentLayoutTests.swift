import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// A banner that arrives after the window has laid out must not change what
/// the window asks for. On macOS, AppKit re-measures the hosted content's
/// minimum size when it changes, and a view whose minimum height is answered
/// at zero width can make that minimum taller than the window; the whole
/// split view then grows past the window and sits centred in it, which a
/// person sees as the screen shifting up out of frame. Activity's drift
/// notice did exactly this.
@Suite("Content arriving after layout", .serialized)
@MainActor
struct LateContentLayoutTests {
    private static let windowSize = CGSize(width: 1_440, height: 860)

    private func drift(_ count: Int) -> [InstalledPackageDrift] {
        (0..<count).map { index in
            InstalledPackageDrift(
                destinationPath: "/Users/someone/.claude/skills/removed-skill-\(index)",
                packageName: "removed-skill-\(index)", state: .removed, reviewedFingerprint: "abc", reviewedAt: .now)
        }
    }

    /// Hosts the view in a titled window, runs `change`, and returns the
    /// hosting view's height afterwards. It must still be the window's.
    private func heightAfterChange(_ view: some View, change: () async -> Void) async throws -> CGFloat {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: AnyView(view))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        Self.spin(0.3)
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.height == Self.windowSize.height, "the screen did not fit the window before the change")
        await change()
        Self.spin(0.5)
        host.layoutSubtreeIfNeeded()
        return host.frame.height
    }

    @MainActor private static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Test func aDriftNoticeArrivingLateKeepsActivityInTheWindow() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        try fixture.seedActivity()
        let session = WorkspaceActivitySession(store: fixture.store)
        await session.refresh(driftReader: StubInstallDriftReader(reports: []))

        let height = try await heightAfterChange(ActivityView(session: session).environment(AppNavigationState())) {
            await session.refresh(driftReader: StubInstallDriftReader(reports: drift(3)))
        }

        #expect(session.drift.count == 3)
        #expect(height == Self.windowSize.height, "the drift notice made the screen taller than the window")
    }

    /// The layout behind `wrapsLines()`, on its own: a wrapping sentence
    /// inserted above a scroll view after first layout.
    @Test func wrappingTextArrivingLateKeepsTheScreenInTheWindow() async throws {
        let shown = LateBannerHost.Shown()
        let height = try await heightAfterChange(LateBannerHost(shown: shown)) {
            shown.value = true
        }
        #expect(height == Self.windowSize.height)
    }
}

private struct LateBannerHost: View {
    @Observable final class Shown { var value = false }
    let shown: Shown

    var body: some View {
        @Bindable var shown = shown
        VStack(spacing: 0) {
            Text("Toolbar").frame(height: Size.toolbarHeight)
            if shown.value {
                HStack {
                    Text("A sentence long enough to wrap when the width is narrow, which is what the minimum-size probe proposes.")
                        .wrapsLines()
                    Spacer()
                    Button("Review") {}
                }
                .padding(Space.lg)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<3) { index in Text("Row \(index)").frame(height: Size.rowHeight) }
                }
            }
            .collectionSurface()
        }
    }
}

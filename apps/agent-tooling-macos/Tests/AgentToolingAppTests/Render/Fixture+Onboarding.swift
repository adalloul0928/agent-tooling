import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The shapes the onboarding wizard reaches for, added to the shared fixture
/// rather than to the harness every screen uses.

/// `rasterize` in `ShellRenderHarness.swift` hosts a view in a bare
/// `NSHostingView` with no backing window. Every other section's primary
/// action happens to be disabled in its fixture's default state, so nothing
/// exposed this: an *enabled* `.buttonStyle(.glassProminent)` control — the
/// wizard's "Continue" is enabled from the first frame — does not finish
/// compositing before a synchronous `cacheDisplay` reads it back on this
/// toolchain, and the whole frame reads back as one flat colour, not just the
/// button. A disabled glass-prominent control, and every other primitive this
/// suite renders, is unaffected.
///
/// This is a gap in the shared harness, not in the screen: the same view
/// inside a real (if offscreen) window, given one run-loop turn to settle,
/// composites correctly — proved below before this was written as a
/// workaround rather than a guess. `ShellRenderHarness.swift` is frozen for
/// this scope, so the fix lives here instead of there; see the report's
/// "Needs a shared change" for lifting it into the shared helper.
@MainActor
func rasterizeWarmed(
    _ view: some View, _ location: SourceLocation = #_sourceLocation
) throws -> NSBitmapImageRep {
    let size = shellWindowSize
    let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()

    #expect(host.fittingSize.width > 0, "the screen laid out to no width", sourceLocation: location)
    #expect(host.fittingSize.height > 0, "the screen laid out to no height", sourceLocation: location)

    let bitmap = try #require(
        host.bitmapImageRepForCachingDisplay(in: host.bounds),
        "the screen produced no drawable area", sourceLocation: location)
    host.cacheDisplay(in: host.bounds, to: bitmap)
    window.orderOut(nil)
    return bitmap
}

@MainActor
func expectDrawnWarmed(
    _ view: some View, _ location: SourceLocation = #_sourceLocation
) throws {
    let bitmap = try rasterizeWarmed(view, location)
    #expect(
        distinctColours(in: bitmap) > 4, "the screen drew a blank frame",
        sourceLocation: location)
}

extension ShellRenderFixture {
    /// Saves one assignment for the standalone skill through the same path the
    /// wizard's own picker and `WorkspaceAssignmentSheet` use. This is what
    /// turns the assign step's "done" state on; nothing here writes a row
    /// directly.
    func assignForOnboarding(to surface: TargetSurface = .claudeCode) async {
        await workspace.library.reviewAssignments(
            artifactIDs: [Self.skill],
            destinations: [.init(surface: surface, scope: .user)])
        await workspace.library.applyReviewedAssignments()
    }
}

/// A library that a bare first run could really produce: one item a scan only
/// tracks, and nothing else. `WorkspaceFirstRun` never claims `centralPersonal`
/// or `nativeOwned` on someone's behalf, so a workspace with no plugin a
/// client already installed can legitimately hold nothing assignable at all —
/// the assign step has to stay honest about that rather than offering an
/// action ownership forbids.
@MainActor struct OnboardingTrackedOnlyFixture {
    static let server = ArtifactID()
    let root: URL
    let workspace: WorkspaceLaunch.Workspace

    init() async throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "onboarding-tracked-only-\(UUID())", directoryHint: .isDirectory)
        let container = root.appending(path: "store", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        for directory in [container, home] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let writerID = WorkspaceObjectID()
        let document = try WorkspaceDocumentCoding.seal(
            .init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                artifacts: [
                    .init(
                        identity: .init(id: Self.server, kind: .mcpServer, displayName: "Only Tracked Server"),
                        authority: .trackedOnly)
                ]))
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        let store = try WorkspaceRevisionStore(
            containerRoot: container, workspaceID: document.workspaceID, deviceID: device.deviceID)
        try store.initialize(document: document, device: device)
        workspace = WorkspaceLaunch.sessions(
            store: store, homeRoot: home, isFirstRun: true, deviceObserver: StubDeviceObserver())
        await workspace.library.refresh()
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

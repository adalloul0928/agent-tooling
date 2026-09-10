import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The shapes the onboarding wizard reaches for, added to the shared fixture
/// rather than to the harness every screen uses.

/// The wizard's "Continue" is enabled from the first frame, which is what
/// first showed that a bare hosting view cannot composite an enabled glass
/// control before a synchronous read-back. The shared harness now rasterizes
/// inside a real window; these two names remain for the wizard tests.
@MainActor
func rasterizeWarmed(
    _ view: some View, _ location: SourceLocation = #_sourceLocation
) throws -> NSBitmapImageRep {
    try rasterize(view, location)
}

@MainActor
func expectDrawnWarmed(
    _ view: some View, _ location: SourceLocation = #_sourceLocation
) throws {
    try expectDrawn(view, location)
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

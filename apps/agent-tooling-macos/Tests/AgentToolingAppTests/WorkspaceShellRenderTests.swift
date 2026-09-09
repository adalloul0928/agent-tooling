import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Every screen the shell can reach has to draw something over a real
/// workspace.
///
/// The sessions behind these views are covered elsewhere; what is not covered
/// by any of that is the screen itself failing to build, or laying out to
/// nothing. Both are invisible until someone opens the app, which is exactly
/// when it is most expensive to find out.
@Suite("Shell screens render")
@MainActor
struct WorkspaceShellRenderTests {
    @Test func theLibraryDrawsTheWorkspaceItWasGiven() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try expectDrawn(
            WorkspaceLibraryView(session: fixture.workspace.library,
                                 authoring: fixture.workspace.authoring,
                                 export: fixture.workspace.export))
    }

    @Test func firstRunDrawsBeforeAnythingIsAssigned() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try expectDrawn(WorkspaceOnboardingView(session: fixture.workspace.library) {})
    }

    @Test func projectsDraws() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try expectDrawn(WorkspaceProjectsView(session: fixture.workspace.library) { _ in })
    }

    @Test func presetsDraws() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let presets = try #require(fixture.workspace.presets)
        await presets.refresh()
        try expectDrawn(WorkspacePresetsView(session: presets, library: fixture.workspace.library))
    }

    @Test func installDraws() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try expectDrawn(WorkspaceDeploymentView(session: fixture.workspace.deployment))
    }

    @Test func appSettingsDraws() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await fixture.workspace.settings.refresh()
        try expectDrawn(WorkspaceSettingsView(session: fixture.workspace.settings))
    }

    @Test func syncDraws() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let sync = try #require(fixture.workspace.sync)
        sync.load()
        try expectDrawn(WorkspaceSyncView(session: sync))
    }

    @Test func historyDraws() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await fixture.workspace.history.refresh()
        try expectDrawn(WorkspaceHistoryView(session: fixture.workspace.history))
    }

    /// Proves the blank-frame check above can fail.
    ///
    /// Every test in this suite would pass on an app that opened to nothing if
    /// the check could not tell a drawn screen from an empty one, so the check
    /// is held to an empty screen here.
    @Test func theBlankFrameCheckWouldCatchAScreenThatDrewNothing() throws {
        let empty = try Self.rasterize(Color(nsColor: .windowBackgroundColor))
        #expect(Self.distinctColours(in: empty) <= 4)
    }

    /// Lays the screen out at a real window size and rasterizes it.
    ///
    /// A screen that throws never gets here. A screen that builds but puts
    /// nothing on the canvas rasterizes to a single flat colour, which is the
    /// blank frame a person would report as "it opened to nothing".
    private func expectDrawn(
        _ view: some View,
        _ location: SourceLocation = #_sourceLocation
    ) throws {
        let bitmap = try Self.rasterize(view, location)
        #expect(Self.distinctColours(in: bitmap) > 4, "the screen drew a blank frame",
                sourceLocation: location)
    }

    private static func rasterize(
        _ view: some View,
        _ location: SourceLocation = #_sourceLocation
    ) throws -> NSBitmapImageRep {
        let size = CGSize(width: 1_100, height: 760)
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.width > 0, "the screen laid out to no width", sourceLocation: location)
        #expect(host.fittingSize.height > 0, "the screen laid out to no height", sourceLocation: location)

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                  "the screen produced no drawable area", sourceLocation: location)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// Samples on a coarse grid; enough to tell text and controls from an
    /// empty wash without depending on exact pixels or on the render being
    /// byte-identical across macOS versions.
    private static func distinctColours(in bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        let step = 7
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                let packed =
                    UInt32(colour.redComponent * 255) << 16
                    | UInt32(colour.greenComponent * 255) << 8
                    | UInt32(colour.blueComponent * 255)
                seen.insert(packed)
                if seen.count > 4 { return seen.count }
            }
        }
        return seen.count
    }

    /// A workspace with the shapes each screen reaches for: a plugin that
    /// carries a skill, a standalone skill, a server, a preset and a project.
    @MainActor private struct Fixture {
        static let plugin = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000f1")!)
        static let child = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000f2")!)
        static let skill = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000f3")!)
        static let server = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000f4")!)
        static let presetID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000f5")!)
        static let projectID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000f6")!)
        let root: URL
        let workspace: WorkspaceLaunch.Workspace

        init() async throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "shell-render-\(UUID())", directoryHint: .isDirectory)
            let container = root.appending(path: "store", directoryHint: .isDirectory)
            let home = root.appending(path: "home", directoryHint: .isDirectory)
            for directory in [container, home] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let writerID = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                artifacts: [
                    .init(identity: .init(id: Self.plugin, kind: .nativePlugin, displayName: "Example Plugin"),
                          authority: .nativeOwned,
                          nativeRoutes: [.init(client: .claude, externalPluginID: "example@vendor")]),
                    // A native-owned skill member has a file of its own, so the
                    // document requires it to say where inside the package. It
                    // carries no route: the package it belongs to holds that.
                    .init(identity: .init(id: Self.child, kind: .skill, displayName: "Bundled Skill",
                                          parentPackageID: Self.plugin),
                          authority: .nativeOwned,
                          packageRelativePath: "skills/bundled"),
                    .init(identity: .init(id: Self.skill, kind: .skill, displayName: "Standalone Skill"),
                          authority: .centralPersonal),
                    .init(identity: .init(id: Self.server, kind: .mcpServer, displayName: "Example Server"),
                          authority: .trackedOnly),
                    .init(identity: .init(id: Self.presetID, kind: .preset, displayName: "Starter"),
                          authority: .centralPersonal),
                    .init(identity: .init(id: Self.projectID, kind: .logicalProject, displayName: "Project A"),
                          authority: .centralPersonal),
                ],
                logicalProjects: [.init(id: Self.projectID, name: "Project A",
                                        repositoryHints: ["https://github.com/acme/project"])],
                presets: [.init(id: Self.presetID, name: "Starter", revision: 1,
                                memberArtifactIDs: [Self.skill])]))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            let store = try WorkspaceRevisionStore(containerRoot: container,
                                                   workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            // The app's own wiring, so a screen that outgrows what launch hands
            // it fails here rather than only on a real Mac.
            workspace = WorkspaceLaunch.sessions(store: store, homeRoot: home, isFirstRun: true)
            await workspace.library.refresh()
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

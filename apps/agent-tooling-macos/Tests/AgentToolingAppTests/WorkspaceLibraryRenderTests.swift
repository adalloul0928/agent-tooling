import AgentToolingCore
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

@Suite("Workspace library render coverage")
@MainActor
struct WorkspaceLibraryRenderTests {
    @Test func readOnlyLibraryAndReviewedAssignmentRenderWithoutWriting() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        await session.refresh()
        #expect(session.lastReceipt == nil)
        let before = try #require(try fixture.store.snapshot())

        for scheme in [ColorScheme.light, .dark] {
            try await render(
                WorkspaceLibraryView(session: session),
                scheme: scheme,
                size: NSSize(width: 1_160, height: 780),
                name: "workspace-library"
            )
        }
        let afterLibrary = try #require(try fixture.store.snapshot())
        #expect(afterLibrary.document.revision.id == before.document.revision.id)
        #expect(session.lastReceipt == nil)

        let reviewSession = fixture.session(access: .writable)
        let destinations = [
            PortableDestination(surface: .claudeCode, scope: .user, deviceIDs: [fixture.device.deviceID]),
            PortableDestination(surface: .codexCLI, scope: .user, deviceIDs: [fixture.device.deviceID])
        ]
        for scheme in [ColorScheme.light, .dark] {
            await reviewSession.reviewAssignments(artifactIDs: [fixture.personalSkillID], destinations: destinations)
            #expect(reviewSession.review?.preview.additions.count == 2)
            #expect(reviewSession.lastReceipt == nil)
            try await render(
                WorkspaceAssignmentSheet(session: reviewSession, artifactIDs: [fixture.personalSkillID]),
                scheme: scheme,
                size: NSSize(width: 720, height: 680),
                name: "workspace-assignment-review"
            )
        }
        let afterSheet = try #require(try fixture.store.snapshot())
        #expect(afterSheet.document.revision.id == before.document.revision.id)
        #expect(afterSheet.document.assignments.isEmpty)
        #expect(reviewSession.lastReceipt == nil)
    }

    private func render<V: View>(_ rootView: V, scheme: ColorScheme, size: NSSize, name: String) async throws {
        let view = NSHostingView(rootView: rootView.environment(\.colorScheme, scheme))
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }

        try await Task.sleep(for: .milliseconds(50))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.size == size)
        if let directory = ProcessInfo.processInfo.environment["WORKSPACE_LIBRARY_LAYOUT_CAPTURE"],
           let png = bitmap.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(fileURLWithPath: directory).appending(path: "\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    @MainActor private struct Fixture {
        let root: URL
        let writerID = WorkspaceObjectID()
        let personalSkillID = ArtifactID()
        let nativePluginID = ArtifactID()
        let trackedMCPID = ArtifactID()
        let presetID = ArtifactID()
        let projectID = ArtifactID()
        let document: PortableWorkspaceDocument
        let device: DeviceWorkspaceState
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService

        init() throws {
            let pilotDirectory = ProcessInfo.processInfo.environment["WORKSPACE_LIBRARY_PILOT_ROOT"].map { URL(fileURLWithPath: $0) }
            root = (pilotDirectory ?? FileManager.default.temporaryDirectory).appending(path: "workspace-library-render-\(UUID())")
            let nativeChildOne = ArtifactID()
            let nativeChildTwo = ArtifactID()
            document = try WorkspaceDocumentCoding.seal(.init(
                revision: .init(writerID: writerID),
                artifacts: [
                    .init(identity: .init(id: personalSkillID, kind: .skill, displayName: "Personal workflow"), authority: .centralPersonal),
                    .init(
                        identity: .init(id: nativePluginID, kind: .nativePlugin, displayName: "Native extension"),
                        authority: .nativeOwned,
                        nativeRoutes: [.init(client: .claude, externalPluginID: "native@vendor")]
                    ),
                    .init(
                        identity: .init(id: nativeChildOne, kind: .skill, displayName: "Native child one", parentPackageID: nativePluginID),
                        authority: .nativeOwned,
                        packageRelativePath: "skills/one"
                    ),
                    .init(
                        identity: .init(id: nativeChildTwo, kind: .mcpServer, displayName: "Native child two", parentPackageID: nativePluginID),
                        authority: .nativeOwned,
                        packageRelativePath: "servers/two"
                    ),
                    .init(identity: .init(id: trackedMCPID, kind: .mcpServer, displayName: "Tracked MCP"), authority: .trackedOnly),
                    .init(identity: .init(id: presetID, kind: .preset, displayName: "Starter"), authority: .centralPersonal),
                    .init(identity: .init(id: projectID, kind: .logicalProject, displayName: "Demo project"), authority: .centralPersonal)
                ],
                logicalProjects: [.init(id: projectID, name: "Demo project", repositoryHints: ["https://github.com/acme/demo"])],
                presets: [.init(id: presetID, name: "Starter", revision: 1, memberArtifactIDs: [personalSkillID])]
            ))
            device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
            if let pilotDirectory {
                let manifest = ["root": root.path, "workspaceID": document.workspaceID.rawValue.uuidString.lowercased(),
                                "deviceID": device.deviceID.rawValue.uuidString.lowercased()]
                try JSONEncoder().encode(manifest).write(to: pilotDirectory.appending(path: "pilot.json"))
            }
        }

        func session(access: WorkspaceLibraryAccess = .readOnly) -> WorkspaceLibrarySession {
            WorkspaceLibrarySession(
                service: service,
                workspaceID: document.workspaceID,
                deviceID: device.deviceID,
                access: access
            )
        }

        func remove() {
            if ProcessInfo.processInfo.environment["WORKSPACE_LIBRARY_PILOT_ROOT"] == nil {
                try? FileManager.default.removeItem(at: root)
            }
        }
    }
}

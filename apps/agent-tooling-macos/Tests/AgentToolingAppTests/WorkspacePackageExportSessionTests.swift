import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

/// Previewing writes nothing. Writing produces a plain folder, refuses to
/// overwrite anything, and reports what each app on this Mac could do with it
/// rather than quietly changing the package to suit one.
@MainActor
struct WorkspacePackageExportSessionTests {
    @Test func previewingDescribesTheContentWithoutWritingIt() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()

        await session.prepare(Fixture.skillID)

        let preview = try #require(session.preview)
        #expect(preview.declaredName == "personal")
        #expect(preview.fileCount == 2)
        #expect(preview.relativePaths == ["SKILL.md", "scripts", "scripts/run"])
        #expect(session.writtenPath == nil)
        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
    }

    @Test func writingProducesAPlainFolderWithTheApprovedBytes() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.prepare(Fixture.skillID)
        let destination = fixture.root.appending(path: "out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        await session.write(to: destination)

        let written = try #require(session.writtenPath)
        #expect(written == destination.appending(path: "personal").path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: written).appending(path: "SKILL.md"))
            == fixture.skillBytes)
        #expect(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: written).appending(path: "scripts/run").path))
    }

    @Test func aNameAlreadyTakenInThatFolderIsRefusedRatherThanMergedInto() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.prepare(Fixture.skillID)
        let destination = fixture.root.appending(path: "out")
        let occupied = destination.appending(path: "personal")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        let existing = occupied.appending(path: "SOMETHING.md")
        try Data("someone else's work\n".utf8).write(to: existing)

        await session.write(to: destination)

        #expect(session.writtenPath == nil)
        #expect(session.errorMessage?.contains("already something") == true,
                "\(session.errorMessage ?? "")")
        // What was there is exactly as it was.
        #expect(try Data(contentsOf: existing) == Data("someone else's work\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: occupied.appending(path: "SKILL.md").path))
    }

    @Test func anAppThatCannotUseThePackageIsNamedRatherThanTheExportBeingChanged() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()

        await session.prepare(Fixture.skillID)

        let preview = try #require(session.preview)
        let codexReport = preview.compatibility.first { $0.surface == .codexCLI }
        let codex = try #require(codexReport)
        #expect(codex.isFullySupported == false)
        // The executable file is called out by name, on every target.
        #expect(preview.compatibility.allSatisfy { report in
            report.notes.contains { $0.kind == .executableContent && $0.relativePath == "scripts/run" }
        })
        // And the package itself is unchanged by any of it.
        #expect(preview.relativePaths.contains("scripts/run"))
    }

    @Test func anItemThisWorkspaceOnlyRecordsHasNothingToWriteAndSaysSo() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()

        await session.prepare(Fixture.trackedID)

        #expect(session.preview == nil)
        #expect(session.errorMessage?.contains("does not hold its content") == true,
                "\(session.errorMessage ?? "")")
    }

    @Test func anItemThatIsNoLongerHereIsReportedRatherThanExportedEmpty() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()

        await session.prepare(ArtifactID())

        #expect(session.preview == nil)
        #expect(session.errorMessage?.contains("no longer in this workspace") == true,
                "\(session.errorMessage ?? "")")
    }

    @MainActor private struct Fixture {
        static let skillID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
        static let trackedID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!)
        let root: URL
        let store: WorkspaceRevisionStore
        let contentStore: CentralPackageContentStore
        let library: WorkspaceLibrarySession
        let skillBytes = Data("---\nname: personal\ndescription: Fixture\n---\n\n# Personal\n".utf8)

        init() async throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "package-export-session-\(UUID())")
            let contentRoot = root.appending(path: "content")
            try FileManager.default.createDirectory(at: contentRoot, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let tree = try CapturedPackageTree(entries: [
                .init(relativePath: "SKILL.md", kind: .file(bytes: skillBytes, executable: false)),
                .init(relativePath: "scripts", kind: .directory),
                .init(relativePath: "scripts/run", kind: .file(bytes: Data("#!/bin/sh\n".utf8),
                                                               executable: true)),
            ])
            let writerID = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                artifacts: [
                    .init(identity: .init(id: Self.skillID, kind: .skill, displayName: "Personal"),
                          authority: .centralPersonal, declaredName: "personal",
                          contentDigest: tree.digest),
                    .init(identity: .init(id: Self.trackedID, kind: .skill, displayName: "Only recorded"),
                          authority: .trackedOnly),
                ]))
            var device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            // Codex accepts skills but not the ones this Mac has evidence for,
            // so the report has something real to say.
            device.capabilityEvidence = [
                .init(surface: .codexCLI, installedClientVersion: "1.0.0", adapterContractVersion: 1,
                      component: .mcpServer, scopes: [.user], support: .supported,
                      observedAt: Date(timeIntervalSince1970: 1_700_000_000)),
                .init(surface: .claudeCode, installedClientVersion: "2.0.0", adapterContractVersion: 1,
                      component: .skill, scopes: [.user], support: .supported,
                      observedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            ]
            store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store"),
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            contentStore = try CentralPackageContentStore(directory: contentRoot)
            _ = try await contentStore.store(tree)
            library = WorkspaceLibrarySession(
                service: WorkspaceApplicationService(store: store, writerID: writerID,
                                                     contentStore: contentStore),
                workspaceID: document.workspaceID, deviceID: device.deviceID, access: .writable)
        }

        func session() async -> WorkspacePackageExportSession {
            await library.refresh()
            return WorkspacePackageExportSession(library: library, contentStore: contentStore)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

/// Looking through earlier versions changes nothing. Going back to one is a
/// separate step, refused when the workspace moved under the preview.
@MainActor
struct WorkspaceHistorySessionTests {
    @Test func versionsAreListedWithTheCurrentOneMarkedAndNotRestorable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()

        await session.refresh()

        #expect(session.points.count == 3)
        #expect(session.points.first?.isCurrent == true)
        #expect(session.points.dropFirst().allSatisfy { !$0.isCurrent })
        // Selecting where you already are offers nothing to do.
        session.select(session.points.first?.revisionID)
        #expect(!session.canRestore)
        #expect(session.preview?.isEmpty == true)
    }

    @Test func choosingAnEarlierVersionReadsWhatWouldChangeWithoutChangingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.refresh()

        session.select(fixture.withBoth)

        let preview = try #require(session.preview)
        #expect(preview.restoredItems == ["Beta"])
        #expect(preview.assignmentDifference == 1)
        #expect(session.canRestore)
        // Reading a version is not living in it.
        #expect(try #require(try fixture.store.snapshot()).document.revision.id == fixture.head())
    }

    @Test func goingBackCommitsTheOldContentsAndTheLibraryShowsIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.refresh()
        session.select(fixture.withBoth)

        await session.restore()

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        let document = try #require(try fixture.store.snapshot()).document
        #expect(document.artifacts.map(\.identity.displayName).sorted() == ["Alpha", "Beta"])
        // The restored version is one more entry, not a rewind.
        #expect(session.points.count == 4)
        #expect(session.points.first?.isCurrent == true)
        #expect(session.points.first?.revisionID != fixture.withBoth)
        // The selection is spent, and the library was re-read.
        #expect(session.selectedID == nil)
        #expect(session.lastRestoredID == fixture.withBoth)
        #expect(fixture.library.state?.library.rows.count == 2)
    }

    @Test func aReadOnlyWorkspaceCanLookThroughHistoryButNotRewriteIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session(access: .readOnly)
        await session.refresh()

        session.select(fixture.withBoth)

        #expect(session.preview?.restoredItems == ["Beta"])
        #expect(!session.canRestore)
        await session.restore()
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.count == 1)
    }

    @Test func aVersionThatMovedOnUnderThePreviewIsRefusedRatherThanOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.refresh()
        session.select(fixture.withBoth)
        // Something else changes the workspace after the preview was read.
        try fixture.commit { $0.artifacts += [Fixture.artifact(Fixture.gamma, "Gamma")] }

        await session.restore()

        #expect(session.errorMessage?.contains("Nothing was restored") == true,
                "\(session.errorMessage ?? "")")
        let names = try #require(try fixture.store.snapshot()).document.artifacts
            .map(\.identity.displayName).sorted()
        #expect(names == ["Alpha", "Gamma"])
    }

    @Test func historyThatCannotBeReadSaysSoRatherThanShowingAnEmptyList() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.refresh()
        let known = try #require(session.points.last?.revisionID)

        // A version this workspace does not hold has nothing to preview.
        session.select(WorkspaceObjectID())

        #expect(session.preview == nil)
        #expect(session.errorMessage?.isEmpty == false)
        session.select(known)
        #expect(session.preview != nil)
    }

    @MainActor private struct Fixture {
        static let alpha = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
        static let beta = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!)
        static let gamma = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!)
        let root: URL
        let store: WorkspaceRevisionStore
        let library: WorkspaceLibrarySession
        let writerID = WorkspaceObjectID()
        /// The version that held both items and asked for both places.
        let withBoth: WorkspaceObjectID

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "history-session-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID())))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store"),
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            let codex = PortableDestination(surface: .codexCLI, scope: .user)
            var recorded = WorkspaceObjectID()
            try Self.commit(store: store, writerID: writerID) { document in
                document.artifacts = [Self.artifact(Self.alpha, "Alpha"), Self.artifact(Self.beta, "Beta")]
                document.assignments = [
                    .init(artifactID: Self.alpha, destination: codex, reason: .manual),
                    .init(artifactID: Self.beta, destination: codex, reason: .manual),
                ]
            }
            recorded = (try store.snapshot())?.document.revision.id ?? recorded
            withBoth = recorded
            // Beta is dropped, leaving one item and one place.
            try Self.commit(store: store, writerID: writerID) { document in
                document.artifacts = [Self.artifact(Self.alpha, "Alpha")]
                document.assignments = [.init(artifactID: Self.alpha, destination: codex, reason: .manual)]
            }
            library = WorkspaceLibrarySession(
                service: WorkspaceApplicationService(store: store, writerID: writerID),
                workspaceID: document.workspaceID, deviceID: device.deviceID, access: .writable)
        }

        static func artifact(_ id: ArtifactID, _ name: String) -> ArtifactRecord {
            .init(identity: .init(id: id, kind: .skill, displayName: name), authority: .trackedOnly)
        }

        static func commit(
            store: WorkspaceRevisionStore, writerID: WorkspaceObjectID,
            _ mutation: @escaping (inout PortableWorkspaceDocument) -> Void
        ) throws {
            guard let head = try store.snapshot()?.document.revision.id else { return }
            _ = try store.commitMetadata(
                expectedRevisionID: head, idempotencyKey: WorkspaceObjectID(),
                inputDigest: String(repeating: "c", count: 64), writerID: writerID
            ) { document in
                mutation(&document)
                return document.artifacts.map(\.identity.id).sorted()
            }
        }

        func commit(_ mutation: @escaping (inout PortableWorkspaceDocument) -> Void) throws {
            try Self.commit(store: store, writerID: writerID, mutation)
        }

        func head() -> WorkspaceObjectID {
            (try? store.snapshot())?.document.revision.id ?? WorkspaceObjectID()
        }

        func session(access: WorkspaceLibraryAccess = .writable) async -> WorkspaceHistorySession {
            await library.refresh()
            return WorkspaceHistorySession(store: store, library: library,
                                           writerID: writerID, access: access)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

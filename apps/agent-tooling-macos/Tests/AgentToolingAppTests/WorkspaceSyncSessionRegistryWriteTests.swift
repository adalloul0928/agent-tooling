import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Registry changes made from the Sync settings, such as whether a Mac takes
/// shared assignments.
///
/// Nothing here is connected to a repository, so no pass runs after a change
/// and what is checked is the change itself.
@MainActor
struct WorkspaceSyncSessionRegistryWriteTests {
    /// The toggle shows what is recorded until a write lands, so a second click
    /// before then sends the same value again. Each click starts its own task;
    /// the second must not read a head the first is about to move and then be
    /// refused as stale, which used to put "Nothing was changed" on screen.
    @Test func aSecondClickBeforeTheFirstLandsIsNotRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        let mac = try #require(session.thisDevice)
        #expect(mac.receivesSharedAssignments)

        let first = Task { await session.setReceivesSharedAssignments(false, for: mac.id) }
        let second = Task { await session.setReceivesSharedAssignments(false, for: mac.id) }
        _ = await (first.value, second.value)

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(session.thisDevice?.receivesSharedAssignments == false)
        #expect(try fixture.recorded(mac.id)?.receivesSharedAssignments == false)
    }

    /// Two Macs' toggles flipped at once are both recorded.
    @Test func twoMacsFlippedAtOnceAreBothRecorded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        let mac = try #require(session.thisDevice)
        let other = try #require(session.otherDevices.first)

        let first = Task { await session.setReceivesSharedAssignments(false, for: mac.id) }
        let second = Task { await session.setReceivesSharedAssignments(false, for: other.id) }
        _ = await (first.value, second.value)

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(try fixture.recorded(mac.id)?.receivesSharedAssignments == false)
        #expect(try fixture.recorded(other.id)?.receivesSharedAssignments == false)
    }

    /// A store with this Mac and one other in its registry.
    @MainActor private struct Fixture {
        let folder: TemporaryFolder
        let store: WorkspaceRevisionStore
        let enrollmentStore: WorkspaceSyncEnrollmentStore
        let workspaceID: WorkspaceObjectID
        let writerID = WorkspaceObjectID()

        init() throws {
            folder = try TemporaryFolder("sync-registry-writes")
            let document = try WorkspaceDocumentCoding.seal(
                .init(workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID)))
            workspaceID = document.workspaceID
            store = try WorkspaceRevisionStore(
                containerRoot: folder.url.appending(path: "store"), workspaceID: workspaceID,
                deviceID: WorkspaceObjectID())
            try store.initialize(document: document, device: .init(workspaceID: workspaceID, deviceID: store.deviceID))
            enrollmentStore = try WorkspaceSyncEnrollmentStore(containerRoot: folder.url)
            for (id, name) in [(store.deviceID, "This Mac"), (WorkspaceObjectID(), "Other Mac")] {
                let head = try #require(try store.snapshot()).document.revision.id
                _ = try store.commitMetadata(
                    expectedRevisionID: head, idempotencyKey: WorkspaceObjectID(),
                    inputDigest: String(repeating: "b", count: 64), writerID: writerID
                ) { document in
                    document.devices = document.deviceRegistry + [.init(id: id, name: name)]
                    return []
                }
            }
        }

        func session() -> WorkspaceSyncSession {
            WorkspaceSyncSession(
                store: store, enrollmentStore: enrollmentStore, workspaceID: workspaceID, writerID: writerID)
        }

        /// The registry row as the store holds it.
        func recorded(_ id: WorkspaceObjectID) throws -> DeviceRecord? {
            try store.snapshot()?.document.deviceRegistry.first { $0.id == id }
        }

        func remove() { try? FileManager.default.removeItem(at: folder.url) }
    }
}

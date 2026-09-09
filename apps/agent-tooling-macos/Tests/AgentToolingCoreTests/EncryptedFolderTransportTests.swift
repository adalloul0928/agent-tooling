import CryptoKit
import Foundation
import Testing

@testable import AgentToolingCore

/// A folder a sync service moves, holding only sealed bytes. Two Macs sharing
/// it converge through the same coordinator as Git, and neither overwrites the
/// other by being second.
@Suite("Encrypted folder transport")
struct EncryptedFolderTransportTests {
    @Test func anEmptyFolderIsNoPublishedRevisionRatherThanAnEmptyWorkspace() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let state = try await fixture.transport().remoteState()

        #expect(state.head == nil)
        #expect(state.document == nil)
    }

    @Test func nothingReadableIsWrittenIntoTheFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = try fixture.transport()
        let document = try Fixture.document(named: "Something private")

        _ = try await transport.publish(document: document, expectedRemoteHead: nil)

        let bytes = try Data(contentsOf: fixture.folder
            .appending(path: EncryptedFolderWorkspaceTransport.documentFileName))
        let text = String(decoding: bytes, as: UTF8.self)
        // Every name in the library is in that document. None of it is in the
        // folder in the clear.
        #expect(!text.contains("Something private"))
        #expect(!text.contains(document.workspaceID.rawValue.uuidString.lowercased()))
        // And nothing half-written is left behind for the sync service.
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path)
            == [EncryptedFolderWorkspaceTransport.documentFileName])
    }

    @Test func whatWasPublishedComesBackExactly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = try fixture.transport()
        let document = try Fixture.document(named: "Alpha")

        let receipt = try await transport.publish(document: document, expectedRemoteHead: nil)
        let state = try await transport.remoteState()

        #expect(state.head == receipt.commit)
        #expect(state.document == document)
        #expect(receipt.previousHead == nil)
        #expect(receipt.revisionID == document.revision.id)
    }

    @Test func anotherMacThatPublishedFirstIsNotOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let mine = try fixture.transport()
        let theirs = try fixture.transport()
        _ = try await mine.publish(document: try Fixture.document(named: "Mine"),
                                   expectedRemoteHead: nil)

        // The other Mac still believes the folder is empty.
        await #expect(throws: (any Error).self) {
            _ = try await theirs.publish(document: try Fixture.document(named: "Theirs"),
                                         expectedRemoteHead: nil)
        }
        #expect(try await theirs.remoteState().document?.artifacts.first?.identity.displayName == "Mine")
    }

    @Test func aFolderThisKeyDoesNotOpenIsRefusedRatherThanReplaced() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.transport().publish(document: try Fixture.document(named: "Alpha"),
                                                  expectedRemoteHead: nil)
        let stranger = try EncryptedFolderWorkspaceTransport(
            folder: fixture.folder, key: WorkspaceFolderKeyStore.generate())

        await #expect(throws: EncryptedFolderTransportError.cannotDecrypt) {
            _ = try await stranger.remoteState()
        }
        // What was there is untouched.
        #expect(try await fixture.transport().remoteState().document?.artifacts.count == 1)
    }

    @Test func aFolderThatIsNotThereIsRefusedRatherThanCreated() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = fixture.root.appending(path: "not-here")

        #expect(throws: EncryptedFolderTransportError.invalidFolder) {
            _ = try EncryptedFolderWorkspaceTransport(folder: missing, key: fixture.key)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func twoMacsSharingAFolderConvergeThroughTheOrdinarySyncPass() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = WorkspaceSyncCoordinator(store: fixture.storeA, transport: try fixture.transport(),
                                         writerID: WorkspaceObjectID())
        let b = WorkspaceSyncCoordinator(store: fixture.storeB, transport: try fixture.transport(),
                                         writerID: WorkspaceObjectID())

        _ = try await a.sync()
        _ = try await b.sync()
        try fixture.rename(store: fixture.storeA, to: "Renamed on A")
        _ = try await a.sync()
        let outcome = try await b.sync()

        // B took in A's change without anyone deciding anything.
        if case .adopted = outcome {} else if case .merged = outcome {} else {
            Issue.record("Expected B to take in A's revision, got \(outcome)")
        }
        #expect(try fixture.storeB.snapshot()?.document.artifacts.first?.identity.displayName
            == "Renamed on A")
    }

    private struct Fixture {
        static let alpha = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
        static let workspaceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000e5")!)
        let root: URL
        let folder: URL
        let key: SymmetricKey
        let storeA: WorkspaceRevisionStore
        let storeB: WorkspaceRevisionStore

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "encrypted-folder-\(UUID())")
            folder = root.appending(path: "shared")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            key = WorkspaceFolderKeyStore.generate()
            let document = try Self.document(named: "Alpha")
            storeA = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store-a"),
                workspaceID: Self.workspaceID, deviceID: WorkspaceObjectID())
            try storeA.initialize(document: document,
                                  device: .init(workspaceID: Self.workspaceID, deviceID: storeA.deviceID))
            storeB = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store-b"),
                workspaceID: Self.workspaceID, deviceID: WorkspaceObjectID())
            try storeB.initialize(document: document,
                                  device: .init(workspaceID: Self.workspaceID, deviceID: storeB.deviceID))
        }

        func transport() throws -> EncryptedFolderWorkspaceTransport {
            try .init(folder: folder, key: key)
        }

        static func document(named name: String) throws -> PortableWorkspaceDocument {
            try WorkspaceDocumentCoding.seal(.init(
                workspaceID: workspaceID,
                revision: .init(id: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000f6")!),
                                writerID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000f7")!),
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
                artifacts: [.init(identity: .init(id: alpha, kind: .skill, displayName: name),
                                  authority: .trackedOnly)]))
        }

        func rename(store: WorkspaceRevisionStore, to name: String) throws {
            guard let head = try store.snapshot()?.document.revision.id else { return }
            _ = try store.commitMetadata(
                expectedRevisionID: head, idempotencyKey: WorkspaceObjectID(),
                inputDigest: String(repeating: "a", count: 64), writerID: WorkspaceObjectID()
            ) { document in
                guard let index = document.artifacts.firstIndex(where: { $0.identity.id == Self.alpha })
                else { return [] }
                document.artifacts[index].identity.displayName = name
                return [Self.alpha]
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

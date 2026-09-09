@testable import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

@Suite("Workspace authority launch")
@MainActor
struct WorkspaceAuthorityLaunchTests {
    @Test func missingRegistryAndMissingRootReturnLegacyPathWithoutCreatingAnything() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "authority-missing-\(UUID())")
        #expect(try WorkspaceAuthorityLaunch.openSession(legacyRoot: missing) == nil)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func malformedAndFutureRegistriesThrowInsteadOfFallingBack() throws {
        let root = try temporaryLegacyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRegistryFiles(root: root, bytes: Data("not json".utf8))
        #expect(throws: WorkspaceAuthorityStoreError.corruptRegistry) {
            _ = try WorkspaceAuthorityLaunch.openSession(legacyRoot: root)
        }

        try writeRegistryFiles(root: root, bytes: Data(#"{"schemaVersion":2,"selections":[]}"#.utf8))
        #expect(throws: WorkspaceAuthorityStoreError.unsupportedVersion) {
            _ = try WorkspaceAuthorityLaunch.openSession(legacyRoot: root)
        }
    }

    @Test func selectedVersionedAttemptOpensAReadOnlyBoundSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.commitVersionedSelection()

        let session = try #require(try WorkspaceAuthorityLaunch.openSession(legacyRoot: fixture.legacyRoot))
        if case .readOnly = session.access {} else { Issue.record("authority launch must be read-only") }
        #expect(session.workspaceID == fixture.workspaceID)
        #expect(session.deviceID == fixture.deviceID)
        await session.refresh()
        #expect(session.state?.snapshot.document.revision.id == fixture.initialRevisionID)
        #expect(session.lastReceipt == nil)
    }

    @Test func legacyRollbackReturnsNilAndRetainsBothStores() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let versioned = try fixture.commitVersionedSelection()
        try fixture.commitLegacyRollback(previous: versioned)
        let before = try #require(try fixture.store.snapshot())

        #expect(try WorkspaceAuthorityLaunch.openSession(legacyRoot: fixture.legacyRoot) == nil)
        let after = try #require(try fixture.store.snapshot())
        #expect(after.document.revision.id == before.document.revision.id)
        #expect(FileManager.default.fileExists(atPath: fixture.legacyDatabase.path))
    }

    @Test func missingSelectedAttemptThrowsAndDoesNotOpenLegacyStore() throws {
        let fixture = try Fixture(createVersionedStore: false)
        defer { fixture.remove() }
        _ = try fixture.commitVersionedSelection()

        #expect(throws: (any Error).self) {
            _ = try WorkspaceAuthorityLaunch.openSession(legacyRoot: fixture.legacyRoot)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.legacyDatabase.path))
    }

    private func temporaryLegacyRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "authority-launch-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func writeRegistryFiles(root: URL, bytes: Data) throws {
        let lock = root.appending(path: ".workspace-authority-v1.lock")
        let registry = root.appending(path: "workspace-authority-v1.json")
        try Data().write(to: lock, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
        try bytes.write(to: registry, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registry.path)
    }

    private struct Fixture {
        let root: URL
        let legacyRoot: URL
        let legacyDatabase: URL
        let containerRoot: URL
        let workspaceID = WorkspaceObjectID()
        let deviceID = WorkspaceObjectID()
        let attemptID = WorkspaceObjectID()
        let writerID = WorkspaceObjectID()
        let initialRevisionID = WorkspaceObjectID()
        let store: WorkspaceRevisionStore
        let record: WorkspaceMigrationRecord

        init(createVersionedStore: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "authority-launch-fixture-\(UUID())")
            legacyRoot = root.appending(path: "legacy", directoryHint: .isDirectory)
            containerRoot = root.appending(path: "versioned", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            legacyDatabase = legacyRoot.appending(path: "agent-tooling.sqlite")
            try Data("retained legacy bytes".utf8).write(to: legacyDatabase)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyDatabase.path)

            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: workspaceID,
                revision: .init(id: initialRevisionID, writerID: writerID)
            ))
            let device = DeviceWorkspaceState(workspaceID: workspaceID, deviceID: deviceID)
            let manifest = WorkspaceMigrationManifest(
                formatVersion: 1,
                attemptID: attemptID,
                workspaceID: workspaceID,
                deviceID: deviceID,
                initialRevisionID: initialRevisionID,
                legacyDatabasePath: legacyDatabase.path,
                checkpointSHA256: String(repeating: "a", count: 64),
                documentSHA256: WorkspaceMigrationRecord.hash(try WorkspaceDocumentCoding.encode(document)),
                deviceSHA256: WorkspaceMigrationRecord.hash(try WorkspaceDocumentCoding.encodeDeviceState(device)),
                content: [],
                sourceCaptures: [],
                deploymentNames: []
            )
            record = WorkspaceMigrationRecord(manifest: manifest, document: document, device: device)
            store = try WorkspaceRevisionStore(
                containerRoot: containerRoot,
                workspaceID: workspaceID,
                deviceID: deviceID,
                access: .readWrite
            )
            if createVersionedStore {
                _ = try store.prepareMigration(record)
                _ = try store.initializeMigration(attemptID: attemptID, inputDigest: try record.inputDigest)
            }
        }

        func commitVersionedSelection() throws -> WorkspaceAuthoritySelection {
            let selection = WorkspaceAuthoritySelection(
                choice: .versioned,
                target: .init(containerRootPath: containerRoot.path, workspaceID: workspaceID, deviceID: deviceID, attemptID: attemptID),
                checkpointSHA256: record.manifest.checkpointSHA256,
                versionedRevisionID: initialRevisionID,
                selectedAt: Date(timeIntervalSince1970: 1)
            )
            let registry = try WorkspaceAuthorityStore(legacyRoot: legacyRoot)
            return try registry.withExclusiveAccess { transaction in
                try transaction.commit(selection, expectedSelectionID: nil)
            }
        }

        func commitLegacyRollback(previous: WorkspaceAuthoritySelection) throws {
            let selection = WorkspaceAuthoritySelection(
                previousID: previous.id,
                choice: .legacy,
                target: previous.target,
                checkpointSHA256: previous.checkpointSHA256,
                versionedRevisionID: previous.versionedRevisionID,
                selectedAt: Date(timeIntervalSince1970: 2)
            )
            let registry = try WorkspaceAuthorityStore(legacyRoot: legacyRoot)
            _ = try registry.withExclusiveAccess { transaction in
                try transaction.commit(selection, expectedSelectionID: previous.id)
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

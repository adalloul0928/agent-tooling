import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

@Suite("Writable workspace authority launch")
@MainActor
struct WorkspaceAuthorityWritableLaunchTests {
    @Test func selectedWritableSessionAndGuardedRenameSurviveReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let selected = try fixture.commitVersionedSelection()

        let session = try #require(try WorkspaceAuthorityLaunch.openWritableSession(legacyRoot: fixture.legacyRoot))
        if case .writable = session.access {} else { Issue.record("selected launch must bind a writable session") }
        await session.refresh()
        #expect(session.state?.snapshot.document.revision.id == fixture.initialRevisionID)

        let store = try WorkspaceRevisionStore.openSelected(legacyRoot: fixture.legacyRoot, selection: selected)
        let service = WorkspaceApplicationService(store: store, writerID: fixture.writerID)
        let receipt = try await service.renameArtifact(.init(
            expectedRevisionID: fixture.initialRevisionID,
            artifactID: fixture.artifactID,
            displayName: "After"
        ))
        #expect(receipt.committedRevisionID != fixture.initialRevisionID)

        let reopened = try WorkspaceRevisionStore(containerRoot: fixture.containerRoot,
            workspaceID: fixture.workspaceID, deviceID: fixture.deviceID, access: .existingReadOnly)
        let saved = try #require(try reopened.snapshot())
        #expect(saved.document.artifacts.first?.identity.displayName == "After")
    }

    @Test func rollbackLeavesExistingSelectedStoreReadableAndRejectsItsNextWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let versioned = try fixture.commitVersionedSelection()
        let store = try WorkspaceRevisionStore.openSelected(legacyRoot: fixture.legacyRoot, selection: versioned)
        let service = WorkspaceApplicationService(store: store, writerID: fixture.writerID)

        try fixture.commitLegacyRollback(previous: versioned)
        #expect(try await service.snapshot()?.document.revision.id == fixture.initialRevisionID)
        await #expect(throws: WorkspaceAuthorityStoreError.self) {
            _ = try await service.renameArtifact(.init(
                expectedRevisionID: fixture.initialRevisionID,
                artifactID: fixture.artifactID,
                displayName: "Blocked"
            ))
        }
        #expect(try await service.snapshot()?.document.artifacts.first?.identity.displayName == "Before")
    }

    @Test func missingAndMismatchedSelectionsNeverCreateAVersionedStore() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "writable-authority-missing-\(UUID())")
        #expect(try WorkspaceAuthorityLaunch.openWritableSession(legacyRoot: missing) == nil)
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        let fixture = try Fixture(createVersionedStore: false)
        defer { fixture.remove() }
        let selection = try fixture.commitVersionedSelection()
        #expect(throws: (any Error).self) {
            _ = try WorkspaceAuthorityLaunch.openWritableSession(legacyRoot: fixture.legacyRoot)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.containerRoot.path))
        #expect(selection.choice == .versioned)

        let initialized = try Fixture()
        defer { initialized.remove() }
        try initialized.commitVersionedSelection(checkpoint: String(repeating: "b", count: 64))
        #expect(throws: (any Error).self) {
            _ = try WorkspaceAuthorityLaunch.openWritableSession(legacyRoot: initialized.legacyRoot)
        }
        #expect(FileManager.default.fileExists(atPath: initialized.store.databaseURL.path))
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
        let artifactID = ArtifactID()
        let initialRevisionID = WorkspaceObjectID()
        let store: WorkspaceRevisionStore
        let record: WorkspaceMigrationRecord

        init(createVersionedStore: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "writable-authority-\(UUID())", directoryHint: .isDirectory)
            legacyRoot = root.appending(path: "legacy", directoryHint: .isDirectory)
            containerRoot = root.appending(path: "versioned", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            legacyDatabase = legacyRoot.appending(path: "agent-tooling.sqlite")
            try Data("retained legacy bytes".utf8).write(to: legacyDatabase)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyDatabase.path)

            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: workspaceID,
                revision: .init(id: initialRevisionID, writerID: writerID),
                artifacts: [.init(identity: .init(id: artifactID, kind: .skill, displayName: "Before"), authority: .trackedOnly)]
            ))
            let device = DeviceWorkspaceState(workspaceID: workspaceID, deviceID: deviceID)
            let manifest = WorkspaceMigrationManifest(
                formatVersion: 1, attemptID: attemptID, workspaceID: workspaceID, deviceID: deviceID,
                initialRevisionID: initialRevisionID, legacyDatabasePath: legacyDatabase.path,
                checkpointSHA256: String(repeating: "a", count: 64),
                documentSHA256: WorkspaceMigrationRecord.hash(try WorkspaceDocumentCoding.encode(document)),
                deviceSHA256: WorkspaceMigrationRecord.hash(try WorkspaceDocumentCoding.encodeDeviceState(device)),
                content: [], sourceCaptures: [], deploymentNames: []
            )
            record = .init(manifest: manifest, document: document, device: device)
            if createVersionedStore {
                store = try WorkspaceRevisionStore(containerRoot: containerRoot, workspaceID: workspaceID, deviceID: deviceID)
                _ = try store.prepareMigration(record)
                _ = try store.initializeMigration(attemptID: attemptID, inputDigest: try record.inputDigest)
            } else {
                store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "placeholder"),
                    workspaceID: workspaceID, deviceID: deviceID)
            }
        }

        var selection: WorkspaceAuthoritySelection {
            .init(choice: .versioned,
                target: .init(containerRootPath: containerRoot.path, workspaceID: workspaceID, deviceID: deviceID, attemptID: attemptID),
                checkpointSHA256: record.manifest.checkpointSHA256, versionedRevisionID: initialRevisionID,
                selectedAt: Date(timeIntervalSince1970: 1))
        }

        @discardableResult
        func commitVersionedSelection(checkpoint: String? = nil) throws -> WorkspaceAuthoritySelection {
            let base = selection
            let value = WorkspaceAuthoritySelection(id: base.id, choice: base.choice, target: base.target,
                checkpointSHA256: checkpoint ?? base.checkpointSHA256, versionedRevisionID: base.versionedRevisionID,
                selectedAt: base.selectedAt)
            let registry = try WorkspaceAuthorityStore(legacyRoot: legacyRoot)
            return try registry.withExclusiveAccess { try $0.commit(value, expectedSelectionID: nil) }
        }

        func commitLegacyRollback(previous: WorkspaceAuthoritySelection) throws {
            let selection = WorkspaceAuthoritySelection(previousID: previous.id, choice: .legacy, target: previous.target,
                checkpointSHA256: previous.checkpointSHA256, versionedRevisionID: previous.versionedRevisionID,
                selectedAt: Date(timeIntervalSince1970: 2))
            let registry = try WorkspaceAuthorityStore(legacyRoot: legacyRoot)
            _ = try registry.withExclusiveAccess { try $0.commit(selection, expectedSelectionID: previous.id) }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

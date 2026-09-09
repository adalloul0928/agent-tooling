import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Workspace authority registry")
struct WorkspaceAuthorityStoreTests {
    @Test func versionedSelectionReopensAndExactIDReplayDoesNotRewriteLaterRollback() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try WorkspaceAuthorityStore(legacyRoot: fixture.root)
        let versioned = fixture.selection(choice: .versioned)
        let saved = try store.withExclusiveAccess { try $0.commit(versioned, expectedSelectionID: nil) }
        #expect(saved.selectedAt == WorkspaceDomainValidation.canonicalDate(versioned.selectedAt))

        let rollback = WorkspaceAuthoritySelection(
            previousID: saved.id, choice: .legacy, target: fixture.target,
            checkpointSHA256: String(repeating: "b", count: 64),
            versionedRevisionID: WorkspaceObjectID(), selectedAt: saved.selectedAt.addingTimeInterval(1)
        )
        _ = try store.withExclusiveAccess { try $0.commit(rollback, expectedSelectionID: saved.id) }
        let replay = try store.withExclusiveAccess { try $0.commit(versioned, expectedSelectionID: nil) }

        #expect(replay == saved)
        #expect(try WorkspaceAuthorityStore(legacyRoot: fixture.root).history() == [saved, rollback])
        #expect(try store.read() == rollback)
        #expect(try store.lookup(saved.id) == saved)
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: fixture.root) == rollback)
    }

    @Test func concurrentInitialCASAllowsOnlyOneSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try WorkspaceAuthorityStore(legacyRoot: fixture.root)
        let candidates = [fixture.selection(choice: .versioned), fixture.selection(choice: .versioned)]
        let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for candidate in candidates {
                group.addTask {
                    do {
                        let store = try WorkspaceAuthorityStore(legacyRoot: fixture.root)
                        _ = try store.withExclusiveAccess { try $0.commit(candidate, expectedSelectionID: nil) }
                        return "saved"
                    } catch let error as WorkspaceAuthorityStoreError {
                        if case .staleSelection = error { return "contended" }
                        if error == .busy { return "contended" }
                        return "unexpected"
                    } catch { return "unexpected" }
                }
            }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(outcomes.sorted() == ["contended", "saved"])
        #expect(try WorkspaceAuthorityStore(legacyRoot: fixture.root).history().count == 1)
    }

    @Test func failedPublicationLeavesNoSelectionOrPartialRegistry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try WorkspaceAuthorityStore(legacyRoot: fixture.root)

        #expect(throws: InjectedFailure.self) {
            try store.withExclusiveAccess { transaction in
                try transaction.commit(fixture.selection(choice: .versioned), expectedSelectionID: nil) {
                    throw InjectedFailure()
                }
            }
        }

        #expect(try store.read() == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(!names.contains(where: { $0.hasSuffix(".tmp") }))
    }

    @Test func corruptFutureAndUnknownContentNeverFallsBackToLegacy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try WorkspaceAuthorityStore(legacyRoot: fixture.root)
        let registry = fixture.root.appending(path: "workspace-authority-v1.json")

        try Data(#"{"schemaVersion":2,"selections":[]}"#.utf8).write(to: registry)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registry.path)
        #expect(throws: WorkspaceAuthorityStoreError.unsupportedVersion) {
            try WorkspaceAuthorityStore.readIfPresent(legacyRoot: fixture.root)
        }

        try Data(#"{"extra":true,"schemaVersion":1,"selections":[]}"#.utf8).write(to: registry)
        #expect(throws: WorkspaceAuthorityStoreError.corruptRegistry) {
            try WorkspaceAuthorityStore.readIfPresent(legacyRoot: fixture.root)
        }

        try Data("not-json".utf8).write(to: registry)
        #expect(throws: WorkspaceAuthorityStoreError.corruptRegistry) { try WorkspaceAuthorityStore(legacyRoot: fixture.root).read() }
    }

    @Test func invalidPathHashAndPredecessorAreRejectedWithoutChangingHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try WorkspaceAuthorityStore(legacyRoot: fixture.root)
        let initial = fixture.selection(choice: .versioned)
        let saved = try store.withExclusiveAccess { try $0.commit(initial, expectedSelectionID: nil) }

        let invalidTarget = WorkspaceAuthorityTarget(
            containerRootPath: "relative", workspaceID: fixture.target.workspaceID,
            deviceID: fixture.target.deviceID, attemptID: fixture.target.attemptID
        )
        let invalid = WorkspaceAuthoritySelection(
            previousID: saved.id, choice: .legacy, target: invalidTarget,
            checkpointSHA256: String(repeating: "A", count: 64),
            versionedRevisionID: fixture.revisionID, selectedAt: saved.selectedAt.addingTimeInterval(1)
        )
        #expect(throws: WorkspaceAuthorityStoreError.invalidSelection) {
            try store.withExclusiveAccess { try $0.commit(invalid, expectedSelectionID: saved.id) }
        }
        #expect(try store.history() == [saved])
    }

    @Test func cooperativeLegacyWritesAreBlockedUntilRollback() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try WorkspaceAuthorityStore(legacyRoot: fixture.root)
        let selected = try store.withExclusiveAccess {
            try $0.commit(fixture.selection(choice: .versioned), expectedSelectionID: nil)
        }
        #expect(throws: WorkspaceAuthorityStoreError.self) {
            try WorkspaceAuthorityStore.withLegacyWriteAccess(legacyRoot: fixture.root) { true }
        }
        let rollback = fixture.selection(previousID: selected.id, choice: .legacy,
            selectedAt: selected.selectedAt.addingTimeInterval(1))
        _ = try store.withExclusiveAccess { try $0.commit(rollback, expectedSelectionID: selected.id) }
        let result = try WorkspaceAuthorityStore.withLegacyWriteAccess(legacyRoot: fixture.root) { "allowed" }
        #expect(result == "allowed")
    }

    @Test func missingReadDoesNotCreateRootAndUnsafeRootIsRejected() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "authority-missing-\(UUID())")
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: missing) == nil)
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: fixture.root) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        #expect(throws: WorkspaceAuthorityStoreError.unsafePath) {
            try WorkspaceAuthorityStore(legacyRoot: fixture.root)
        }
    }

    @Test func registryWithMultipleHardLinksIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try WorkspaceAuthorityStore(legacyRoot: fixture.root)
        _ = try store.withExclusiveAccess {
            try $0.commit(fixture.selection(choice: .versioned), expectedSelectionID: nil)
        }
        let registry = fixture.root.appending(path: "workspace-authority-v1.json")
        let alias = fixture.root.appending(path: "authority-alias")
        try FileManager.default.linkItem(at: registry, to: alias)
        #expect(throws: WorkspaceAuthorityStoreError.unsafePath) { try store.read() }
    }

    private struct InjectedFailure: Error {}

    private struct Fixture: @unchecked Sendable {
        let root: URL
        let target: WorkspaceAuthorityTarget
        let revisionID = WorkspaceObjectID()
        let checkpoint = String(repeating: "a", count: 64)

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "authority-store-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            target = WorkspaceAuthorityTarget(
                containerRootPath: root.path, workspaceID: WorkspaceObjectID(),
                deviceID: WorkspaceObjectID(), attemptID: WorkspaceObjectID()
            )
        }

        func selection(
            id: WorkspaceObjectID = WorkspaceObjectID(),
            previousID: WorkspaceObjectID? = nil,
            choice: WorkspaceAuthorityChoice,
            selectedAt: Date = Date(timeIntervalSince1970: 2_000_000_000.1234)
        ) -> WorkspaceAuthoritySelection {
            WorkspaceAuthoritySelection(
                id: id, previousID: previousID, choice: choice, target: target,
                checkpointSHA256: checkpoint, versionedRevisionID: revisionID, selectedAt: selectedAt
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

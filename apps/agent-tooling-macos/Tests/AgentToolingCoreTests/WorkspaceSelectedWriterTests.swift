import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceSelectedWriterTests {
    @Test func selectedWriterCanRenameAndReopenWithLatestRevision() async throws {
        let fixture = try await Fixture.ready()
        defer { fixture.remove() }
        let selected = try WorkspaceRevisionStore.openSelected(legacyRoot: fixture.legacy.rootURL, selection: fixture.selection)
        let service = WorkspaceApplicationService(store: selected, writerID: fixture.context.revision.writerID)
        let receipt = try await service.renameArtifact(.init(expectedRevisionID: fixture.selection.versionedRevisionID,
            artifactID: fixture.artifactID, displayName: "Selected edit"))

        let reopened = try WorkspaceRevisionStore.openSelected(legacyRoot: fixture.legacy.rootURL, selection: fixture.selection)
        let snapshot = try #require(try reopened.snapshot())
        #expect(snapshot.document.revision.id == receipt.committedRevisionID)
        #expect(snapshot.document.artifacts.first?.identity.displayName == "Selected edit")
    }

    @Test func openSelectedRequiresActivationAndIsRejectedAfterRollback() async throws {
        let fixture = try await Fixture.prepared()
        defer { fixture.remove() }
        let authority = try fixture.authority()
        let pending = try await authority.prepareActivation(attemptID: fixture.preparation.record.manifest.attemptID)
        #expect(throws: WorkspaceAuthorityStoreError.staleSelection(current: nil)) {
            _ = try WorkspaceRevisionStore.openSelected(legacyRoot: fixture.legacy.rootURL, selection: pending)
        }
        let activated = try await authority.apply(pending)
        let selected = try WorkspaceRevisionStore.openSelected(legacyRoot: fixture.legacy.rootURL, selection: activated)
        let service = WorkspaceApplicationService(store: selected, writerID: fixture.context.revision.writerID)
        let edit = RenameArtifactCommand(expectedRevisionID: activated.versionedRevisionID,
            artifactID: fixture.artifactID, displayName: "Before rollback")
        let receipt = try await service.renameArtifact(edit)
        let rollback = try await authority.prepareRollback()
        _ = try await authority.apply(rollback)
        #expect(throws: WorkspaceAuthorityStoreError.staleSelection(current: rollback.id)) {
            _ = try WorkspaceRevisionStore.openSelected(legacyRoot: fixture.legacy.rootURL, selection: activated)
        }
        await #expect(throws: WorkspaceAuthorityStoreError.staleSelection(current: rollback.id)) {
            try await service.renameArtifact(edit)
        }
        #expect(try selected.snapshot()?.document.revision.id == receipt.committedRevisionID)
        #expect(try selected.snapshot()?.document.artifacts.first?.identity.displayName == "Before rollback")
        #expect(try selected.revision(activated.versionedRevisionID) != nil)
        await #expect(throws: WorkspaceAuthorityStoreError.staleSelection(current: rollback.id)) {
            try await service.renameArtifact(.init(expectedRevisionID: receipt.committedRevisionID,
                artifactID: fixture.artifactID, displayName: "Must remain blocked"))
        }
    }

    @Test func openSelectedMissingDatabaseDoesNotCreateIt() async throws {
        let fixture = try await Fixture.ready()
        defer { fixture.remove() }
        let database = fixture.selection.target.containerRootPath + "/workspaces-v1/"
            + fixture.context.workspaceID.rawValue.uuidString.lowercased() + "/revisions.sqlite"
        let backup = database + ".held"
        try FileManager.default.moveItem(atPath: database, toPath: backup)
        defer { try? FileManager.default.moveItem(atPath: backup, toPath: database) }
        #expect(throws: WorkspaceRevisionStoreError.self) {
            _ = try WorkspaceRevisionStore.openSelected(legacyRoot: fixture.legacy.rootURL, selection: fixture.selection)
        }
        #expect(FileManager.default.fileExists(atPath: database) == false)
    }

    @Test func forgedSelectionTargetIsRejectedWithoutChangingRegistry() async throws {
        let fixture = try await Fixture.ready()
        defer { fixture.remove() }
        let forged = WorkspaceAuthoritySelection(id: fixture.selection.id, choice: .versioned,
            target: .init(containerRootPath: fixture.selection.target.containerRootPath,
                workspaceID: WorkspaceObjectID(), deviceID: fixture.selection.target.deviceID,
                attemptID: fixture.selection.target.attemptID), checkpointSHA256: fixture.selection.checkpointSHA256,
            versionedRevisionID: fixture.selection.versionedRevisionID, selectedAt: fixture.selection.selectedAt)
        #expect(throws: WorkspaceAuthorityStoreError.staleSelection(current: fixture.selection.id)) {
            _ = try WorkspaceRevisionStore.openSelected(legacyRoot: fixture.legacy.rootURL, selection: forged)
        }
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: fixture.legacy.rootURL) == fixture.selection)
    }

    @Test func selectedCommitHoldsSharedLeaseThroughMetadataTransaction() async throws {
        let fixture = try await Fixture.ready()
        defer { fixture.remove() }
        let selected = try WorkspaceRevisionStore.openSelected(legacyRoot: fixture.legacy.rootURL, selection: fixture.selection)
        let registry = try WorkspaceAuthorityStore(legacyRoot: fixture.legacy.rootURL)
        let current = try #require(try selected.snapshot())
        var leaseError: WorkspaceAuthorityStoreError?
        _ = try selected.commitMetadata(expectedRevisionID: current.document.revision.id,
            idempotencyKey: WorkspaceObjectID(), inputDigest: String(repeating: "d", count: 64), writerID: fixture.context.revision.writerID) { document in
                do { _ = try registry.withExclusiveAccess { _ in () } }
                catch let error as WorkspaceAuthorityStoreError { leaseError = error }
                document.artifacts[0].identity.displayName = "lease held"
                return [fixture.artifactID]
            }
        #expect(leaseError == .busy)
        #expect(try selected.snapshot()?.document.artifacts[0].identity.displayName == "lease held")
    }

    private struct Fixture {
        let base: WorkspaceMigrationServiceTests.Fixture
        let preparation: WorkspaceMigrationPreparation
        let selection: WorkspaceAuthoritySelection
        let legacy: WorkspaceStore
        let context: WorkspaceMigrationContext
        let artifactID: ArtifactID

        static func prepared() async throws -> Self {
            let base = try WorkspaceMigrationServiceTests.Fixture()
            try base.legacy.saveWorkspaceSnapshot(base.snapshot(label: "reviewed"))
            let preparation = try await base.preparation()
            let migration = try base.service()
            _ = try await migration.stage(preparation)
            _ = try await migration.initialize(attemptID: preparation.record.manifest.attemptID,
                inputDigest: try preparation.record.inputDigest)
            let artifactID = try #require(preparation.record.document.artifacts.first?.identity.id)
            return .init(base: base, preparation: preparation, selection: .init(choice: .versioned,
                target: .init(containerRootPath: base.root.path,
                    workspaceID: base.context.workspaceID, deviceID: base.context.deviceID,
                    attemptID: preparation.record.manifest.attemptID), checkpointSHA256: preparation.record.manifest.checkpointSHA256,
                versionedRevisionID: preparation.record.manifest.initialRevisionID), legacy: base.legacy,
                context: base.context, artifactID: artifactID)
        }

        static func ready() async throws -> Self {
            let value = try await prepared()
            let authority = try value.authority()
            let applied = try await authority.apply(try await authority.prepareActivation(attemptID: value.preparation.record.manifest.attemptID))
            return .init(base: value.base, preparation: value.preparation, selection: applied, legacy: value.legacy,
                context: value.context, artifactID: value.artifactID)
        }

        func authority() throws -> WorkspaceAuthorityService {
            try WorkspaceAuthorityService(legacyRoot: legacy.rootURL, store: base.revisionStore(),
                checkpoints: base.checkpointStore(), content: base.contentStore())
        }
        func remove() { base.remove() }
    }
}

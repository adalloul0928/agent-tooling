import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Workspace migration review")
struct WorkspaceMigrationReviewTests {
    @Test func locationRoundTripsCanonicallyAndRejectsUnknownOrInvalidContent() throws {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        defer { fixture.remove() }
        let location = Self.location(fixture, attemptID: WorkspaceObjectID())
        let bytes = try location.encode()
        #expect(try WorkspaceMigrationReviewLocation.decode(bytes) == location)
        #expect(try WorkspaceMigrationReviewLocation.decode(bytes).encode() == bytes)

        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["unknown"] = true
        let unknown = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(throws: WorkspaceMigrationReviewError.nonCanonicalLocation) {
            try WorkspaceMigrationReviewLocation.decode(unknown)
        }
        let invalid = WorkspaceMigrationReviewLocation(
            legacyRoot: URL(fileURLWithPath: "/"), containerRoot: location.containerRoot,
            checkpointRoot: location.checkpointRoot, contentRoot: location.contentRoot,
            workspaceID: location.workspaceID, deviceID: location.deviceID, attemptID: location.attemptID
        )
        #expect(throws: WorkspaceMigrationReviewError.invalidLocation) { try invalid.encode() }
    }

    @Test func preparedStateIsReadOnlyAndSummarizesReviewedRoots() async throws {
        let ready = try await Self.preparedFixture()
        defer { ready.fixture.remove() }
        let review = try WorkspaceMigrationReviewService(location: ready.location)

        let before = try #require(try ready.fixture.revisionStore().migration(ready.location.attemptID))
        let state = try await review.state()

        #expect(state.journalEntry == before)
        #expect(state.journalEntry.phase == .prepared)
        #expect(state.currentRevisionID == nil)
        #expect(state.authoritySelection == nil)
        #expect(state.reviewedSummary.centralPersonalCount == 1)
        #expect(state.reviewedSummary.assignmentCount == 1)
        #expect(state.reviewedSummary.wholePluginChildCount == 0)
        #expect(try ready.fixture.revisionStore().snapshot() == nil)
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: ready.fixture.legacy.rootURL) == nil)
    }

    @Test func explicitInitializationUsesTheExactPreparedRecord() async throws {
        let ready = try await Self.preparedFixture()
        defer { ready.fixture.remove() }
        let review = try WorkspaceMigrationReviewService(location: ready.location)
        let conflicting = try await ready.fixture.preparation(displayName: "Different review")

        await #expect(throws: WorkspaceMigrationReviewError.wrongBinding) {
            try await review.initializeReviewed(record: conflicting.record)
        }
        #expect(try ready.fixture.revisionStore().snapshot() == nil)

        let initialized = try await review.initializeReviewed(record: ready.preparation.record)
        #expect(initialized.phase == .initialized)
        let replay = try await review.initializeReviewed(record: ready.preparation.record)
        #expect(replay == initialized)
        let state = try await review.state()
        #expect(state.currentRevisionID == ready.preparation.record.document.revision.id)
        #expect(state.authoritySelection == nil)
    }

    @Test func activationAndRollbackFlowThroughTheReviewedLocation() async throws {
        let ready = try await Self.preparedFixture()
        defer { ready.fixture.remove() }
        let review = try WorkspaceMigrationReviewService(location: ready.location)
        _ = try await review.initializeReviewed(record: ready.preparation.record)

        let activation = try await review.prepareActivation()
        #expect(activation.choice == .versioned)
        #expect(activation.target.attemptID == ready.location.attemptID)
        let wrongTarget = WorkspaceAuthoritySelection(
            id: activation.id,
            previousID: activation.previousID,
            choice: activation.choice,
            target: WorkspaceAuthorityTarget(
                containerRootPath: activation.target.containerRootPath,
                workspaceID: activation.target.workspaceID,
                deviceID: WorkspaceObjectID(),
                attemptID: activation.target.attemptID
            ),
            checkpointSHA256: activation.checkpointSHA256,
            versionedRevisionID: activation.versionedRevisionID,
            selectedAt: activation.selectedAt
        )
        await #expect(throws: WorkspaceMigrationReviewError.wrongBinding) {
            try await review.apply(selection: wrongTarget)
        }
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: ready.fixture.legacy.rootURL) == nil)

        let activated = try await review.apply(selection: activation)
        #expect(activated == activation)
        let activatedState = try await review.state()
        #expect(activatedState.authoritySelection == activation)

        let rollback = try await review.prepareRollback()
        #expect(rollback.choice == .legacy)
        #expect(rollback.previousID == activation.id)
        let rolledBack = try await review.apply(selection: rollback)
        #expect(rolledBack == rollback)
        let rolledBackState = try await review.state()
        #expect(rolledBackState.authoritySelection == rollback)
        #expect(try ready.fixture.revisionStore().snapshot()?.document.revision.id == rollback.versionedRevisionID)
    }

    @Test func wrongAttemptAndMissingExplicitRootsNeverCreateFallbackStores() async throws {
        let ready = try await Self.preparedFixture()
        defer { ready.fixture.remove() }
        let wrongAttempt = Self.location(ready.fixture, attemptID: WorkspaceObjectID())
        let wrongReview = try WorkspaceMigrationReviewService(location: wrongAttempt)
        await #expect(throws: WorkspaceMigrationReviewError.missingAttempt) { try await wrongReview.state() }

        let missingContainer = ready.fixture.root.appending(path: "missing-review-container")
        let missing = WorkspaceMigrationReviewLocation(
            legacyRoot: ready.location.legacyRoot, containerRoot: missingContainer,
            checkpointRoot: ready.location.checkpointRoot, contentRoot: ready.location.contentRoot,
            workspaceID: ready.location.workspaceID, deviceID: ready.location.deviceID,
            attemptID: ready.location.attemptID
        )
        let missingReview = try WorkspaceMigrationReviewService(location: missing)
        await #expect(throws: WorkspaceRevisionStoreError.self) { try await missingReview.state() }
        #expect(!FileManager.default.fileExists(atPath: missingContainer.path))
    }

    @Test func aNonCurrentVersionedHeadRequiresAReplacementReview() async throws {
        let ready = try await Self.preparedFixture()
        defer { ready.fixture.remove() }
        let review = try WorkspaceMigrationReviewService(location: ready.location)
        _ = try await review.initializeReviewed(record: ready.preparation.record)
        let store = try ready.fixture.revisionStore()
        let current = try #require(try store.snapshot())
        _ = try store.commitMetadata(
            expectedRevisionID: current.document.revision.id,
            idempotencyKey: WorkspaceObjectID(), inputDigest: String(repeating: "d", count: 64),
            writerID: WorkspaceObjectID()
        ) { document in
            document.artifacts[0].identity.displayName = "Changed after review"
            return [document.artifacts[0].identity.id]
        }

        await #expect(throws: WorkspaceAuthorityServiceError.needsReconciliation) {
            try await review.prepareActivation()
        }
        #expect(try WorkspaceAuthorityStore.readIfPresent(legacyRoot: ready.fixture.legacy.rootURL) == nil)
    }

    @Test func nativePackageSummaryCountsOneRootAndItsWholeChildGraph() async throws {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        defer { fixture.remove() }
        try fixture.legacy.saveWorkspaceSnapshot(fixture.nativeSnapshot())
        let preparation = try await fixture.nativePreparation()
        _ = try await fixture.service().stage(preparation)
        let review = try WorkspaceMigrationReviewService(
            location: Self.location(fixture, attemptID: preparation.record.manifest.attemptID)
        )

        let state = try await review.state()
        #expect(state.reviewedSummary.nativeOwnedCount == 1)
        #expect(state.reviewedSummary.wholePluginChildCount == 1)
        #expect(state.reviewedSummary.centralPersonalCount == 0)
    }

    private struct PreparedFixture {
        let fixture: WorkspaceMigrationServiceTests.Fixture
        let preparation: WorkspaceMigrationPreparation
        let location: WorkspaceMigrationReviewLocation
    }

    private static func preparedFixture() async throws -> PreparedFixture {
        let fixture = try WorkspaceMigrationServiceTests.Fixture()
        do {
            try fixture.legacy.saveWorkspaceSnapshot(fixture.snapshot(label: "reviewed"))
            let preparation = try await fixture.preparation()
            _ = try await fixture.service().stage(preparation)
            return PreparedFixture(
                fixture: fixture,
                preparation: preparation,
                location: location(fixture, attemptID: preparation.record.manifest.attemptID)
            )
        } catch {
            fixture.remove()
            throw error
        }
    }

    private static func location(
        _ fixture: WorkspaceMigrationServiceTests.Fixture,
        attemptID: WorkspaceObjectID
    ) -> WorkspaceMigrationReviewLocation {
        WorkspaceMigrationReviewLocation(
            legacyRoot: fixture.legacy.rootURL,
            containerRoot: fixture.root.appending(path: "revisions"),
            checkpointRoot: fixture.root.appending(path: "checkpoints"),
            contentRoot: fixture.root.appending(path: "content"),
            workspaceID: fixture.context.workspaceID,
            deviceID: fixture.context.deviceID,
            attemptID: attemptID
        )
    }
}

import Foundation
import Testing

@testable import AgentToolingCore

@MainActor
struct WorkspaceLibrarySessionTests {
    @Test func refreshLoadsBoundLibraryStateAndReadModel() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()

        await session.refresh()

        let state = try #require(session.state)
        #expect(state.snapshot.document.workspaceID == fixture.document.workspaceID)
        #expect(state.snapshot.device.deviceID == fixture.device.deviceID)
        #expect(state.library.rows.map(\.artifactID) == [fixture.artifactID])
        #expect(state.library.rows.first?.isAssignable == true)
        #expect(session.errorMessage == nil)
        #expect(session.isBusy == false)
    }

    @Test func writableReviewAppliesReceiptAndRefreshesAfterReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session(access: .writable)
        await session.reviewAssignments(artifactIDs: [fixture.artifactID], destinations: [fixture.destination])

        let review = try #require(session.review)
        #expect(review.preview.additions.count == 1)
        await session.applyReviewedAssignments()

        let receipt = try #require(session.lastReceipt)
        #expect(session.review == nil)
        #expect(session.errorMessage == nil)
        #expect(receipt.affectedArtifactIDs == [fixture.artifactID])
        let reopenedService = WorkspaceApplicationService(store: try fixture.reopen(), writerID: fixture.writerID)
        let saved = try #require(await reopenedService.snapshot())
        #expect(saved.document.assignments.count == 1)
        #expect(saved.document.assignments.first?.artifactID == fixture.artifactID)
    }

    @Test func staleReviewFailsAndPreservesConcurrentRename() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session(access: .writable)
        await session.reviewAssignments(artifactIDs: [fixture.artifactID], destinations: [fixture.destination])
        _ = try await fixture.service.renameArtifact(.init(expectedRevisionID: fixture.document.revision.id,
            artifactID: fixture.artifactID, displayName: "Renamed elsewhere"))

        await session.applyReviewedAssignments()

        #expect(session.lastReceipt == nil)
        #expect(session.review == nil)
        #expect(session.errorMessage?.isEmpty == false)
        let current = try #require(await fixture.service.snapshot())
        #expect(current.document.artifacts.first?.identity.displayName == "Renamed elsewhere")
        #expect(current.document.assignments.isEmpty)
    }

    @Test func nativeChildReviewIsRejectedWhileWholePluginRemainsAssignable() async throws {
        let packageID = ArtifactID()
        let childID = ArtifactID()
        let fixture = try Fixture(artifacts: [
            .init(identity: .init(id: packageID, kind: .nativePlugin, displayName: "Plugin"), authority: .nativeOwned,
                declaredName: "plugin", nativeRoutes: [.init(client: .claude, externalPluginID: "plugin")]),
            .init(identity: .init(id: childID, kind: .skill, displayName: "Child", parentPackageID: packageID),
                authority: .nativeOwned, packageRelativePath: "skills/child")
        ])
        defer { fixture.remove() }
        let session = fixture.session(access: .writable)

        await session.reviewAssignments(artifactIDs: [childID], destinations: [fixture.destination])

        #expect(session.review == nil)
        #expect(session.errorMessage?.contains("whole plugin") == true)
        let packageRow = try #require(session.state?.library.rows.first { $0.artifactID == packageID })
        #expect(packageRow.isAssignable)
    }

    @Test func readOnlySessionCanReviewButCannotSaveAssignment() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session(access: .readOnly)
        await session.reviewAssignments(artifactIDs: [fixture.artifactID], destinations: [fixture.destination])
        #expect(session.review != nil)
        let before = try #require(await fixture.service.snapshot())

        await session.applyReviewedAssignments()

        #expect(session.lastReceipt == nil)
        #expect(session.errorMessage?.contains("cannot be saved") == true)
        #expect(try await fixture.service.snapshot()?.document == before.document)
    }

    /// The shell starts reading the library the moment the window is up. A screen
    /// that asks for the library while that read is still in flight must get the
    /// read's answer when it lands, not an early return with no state behind it:
    /// a plan prepared over "no library yet" is nothing, silently.
    @Test func overlappingRefreshesShareOneReadAndBothReturnWithItsState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let state = try await fixture.service.libraryState()
        let stub = SessionServingStub(state: state, holdLoads: true)
        let session = WorkspaceLibrarySession(service: stub, workspaceID: fixture.document.workspaceID,
            deviceID: fixture.device.deviceID)
        let first = Task { @MainActor in await session.refresh() }
        await stub.waitForLoadStart()
        #expect(session.state == nil)
        let second = Task { @MainActor in
            await session.refresh()
            return session.state != nil
        }
        await Task.yield()
        await stub.releaseLoad()
        #expect(await second.value, "the second caller returned before any state existed")
        await first.value
        #expect(await stub.loadCount == 1)
        #expect(session.isBusy == false)
    }

    @Test func cancelledRefreshDoesNotPublishPartialStateAndResetsBusy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let state = try await fixture.service.libraryState()
        let stub = SessionServingStub(state: state, holdLoads: true)
        let session = WorkspaceLibrarySession(service: stub, workspaceID: fixture.document.workspaceID,
            deviceID: fixture.device.deviceID)
        let refresh = Task { @MainActor in await session.refresh() }
        await stub.waitForLoadStart()
        refresh.cancel()
        await stub.releaseLoad()
        await refresh.value
        #expect(session.state == nil)
        #expect(session.errorMessage == nil)
        #expect(session.isBusy == false)
    }

    @Test func refreshRejectsStateForWrongWorkspaceOrDevice() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let state = try await fixture.service.libraryState()
        let stub = SessionServingStub(state: state)
        let session = WorkspaceLibrarySession(service: stub, workspaceID: WorkspaceObjectID(), deviceID: fixture.device.deviceID)

        await session.refresh()

        #expect(session.state == nil)
        #expect(session.errorMessage?.isEmpty == false)
        #expect(session.isBusy == false)
    }

    @Test func successfulApplyRetainsReceiptWhenFollowupReadFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let state = try await fixture.service.libraryState()
        let stub = SessionServingStub(state: state, failLoadsAfter: 1, receiptArtifactID: fixture.artifactID)
        let session = WorkspaceLibrarySession(service: stub, workspaceID: fixture.document.workspaceID,
            deviceID: fixture.device.deviceID, access: .writable)
        await session.reviewAssignments(artifactIDs: [fixture.artifactID], destinations: [fixture.destination])
        #expect(session.review != nil)

        await session.applyReviewedAssignments()

        #expect(session.lastReceipt != nil)
        #expect(session.review == nil)
        #expect(session.errorMessage?.contains("could not refresh") == true)
        #expect(await stub.applyCount == 1)
    }

    @MainActor private struct Fixture {
        let root: URL
        let artifactID: ArtifactID
        let writerID = WorkspaceObjectID()
        let document: PortableWorkspaceDocument
        let device: DeviceWorkspaceState
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let destination = PortableDestination(surface: .claudeCode, scope: .user)

        init(artifacts: [ArtifactRecord]? = nil) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "library-session-\(UUID())")
            let defaultID = ArtifactID()
            artifactID = artifacts?.first?.identity.id ?? defaultID
            let records = artifacts ?? [.init(identity: .init(id: defaultID, kind: .skill, displayName: "Skill"), authority: .centralPersonal)]
            document = try WorkspaceDocumentCoding.seal(.init(revision: .init(writerID: writerID), artifacts: records))
            device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
        }

        func session(access: WorkspaceLibraryAccess = .readOnly) -> WorkspaceLibrarySession {
            WorkspaceLibrarySession(service: service, workspaceID: document.workspaceID, deviceID: device.deviceID, access: access)
        }

        func reopen() throws -> WorkspaceRevisionStore {
            try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor SessionServingStub: WorkspaceLibraryServing {
    let state: WorkspaceLibraryState
    let holdLoads: Bool
    let failLoadsAfter: Int?
    let receiptArtifactID: ArtifactID?
    private(set) var loadCount = 0
    private(set) var applyCount = 0
    private var loadStarted = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    init(state: WorkspaceLibraryState, holdLoads: Bool = false, failLoadsAfter: Int? = nil, receiptArtifactID: ArtifactID? = nil) {
        self.state = state
        self.holdLoads = holdLoads
        self.failLoadsAfter = failLoadsAfter
        self.receiptArtifactID = receiptArtifactID
    }

    func libraryState() async throws -> WorkspaceLibraryState {
        loadCount += 1
        if let failLoadsAfter, loadCount > failLoadsAfter { throw WorkspaceRevisionStoreError.databaseUnavailable }
        if holdLoads {
            loadStarted = true
            loadWaiters.forEach { $0.resume() }
            loadWaiters.removeAll()
            await withCheckedContinuation { release = $0 }
        }
        return state
    }

    func previewAssignmentBatch(_ command: WorkspaceAssignmentBatchCommand) async throws -> WorkspaceAssignmentBatchPreview {
        .init(expectedRevisionID: command.expectedRevisionID, additions: command.additions, removals: [],
            remainingContributions: command.additions)
    }

    func applyAssignmentBatch(_ command: WorkspaceAssignmentBatchCommand) async throws -> WorkspaceCommandReceipt {
        applyCount += 1
        return .init(idempotencyKey: command.idempotencyKey, inputDigest: try command.inputDigest(),
            previousRevisionID: command.expectedRevisionID, committedRevisionID: WorkspaceObjectID(),
            affectedArtifactIDs: receiptArtifactID.map { [$0] } ?? [])
    }

    func waitForLoadStart() async {
        if loadStarted { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    func releaseLoad() {
        release?.resume()
        release = nil
    }
}

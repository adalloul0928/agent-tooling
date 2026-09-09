import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

@MainActor
struct WorkspaceMigrationReviewSessionTests {
    @Test func refreshReadsStateWithoutInitializingOrApplying() async throws {
        let fixture = try Fixture()
        let service = ReviewStub(state: fixture.state)
        let session = WorkspaceMigrationReviewSession(service: service, location: fixture.location)

        await session.refresh()

        #expect(session.state == fixture.state)
        #expect(await service.initializeCount == 0)
        #expect(await service.applyCount == 0)
        #expect(session.pendingSelection == nil)
    }

    @Test func cancelledPrepareDoesNotApplyAndBusyRefreshCoalesces() async throws {
        let fixture = try Fixture()
        let service = ReviewStub(state: fixture.state, holdPrepare: true)
        let session = WorkspaceMigrationReviewSession(service: service, location: fixture.location)
        let prepare = Task { @MainActor in await session.prepareActivation() }
        await service.waitForPrepareStart()
        prepare.cancel()
        await session.refresh()
        #expect(await service.stateCount == 0)
        await service.releasePrepare()
        await prepare.value

        #expect(await service.prepareCount == 1)
        #expect(await service.applyCount == 0)
        #expect(session.pendingSelection == nil)
        #expect(session.isBusy == false)
    }

    @Test func applyPreservesReceiptWhenFollowupStateReadFails() async throws {
        let fixture = try Fixture()
        let service = ReviewStub(state: fixture.state, failStateAfter: 0, appliedSelection: fixture.selection)
        let session = WorkspaceMigrationReviewSession(service: service, location: fixture.location)
        await session.prepareActivation()
        await session.applyPendingSelection()

        #expect(session.committedSelection == fixture.selection)
        #expect(session.pendingSelection == nil)
        #expect(session.errorMessage?.contains("saved") == true)
        #expect(await service.applyCount == 1)
    }

    @Test func cancellingPreparedSelectionClearsPendingWithoutApplying() async throws {
        let fixture = try Fixture()
        let service = ReviewStub(state: fixture.state)
        let session = WorkspaceMigrationReviewSession(service: service, location: fixture.location)
        await session.prepareActivation()
        #expect(session.pendingSelection != nil)

        session.cancelPendingSelection()

        #expect(session.pendingSelection == nil)
        #expect(await service.applyCount == 0)
    }

    @Test func refreshClearsPendingSelection() async throws {
        let fixture = try Fixture()
        let service = ReviewStub(state: fixture.state)
        let session = WorkspaceMigrationReviewSession(service: service, location: fixture.location)
        await session.prepareActivation()
        #expect(session.pendingSelection != nil)

        await session.refresh()

        #expect(session.pendingSelection == nil)
        #expect(session.state == fixture.state)
    }

    @Test func initializePreservesInitializedEntryWhenFollowupStateReadFails() async throws {
        let fixture = try Fixture()
        let initialized = WorkspaceMigrationJournalEntry(record: fixture.record, phase: .initialized)
        let service = ReviewStub(state: fixture.state, failStateAfter: 1, initializedEntry: initialized)
        let session = WorkspaceMigrationReviewSession(service: service, location: fixture.location)
        await session.refresh()
        await session.initializeReviewed()

        #expect(session.initializedEntry == initialized)
        #expect(session.errorMessage?.contains("initialized") == true)
        #expect(await service.initializeCount == 1)
    }

    private struct Fixture {
        let location: WorkspaceMigrationReviewLocation
        let record: WorkspaceMigrationRecord
        let state: WorkspaceMigrationReviewState
        let selection: WorkspaceAuthoritySelection

        init() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "migration-review-session-\(UUID())")
            let legacy = root.appending(path: "legacy", directoryHint: .isDirectory)
            let container = root.appending(path: "versioned", directoryHint: .isDirectory)
            let workspaceID = WorkspaceObjectID(), deviceID = WorkspaceObjectID(), attemptID = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(.init(workspaceID: workspaceID, revision: .init(writerID: WorkspaceObjectID())))
            let device = DeviceWorkspaceState(workspaceID: workspaceID, deviceID: deviceID)
            record = .init(manifest: .init(formatVersion: 1, attemptID: attemptID, workspaceID: workspaceID,
                deviceID: deviceID, initialRevisionID: document.revision.id,
                legacyDatabasePath: legacy.appending(path: "agent-tooling.sqlite").path,
                checkpointSHA256: String(repeating: "a", count: 64),
                documentSHA256: WorkspaceMigrationRecord.hash(try WorkspaceDocumentCoding.encode(document)),
                deviceSHA256: WorkspaceMigrationRecord.hash(try WorkspaceDocumentCoding.encodeDeviceState(device)),
                content: [], sourceCaptures: [], deploymentNames: []), document: document, device: device)
            location = .init(legacyRoot: legacy, containerRoot: container, checkpointRoot: root.appending(path: "checkpoints"),
                contentRoot: root.appending(path: "content"), workspaceID: workspaceID, deviceID: deviceID, attemptID: attemptID)
            let journal = WorkspaceMigrationJournalEntry(record: record, phase: .prepared)
            state = try .init(journalEntry: journal, currentRevisionID: nil, authoritySelection: nil,
                reviewedSummary: .init(centralPersonalCount: 0, centralUpstreamCount: 0, nativeOwnedCount: 0,
                    attachedAuthoringCount: 0, trackedOnlyCount: 0, assignmentCount: 0, wholePluginChildCount: 0))
            selection = .init(choice: .versioned,
                target: .init(containerRootPath: container.path, workspaceID: workspaceID, deviceID: deviceID, attemptID: attemptID),
                checkpointSHA256: record.manifest.checkpointSHA256, versionedRevisionID: document.revision.id)
        }
    }
}

private actor ReviewStub: WorkspaceMigrationReviewServing {
    let stateValue: WorkspaceMigrationReviewState
    let appliedSelection: WorkspaceAuthoritySelection?
    let initializedValue: WorkspaceMigrationJournalEntry?
    let failStateAfter: Int?
    let holdPrepare: Bool
    private(set) var stateCount = 0
    private(set) var initializeCount = 0
    private(set) var applyCount = 0
    private(set) var prepareCount = 0
    private var prepareStarted = false
    private var prepareWaiters: [CheckedContinuation<Void, Never>] = []
    private var prepareRelease: CheckedContinuation<Void, Never>?

    init(state: WorkspaceMigrationReviewState, failStateAfter: Int? = nil, appliedSelection: WorkspaceAuthoritySelection? = nil,
         initializedEntry: WorkspaceMigrationJournalEntry? = nil, holdPrepare: Bool = false) {
        stateValue = state; self.failStateAfter = failStateAfter; self.appliedSelection = appliedSelection
        initializedValue = initializedEntry; self.holdPrepare = holdPrepare
    }

    func state() async throws -> WorkspaceMigrationReviewState {
        stateCount += 1
        if let failStateAfter, stateCount > failStateAfter { throw WorkspaceMigrationReviewError.wrongBinding }
        return stateValue
    }
    func initializeReviewed(record: WorkspaceMigrationRecord) async throws -> WorkspaceMigrationJournalEntry {
        initializeCount += 1
        return initializedValue ?? .init(record: record, phase: .initialized)
    }
    func prepareActivation() async throws -> WorkspaceAuthoritySelection {
        prepareCount += 1
        if holdPrepare {
            prepareStarted = true; prepareWaiters.forEach { $0.resume() }; prepareWaiters.removeAll()
            await withCheckedContinuation { prepareRelease = $0 }
        }
        return appliedSelection ?? .init(choice: .versioned, target: .init(containerRootPath: "/tmp", workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID(), attemptID: WorkspaceObjectID()), checkpointSHA256: String(repeating: "a", count: 64), versionedRevisionID: WorkspaceObjectID())
    }
    func prepareRollback() async throws -> WorkspaceAuthoritySelection { try await prepareActivation() }
    func apply(selection: WorkspaceAuthoritySelection) async throws -> WorkspaceAuthoritySelection { applyCount += 1; return appliedSelection ?? selection }
    func waitForPrepareStart() async { if prepareStarted { return }; await withCheckedContinuation { prepareWaiters.append($0) } }
    func releasePrepare() { prepareRelease?.resume(); prepareRelease = nil }
}

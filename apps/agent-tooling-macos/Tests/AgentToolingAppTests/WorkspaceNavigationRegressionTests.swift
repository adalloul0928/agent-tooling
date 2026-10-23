import AgentToolingTestSupport
import Foundation
import SQLite3
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

@Suite("Workspace navigation and settings regressions")
@MainActor
struct WorkspaceNavigationRegressionTests {
    @Test func changingProjectDuringAReadPublishesOnlyTheNewestScope() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let reader = DeferredSettingsReader()
        let session = WorkspaceSettingsSession(
            homeRoot: fixture.home, library: fixture.workspace.library,
            managedPolicyPath: .some(nil), reader: reader)
        let firstRead = Task { await session.refresh() }
        await reader.waitUntilReading()
        let newestProject = ArtifactID()

        session.select(project: newestProject)
        #expect(session.selectedProjectID == newestProject)
        #expect(session.surfaces.isEmpty)
        #expect(!session.hasLoaded)
        await reader.release()
        await firstRead.value

        #expect(session.surfaces.first?.title == newestProject.rawValue.uuidString)
        #expect(session.hasLoaded)
        #expect(!session.isBusy)
        #expect(await reader.projectIDs.last == newestProject)
    }

    @Test func changingManagedClientsDuringAReadDropsTheOldSurfaces() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let reader = DeferredSettingsReader()
        let session = WorkspaceSettingsSession(
            homeRoot: fixture.home, library: fixture.workspace.library,
            managedPolicyPath: .some(nil), reader: reader)
        let firstRead = Task { await session.refresh(managedClients: [.claude]) }
        await reader.waitUntilReading()

        await session.refresh(managedClients: [.codex])
        #expect(session.surfaces.isEmpty)
        #expect(!session.hasNoReadableSurfaces)
        await reader.release()
        await firstRead.value

        #expect(session.surfaces.map(\.id) == [.codexCLI])
        #expect(await reader.clientScopes == [[.claude], [.codex]])
    }

    @Test func appSettingsReadOnlyTheRequestedEnabledClients() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        try write(fixture.home.appending(path: ".claude/CLAUDE.md"), "Claude fixture instructions")
        try write(fixture.home.appending(path: ".codex/AGENTS.md"), "Codex fixture instructions")
        let session = WorkspaceSettingsSession(
            homeRoot: fixture.home, library: fixture.workspace.library, managedPolicyPath: .some(nil))

        await session.refresh(managedClients: [.codex])
        #expect(session.surfaces.map(\.id) == [.codexCLI])
        #expect(session.instructions?.entries.map(\.surface) == [.codexCLI])
        await session.refresh(managedClients: [])
        #expect(session.surfaces.isEmpty)
        #expect(session.instructions?.entries.isEmpty == true)
        #expect(session.hasLoaded)
    }

    @Test func anExecutedOperationAppearsWithoutAnArtificialJournalEntry() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let plan = OperationPlan(
            kind: .doctor, title: "Review setup", summary: "Manual local check",
            steps: [.init(kind: .manual, title: "Review client", detail: "Check the displayed settings.")])
        let executor = OperationExecutor(store: fixture.store, homeURL: fixture.home)
        let receipt = await executor.execute(plan)
        #expect(try fixture.store.activityJournal(as: AgentActivityJournal.self, default: .init()).entries.isEmpty)
        let session = WorkspaceActivitySession(store: fixture.store)
        #expect(!session.hasLoaded)
        #expect(session.activityID(for: receipt.id.uuidString) == nil)
        await session.refresh(driftReader: StubInstallDriftReader())

        #expect(session.hasLoaded)
        #expect(session.mergedActivities.count == 1)
        #expect(session.mergedActivities.first?.operationReceiptID == receipt.id)
        #expect(session.activityID(for: receipt.id.uuidString) == receipt.id)
        #expect(session.operationReceipt(for: receipt.id)?.itemOutcomes.count == 1)

        let journalID = UUID()
        try fixture.store.saveActivityJournal(
            AgentActivityJournal(entries: [
                .init(
                    id: journalID, kind: .validation, title: "Reviewed setup", detail: "Additional context",
                    date: receipt.createdAt, state: receipt.state, operationReceiptID: receipt.id)
            ]))
        await session.refresh(driftReader: StubInstallDriftReader())
        #expect(session.mergedActivities.count == 1)
        #expect(session.activityID(for: receipt.id.uuidString) == journalID)
    }

    @Test func removalRecoveryPathsRemainVisibleBeyondTheCondensedOutcome() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let stepID = UUID()
        let recovery = fixture.root.appending(path: "recovery/removed-skill").path
        let original = fixture.home.appending(path: ".claude/skills/removed-skill").path
        let output =
            String(repeating: "Reviewed local removal. ", count: 20)
            + "Recovery folder: \(recovery). Original destination: \(original)."
        let receipt = OperationReceipt(
            planID: UUID(), kind: .installSkill, title: "Remove a managed skill", state: .healthy,
            targetSurfaces: [.claudeCode],
            results: [.init(stepID: stepID, status: .succeeded, output: output, startedAt: .now, finishedAt: .now)],
            verificationSummary: "Removed with a recovery copy.",
            itemOutcomes: [
                .init(
                    id: stepID, title: "Remove managed skill", status: .succeeded,
                    reason: "Removed. Full recovery details are in the receipt.")
            ])
        try fixture.store.recordOperationReceipt(receipt)
        let session = WorkspaceActivitySession(store: fixture.store)
        await session.refresh(driftReader: StubInstallDriftReader())
        let saved = try #require(session.operationReceipt(for: receipt.id))
        #expect(saved.results.first?.output == output)
        let elements = accessibilitySnapshot(OperationReceiptOutputs(receipt: saved))
        #expect(elements.contains { $0.identifier == "operation-step-output-\(stepID.uuidString)" })
        let text = elements.flatMap { [$0.label, $0.value].compactMap { $0 } }.joined(separator: "\n")
        #expect(text.contains(recovery))
        #expect(text.contains(original))
    }

    @Test(arguments: [false, true])
    func activityReadFinishesBeforeSlowDriftInspection(unreadableJournal: Bool) async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let receipt = try fixture.seedActivity()
        if unreadableJournal {
            try fixture.store.saveActivityJournal("Unreadable fixture journal")
        }
        let reader = DeferredInstallDriftReader()
        let session = WorkspaceActivitySession(store: fixture.store)
        let refresh = Task { await session.refresh(driftReader: reader) }
        await reader.waitUntilReading()

        #expect(session.isBusy, "The installed-tree inspection is still pending.")
        #expect(session.hasLoaded, "Primary activity and its read errors must already be visible.")
        if unreadableJournal {
            #expect(session.errorMessage != nil)
            #expect(session.mergedActivities.isEmpty)
        } else {
            #expect(session.errorMessage == nil)
            #expect(session.mergedActivities.first?.operationReceiptID == receipt.id)
        }

        await reader.release()
        await refresh.value
        #expect(!session.isBusy)
    }

    @Test func aColdSkillNameRouteWaitsThenIsConsumedExactlyOnce() async throws {
        let fixture = try await ShellRenderFixture(readsLibrary: false)
        defer { fixture.remove() }
        let navigation = AppNavigationState()
        navigation.open(.skill("standalone-skill"))
        #expect(navigation.resolveRequestedSkill(in: []) == nil)
        #expect(navigation.requestedSkillID == "standalone-skill")

        await fixture.workspace.library.refresh()
        let skills = SkillInventoryIndex(
            library: fixture.workspace.library.state?.library,
            snapshot: fixture.workspace.library.state?.snapshot,
            observations: [], ownershipJSON: "{}"
        ).skills
        #expect(navigation.resolveRequestedSkill(in: skills) == ShellRenderFixture.skill)
        #expect(navigation.requestedSkillID == nil)
        #expect(navigation.resolveRequestedSkill(in: skills) == nil)
        navigation.open(.skill(ShellRenderFixture.skill.rawValue.uuidString.uppercased()))
        #expect(navigation.resolveRequestedSkill(in: skills) == ShellRenderFixture.skill)
        // Ambiguous legacy names never select an arbitrary matching record.
        #expect(SkillRouteResolver.resolve("standalone-skill", in: skills + skills) == nil)
    }

    @Test func pendingReviewAndPaletteObjectsReachTheirExactDestinations() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let navigation = AppNavigationState()
        navigation.openClient(.codex)
        navigation.open(.section(.overview))
        let requestID = UUID()
        navigation.open(.pendingRequest(requestID))
        #expect(navigation.requestedSection == .syncCenter)
        #expect(navigation.selectedClient == nil)
        navigation.consumeRequestedSection(.syncCenter)
        #expect(navigation.requestedPendingRequestID == requestID)

        let items = CommandPaletteCatalog.items(for: fixture.workspace)
        #expect(
            items.contains { $0.outcome == .screenRequest(.selectPreset(ShellRenderFixture.presetID.rawValue.uuidString.lowercased())) })
        #expect(
            items.contains { $0.outcome == .screenRequest(.selectProject(ShellRenderFixture.projectID.rawValue.uuidString.lowercased())) })
        navigation.openItem(ShellRenderFixture.projectID.rawValue.uuidString, in: .projects)
        #expect(navigation.resolveRequestedItem(in: []) == nil)
        #expect(navigation.requestedItemID != nil)
        #expect(navigation.resolveRequestedItem(in: [ShellRenderFixture.projectID]) == ShellRenderFixture.projectID)
        #expect(navigation.requestedItemID == nil)
    }

    @Test func anExactRequestWaitsForTheAlreadyRunningQueueRead() async throws {
        let requested = ShellRenderFixture.pendingRequest()
        let queue = DeferredPendingRequestQueue(request: requested)
        let fixture = try await ShellRenderFixture(requestQueue: queue)
        defer {
            queue.release()
            fixture.remove()
        }
        let session = fixture.workspace.requests
        let firstRead = Task { await session.refresh() }
        await queue.waitUntilReading()
        #expect(session.requests.isEmpty)
        #expect(session.isBusy)

        // The release can run only once the exact lookup yields. A busy
        // refresh that returns early would look in the still-empty array.
        let release = Task { @MainActor in queue.release() }
        let found = await session.request(id: requested.id)
        await release.value
        await firstRead.value

        #expect(found?.id == requested.id)
        #expect(queue.readCount == 1)
        #expect(session.errorMessage == nil)
    }

    @Test(arguments: [false, true])
    func queuedRequestsWaitForRequestAndPlanDismissal(planFinishesFirst: Bool) {
        let presentation = ClientReviewPresentation()
        let first = ShellRenderFixture.pendingRequest()
        let next = UUID()
        presentation.present(first, draftingClient: .codex)
        #expect(presentation.draftingClient == .codex)
        presentation.acceptedRequest()
        #expect(presentation.reviewedRequest == nil)
        #expect(!presentation.beginRequestLoad(next))

        if planFinishesFirst {
            presentation.prepared(hasPlan: true)
            #expect(!presentation.isReviewingPlan)
            #expect(!presentation.beginRequestLoad(next))
            #expect(presentation.finishRequestPresentation() == first.id)
        } else {
            #expect(presentation.finishRequestPresentation() == first.id)
            #expect(!presentation.beginRequestLoad(next))
            presentation.prepared(hasPlan: true)
        }
        #expect(presentation.isReviewingPlan)
        #expect(presentation.draftingClient == nil)
        #expect(!presentation.beginRequestLoad(next))
        presentation.isReviewingPlan = false
        #expect(!presentation.beginRequestLoad(next), "The plan is still dismissing.")
        presentation.finishPlanPresentation()
        #expect(presentation.beginRequestLoad(next))
        #expect(!presentation.beginRequestLoad(next), "A queued lookup starts only once.")
        presentation.finishRequestLoad(next)
        presentation.present(ShellRenderFixture.pendingRequest())
        #expect(presentation.reviewedRequest != nil)
    }

    @Test func anExportSelectionMustStillBelongToTheDisplayedPreset() {
        let previous = ArtifactID()
        let current = ArtifactID()
        #expect(PresetsView.shareableSelection(previous, candidates: [previous]) == previous)
        #expect(PresetsView.shareableSelection(previous, candidates: [current]) == nil)
        #expect(PresetsView.shareableSelection(previous, candidates: []) == nil)
    }

    @Test func unreadableHistoryIsVisibleAndRetryClearsTheFailure() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let document = try #require(try fixture.store.snapshot()).document
        let saved = try WorkspaceDocumentCoding.encode(document)
        let history = fixture.workspace.history
        #expect(!history.hasLoaded)
        try replaceHeadPayload(Data([0]), in: fixture.store)
        await history.refresh()
        #expect(history.hasLoaded)
        #expect(history.points.isEmpty)
        #expect(history.errorMessage != nil)

        let failed = accessibilitySnapshot(HistorySection(workspace: fixture.workspace))
        let labels = failed.flatMap { [$0.label, $0.value].compactMap { $0 } }.joined(separator: "\n")
        #expect(labels.contains("History could not be read"))
        #expect(labels.contains("Try again"))
        #expect(!labels.contains("No earlier versions"))

        try replaceHeadPayload(saved, in: fixture.store)
        await history.refresh()
        #expect(history.errorMessage == nil)
        #expect(history.points.count == 1)
        history.select(WorkspaceObjectID())
        #expect(history.errorMessage != nil)
        history.select(document.revision.id)
        #expect(history.preview != nil)
        #expect(history.errorMessage == nil)
    }

    private func replaceHeadPayload(_ data: Data, in store: WorkspaceRevisionStore) throws {
        var database: OpaquePointer?
        guard sqlite3_open(store.databaseURL.path, &database) == SQLITE_OK, let database else {
            throw WorkspaceRevisionStoreError.databaseUnavailable
        }
        defer { sqlite3_close(database) }
        // Simulate on-disk corruption in this disposable fixture, outside the
        // store's normal immutable-revision write guard.
        guard sqlite3_exec(database, "DROP TRIGGER IF EXISTS revisions_immutable_update", nil, nil, nil) == SQLITE_OK else {
            throw WorkspaceRevisionStoreError.corruptState
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "UPDATE revisions SET payload = ? WHERE id = (SELECT revision_id FROM workspace_head)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WorkspaceRevisionStoreError.corruptState
        }
        let status = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard status == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw WorkspaceRevisionStoreError.corruptState
        }
    }
}

private actor DeferredInstallDriftReader: InstallDriftReading {
    private var started = false
    private var gate: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func drift(in store: WorkspaceRevisionStore) async -> [InstalledPackageDrift] {
        started = true
        for arrival in arrivals { arrival.resume() }
        arrivals = []
        await withCheckedContinuation { gate = $0 }
        return []
    }

    func waitUntilReading() async {
        guard !started else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

private final class DeferredPendingRequestQueue: PendingRequestQueuing, @unchecked Sendable {
    private let condition = NSCondition()
    private let request: PendingAgentRequest
    private var started = false
    private var released = false
    private var reads = 0
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    init(request: PendingAgentRequest) { self.request = request }

    var readCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return reads
    }

    func pendingRequests(store: WorkspaceRevisionStore) throws -> [PendingAgentRequest] {
        condition.lock()
        defer { condition.unlock() }
        reads += 1
        started = true
        for arrival in arrivals { arrival.resume() }
        arrivals = []
        while !released { condition.wait() }
        return [request]
    }

    func waitUntilReading() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            defer { condition.unlock() }
            if started { continuation.resume() } else { arrivals.append(continuation) }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func resolve(id: UUID, expectedFingerprint: String, store: WorkspaceRevisionStore) throws -> PendingAgentRequest? { nil }
    func restore(_ request: PendingAgentRequest, store: WorkspaceRevisionStore) throws {}
}

private actor DeferredSettingsReader: WorkspaceSettingsReading {
    private(set) var projectIDs: [ArtifactID?] = []
    private(set) var clientScopes: [Set<ClientKind>] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func read(_ request: WorkspaceSettingsReadRequest) async -> WorkspaceSettingsReadResult {
        projectIDs.append(request.projectID)
        clientScopes.append(request.clients)
        if projectIDs.count == 1 {
            for arrival in arrivals { arrival.resume() }
            arrivals = []
            await withCheckedContinuation { gate = $0 }
        }
        return .init(
            instructions: AgentInstructionInventory.scan(homeRoot: request.homeRoot, surfaces: []),
            surfaces: [
                .init(
                    id: request.clients == [.codex] ? .codexCLI : .claudeCode,
                    title: request.projectID?.rawValue.uuidString ?? "No project",
                    configuration: nil, errorMessage: nil)
            ])
    }

    func waitUntilReading() async {
        guard projectIDs.isEmpty else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

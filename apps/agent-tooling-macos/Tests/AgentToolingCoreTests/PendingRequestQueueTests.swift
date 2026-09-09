import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Pending request queue lifecycle")
struct PendingRequestQueueTests {
    @Test func resolvingARequestPersistsItsRemovalAndFreesCapacity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outcome = try fixture.enqueue(component: "weather", client: "Claude Code")
        let resolved = try PendingRequestQueueService.resolve(
            id: outcome.request.id,
            expectedFingerprint: outcome.request.fingerprint,
            store: fixture.store
        )

        #expect(resolved?.id == outcome.request.id)
        #expect(try fixture.store.pendingRequestQueue().requests.isEmpty)
        #expect(
            try PendingRequestQueueService.resolve(
                id: outcome.request.id,
                expectedFingerprint: outcome.request.fingerprint,
                store: fixture.store
            ) == nil)
    }

    @Test func resolvingWithAStaleFingerprintLeavesTheCurrentRowQueued() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outcome = try fixture.enqueue(component: "weather", client: "Claude Code")

        #expect(throws: PendingRequestQueueError.requestConflict) {
            try PendingRequestQueueService.resolve(
                id: outcome.request.id,
                expectedFingerprint: String(repeating: "0", count: 64),
                store: fixture.store
            )
        }
        let remaining = try fixture.store.pendingRequestQueue().requests
        #expect(remaining.map(\.id) == [outcome.request.id])
        #expect(remaining.map(\.fingerprint) == [outcome.request.fingerprint])
        #expect(remaining.first?.componentID == outcome.request.componentID)
    }
    @Test func expiredRowsAndTheirSkillDraftPayloadsAreRemovedOnAdmission() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let old = try PendingRequestQueueService.enqueue(
            kind: .createSkill,
            title: "Create old skill",
            summary: "Old fixture",
            componentID: "old-skill",
            scope: .user,
            targets: [.codex],
            reason: nil,
            reviewDetails: PendingRequestReviewDetails(instruction: "Old instruction"),
            fingerprintInputs: ["old-skill", "Old instruction"],
            clientLabel: "Old client",
            store: fixture.store,
            now: oldDate
        )
        try fixture.store.saveRequestDraft(
            old.request.id,
            CodexSkillDraftRequest(id: old.request.id, instruction: "Old instruction"))
        let repeated = try PendingRequestQueueService.enqueue(
            kind: .createSkill,
            title: "Create old skill",
            summary: "Old fixture",
            componentID: "old-skill",
            scope: .user,
            targets: [.codex],
            reason: nil,
            reviewDetails: PendingRequestReviewDetails(instruction: "Old instruction"),
            fingerprintInputs: ["old-skill", "Old instruction"],
            clientLabel: "Another self-reported client",
            store: fixture.store,
            now: oldDate.addingTimeInterval(PendingAgentRequestQueue.maximumPendingAge - 1)
        )
        #expect(repeated.collapsed)
        #expect(repeated.request.lastRequestedAt > repeated.request.createdAt)
        _ = try fixture.enqueue(
            component: "current",
            client: "Current client",
            now: oldDate.addingTimeInterval(PendingAgentRequestQueue.maximumPendingAge + 1)
        )
        let rows = try fixture.store.pendingRequestQueue().requests
        #expect(rows.map(\.componentID) == ["current"])
        #expect(try fixture.store.requestDraft(old.request.id, as: CodexSkillDraftRequest.self) == nil)
    }
    @Test func concurrentProcessesDoNotOverwriteEachOthersRequests() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PendingQueueConcurrency-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        // Sixteen separate handles on one workspace, the way sixteen processes
        // would each open it.
        let document = try WorkspaceDocumentCoding.seal(.init(
            workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID())))
        let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        let first = try WorkspaceRevisionStore(containerRoot: root,
            workspaceID: document.workspaceID, deviceID: device.deviceID)
        try first.initialize(document: document, device: device)
        let stores = try [first] + (1..<16).map { _ in
            try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID,
                                       deviceID: device.deviceID)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, store) in stores.enumerated() {
                group.addTask {
                    _ = try PendingRequestQueueService.enqueue(
                        kind: .installSkill,
                        title: "Install fixture \(index)",
                        summary: "Concurrency fixture",
                        componentID: "fixture-\(index)",
                        scope: .user,
                        targets: [.codex],
                        reason: nil,
                        reviewDetails: PendingRequestReviewDetails(),
                        fingerprintInputs: ["fixture-\(index)"],
                        clientLabel: "Client \(index % 4)",
                        store: store
                    )
                }
            }
            try await group.waitForAll()
        }
        let rows = try WorkspaceRevisionStore(
            containerRoot: root, workspaceID: stores[0].workspaceID,
            deviceID: stores[0].deviceID).pendingRequestQueue().requests
        #expect(rows.count == 16)
        #expect(Set(rows.compactMap(\.componentID)).count == 16)
    }

    @Test func listingPrunesExpiredRowsWithoutRequiringAnotherAdmission() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try fixture.enqueue(component: "expired", client: "Display label", now: createdAt)

        let current = try PendingRequestQueueService.pendingRequests(
            store: fixture.store,
            now: createdAt.addingTimeInterval(PendingAgentRequestQueue.maximumPendingAge + 1)
        )

        #expect(current.isEmpty)
        #expect(try fixture.store.pendingRequestQueue().requests.isEmpty)
    }
    private struct Fixture {
        let root: URL
        let store: WorkspaceRevisionStore
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "PendingQueueLifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID())))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: root,
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
        }
        func enqueue(component: String, client: String, now: Date = .now) throws -> PendingRequestOutcome {
            try PendingRequestQueueService.enqueue(
                kind: .installSkill,
                title: "Install \(component)",
                summary: "Lifecycle fixture",
                componentID: component,
                scope: .user,
                targets: [.codex],
                reason: nil,
                reviewDetails: PendingRequestReviewDetails(),
                fingerprintInputs: [component],
                clientLabel: client,
                store: store,
                now: now
            )
        }
        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

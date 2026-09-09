import Foundation
import Testing

@testable import AgentToolingCore

/// Receipts, the agent review queue and the activity journal, on the versioned
/// store. `DeviceWorkspaceState` reserved slots for the first two from the
/// start; this is where their bodies live.
@Suite("Workspace operational records")
struct WorkspaceOperationalRecordTests {
    @Test func aRecordedReceiptComesBackAndTheDeviceKnowsAboutIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receipt = Fixture.receipt(title: "Installed a skill")

        try fixture.store.recordOperationReceipt(receipt)

        #expect(try fixture.store.operationReceipts() == [receipt])
        #expect(try fixture.store.operationReceipt(receipt.id) == receipt)
        // A receipt the device does not know about would be a record nothing
        // points at, so both halves are written together.
        let device = try #require(try fixture.store.snapshot()).device
        #expect(device.receiptIDs == [WorkspaceObjectID(receipt.id)])
    }

    @Test func receiptsComeBackNewestFirstByWhenTheyHappened() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let older = Fixture.receipt(title: "First", at: 1_700_000_000)
        let newer = Fixture.receipt(title: "Second", at: 1_700_000_900)

        // Written in the wrong order on purpose.
        try fixture.store.recordOperationReceipt(newer)
        try fixture.store.recordOperationReceipt(older)

        #expect(try fixture.store.operationReceipts().map(\.title) == ["Second", "First"])
        #expect(try fixture.store.operationReceipts(limit: 1).map(\.title) == ["Second"])
    }

    @Test func aReceiptCannotBeRewrittenAfterTheFact() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receipt = Fixture.receipt(title: "What happened")
        try fixture.store.recordOperationReceipt(receipt)

        var edited = receipt
        edited.title = "Something else"
        try fixture.store.recordOperationReceipt(edited)

        // A record of what happened is worth nothing if it can be edited, so a
        // repeat of the same id is a no-op rather than an overwrite.
        #expect(try fixture.store.operationReceipt(receipt.id)?.title == "What happened")
        #expect(try fixture.store.operationReceipts().count == 1)
    }

    @Test func aLongLivedWorkspaceKeepsAMemoryRatherThanALog() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let extra = 5
        for index in 0..<(WorkspaceRevisionStore.maximumReceipts + extra) {
            try fixture.store.recordOperationReceipt(
                Fixture.receipt(title: "Run \(index)", at: 1_700_000_000 + Double(index)))
        }

        #expect(try fixture.store.operationReceipts(limit: 10_000).count
            == WorkspaceRevisionStore.maximumReceipts)
        // The oldest go first, so what is kept is what a person is most likely
        // to still be asking about.
        #expect(try fixture.store.operationReceipts(limit: 1).first?.title
            == "Run \(WorkspaceRevisionStore.maximumReceipts + extra - 1)")
        let device = try #require(try fixture.store.snapshot()).device
        #expect(device.receiptIDs.count == WorkspaceRevisionStore.maximumReceipts)
    }

    @Test func theReviewQueueSurvivesAndIsChangedUnderOneLock() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(try fixture.store.pendingRequestQueue().requests.isEmpty)

        try fixture.store.updatePendingRequestQueue { queue in
            queue.requests.append(Fixture.request("a"))
        }
        try fixture.store.updatePendingRequestQueue { queue in
            queue.requests.append(Fixture.request("b"))
        }

        #expect(try fixture.store.pendingRequestQueue().requests.map(\.title) == ["a", "b"])
        let reopened = try fixture.reopen()
        #expect(try reopened.pendingRequestQueue().requests.count == 2)
    }

    @Test func theQueueUpdateSeesWhatIsThereRatherThanWhatWasThere() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.updatePendingRequestQueue { $0.requests = [Fixture.request("a")] }

        // Two callers each admitting against the same remaining capacity is
        // exactly what reading inside the write transaction prevents.
        let admitted = try fixture.store.updatePendingRequestQueue { queue -> Bool in
            guard queue.requests.count < 2 else { return false }
            queue.requests.append(Fixture.request("b"))
            return true
        }
        let refused = try fixture.store.updatePendingRequestQueue { queue -> Bool in
            guard queue.requests.count < 2 else { return false }
            queue.requests.append(Fixture.request("c"))
            return true
        }

        #expect(admitted)
        #expect(!refused)
        #expect(try fixture.store.pendingRequestQueue().requests.map(\.title) == ["a", "b"])
    }

    @Test func theActivityJournalRoundTripsAndDefaultsToEmpty() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        struct Journal: Codable, Equatable { var entries: [String] }

        #expect(try fixture.store.activityJournal(as: Journal.self, default: .init(entries: []))
            == Journal(entries: []))
        try fixture.store.saveActivityJournal(Journal(entries: ["search_inventory"]))

        #expect(try fixture.reopen().activityJournal(as: Journal.self, default: .init(entries: []))
            == Journal(entries: ["search_inventory"]))
    }

    @Test func aStoreWithNoOperationalHistoryReportsNoneRatherThanFailing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(try fixture.store.operationReceipts().isEmpty)
        #expect(try fixture.store.operationReceipt(UUID()) == nil)
        #expect(try fixture.store.pendingRequestQueue().requests.isEmpty)
    }

    private struct Fixture {
        let root: URL
        let store: WorkspaceRevisionStore
        let workspaceID: WorkspaceObjectID
        let deviceID: WorkspaceObjectID

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "operational-records-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID())))
            workspaceID = document.workspaceID
            let device = DeviceWorkspaceState(workspaceID: workspaceID)
            deviceID = device.deviceID
            store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store"),
                workspaceID: workspaceID, deviceID: deviceID)
            try store.initialize(document: document, device: device)
        }

        func reopen() throws -> WorkspaceRevisionStore {
            try WorkspaceRevisionStore(containerRoot: root.appending(path: "store"),
                                       workspaceID: workspaceID, deviceID: deviceID)
        }

        static func receipt(title: String, at seconds: TimeInterval = 1_700_000_000) -> OperationReceipt {
            .init(planID: UUID(), kind: .installSkill, title: title, state: .healthy,
                  targetSurfaces: [.codexCLI], results: [],
                  createdAt: Date(timeIntervalSince1970: seconds),
                  verificationSummary: "Verified in place.")
        }

        static func request(_ label: String) -> PendingAgentRequest {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            return .init(
                id: UUID(), kind: .installSkill, title: label, summary: "Fixture",
                componentID: nil, scope: .user, targets: [.codex], reason: nil,
                reviewDetails: .init(), createdAt: now, lastRequestedAt: now,
                repeatCount: 1, requestedByLabels: ["Test"],
                fingerprint: String(repeating: "a", count: 64))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

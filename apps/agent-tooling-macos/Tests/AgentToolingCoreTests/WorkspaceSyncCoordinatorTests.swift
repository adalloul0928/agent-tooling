import Foundation
import Testing

@testable import AgentToolingCore

/// Two isolated stores and two checkouts of one real local repository stand in
/// for two Macs. This is a convergence suite, not a two-Mac pilot: nothing here
/// runs a native client or touches a real setup.
@Suite("Workspace sync coordinator")
struct WorkspaceSyncCoordinatorTests {
    @Test func aDeviceWithNoLocalEditsAdoptsTheSharedRevisionWhole() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        guard case .published = try await fixture.a.sync() else {
            Issue.record("The first device must publish into an empty repository.")
            return
        }
        // Both devices start from the same revision, so there is nothing to do.
        guard case .upToDate = try await fixture.b.sync() else {
            Issue.record("Matching revisions need no work.")
            return
        }

        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "Renamed on A")
        _ = try await fixture.a.sync()
        let outcome = try await fixture.b.sync()

        guard case .adopted(let receipt) = outcome else {
            Issue.record("A device with no local edits must adopt, got \(outcome).")
            return
        }
        let adopted = try #require(try fixture.storeB.snapshot())
        #expect(adopted.document.revision.id == receipt.committedRevisionID)
        #expect(adopted.document.artifacts.contains { $0.identity.displayName == "Renamed on A" })
        // Adoption keeps the shared revision's identity, so both heads agree.
        #expect(adopted.document.revision.id
            == (try #require(try fixture.storeA.snapshot())).document.revision.id)
    }

    @Test func independentEditsOnBothDevicesConverge() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.a.sync()
        _ = try await fixture.b.sync()

        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "Renamed on A")
        try fixture.rename(store: fixture.storeB, artifact: Fixture.beta, to: "Renamed on B")

        _ = try await fixture.a.sync()
        let merged = try await fixture.b.sync()
        guard case .merged = merged else {
            Issue.record("Expected a merge on the second device, got \(merged).")
            return
        }
        _ = try await fixture.a.sync()

        for store in [fixture.storeA, fixture.storeB] {
            let names = Set((try #require(try store.snapshot())).document.artifacts.map(\.identity.displayName))
            #expect(names == ["Renamed on A", "Renamed on B"])
        }
        #expect(try #require(try fixture.storeA.snapshot()).document.revision.id
            == (try #require(try fixture.storeB.snapshot())).document.revision.id)
    }

    @Test func aConflictStopsThePassWithoutCommittingOrPublishing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.a.sync()
        _ = try await fixture.b.sync()

        // Both devices rename the same item differently.
        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "A's name")
        try fixture.rename(store: fixture.storeB, artifact: Fixture.alpha, to: "B's name")
        _ = try await fixture.a.sync()
        let headBefore = try #require(try fixture.storeB.snapshot()).document.revision.id
        let remoteBefore = try await fixture.transportB.remoteState().head

        let outcome = try await fixture.b.sync()

        guard case .needsResolution(let conflicts) = outcome else {
            Issue.record("Expected an unresolved merge, got \(outcome).")
            return
        }
        #expect(conflicts.contains { $0.kind == .artifactField })
        // Nothing was committed here and nothing was pushed.
        #expect(try #require(try fixture.storeB.snapshot()).document.revision.id == headBefore)
        #expect(try await fixture.transportB.remoteState().head == remoteBefore)
        #expect(try #require(try fixture.storeB.snapshot())
            .document.artifacts.contains { $0.identity.displayName == "B's name" })
    }

    @Test func decidingAConflictConvergesBothDevicesOnTheChosenResult() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.a.sync()
        _ = try await fixture.b.sync()
        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "A's name")
        try fixture.rename(store: fixture.storeB, artifact: Fixture.alpha, to: "B's name")
        _ = try await fixture.a.sync()

        guard case .needsResolution(let conflicts) = try await fixture.b.sync() else {
            Issue.record("Expected a conflict on the second device.")
            return
        }
        // Undecided conflicts change nothing.
        let undecided = try await fixture.b.resolve([])
        guard case .needsResolution = undecided else {
            Issue.record("An unanswered conflict must not be applied, got \(undecided).")
            return
        }

        let decided = try await fixture.b.resolve(conflicts.map {
            .init(kind: $0.kind, artifactID: $0.artifactID, objectID: $0.objectID, choice: .keepLocal)
        })
        guard case .merged = decided else {
            Issue.record("Expected the decision to be applied, got \(decided).")
            return
        }
        _ = try await fixture.a.sync()

        for store in [fixture.storeA, fixture.storeB] {
            let snapshot = try #require(try store.snapshot())
            #expect(snapshot.document.artifacts.first { $0.identity.id == Fixture.alpha }?
                .identity.displayName == "B's name")
        }
        #expect(try #require(try fixture.storeA.snapshot()).document.revision.id
            == (try #require(try fixture.storeB.snapshot())).document.revision.id)
    }

    @Test func repeatingAPassReturnsItsOriginalResult() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.a.sync()
        try fixture.rename(store: fixture.storeA, artifact: Fixture.alpha, to: "Renamed on A")
        _ = try await fixture.a.sync()
        let key = WorkspaceObjectID()

        guard case .adopted(let first) = try await fixture.b.sync(idempotencyKey: key) else {
            Issue.record("Expected an adoption."); return
        }
        let repeated = try await fixture.b.sync(idempotencyKey: key)

        guard case .upToDate = repeated else {
            Issue.record("A settled device must report up to date, got \(repeated).")
            return
        }
        #expect(try #require(try fixture.storeB.snapshot()).document.revision.id == first.committedRevisionID)
    }

    private struct Fixture {
        static let alpha = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
        static let beta = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!)

        let root: URL
        let storeA: WorkspaceRevisionStore
        let storeB: WorkspaceRevisionStore
        let transportB: GitWorkspaceTransport
        let a: WorkspaceSyncCoordinator
        let b: WorkspaceSyncCoordinator

        init() async throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "workspace-sync-\(UUID())")
            let remote = root.appending(path: "remote.git")
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try Self.git(["init", "--bare", "--initial-branch", "main", remote.path], in: root)

            let workspaceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000e5")!)
            let writerA = WorkspaceObjectID()
            let writerB = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: workspaceID, revision: .init(writerID: writerA),
                artifacts: [
                    .init(identity: .init(id: Self.alpha, kind: .skill, displayName: "From A"),
                          authority: .trackedOnly),
                    .init(identity: .init(id: Self.beta, kind: .skill, displayName: "Second"),
                          authority: .trackedOnly),
                ]))
            // Each device keeps its own store and its own device identity.
            storeA = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store-a"),
                workspaceID: workspaceID, deviceID: WorkspaceObjectID())
            try storeA.initialize(document: document, device: .init(workspaceID: workspaceID,
                deviceID: storeA.deviceID))
            storeB = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store-b"),
                workspaceID: workspaceID, deviceID: WorkspaceObjectID())
            try storeB.initialize(document: document, device: .init(workspaceID: workspaceID,
                deviceID: storeB.deviceID))

            let transportA = try await Self.enroll(remote: remote, checkout: root.appending(path: "checkout-a"))
            transportB = try await Self.enroll(remote: remote, checkout: root.appending(path: "checkout-b"))
            a = WorkspaceSyncCoordinator(store: storeA, transport: transportA, writerID: writerA)
            b = WorkspaceSyncCoordinator(store: storeB, transport: transportB, writerID: writerB)
        }

        /// A local edit through the store's own committed command path.
        func rename(store: WorkspaceRevisionStore, artifact: ArtifactID, to name: String) throws {
            guard let head = try store.snapshot()?.document.revision.id else { return }
            _ = try store.commitMetadata(
                expectedRevisionID: head, idempotencyKey: WorkspaceObjectID(),
                inputDigest: String(repeating: "a", count: 64), writerID: WorkspaceObjectID()
            ) { document in
                guard let index = document.artifacts.firstIndex(where: { $0.identity.id == artifact })
                else { return [] }
                document.artifacts[index].identity.displayName = name
                return [artifact]
            }
        }

        static func enroll(remote: URL, checkout: URL) async throws -> GitWorkspaceTransport {
            let transport = try await GitWorkspaceTransport.enroll(remote: remote.path, checkout: checkout)
            try git(["config", "user.email", "fixture@example.com"], in: checkout)
            try git(["config", "user.name", "Fixture"], in: checkout)
            return transport
        }

        static func git(_ arguments: [String], in directory: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

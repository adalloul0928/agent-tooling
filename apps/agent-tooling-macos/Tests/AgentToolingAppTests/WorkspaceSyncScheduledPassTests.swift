import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

/// The automatic check asks the scheduler and does what it says. A quiet
/// scheduler always has a reason a person can read.
///
/// The conflict case runs over a real repository, because the thing being
/// checked is that a real undecided conflict stops the loop — not that a
/// hand-set flag does.
@MainActor
struct WorkspaceSyncScheduledPassTests {
    @Test func aMacThatIsNotConnectedNeverRunsAPassOnItsOwn() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        session.load()

        let decision = await session.runScheduledPass()

        #expect(decision == .notConnected)
        #expect(session.scheduleText?.contains("not connected") == true)
        #expect(session.lastAttempt == nil)
    }

    @Test func turningItOffStopsAutomaticPassesAndIsRemembered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.connect()
        let session = fixture.session()
        session.load()
        #expect(session.isAutomatic)

        session.setAutomatic(false)

        #expect(!session.isAutomatic)
        #expect(await session.runScheduledPass() == .disabled)
        #expect(session.scheduleText == "Automatic syncing is off on this Mac.")
        // The choice belongs to this Mac and survives reopening.
        let reopened = fixture.session()
        reopened.load()
        #expect(!reopened.isAutomatic)
        #expect(await reopened.runScheduledPass() == .disabled)
    }

    @Test func aPassThatJustRanWaitsRatherThanRunningAgainImmediately() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.connect()
        let session = fixture.session()
        session.load()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(await session.runScheduledPass(now: start) == .run)
        #expect(session.lastAttempt == start)
        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        #expect(session.consecutiveFailures == 0)

        let again = await session.runScheduledPass(now: start.addingTimeInterval(60))
        #expect(again == .tooSoon(nextEligible: start.addingTimeInterval(WorkspaceSyncScheduler.interval)))
        #expect(session.scheduleText?.hasPrefix("Next automatic sync") == true)
    }

    @Test func anUnreachableRepositoryBacksOffInsteadOfRetryingConstantly() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // Connected on paper, with nothing at the other end.
        try fixture.recordConnectionWithoutACheckout()
        let session = fixture.session()
        session.load()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(await session.runScheduledPass(now: start) == .run)
        #expect(session.errorMessage?.isEmpty == false)
        #expect(session.consecutiveFailures == 1)

        let again = await session.runScheduledPass(now: start.addingTimeInterval(60))
        // Twice the ordinary spacing after one failure, not another try now.
        #expect(again == .tooSoon(nextEligible: start.addingTimeInterval(WorkspaceSyncScheduler.interval * 2)))
    }

    @Test func aRealUndecidedConflictStopsAutomaticPassesUntilAPersonDecides() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.connect()
        let session = fixture.session()
        session.load()
        // Both Macs publish, then each renames the same item differently.
        await session.sync()
        _ = try await fixture.other.sync()
        try fixture.rename(store: fixture.store, to: "This Mac's name")
        try fixture.rename(store: fixture.otherStore, to: "The other Mac's name")
        _ = try await fixture.other.sync()

        await session.sync()

        #expect(!session.conflicts.isEmpty, "\(session.lastOutcome as Any)")
        #expect(await session.runScheduledPass() == .waitingForDecisions)
        #expect(session.scheduleText?.contains("paused until you decide") == true)
    }

    @Test func theCheckWakesFarMoreOftenThanItSyncs() {
        // The loop's job is to ask, not to sync. A wake-up has to be much more
        // frequent than a real pass, or the timer would be setting the spacing
        // instead of the scheduler.
        #expect(WorkspaceSyncSession.checkInterval < .seconds(WorkspaceSyncScheduler.interval))
    }

    @MainActor private struct Fixture {
        static let alpha = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
        let root: URL
        let remote: URL
        let store: WorkspaceRevisionStore
        let otherStore: WorkspaceRevisionStore
        let other: WorkspaceSyncCoordinator
        let enrollmentStore: WorkspaceSyncEnrollmentStore
        let workspaceID: WorkspaceObjectID

        init() async throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "scheduled-pass-\(UUID())")
            remote = root.appending(path: "remote.git")
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try Self.git(["init", "--bare", "--initial-branch", "main", remote.path], in: root)

            workspaceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000e5")!)
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: workspaceID, revision: .init(writerID: WorkspaceObjectID()),
                artifacts: [.init(identity: .init(id: Self.alpha, kind: .skill, displayName: "Shared"),
                                  authority: .trackedOnly)]))
            store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store"),
                workspaceID: workspaceID, deviceID: WorkspaceObjectID())
            try store.initialize(document: document,
                                 device: .init(workspaceID: workspaceID, deviceID: store.deviceID))
            otherStore = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store-other"),
                workspaceID: workspaceID, deviceID: WorkspaceObjectID())
            try otherStore.initialize(document: document,
                                      device: .init(workspaceID: workspaceID, deviceID: otherStore.deviceID))
            other = WorkspaceSyncCoordinator(
                store: otherStore,
                transport: try await Self.enroll(remote: remote, checkout: root.appending(path: "checkout-other")),
                writerID: WorkspaceObjectID())
            enrollmentStore = try WorkspaceSyncEnrollmentStore(containerRoot: root)
        }

        /// Prepares this Mac's own checkout and records the connection.
        func connect() async throws {
            let checkout = root.appending(path: "checkout")
            _ = try await Self.enroll(remote: remote, checkout: checkout)
            try enrollmentStore.write(.init(workspaceID: workspaceID, remote: remote.path,
                                            checkoutPath: checkout.standardizedFileURL.path))
        }

        /// A connection to a folder that holds no repository.
        func recordConnectionWithoutACheckout() throws {
            let checkout = root.appending(path: "empty-checkout")
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            try enrollmentStore.write(.init(workspaceID: workspaceID, remote: remote.path,
                                            checkoutPath: checkout.standardizedFileURL.path))
        }

        func rename(store: WorkspaceRevisionStore, to name: String) throws {
            guard let head = try store.snapshot()?.document.revision.id else { return }
            _ = try store.commitMetadata(
                expectedRevisionID: head, idempotencyKey: WorkspaceObjectID(),
                inputDigest: String(repeating: "a", count: 64), writerID: WorkspaceObjectID()
            ) { document in
                guard let index = document.artifacts.firstIndex(where: { $0.identity.id == Self.alpha })
                else { return [] }
                document.artifacts[index].identity.displayName = name
                return [Self.alpha]
            }
        }

        func session() -> WorkspaceSyncSession {
            WorkspaceSyncSession(store: store, enrollmentStore: enrollmentStore,
                                 workspaceID: workspaceID, writerID: WorkspaceObjectID())
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

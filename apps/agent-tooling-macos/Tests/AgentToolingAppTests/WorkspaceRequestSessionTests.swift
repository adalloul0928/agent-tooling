import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Deciding what a local integration asked for.
///
/// Every row in the queue is untrusted local input, so what matters here is
/// what the app refuses: a request naming something nobody put in the library,
/// one whose fields no longer match the fingerprint it was admitted under, and
/// one aimed at an app this Mac does not manage. What it accepts becomes
/// assignment intent and nothing else — never an installation.
@MainActor
struct WorkspaceRequestSessionTests {
    @Test func theQueueIsReadRatherThanAssumed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.enqueueInstall(named: "Standalone Skill")
        let session = await fixture.session()
        #expect(session.requests.isEmpty)

        await session.refresh()

        #expect(session.requests.count == 1)
        #expect(session.errorMessage == nil)
    }

    @Test func acceptingRecordsWhereAToolIsWantedAndInstallsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = try fixture.enqueueInstall(named: "Standalone Skill")
        let session = await fixture.session()
        await session.refresh()

        let outcome = await session.accept(request)

        #expect(outcome == .assignmentSaved, "\(session.errorMessage ?? "")")
        // The decision leaves the queue.
        #expect(session.requests.isEmpty)
        #expect(try PendingRequestQueueService.pendingRequests(store: fixture.store).isEmpty)

        let snapshot = try #require(try fixture.store.snapshot())
        let assignments = snapshot.document.assignments
        #expect(assignments.count == 1)
        #expect(assignments.first?.artifactID == Fixture.skill)
        #expect(assignments.first?.destination.surface == .claudeCode)
        #expect(assignments.first?.destination.scope == .user)

        // What was asked for is asked for. Nothing here claims it is installed.
        await fixture.library.refresh()
        let library = try #require(fixture.library.state?.library)
        let inventory = VersionedInventoryProjection.inventory(library)
        let skill = try #require(inventory.skills.first { $0.name == "Standalone Skill" })
        #expect(!skill.clients.isEmpty)
        #expect(skill.clients.allSatisfy { !$0.reportsLocalPresence })
    }

    @Test func aRequestNamingSomethingOutsideTheLibraryIsRefusedAndStaysInTheQueue() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = try fixture.enqueueInstall(named: "Something Nobody Added")
        let session = await fixture.session()
        await session.refresh()

        let outcome = await session.accept(request)

        guard case .refused(let reason) = outcome else {
            Issue.record("a request for an unknown tool was accepted")
            return
        }
        #expect(reason.contains("is not in your library"))
        // Approving never adds a library item, and refusing never loses the row.
        #expect(try fixture.store.snapshot()?.document.artifacts.count == 1)
        #expect(try PendingRequestQueueService.pendingRequests(store: fixture.store).count == 1)
        #expect(session.requests.count == 1)
    }

    @Test func aRequestWhoseFieldsNoLongerMatchItsFingerprintIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var request = try fixture.enqueueInstall(named: "Standalone Skill")
        // Exactly the tamper the fingerprint exists to catch: the row a person
        // read said one thing, and the row being approved says another.
        request.componentID = "Something Else"
        let session = await fixture.session()
        await session.refresh()

        let outcome = await session.accept(request)

        guard case .refused(let reason) = outcome else {
            Issue.record("a tampered request was accepted")
            return
        }
        #expect(reason.contains("integrity fingerprint"))
        #expect(try fixture.store.snapshot()?.document.assignments.isEmpty == true)
        #expect(try PendingRequestQueueService.pendingRequests(store: fixture.store).count == 1)
    }

    @Test func aRequestForAnAppThisMacDoesNotManageIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = try fixture.enqueueInstall(named: "Standalone Skill", targets: [.gemini])
        let session = await fixture.session()
        await session.refresh()
        await fixture.device.setEnabled(.gemini, false)

        let outcome = await session.accept(request)

        guard case .refused(let reason) = outcome else {
            Issue.record("a request for an unmanaged app was accepted")
            return
        }
        #expect(reason.contains("not managing Gemini"))
        #expect(try fixture.store.snapshot()?.document.assignments.isEmpty == true)
        #expect(try PendingRequestQueueService.pendingRequests(store: fixture.store).count == 1)
    }

    @Test func rejectingRemovesTheRowAndChangesNothingElse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = try fixture.enqueueInstall(named: "Standalone Skill")
        let session = await fixture.session()
        await session.refresh()

        #expect(await session.reject(request))

        #expect(session.requests.isEmpty)
        #expect(try PendingRequestQueueService.pendingRequests(store: fixture.store).isEmpty)
        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.assignments.isEmpty)
        #expect(snapshot.document.artifacts.count == 1)
    }

    @Test func withdrawingTakesBackWhatWasAskedForRatherThanRemovingAnything() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let install = try fixture.enqueueInstall(named: "Standalone Skill")
        let session = await fixture.session()
        await session.refresh()
        #expect(await session.accept(install) == .assignmentSaved, "\(session.errorMessage ?? "")")

        let removal = try fixture.enqueueRemoval(named: "Standalone Skill")
        await session.refresh()
        let outcome = await session.accept(removal)

        #expect(outcome == .assignmentSaved, "\(session.errorMessage ?? "")")
        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.assignments.isEmpty)
        // Withdrawing intent is not an uninstall; the item stays in the library.
        #expect(snapshot.document.artifacts.count == 1)
    }

    /// The envelope check, on its own, over the fields it is there to police.
    @Test func theEnvelopeRefusesAnUnsupportedScopeAndAStrayProjectFolder() throws {
        var request = ShellRenderFixture.pendingRequest()
        #expect(PendingRequestEnvelope.rejection(for: request) == nil)

        request.scope = .managed
        #expect(PendingRequestEnvelope.rejection(for: request)?.contains("unsupported scope") == true)

        request = ShellRenderFixture.pendingRequest()
        request.reviewDetails.projectRoot = "/tmp/somewhere"
        #expect(
            PendingRequestEnvelope.rejection(for: request)?.contains("cannot carry a project folder")
                == true)

        request = ShellRenderFixture.pendingRequest()
        request.targets = []
        #expect(
            PendingRequestEnvelope.rejection(for: request)?.contains("invalid app selection") == true)
    }

    /// A real store in a temporary folder, wired the way the app wires it, with
    /// one skill in the library for a request to name.
    @MainActor private struct Fixture {
        static let skill = ArtifactID()
        let root: URL
        let home: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let library: WorkspaceLibrarySession
        let device: WorkspaceDeviceSession
        let writerID = WorkspaceObjectID()

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "request-session-\(UUID())", directoryHint: .isDirectory)
            let container = root.appending(path: "store", directoryHint: .isDirectory)
            home = root.appending(path: "home", directoryHint: .isDirectory)
            for directory in [container, home] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let document = try WorkspaceDocumentCoding.seal(
                .init(
                    workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                    artifacts: [
                        .init(
                            identity: .init(
                                id: Self.skill, kind: .skill, displayName: "Standalone Skill"),
                            authority: .centralPersonal)
                    ]))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(
                containerRoot: container, workspaceID: document.workspaceID,
                deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
            library = WorkspaceLibrarySession(
                service: service, workspaceID: document.workspaceID, deviceID: device.deviceID,
                access: .writable)
            self.device = WorkspaceDeviceSession(
                service: service, library: library, store: store, homeRoot: home,
                observer: SilentObserver())
        }

        /// The real queue, so the row under test carries the fingerprint the
        /// admission path actually writes.
        @discardableResult
        func enqueueInstall(named name: String, targets: [ClientKind] = [.claude]) throws
            -> PendingAgentRequest
        {
            try PendingRequestQueueService.enqueue(
                kind: .installSkill, title: "Install \(name)",
                summary: "A local client asked for \(name).", componentID: name, scope: .user,
                targets: targets, reason: nil, reviewDetails: .init(),
                fingerprintInputs: [name, ""], clientLabel: "Claude Code", store: store
            ).request
        }

        @discardableResult
        func enqueueRemoval(named name: String, targets: [ClientKind] = [.claude]) throws
            -> PendingAgentRequest
        {
            try PendingRequestQueueService.enqueue(
                kind: .removeComponent, title: "Remove \(name)",
                summary: "A local client asked to stop using \(name).", componentID: name,
                scope: .user, targets: targets, reason: nil,
                reviewDetails: .init(componentKind: "skill"),
                fingerprintInputs: ["skill", name], clientLabel: "Claude Code", store: store
            ).request
        }

        func session() async -> WorkspaceRequestSession {
            await library.refresh()
            return WorkspaceRequestSession(
                store: store, library: library, device: device, queue: LivePendingRequestQueue())
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// A scan that finds nothing and runs nothing, so these tests never depend
    /// on what happens to be installed on the machine running them.
    private struct SilentObserver: DeviceObserving {
        func observe(homeRoot: URL) async throws -> [TargetObservation] { [] }
    }
}

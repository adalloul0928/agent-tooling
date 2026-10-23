import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// Two stores, two checkouts, one real bare repository: the whole multi-Mac
/// lifecycle short of two real Macs. Join, author on A and see it on B with
/// its bytes, scope a Mac out, edit apart and converge, retire.
@Suite("Multi-Mac sync", .serialized)
struct MultiMacSyncTests {
    private struct Mac {
        let name: String
        let home: URL
        let container: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let contentStore: CentralPackageContentStore
        let coordinator: WorkspaceSyncCoordinator
        let transport: GitWorkspaceTransport

        var head: WorkspaceObjectID { get throws { try #require(try store.snapshot()).document.revision.id } }
        var document: PortableWorkspaceDocument { get throws { try #require(try store.snapshot()).document } }
    }

    private struct Fixture {
        let root: URL
        let remote: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "multi-mac-\(UUID())")
            remote = root.appending(path: "remote.git")
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try GitTestFixture.git(["init", "--bare", "--initial-branch", "main", remote.path], in: root)
        }

        /// A Mac's home with a Git identity, so commits have an author the way a
        /// person's Mac would.
        func home(_ name: String) throws -> URL {
            let home = root.appending(path: "\(name)/home", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try Data("[user]\n\tname = \(name)\n\temail = \(name)@example.com\n".utf8).write(to: home.appending(path: ".gitconfig"))
            return home
        }

        /// The first Mac: a workspace of its own, connected to the repository.
        func firstMac(_ name: String) async throws -> Mac {
            let home = try home(name)
            let container = root.appending(path: "\(name)/support", directoryHint: .isDirectory)
            let contentRoot = container.appending(path: "content", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: contentRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let writer = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(.init(revision: .init(writerID: writer)))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            let store = try WorkspaceRevisionStore(containerRoot: container, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            let contentStore = try CentralPackageContentStore(directory: contentRoot)
            let service = WorkspaceApplicationService(store: store, writerID: writer, contentStore: contentStore)
            _ = try await service.registerDevice(.init(expectedRevisionID: document.revision.id, deviceID: device.deviceID, name: name))
            let runner = ProcessCommandRunner(timeout: .seconds(60), homeURL: home)
            let transport = try await GitWorkspaceTransport.enroll(
                remote: remote.path, checkout: root.appending(path: "\(name)/checkout"), runner: runner)
            let coordinator = WorkspaceSyncCoordinator(store: store, transport: transport, writerID: writer, contentStore: contentStore)
            return .init(
                name: name, home: home, container: container, store: store, service: service,
                contentStore: contentStore, coordinator: coordinator, transport: transport)
        }

        /// A second Mac joining what the first published.
        func joiningMac(_ name: String) async throws -> Mac {
            let home = try home(name)
            let container = root.appending(path: "\(name)/support", directoryHint: .isDirectory)
            let contentRoot = container.appending(path: "content", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: contentRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let contentStore = try CentralPackageContentStore(directory: contentRoot)
            let runner = ProcessCommandRunner(timeout: .seconds(60), homeURL: home)
            let locator = try WorkspaceLocator(root: container)
            let joined = try await WorkspaceJoin.join(
                remote: remote.path, checkout: root.appending(path: "\(name)/checkout"), containerRoot: container,
                homeURL: home, deviceName: name, runner: runner, registry: .init(adapters: []),
                contentStore: contentStore, locator: locator)
            let writer = WorkspaceObjectID()
            let service = WorkspaceApplicationService(store: joined.store, writerID: writer, contentStore: contentStore)
            let transport = try GitWorkspaceTransport(checkout: URL(fileURLWithPath: joined.enrollment.checkoutPath), runner: runner)
            let coordinator = WorkspaceSyncCoordinator(
                store: joined.store, transport: transport, writerID: writer, contentStore: contentStore)
            #expect(try locator.read()?.workspaceID == joined.store.workspaceID)
            return .init(
                name: name, home: home, container: container, store: joined.store, service: service,
                contentStore: contentStore, coordinator: coordinator, transport: transport)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// A skill with bytes, authored on one Mac through the service.
    private func author(_ mac: Mac, name: String, body: String) async throws -> ArtifactID {
        let tree = try CapturedPackageTree(entries: [
            .init(
                relativePath: "SKILL.md",
                kind: .file(bytes: Data("---\nname: \(name)\ndescription: d\n---\n\(body)\n".utf8), executable: false))
        ])
        let prepared = try WorkspaceSkillPreparation.personal(tree: tree)
        let id = ArtifactID()
        _ = try await mac.service.intakeStandaloneSkill(
            .init(expectedRevisionID: try mac.head, artifactID: id, displayName: name, prepared: prepared), prepared: prepared)
        return id
    }

    private func assign(_ mac: Mac, _ artifact: ArtifactID, destination: PortableDestination) async throws {
        let command = try WorkspaceAssignmentBatchCommand.assign(
            document: try mac.document, artifactIDs: [artifact], destinations: [destination])
        _ = try await mac.service.applyAssignmentBatch(command)
    }

    @Test func aSecondMacJoinsAndReceivesTheFirstMacsSkillWithItsBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try await fixture.firstMac("Studio")
        let skill = try await author(a, name: "release-check", body: "Version one")
        try await assign(a, skill, destination: .init(surface: .claudeCode, scope: .user))  // every Mac
        let first = try await a.coordinator.sync()
        guard case .published = first else {
            Issue.record("expected publish, got \(first)")
            return
        }
        #expect(await a.coordinator.lastContentReport.published.count == 1)

        let b = try await fixture.joiningMac("MacBook")

        // The same workspace, both Macs registered, under their names.
        #expect(b.store.workspaceID == a.store.workspaceID)
        #expect(b.store.deviceID != a.store.deviceID)
        let registry = try b.document.deviceRegistry
        #expect(Set(registry.map(\.name)) == ["Studio", "MacBook"])
        // The skill is there with its content: B can plan it.
        let row = try #require(try b.document.artifacts.first { $0.identity.id == skill })
        #expect(row.authority == .centralPersonal)
        let digest = try #require(row.contentDigest)
        let held = try await b.contentStore.read(digest)
        #expect(held.digest == digest)
        #expect(try b.document.assignments.first?.destination.applies(to: b.store.deviceID, registry: registry) == true)

        // A learns of B on its next pass, and sees B's published status.
        let second = try await a.coordinator.sync()
        guard case .adopted = second else {
            Issue.record("expected adopt, got \(second)")
            return
        }
        #expect(Set(try a.document.deviceRegistry.map(\.name)) == ["Studio", "MacBook"])
    }

    @Test func aLimitedMacTakesOnlyWhatNamesItAndAnExclusionLeavesAMacOut() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try await fixture.firstMac("Studio")
        _ = try await a.coordinator.sync()
        let b = try await fixture.joiningMac("Work")
        // B opts out of shared assignments, from A.
        _ = try await a.coordinator.sync()
        _ = try await a.service.updateDevice(
            .init(expectedRevisionID: try a.head, deviceID: b.store.deviceID, change: .receivesSharedAssignments(false)))
        let shared = try await author(a, name: "shared-skill", body: "for everyone")
        let named = try await author(a, name: "named-skill", body: "for work only")
        let excepted = try await author(a, name: "excepted-skill", body: "everyone but the studio")
        try await assign(a, shared, destination: .init(surface: .claudeCode, scope: .user))
        try await assign(a, named, destination: .init(surface: .claudeCode, scope: .user, deviceIDs: [b.store.deviceID]))
        try await assign(a, excepted, destination: .init(surface: .claudeCode, scope: .user, excludedDeviceIDs: [a.store.deviceID]))
        _ = try await a.coordinator.sync()
        _ = try await b.coordinator.sync()

        let document = try b.document
        let registry = document.deviceRegistry
        func applies(_ id: ArtifactID, on mac: Mac) throws -> Bool {
            let assignment = try #require(document.assignments.first { $0.artifactID == id })
            return assignment.destination.applies(to: mac.store.deviceID, registry: registry)
        }
        #expect(try !applies(shared, on: b))  // limited Mac ignores every-Mac
        #expect(try applies(named, on: b))  // but takes what names it
        #expect(try !applies(excepted, on: b))  // limited: excluded by not taking shared
        #expect(try applies(shared, on: a))
        #expect(try !applies(named, on: a))
        #expect(try !applies(excepted, on: a))  // excluded by name
        #expect(registry.first { $0.id == b.store.deviceID }?.receivesSharedAssignments == false)
    }

    @Test func editsMadeApartConvergeAndARenameRaceIsOneConflictDecidedOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try await fixture.firstMac("Studio")
        _ = try await a.coordinator.sync()
        let b = try await fixture.joiningMac("MacBook")
        _ = try await a.coordinator.sync()

        // Apart: A renames B's device, B authors a skill.
        _ = try await a.service.updateDevice(
            .init(expectedRevisionID: try a.head, deviceID: b.store.deviceID, change: .rename("Travel Mac")))
        let skill = try await author(b, name: "from-b", body: "written on the laptop")
        _ = try await a.coordinator.sync()
        let bPass = try await b.coordinator.sync()
        guard case .merged = bPass else {
            Issue.record("expected merge, got \(bPass)")
            return
        }
        _ = try await a.coordinator.sync()
        #expect(try a.document.deviceRegistry.first { $0.id == b.store.deviceID }?.name == "Travel Mac")
        #expect(try a.document.artifacts.contains { $0.identity.id == skill })
        // B's authored content reached A's content store.
        let digest = try #require(try a.document.artifacts.first { $0.identity.id == skill }?.contentDigest)
        #expect((try? await a.contentStore.read(digest)) != nil)

        // The same device renamed differently on both: one conflict, decided on A, adopted by B.
        _ = try await a.service.updateDevice(
            .init(expectedRevisionID: try a.head, deviceID: b.store.deviceID, change: .rename("Home laptop")))
        _ = try await b.service.updateDevice(
            .init(expectedRevisionID: try b.head, deviceID: b.store.deviceID, change: .rename("Road laptop")))
        _ = try await a.coordinator.sync()
        let conflicted = try await b.coordinator.sync()
        guard case .needsResolution(let conflicts) = conflicted else {
            Issue.record("expected a conflict, got \(conflicted)")
            return
        }
        #expect(conflicts.map(\.kind) == [.deviceField])
        let resolved = try await b.coordinator.resolve([
            .init(kind: .deviceField, artifactID: nil, objectID: b.store.deviceID, choice: .keepLocal)
        ])
        guard case .merged = resolved else {
            Issue.record("expected merged after resolution, got \(resolved)")
            return
        }
        _ = try await a.coordinator.sync()
        #expect(try a.document.deviceRegistry.first { $0.id == b.store.deviceID }?.name == "Road laptop")
        #expect(try b.document.deviceRegistry.first { $0.id == b.store.deviceID }?.name == "Road laptop")
    }

    @Test func retiringAMacLandsOnBothAndItTakesNothingShared() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try await fixture.firstMac("Studio")
        _ = try await a.coordinator.sync()
        let b = try await fixture.joiningMac("Old iMac")
        _ = try await a.coordinator.sync()
        _ = try await a.service.updateDevice(.init(expectedRevisionID: try a.head, deviceID: b.store.deviceID, change: .retire))
        _ = try await a.coordinator.sync()
        _ = try await b.coordinator.sync()
        let record = try #require(try b.document.deviceRegistry.first { $0.id == b.store.deviceID })
        #expect(record.isRetired)
        #expect(
            !PortableDestination(surface: .claudeCode, scope: .user).applies(to: b.store.deviceID, registry: try b.document.deviceRegistry))
        // B cannot un-retire itself by renaming.
        await #expect(throws: DeviceRegistryError.retired) {
            try await b.service.updateDevice(.init(expectedRevisionID: try b.head, deviceID: b.store.deviceID, change: .rename("Back")))
        }
    }

    @Test func theContentReportListsOnlyTreesTheRemoteAccepted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try await fixture.firstMac("Studio")
        let skill = try await author(a, name: "release-check", body: "Version one")
        let digest = try #require(try a.document.artifacts.first { $0.identity.id == skill }?.contentDigest)

        _ = try await a.coordinator.sync()
        // Listed as published, and the remote really has it.
        #expect(await a.coordinator.lastContentReport.published == [digest])
        #expect(try await a.transport.remoteState().contentDigests.contains(digest))

        // A pass with nothing to send claims nothing.
        let again = try await a.coordinator.sync()
        guard case .upToDate = again else {
            Issue.record("expected up to date, got \(again)")
            return
        }
        #expect(await a.coordinator.lastContentReport.published.isEmpty)
        #expect(await a.coordinator.lastContentReport.unpublished.isEmpty)
    }

    @Test func aMacWithAWorkspaceCannotJoinAnotherAndAnEmptyRemoteCannotBeJoined() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try await fixture.firstMac("Studio")
        let locator = try WorkspaceLocator(root: a.container)
        try locator.write(.init(workspaceID: a.store.workspaceID, deviceID: a.store.deviceID))
        await #expect(throws: WorkspaceJoinError.alreadyHasWorkspace) {
            try await WorkspaceJoin.join(
                remote: fixture.remote.path, checkout: fixture.root.appending(path: "x/checkout"), containerRoot: a.container,
                homeURL: a.home, deviceName: "X", runner: ProcessCommandRunner(timeout: .seconds(60), homeURL: a.home),
                registry: .init(adapters: []), locator: locator)
        }
        // Nothing published yet: nothing to join.
        let other = fixture.root.appending(path: "y/support", directoryHint: .isDirectory)
        await #expect(throws: WorkspaceJoinError.emptyRemote) {
            try await WorkspaceJoin.join(
                remote: fixture.remote.path, checkout: fixture.root.appending(path: "y/checkout"), containerRoot: other,
                homeURL: a.home, deviceName: "Y", runner: ProcessCommandRunner(timeout: .seconds(60), homeURL: a.home),
                registry: .init(adapters: []))
        }
    }

    @Test func upgradingAMatchingLegacyHeadAlsoRecoversItsAuthoredSkillFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = try await fixture.firstMac("Studio")
        let skill = try await author(a, name: "release-check", body: "Published skill content")
        _ = try await a.coordinator.sync()
        let digest = try #require(try a.document.artifacts.first { $0.identity.id == skill }?.contentDigest)
        // Simulate a head-only legacy repository with unpublished parents.
        let checkout = fixture.root.appending(path: "Studio/checkout")
        try GitTestFixture.git(["rm", GitWorkspaceTransport.historyFileName], in: checkout, checkingStatus: true)
        try GitTestFixture.git(
            [
                "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "-c", "user.name=Fixture",
                "-c", "user.email=fixture@example.com", "commit", "--quiet", "-m", "Legacy head",
            ],
            in: checkout, checkingStatus: true)
        try GitTestFixture.git(["push", "origin", "main"], in: checkout, checkingStatus: true)
        let emptyRoot = fixture.root.appending(path: "recovered-content")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let recovered = try CentralPackageContentStore(directory: emptyRoot)
        let coordinator = WorkspaceSyncCoordinator(
            store: a.store, transport: a.transport, writerID: WorkspaceObjectID(), contentStore: recovered)

        guard case .published = try await coordinator.sync() else {
            Issue.record("The matching legacy head should be republished with its complete history")
            return
        }

        #expect(await coordinator.lastContentReport.imported == [digest])
        #expect(try await recovered.read(digest) == a.contentStore.read(digest))
        #expect(try await a.transport.remoteState().ancestors.count == a.store.revisionHistory(from: a.head).count - 1)
    }
}

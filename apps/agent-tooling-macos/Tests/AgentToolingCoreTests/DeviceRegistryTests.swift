import Foundation
import Testing

@testable import AgentToolingCore

/// Which Macs an assignment is for, and the registry that makes a Mac limited
/// on purpose. One rule, used by every planner.
@Suite("Device registry and scope")
struct DeviceRegistryTests {
    private let studio = WorkspaceObjectID()
    private let laptop = WorkspaceObjectID()
    private let work = WorkspaceObjectID()

    private var registry: [DeviceRecord] {
        [
            .init(id: studio, name: "Mac Studio"),
            .init(id: laptop, name: "MacBook Pro"),
            .init(id: work, name: "Work laptop", receivesSharedAssignments: false),
        ]
    }

    @Test func everyMacReachesTheMacsThatTakeSharedAssignments() {
        let every = PortableDestination(surface: .claudeCode, scope: .user)
        #expect(every.applies(to: studio, registry: registry))
        #expect(every.applies(to: laptop, registry: registry))
        #expect(!every.applies(to: work, registry: registry))
    }

    @Test func anExclusionLeavesOneMacOutOfEveryMac() {
        let except = PortableDestination(surface: .claudeCode, scope: .user, excludedDeviceIDs: [laptop])
        #expect(except.applies(to: studio, registry: registry))
        #expect(!except.applies(to: laptop, registry: registry))
        #expect(!except.applies(to: work, registry: registry))
    }

    @Test func namingAMacReachesItWhateverItsSetting() {
        let named = PortableDestination(surface: .claudeCode, scope: .user, deviceIDs: [work])
        #expect(named.applies(to: work, registry: registry))
        #expect(!named.applies(to: studio, registry: registry))
    }

    @Test func aMacTheRegistryDoesNotKnowTakesSharedAssignments() {
        // A store from before the registry existed, or a joined Mac mid-registration.
        let stranger = WorkspaceObjectID()
        #expect(PortableDestination(surface: .claudeCode, scope: .user).applies(to: stranger, registry: registry))
        #expect(PortableDestination(surface: .claudeCode, scope: .user).applies(to: stranger, registry: []))
    }

    @Test func aRetiredMacTakesNothingShared() {
        var retired = registry
        retired[1].retiredAt = .now
        #expect(!PortableDestination(surface: .claudeCode, scope: .user).applies(to: laptop, registry: retired))
        // Naming it still reaches it: the record is history, not a guard.
        #expect(PortableDestination(surface: .claudeCode, scope: .user, deviceIDs: [laptop]).applies(to: laptop, registry: retired))
    }

    @Test func emptyExclusionsAreNil() {
        let plain = PortableDestination(surface: .claudeCode, scope: .user, excludedDeviceIDs: [])
        #expect(plain.excludedDeviceIDs == nil)
        #expect(plain == PortableDestination(surface: .claudeCode, scope: .user))
    }

    @Test func aDocumentWithoutARegistryDecodesAndReadsAsEmpty() throws {
        let writer = WorkspaceObjectID()
        let document = try WorkspaceDocumentCoding.seal(.init(revision: .init(writerID: writer)))
        let bytes = try WorkspaceDocumentCoding.encode(document)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("\"devices\""))
        let decoded = try WorkspaceDocumentCoding.decode(bytes)
        #expect(decoded.devices == nil)
        #expect(decoded.deviceRegistry.isEmpty)
    }

    @Test func aRegistryRoundTripsThroughTheSealedDocument() throws {
        let writer = WorkspaceObjectID()
        let document = try WorkspaceDocumentCoding.seal(.init(revision: .init(writerID: writer), devices: registry))
        let decoded = try WorkspaceDocumentCoding.decode(try WorkspaceDocumentCoding.encode(document))
        #expect(decoded.deviceRegistry.map(\.name) == ["Mac Studio", "MacBook Pro", "Work laptop"].sorted(by: { lhs, rhs in
            let ids = [studio, laptop, work]
            let names = ["Mac Studio", "MacBook Pro", "Work laptop"]
            return ids[names.firstIndex(of: lhs)!] < ids[names.firstIndex(of: rhs)!]
        }))
        #expect(decoded.deviceRegistry.first { $0.id == work }?.receivesSharedAssignments == false)
    }

    // MARK: Merge

    private func base() throws -> PortableWorkspaceDocument {
        try WorkspaceDocumentCoding.seal(.init(revision: .init(writerID: WorkspaceObjectID()), devices: registry))
    }

    private func edit(_ document: PortableWorkspaceDocument, _ change: (inout PortableWorkspaceDocument) -> Void) throws -> PortableWorkspaceDocument {
        var next = document
        change(&next)
        next.revision = .init(parentIDs: [document.revision.id], writerID: WorkspaceObjectID())
        return try WorkspaceDocumentCoding.seal(next)
    }

    @Test func retiringOnOneMacAndRenamingOnTheOtherBothLand() throws {
        let ancestor = try base()
        let mine = try edit(ancestor) { $0.devices![$0.devices!.firstIndex { $0.id == laptop }!].retiredAt = Date(timeIntervalSince1970: 1_000) }
        let theirs = try edit(ancestor) { $0.devices![$0.devices!.firstIndex { $0.id == laptop }!].name = "Travel Mac" }
        let merge = WorkspaceMergeEngine.merge(base: ancestor, local: mine, remote: theirs, writerID: WorkspaceObjectID())
        #expect(merge.isResolved)
        let merged = try #require(merge.document?.deviceRegistry.first { $0.id == laptop })
        #expect(merged.isRetired)
        #expect(merged.name == "Travel Mac")
    }

    @Test func renamingOneMacDifferentlyOnBothSidesIsAConflictAPersonDecides() throws {
        let ancestor = try base()
        let mine = try edit(ancestor) { $0.devices![$0.devices!.firstIndex { $0.id == laptop }!].name = "Home laptop" }
        let theirs = try edit(ancestor) { $0.devices![$0.devices!.firstIndex { $0.id == laptop }!].name = "Travel Mac" }
        let merge = WorkspaceMergeEngine.merge(base: ancestor, local: mine, remote: theirs, writerID: WorkspaceObjectID())
        #expect(!merge.isResolved)
        let conflict = try #require(merge.conflicts.first)
        #expect(conflict.kind == .deviceField)
        #expect(conflict.objectID == laptop)
        #expect(conflict.kind.isSettledByChoosingASide)

        let resolved = WorkspaceConflictResolver.resolve(
            base: ancestor, local: mine, remote: theirs, conflicts: merge.conflicts,
            resolutions: [.init(kind: .deviceField, artifactID: nil, objectID: laptop, choice: .takeRemote)],
            writerID: WorkspaceObjectID())
        #expect(resolved.isResolved)
        #expect(resolved.document?.deviceRegistry.first { $0.id == laptop }?.name == "Travel Mac")
    }

    @Test func exclusionsOnASharedAssignmentCombineAsASet() throws {
        let skill = ArtifactID()
        let ancestor = try WorkspaceDocumentCoding.seal(.init(
            revision: .init(writerID: WorkspaceObjectID()),
            artifacts: [.init(identity: .init(id: skill, kind: .skill, displayName: "S"), authority: .centralPersonal, declaredName: "s")],
            assignments: [.init(artifactID: skill, destination: .init(surface: .claudeCode, scope: .user), reason: .manual)],
            devices: registry))
        let mine = try edit(ancestor) { $0.assignments[0].destination.excludedDeviceIDs = [laptop] }
        let theirs = try edit(ancestor) { $0.assignments[0].destination.excludedDeviceIDs = [studio] }
        let merge = WorkspaceMergeEngine.merge(base: ancestor, local: mine, remote: theirs, writerID: WorkspaceObjectID())
        #expect(merge.isResolved)
        #expect(Set(merge.document?.assignments.first?.destination.excludedDeviceIDs ?? []) == [laptop, studio])
    }
}

/// The registry's commands, through the service.
@Suite("Device registry commands")
struct DeviceRegistryCommandTests {
    private struct Fixture {
        let root: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let deviceID: WorkspaceObjectID

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "devices-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let writer = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(.init(revision: .init(writerID: writer)))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            deviceID = device.deviceID
            store = try .init(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = .init(store: store, writerID: writer)
        }

        var head: WorkspaceObjectID { get throws { try #require(try store.snapshot()).document.revision.id } }
        var registry: [DeviceRecord] { (try? store.snapshot())?.document.deviceRegistry ?? [] }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func registeringTwiceIsOneRowAndNamesAreUniqueAmongLivingMacs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.service.registerDevice(.init(expectedRevisionID: try fixture.head, deviceID: fixture.deviceID, name: "Mac Studio"))
        _ = try await fixture.service.registerDevice(.init(expectedRevisionID: try fixture.head, deviceID: fixture.deviceID, name: "Mac Studio"))
        #expect(fixture.registry.count == 1)

        let other = WorkspaceObjectID()
        await #expect(throws: DeviceRegistryError.nameInUse(by: "Mac Studio")) {
            try await fixture.service.registerDevice(.init(expectedRevisionID: try fixture.head, deviceID: other, name: "mac studio"))
        }
        _ = try await fixture.service.registerDevice(.init(expectedRevisionID: try fixture.head, deviceID: other, name: "MacBook Pro", receivesSharedAssignments: false))
        #expect(fixture.registry.count == 2)
        #expect(fixture.registry.first { $0.id == other }?.receivesSharedAssignments == false)
    }

    @Test func aMacCannotRetireItselfButCanRetireAnother() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = WorkspaceObjectID()
        _ = try await fixture.service.registerDevice(.init(expectedRevisionID: try fixture.head, deviceID: fixture.deviceID, name: "Mac Studio"))
        _ = try await fixture.service.registerDevice(.init(expectedRevisionID: try fixture.head, deviceID: other, name: "MacBook Pro"))

        await #expect(throws: DeviceRegistryError.cannotRetireSelf) {
            try await fixture.service.updateDevice(.init(expectedRevisionID: try fixture.head, deviceID: fixture.deviceID, change: .retire))
        }
        _ = try await fixture.service.updateDevice(.init(expectedRevisionID: try fixture.head, deviceID: other, change: .retire))
        #expect(fixture.registry.first { $0.id == other }?.isRetired == true)
        // A retired Mac cannot be renamed or re-registered; its name is free for an explicit rename.
        await #expect(throws: DeviceRegistryError.retired) {
            try await fixture.service.updateDevice(.init(expectedRevisionID: try fixture.head, deviceID: other, change: .rename("Back")))
        }
        _ = try await fixture.service.updateDevice(.init(expectedRevisionID: try fixture.head, deviceID: fixture.deviceID, change: .rename("MacBook Pro")))
        #expect(fixture.registry.first { $0.id == fixture.deviceID }?.name == "MacBook Pro")
    }

    @Test func turningOffSharedAssignmentsIsRecordedAndUnknownMacsAreRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.service.registerDevice(.init(expectedRevisionID: try fixture.head, deviceID: fixture.deviceID, name: "Mac Studio"))
        _ = try await fixture.service.updateDevice(.init(expectedRevisionID: try fixture.head, deviceID: fixture.deviceID, change: .receivesSharedAssignments(false)))
        #expect(fixture.registry.first?.receivesSharedAssignments == false)
        await #expect(throws: DeviceRegistryError.unknownDevice) {
            try await fixture.service.updateDevice(.init(expectedRevisionID: try fixture.head, deviceID: WorkspaceObjectID(), change: .seen(.now)))
        }
    }
}

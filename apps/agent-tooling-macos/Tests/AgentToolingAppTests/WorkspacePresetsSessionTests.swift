import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

/// Following a preset records a standing choice and moves nothing. Catching up
/// applies exactly what was shown, and never removes a destination something
/// else still asks for.
@MainActor
struct WorkspacePresetsSessionTests {
    @Test func followingRecordsTheChoiceWithoutAssigningAnything() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.refresh()
        #expect(session.rows.map(\.isLinked) == [false])

        await session.link(Fixture.presetID, destinations: [Fixture.codex])

        let row = try #require(session.rows.first)
        #expect(row.isLinked)
        #expect(row.hasPendingChanges)
        // Nothing moved: the first catch-up is shown like any other.
        #expect(try #require(try fixture.store.snapshot()).document.assignments.isEmpty)
    }

    @Test func catchingUpAppliesExactlyWhatWasShown() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.refresh()
        await session.link(Fixture.presetID, destinations: [Fixture.codex])

        await session.catchUp(Fixture.presetID)

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        let assignments = try #require(try fixture.store.snapshot()).document.assignments
        #expect(Set(assignments.map(\.artifactID)) == [Fixture.alpha, Fixture.beta])
        #expect(assignments.allSatisfy { $0.reason == .preset(presetID: Fixture.presetID) })
        // Settled: catching up again has nothing to do.
        #expect(session.rows.first?.hasPendingChanges == false)
        #expect(session.lastAppliedName == "Starter")
    }

    @Test func aMemberTheAuthorRemovesIsTakenBackOutOnTheNextCatchUp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.refresh()
        await session.link(Fixture.presetID, destinations: [Fixture.codex])
        await session.catchUp(Fixture.presetID)

        try fixture.setPresetMembers([Fixture.alpha], revision: 3)
        await fixture.library.refresh()
        await session.refresh()
        #expect(session.rows.first?.hasPendingChanges == true)
        await session.catchUp(Fixture.presetID)

        let assignments = try #require(try fixture.store.snapshot()).document.assignments
        #expect(assignments.map(\.artifactID) == [Fixture.alpha])
    }

    @Test func aDestinationYouAlsoAskedForYourselfIsKeptAndSaidToBeKept() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.refresh()
        await session.link(Fixture.presetID, destinations: [Fixture.codex])
        await session.catchUp(Fixture.presetID)
        // The person also asks for Beta there themselves.
        try fixture.addManualAssignment(Fixture.beta)
        try fixture.setPresetMembers([Fixture.alpha], revision: 3)
        await fixture.library.refresh()
        await session.refresh()

        let update = try #require(session.rows.first?.update)
        #expect(update.changes.contains { $0.kind == .retainedByOtherReason && $0.artifactID == Fixture.beta })
        // Nothing a person would notice moves, but there is still work: the
        // preset's own contribution has to be let go of.
        #expect(session.rows.first?.hasPendingChanges == false)
        #expect(session.rows.first?.needsCatchUp == true)
        await session.catchUp(Fixture.presetID)

        let assignments = try #require(try fixture.store.snapshot()).document.assignments
        #expect(assignments.filter { $0.artifactID == Fixture.beta }.map(\.reason) == [.manual])
        #expect(session.rows.first?.needsCatchUp == false)
    }

    @Test func stoppingLeavesWhatItAlreadyPutInPlace() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session()
        await session.refresh()
        await session.link(Fixture.presetID, destinations: [Fixture.codex])
        await session.catchUp(Fixture.presetID)

        await session.unlink(Fixture.presetID)

        #expect(session.rows.first?.isLinked == false)
        // Removing them was not what was asked for.
        #expect(try #require(try fixture.store.snapshot()).document.assignments.count == 2)
    }

    @Test func aReadOnlyWorkspaceCanSeePresetsButNotFollowThem() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = await fixture.session(access: .readOnly)
        await session.refresh()

        await session.link(Fixture.presetID, destinations: [Fixture.codex])

        #expect(!session.canWrite)
        #expect(session.rows.first?.isLinked == false)
        #expect(try fixture.presetStore.read().isEmpty)
    }

    @Test func aLinkedPresetFileThatCannotBeReadShowsNothingAndSaysWhy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("not json".utf8).write(to: fixture.presetFile)
        let session = await fixture.session()

        await session.refresh()

        // Reporting "nothing is linked" would look like the person unlinked
        // everything, and the next catch-up would act on that.
        #expect(session.rows.isEmpty)
        #expect(session.errorMessage?.contains("could not be read") == true)
    }

    @MainActor private struct Fixture {
        static let alpha = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!)
        static let beta = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!)
        static let presetID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!)
        static let codex = PortableDestination(surface: .codexCLI, scope: .user)
        let root: URL
        let container: URL
        let store: WorkspaceRevisionStore
        /// Where the linked-preset store actually keeps its file, so a test can
        /// damage the real one rather than a path that looks like it.
        var presetFile: URL { store.databaseURL.deletingLastPathComponent().appending(path: "linked-presets.json") }
        let presetStore: WorkspaceLinkedPresetStore
        let service: WorkspaceApplicationService
        let library: WorkspaceLibrarySession
        let writerID = WorkspaceObjectID()

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "presets-session-\(UUID())")
            container = root.appending(path: "store")
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                artifacts: [
                    .init(identity: .init(id: Self.alpha, kind: .skill, displayName: "Alpha"),
                          authority: .trackedOnly),
                    .init(identity: .init(id: Self.beta, kind: .skill, displayName: "Beta"),
                          authority: .trackedOnly),
                    .init(identity: .init(id: Self.presetID, kind: .preset, displayName: "Starter"),
                          authority: .centralPersonal),
                ],
                presets: [.init(id: Self.presetID, name: "Starter", revision: 2,
                                memberArtifactIDs: [Self.alpha, Self.beta])]))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: container,
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            presetStore = try WorkspaceLinkedPresetStore(
                containerRoot: store.databaseURL.deletingLastPathComponent())
            service = WorkspaceApplicationService(store: store, writerID: writerID)
            library = WorkspaceLibrarySession(service: service, workspaceID: document.workspaceID,
                                              deviceID: device.deviceID, access: .writable)
        }

        func setPresetMembers(_ members: [ArtifactID], revision: UInt64) throws {
            try commit { document in
                guard let index = document.presets.firstIndex(where: { $0.id == Self.presetID })
                else { return [] }
                document.presets[index].memberArtifactIDs = members
                document.presets[index].revision = revision
                return members
            }
        }

        func addManualAssignment(_ artifactID: ArtifactID) throws {
            try commit { document in
                document.assignments.append(.init(artifactID: artifactID, destination: Self.codex,
                                                  reason: .manual))
                return [artifactID]
            }
        }

        private func commit(_ mutation: @escaping (inout PortableWorkspaceDocument) -> [ArtifactID]) throws {
            guard let head = try store.snapshot()?.document.revision.id else { return }
            _ = try store.commitMetadata(
                expectedRevisionID: head, idempotencyKey: WorkspaceObjectID(),
                inputDigest: String(repeating: "d", count: 64), writerID: writerID,
                mutation: mutation)
        }

        func session(access: WorkspaceLibraryAccess = .writable) async -> WorkspacePresetsSession {
            let library = access == .writable
                ? self.library
                : WorkspaceLibrarySession(service: service, workspaceID: store.workspaceID,
                                          deviceID: store.deviceID, access: .readOnly)
            await library.refresh()
            return WorkspacePresetsSession(service: service, library: library, store: presetStore)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

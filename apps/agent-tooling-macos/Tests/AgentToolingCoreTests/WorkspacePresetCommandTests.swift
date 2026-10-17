import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// A preset is a name and a set of live library items. Creating one writes both
/// its artifact and its record together; renaming keeps its identity; deleting
/// it leaves its members and lets go of only what it alone asked for.
struct WorkspacePresetCommandTests {
    @Test func creatingRecordsThePresetAndItsArtifact() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = try #require(await fixture.service.snapshot()).document.revision.id

        let command = try CreatePresetCommand(
            expectedRevisionID: head, name: "  Starter set  ", memberArtifactIDs: [fixture.alpha, fixture.beta])
        _ = try await fixture.service.createPreset(command)

        let document = try fixture.document()
        let preset = try #require(document.presets.first)
        #expect(preset.name == "Starter set")  // trimmed
        #expect(preset.revision == 1)
        #expect(Set(preset.memberArtifactIDs) == [fixture.alpha, fixture.beta])
        // The preset lives as an artifact too, which is what other records point at.
        #expect(document.artifacts.contains { $0.identity.id == preset.id && $0.identity.kind == .preset })
    }

    @Test func anEmptyNameIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = try #require(await fixture.service.snapshot()).document.revision.id
        #expect(throws: WorkspacePresetCommandError.emptyName) {
            _ = try CreatePresetCommand(expectedRevisionID: head, name: "   ", memberArtifactIDs: [fixture.alpha])
        }
    }

    @Test func aPresetWithNoMembersIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = try #require(await fixture.service.snapshot()).document.revision.id
        #expect(throws: WorkspacePresetCommandError.noMembers) {
            _ = try CreatePresetCommand(expectedRevisionID: head, name: "Empty", memberArtifactIDs: [])
        }
    }

    @Test func aDuplicateNameIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = try #require(await fixture.service.snapshot()).document.revision.id
        _ = try await fixture.service.createPreset(
            try CreatePresetCommand(expectedRevisionID: head, name: "Starter", memberArtifactIDs: [fixture.alpha]))

        let nextHead = try fixture.document().revision.id
        // Case-insensitively the same name is still a name a person cannot tell apart.
        let clash = try CreatePresetCommand(expectedRevisionID: nextHead, name: "starter", memberArtifactIDs: [fixture.beta])
        await #expect(throws: WorkspacePresetCommandError.duplicateName("starter")) {
            _ = try await fixture.service.createPreset(clash)
        }
    }

    @Test func anUnknownMemberIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = try #require(await fixture.service.snapshot()).document.revision.id
        let stranger = ArtifactID()
        let command = try CreatePresetCommand(
            expectedRevisionID: head, name: "Starter", memberArtifactIDs: [fixture.alpha, stranger])
        await #expect(throws: WorkspacePresetCommandError.unknownMember) {
            _ = try await fixture.service.createPreset(command)
        }
        // Nothing landed.
        #expect(try fixture.document().presets.isEmpty)
    }

    @Test func renamingKeepsIdentityRevisionAndMembers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = try #require(await fixture.service.snapshot()).document.revision.id
        let create = try CreatePresetCommand(
            expectedRevisionID: head, name: "Starter", memberArtifactIDs: [fixture.alpha, fixture.beta])
        _ = try await fixture.service.createPreset(create)

        let renameHead = try fixture.document().revision.id
        _ = try await fixture.service.renamePreset(
            try RenamePresetCommand(expectedRevisionID: renameHead, presetID: create.presetID, name: "Daily"))

        let renamed = try fixture.document()
        let preset = try #require(renamed.presets.first)
        #expect(preset.id == create.presetID)
        #expect(preset.name == "Daily")
        #expect(preset.revision == 1)
        #expect(Set(preset.memberArtifactIDs) == [fixture.alpha, fixture.beta])
        // The artifact's display name moved with it.
        let artifact = try #require(
            renamed.artifacts.first { $0.identity.id == create.presetID })
        #expect(artifact.identity.displayName == "Daily")
    }

    @Test func deletingLeavesMembersAndLetsGoOfOnlyItsOwnAssignment() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = try #require(await fixture.service.snapshot()).document.revision.id
        let create = try CreatePresetCommand(
            expectedRevisionID: head, name: "Starter", memberArtifactIDs: [fixture.alpha])
        _ = try await fixture.service.createPreset(create)
        // A preset contribution for alpha, and a manual one the person also made.
        try fixture.addAssignments([
            .init(
                artifactID: fixture.alpha, destination: fixture.destination,
                reason: .preset(presetID: create.presetID)),
            .init(artifactID: fixture.beta, destination: fixture.destination, reason: .manual),
        ])

        let deleteHead = try fixture.document().revision.id
        _ = try await fixture.service.deletePreset(
            DeletePresetCommand(expectedRevisionID: deleteHead, presetID: create.presetID))

        let document = try fixture.document()
        #expect(document.presets.isEmpty)
        #expect(!document.artifacts.contains { $0.identity.id == create.presetID })
        // The members stayed; only the preset's own contribution was let go of.
        #expect(document.artifacts.contains { $0.identity.id == fixture.alpha })
        #expect(document.assignments.map(\.reason) == [.manual])
        // The identity is tombstoned so it cannot silently return.
        #expect(document.tombstones.contains { $0.artifactID == create.presetID })
    }

    private struct Fixture {
        let root: URL
        let alpha = ArtifactID()
        let beta = ArtifactID()
        let writerID = WorkspaceObjectID()
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let destination = PortableDestination(surface: .claudeCode, scope: .user)

        init() throws {
            root = try TemporaryFolder("preset-command").url
            let document = try WorkspaceDocumentCoding.seal(
                .init(
                    revision: .init(writerID: writerID),
                    artifacts: [
                        .init(identity: .init(id: alpha, kind: .skill, displayName: "Alpha"), authority: .trackedOnly),
                        .init(identity: .init(id: beta, kind: .skill, displayName: "Beta"), authority: .trackedOnly),
                    ]))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(
                containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
        }

        /// The current committed document, unwrapped, so a test does not nest a
        /// `try` inside `#require` (which the macro will not expand).
        func document() throws -> PortableWorkspaceDocument {
            guard let snapshot = try store.snapshot() else { throw WorkspaceRevisionStoreError.notInitialized }
            return snapshot.document
        }

        func addAssignments(_ additions: [AssignmentContribution]) throws {
            guard let head = try store.snapshot()?.document.revision.id else { return }
            _ = try store.commitMetadata(
                expectedRevisionID: head, idempotencyKey: WorkspaceObjectID(),
                inputDigest: String(repeating: "a", count: 64), writerID: writerID
            ) { document in
                document.assignments.append(contentsOf: additions)
                return additions.map(\.artifactID)
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

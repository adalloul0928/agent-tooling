import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceAssignmentCommandTests {
    @Test func batchPreservesIndependentContributionReasons() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let presetID = ArtifactID()
        let preset = PresetRecord(id: presetID, name: "Daily", memberArtifactIDs: [fixture.artifactID])
        try fixture.replaceDocument { document in
            document.artifacts.append(.init(identity: .init(id: presetID, kind: .preset, displayName: "Daily"), authority: .trackedOnly))
            document.presets = [preset]
        }
        let snapshot = try #require(await fixture.service.snapshot())
        let manual = AssignmentContribution(artifactID: fixture.artifactID, destination: fixture.destination,
            reason: .manual)
        let presetContribution = AssignmentContribution(artifactID: fixture.artifactID,
            destination: fixture.destination, reason: .preset(presetID: presetID))
        let command = WorkspaceAssignmentBatchCommand(expectedRevisionID: snapshot.document.revision.id,
            additions: [manual, presetContribution],
            presetApplications: [.init(presetID: presetID, revision: preset.revision,
                memberArtifactIDs: preset.memberArtifactIDs)])
        _ = try await fixture.service.applyAssignmentBatch(command)
        let saved = try #require(await fixture.service.snapshot())
        #expect(saved.document.assignments.count == 2)
        #expect(Set(saved.document.assignments.map(\.reason)) == [.manual, .preset(presetID: presetID)])
    }

    @Test func secondAssignAgainstNewHeadRejectsSemanticDuplicate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try WorkspaceAssignmentBatchCommand.assign(
            document: fixture.document, artifactIDs: [fixture.artifactID], destinations: [fixture.destination])
        _ = try await fixture.service.applyAssignmentBatch(first)
        let current = try #require(await fixture.service.snapshot())
        #expect(throws: WorkspaceAssignmentCommandError.contributionConflict) {
            _ = try WorkspaceAssignmentBatchCommand.assign(
                document: current.document, artifactIDs: [fixture.artifactID], destinations: [fixture.destination])
        }
    }

    @Test func duplicateSemanticContributionsWithinBatchAreRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = WorkspaceAssignmentBatchCommand(expectedRevisionID: fixture.document.revision.id, additions: [
            .init(artifactID: fixture.artifactID, destination: fixture.destination, reason: .manual),
            .init(artifactID: fixture.artifactID, destination: fixture.destination, reason: .manual)
        ])
        await #expect(throws: WorkspaceAssignmentCommandError.contributionConflict) {
            try await fixture.service.applyAssignmentBatch(command)
        }
        #expect(try await fixture.service.snapshot()?.document == fixture.document)
    }

    @Test func removingOneContributionLeavesTheOtherReason() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let presetID = ArtifactID()
        try fixture.replaceDocument { document in
            document.artifacts.append(.init(identity: .init(id: presetID, kind: .preset, displayName: "Preset"), authority: .trackedOnly))
            document.presets = [.init(id: presetID, name: "Preset", memberArtifactIDs: [fixture.artifactID])]
        }
        let initial = try #require(await fixture.service.snapshot())
        let first = AssignmentContribution(artifactID: fixture.artifactID, destination: fixture.destination, reason: .manual)
        let second = AssignmentContribution(artifactID: fixture.artifactID,
            destination: fixture.destination, reason: .preset(presetID: presetID))
        let seed = WorkspaceAssignmentBatchCommand(expectedRevisionID: initial.document.revision.id,
            additions: [first, second], presetApplications: [.init(presetID: presetID, revision: 1,
                memberArtifactIDs: [fixture.artifactID])])
        _ = try await fixture.service.applyAssignmentBatch(seed)
        let snapshot = try #require(await fixture.service.snapshot())
        let command = WorkspaceAssignmentBatchCommand(expectedRevisionID: snapshot.document.revision.id, removalIDs: [first.id])
        _ = try await fixture.service.applyAssignmentBatch(command)
        let saved = try #require(await fixture.service.snapshot())
        #expect(saved.document.assignments == [second])
    }

    @Test func removeAndAddSameTargetReplacesOneReasonAndRetainsAnother() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let presetID = ArtifactID()
        try fixture.replaceDocument { document in
            document.artifacts.append(.init(identity: .init(id: presetID, kind: .preset, displayName: "Preset"), authority: .trackedOnly))
            document.presets = [.init(id: presetID, name: "Preset", memberArtifactIDs: [fixture.artifactID])]
        }
        let initial = try #require(await fixture.service.snapshot())
        let manual = AssignmentContribution(artifactID: fixture.artifactID, destination: fixture.destination, reason: .manual)
        let preset = AssignmentContribution(artifactID: fixture.artifactID, destination: fixture.destination, reason: .preset(presetID: presetID))
        let seed = WorkspaceAssignmentBatchCommand(expectedRevisionID: initial.document.revision.id,
            additions: [manual, preset], presetApplications: [.init(presetID: presetID, revision: 1, memberArtifactIDs: [fixture.artifactID])])
        _ = try await fixture.service.applyAssignmentBatch(seed)
        let current = try #require(await fixture.service.snapshot())
        let replacement = AssignmentContribution(artifactID: fixture.artifactID, destination: fixture.destination, reason: .manual)
        let command = WorkspaceAssignmentBatchCommand(expectedRevisionID: current.document.revision.id,
            additions: [replacement], removalIDs: [manual.id])
        _ = try await fixture.service.applyAssignmentBatch(command)
        let saved = try #require(await fixture.service.snapshot())
        #expect(Set(saved.document.assignments) == Set([preset, replacement]))
    }

    @Test func nativePackageRootIsAssignableButNativeChildIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let packageID = ArtifactID()
        let childID = ArtifactID()
        try fixture.replaceDocument { document in
            document.artifacts += [
                .init(identity: .init(id: packageID, kind: .nativePlugin, displayName: "Native package"), authority: .nativeOwned,
                    declaredName: "native-package", nativeRoutes: [.init(client: .claude, externalPluginID: "native-package")]),
                .init(identity: .init(id: childID, kind: .skill, displayName: "Child", parentPackageID: packageID),
                    authority: .nativeOwned, packageRelativePath: "skills/child")
            ]
        }
        let snapshot = try #require(await fixture.service.snapshot())
        let rootCommand = WorkspaceAssignmentBatchCommand(expectedRevisionID: snapshot.document.revision.id,
            additions: [.init(artifactID: packageID, destination: fixture.destination, reason: .manual)])
        _ = try await fixture.service.applyAssignmentBatch(rootCommand)
        let current = try #require(await fixture.service.snapshot())
        let childCommand = WorkspaceAssignmentBatchCommand(expectedRevisionID: current.document.revision.id,
            additions: [.init(artifactID: childID, destination: fixture.destination, reason: .manual)])
        await #expect(throws: WorkspaceAssignmentCommandError.nativeChild) {
            try await fixture.service.applyAssignmentBatch(childCommand)
        }
    }

    @Test func presetApplyOnceCapturesMembersWithoutFollowingLaterMembershipChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let secondID = ArtifactID()
        let presetID = ArtifactID()
        try fixture.replaceDocument { document in
            document.artifacts += [
                .init(identity: .init(id: secondID, kind: .skill, displayName: "Later"), authority: .centralPersonal),
                .init(identity: .init(id: presetID, kind: .preset, displayName: "Preset"), authority: .trackedOnly)
            ]
            document.presets = [.init(id: presetID, name: "Preset", memberArtifactIDs: [fixture.artifactID])]
        }
        let before = try #require(await fixture.service.snapshot())
        let command = try WorkspaceAssignmentBatchCommand.applyPresetOnce(document: before.document,
            presetID: presetID, destinations: [fixture.destination])
        _ = try await fixture.service.applyAssignmentBatch(command)
        let after = try #require(await fixture.service.snapshot())
        try fixture.replaceDocument { document in
            document.presets[0].revision += 1
            document.presets[0].memberArtifactIDs.append(secondID)
        }
        let final = try #require(await fixture.service.snapshot())
        #expect(final.document.assignments.map(\.artifactID) == [fixture.artifactID])
        #expect(Set(final.document.presets[0].memberArtifactIDs) == Set([fixture.artifactID, secondID]))
        #expect(final.document.revision.parentIDs == [after.document.revision.id])
        let freshContributions = command.additions.map { value in
            var value = value
            value.id = WorkspaceObjectID()
            value.destination = .init(surface: .geminiCLI, scope: .user)
            return value
        }
        let updatedExpected = WorkspaceAssignmentBatchCommand(expectedRevisionID: final.document.revision.id,
            additions: freshContributions, presetApplications: command.presetApplications)
        await #expect(throws: WorkspaceAssignmentCommandError.presetChanged) {
            try await fixture.service.applyAssignmentBatch(updatedExpected)
        }
    }

    @Test func selectorCardinalityAndDeviceOrderArePreservedAndCanonicalized() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = WorkspaceObjectID()
        let second = WorkspaceObjectID()
        let ordered = PortableDestination(surface: .claudeCode, scope: .user, deviceIDs: [second, first])
        let nilDevices = PortableDestination(surface: .claudeCode, scope: .user, deviceIDs: nil)
        let emptyDevices = PortableDestination(surface: .claudeCode, scope: .user, deviceIDs: [])
        let snapshot = try #require(await fixture.service.snapshot())
        let command = try WorkspaceAssignmentBatchCommand.assign(document: snapshot.document,
            artifactIDs: [fixture.artifactID], destinations: [ordered, nilDevices, emptyDevices])
        let preview = try await fixture.service.previewAssignmentBatch(command)
        #expect(preview.additions.count == 3)
        #expect(preview.additions.contains { $0.destination.deviceIDs == [first, second].sorted() })
        #expect(preview.additions.contains { $0.destination.deviceIDs == nil })
        #expect(preview.additions.contains { $0.destination.deviceIDs == [] })
        let reorderedDuplicate = WorkspaceAssignmentBatchCommand(expectedRevisionID: snapshot.document.revision.id,
            additions: [.init(artifactID: fixture.artifactID, destination: .init(surface: .claudeCode, scope: .user,
                deviceIDs: [first, second]), reason: .manual),
                .init(artifactID: fixture.artifactID, destination: .init(surface: .claudeCode, scope: .user,
                    deviceIDs: [second, first]), reason: .manual)])
        await #expect(throws: WorkspaceAssignmentCommandError.contributionConflict) {
            try await fixture.service.applyAssignmentBatch(reorderedDuplicate)
        }
    }

    @Test func staleCommandReplaysItsReceiptAfterLaterEditAndReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let initial = try #require(await fixture.service.snapshot())
        let command = WorkspaceAssignmentBatchCommand(expectedRevisionID: initial.document.revision.id,
            additions: [.init(artifactID: fixture.artifactID, destination: fixture.destination, reason: .manual)])
        let receipt = try await fixture.service.applyAssignmentBatch(command)
        let later = WorkspaceAssignmentBatchCommand(expectedRevisionID: receipt.committedRevisionID,
            additions: [.init(artifactID: fixture.artifactID,
                destination: .init(surface: .codexCLI, scope: .user), reason: .manual)])
        _ = try await fixture.service.applyAssignmentBatch(later)
        let staleNewRequest = WorkspaceAssignmentBatchCommand(expectedRevisionID: initial.document.revision.id,
            additions: [.init(artifactID: fixture.artifactID,
                destination: .init(surface: .codexDesktop, scope: .user), reason: .manual)])
        let currentRevision = try #require(await fixture.service.snapshot()).document.revision.id
        await #expect(throws: WorkspaceRevisionStoreError.staleRevision(current: currentRevision)) {
            try await fixture.service.applyAssignmentBatch(staleNewRequest)
        }
        let reopened = WorkspaceApplicationService(store: try fixture.reopen(), writerID: fixture.writerID)
        let replay = try await reopened.applyAssignmentBatch(command)
        #expect(replay == receipt)
        let final = try #require(await fixture.service.snapshot())
        #expect(try await reopened.snapshot()?.document.revision.id == final.document.revision.id)
    }

    @Test func invalidBatchDoesNotMoveHead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try #require(await fixture.service.snapshot())
        let invalid = WorkspaceAssignmentBatchCommand(expectedRevisionID: before.document.revision.id,
            additions: [.init(artifactID: ArtifactID(), destination: fixture.destination, reason: .manual)])
        await #expect(throws: WorkspaceAssignmentCommandError.unsupportedArtifact) {
            try await fixture.service.applyAssignmentBatch(invalid)
        }
        #expect(try await fixture.service.snapshot()?.document == before.document)
    }

    @Test func assignmentBatchLeavesNativeSurfaceAndDeviceStateUntouched() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let nativeRoot = fixture.root.appending(path: "native-surface")
        try FileManager.default.createDirectory(at: nativeRoot, withIntermediateDirectories: true)
        let beforeFiles = try FileManager.default.contentsOfDirectory(atPath: nativeRoot.path)
        let before = try #require(await fixture.service.snapshot())
        let command = WorkspaceAssignmentBatchCommand(expectedRevisionID: before.document.revision.id,
            additions: [.init(artifactID: fixture.artifactID, destination: fixture.destination, reason: .manual)])
        _ = try await fixture.service.applyAssignmentBatch(command)
        let after = try #require(await fixture.service.snapshot())
        #expect(after.device == before.device)
        #expect(try FileManager.default.contentsOfDirectory(atPath: nativeRoot.path) == beforeFiles)
    }

    private struct Fixture {
        let root: URL
        let artifactID = ArtifactID()
        let writerID = WorkspaceObjectID()
        let document: PortableWorkspaceDocument
        let device: DeviceWorkspaceState
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let destination = PortableDestination(surface: .claudeCode, scope: .user)

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "assignment-command-\(UUID())")
            document = try WorkspaceDocumentCoding.seal(.init(revision: .init(writerID: writerID), artifacts: [
                .init(identity: .init(id: artifactID, kind: .skill, displayName: "Skill"), authority: .centralPersonal)
            ]))
            device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
        }

        func replaceDocument(_ mutation: (inout PortableWorkspaceDocument) throws -> Void) throws {
            guard let current = try store.snapshot() else { throw WorkspaceRevisionStoreError.notInitialized }
            _ = try store.commitMetadata(expectedRevisionID: current.document.revision.id,
                idempotencyKey: WorkspaceObjectID(), inputDigest: String(repeating: "a", count: 64), writerID: writerID) { document in
                try mutation(&document)
                return document.artifacts.map(\.identity.id)
            }
        }

        func reopen() throws -> WorkspaceRevisionStore {
            try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

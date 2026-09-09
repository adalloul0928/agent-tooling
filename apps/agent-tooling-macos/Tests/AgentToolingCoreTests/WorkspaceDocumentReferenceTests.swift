import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceDocumentReferenceTests {
    @Test func renamedPackageRetainsItsChildPresetAndProjectAssignmentAfterReload() throws {
        var document = fixture()
        let originalIDs = document.artifacts.map(\.identity.id)
        document.artifacts[0].identity.displayName = "Renamed workflows"
        let sealed = try WorkspaceDocumentCoding.seal(document)
        let loaded = try WorkspaceDocumentCoding.decode(WorkspaceDocumentCoding.encode(sealed))

        #expect(Set(loaded.artifacts.map(\.identity.id)) == Set(originalIDs))
        #expect(loaded.artifacts.first { $0.identity.id == originalIDs[0] }?.identity.displayName == "Renamed workflows")
        #expect(loaded.artifacts.first { $0.identity.id == originalIDs[1] }?.identity.parentPackageID == originalIDs[0])
        #expect(loaded.presets[0].memberArtifactIDs == [originalIDs[1]])
        #expect(loaded.assignments[0].artifactID == originalIDs[1])
        #expect(loaded.assignments[0].destination.logicalProjectID == originalIDs[2])
        #expect(loaded.assignments[0].reason == .preset(presetID: originalIDs[3]))
    }

    @Test func unsupportedWriterAndBrokenReferencesCannotBeSealed() throws {
        var newerWriter = fixture()
        newerWriter.minimumWriterVersion = PortableWorkspaceDocument.currentSchemaVersion + 1
        #expect(throws: WorkspaceDomainValidationError.self) { _ = try WorkspaceDocumentCoding.seal(newerWriter) }

        var missingProject = fixture()
        missingProject.logicalProjects = []
        #expect(throws: WorkspaceDomainValidationError.self) { _ = try WorkspaceDocumentCoding.seal(missingProject) }

        var missingMember = fixture()
        missingMember.artifacts.remove(at: 1)
        #expect(throws: WorkspaceDomainValidationError.self) { _ = try WorkspaceDocumentCoding.seal(missingMember) }

        var collidingAlias = fixture()
        collidingAlias.artifacts[1].identity.aliases = collidingAlias.artifacts[0].identity.aliases
        #expect(throws: WorkspaceDomainValidationError.self) { _ = try WorkspaceDocumentCoding.seal(collidingAlias) }

        var escapingChild = fixture()
        escapingChild.artifacts[1].packageRelativePath = "../other-package/skill"
        #expect(throws: WorkspaceDomainValidationError.self) { _ = try WorkspaceDocumentCoding.seal(escapingChild) }
    }

    private func fixture() -> PortableWorkspaceDocument {
        let packageID = ArtifactID()
        let skillID = ArtifactID()
        let projectID = ArtifactID()
        let presetID = ArtifactID()
        let artifacts = [
            ArtifactRecord(
                identity: ArtifactIdentity(id: packageID, kind: .package, displayName: "My workflows",
                    aliases: [.init(namespace: "legacy.plugin", value: "my-workflows")]),
                authority: .centralPersonal, declaredName: "my-workflows"),
            ArtifactRecord(
                identity: ArtifactIdentity(id: skillID, kind: .skill, displayName: "Review",
                    aliases: [.init(namespace: "legacy.skill", value: "review")], parentPackageID: packageID),
                authority: .centralPersonal, declaredName: "review", packageRelativePath: "skills/review"),
            ArtifactRecord(identity: .init(id: projectID, kind: .logicalProject, displayName: "Project"), authority: .trackedOnly),
            ArtifactRecord(identity: .init(id: presetID, kind: .preset, displayName: "Daily work"), authority: .trackedOnly),
        ]
        return PortableWorkspaceDocument(
            revision: WorkspaceRevision(writerID: WorkspaceObjectID(), createdAt: Date(timeIntervalSince1970: 0)),
            artifacts: artifacts,
            logicalProjects: [.init(id: projectID, name: "Project", repositoryHints: ["https://github.com/example/project"])],
            assignments: [.init(artifactID: skillID,
                destination: .init(surface: .claudeCode, scope: .project, logicalProjectID: projectID),
                reason: .preset(presetID: presetID), desiredEnabled: true)],
            presets: [.init(id: presetID, name: "Daily work", revision: 1, memberArtifactIDs: [skillID])])
    }
}

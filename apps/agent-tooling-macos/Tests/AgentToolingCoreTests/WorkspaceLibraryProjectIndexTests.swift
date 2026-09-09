import Foundation
import Testing

@testable import AgentToolingCore

/// A project view must read precomputed membership rather than scanning every
/// row's assignments, and must distinguish project intent from what every
/// project inherits.
@Suite("Workspace library project index")
struct WorkspaceLibraryProjectIndexTests {
    @Test func projectMembershipIsSeparateFromGloballyAssignedItems() throws {
        let projectID = ArtifactID()
        let otherID = ArtifactID()
        let scoped = Self.skill("Scoped")
        let global = Self.skill("Global")
        let both = Self.skill("Both")
        let unassigned = Self.skill("Unassigned")
        let document = try Self.document(
            projects: [.init(id: projectID, name: "Alpha"), .init(id: otherID, name: "Beta")],
            artifacts: [scoped, global, both, unassigned],
            assignments: [
                Self.assignment(scoped, project: projectID),
                Self.assignment(global, project: nil),
                Self.assignment(both, project: projectID),
                Self.assignment(both, project: nil),
            ])
        let model = try WorkspaceLibraryReadModel(snapshot: Self.snapshot(document))

        #expect(model.rows(inProject: projectID).map(\.displayName) == ["Both", "Scoped"])
        #expect(model.rows(inProject: otherID).isEmpty)
        #expect(model.globallyAssignedRows.map(\.displayName) == ["Both", "Global"])
        #expect(model.assignedItemCount(inProject: projectID) == 2)
        #expect(model.assignedItemCount(inProject: otherID) == 0)
        #expect(!model.rows(inProject: projectID).contains { $0.displayName == "Unassigned" })
    }

    @Test func repeatedProjectAssignmentsCountAnItemOnce() throws {
        let projectID = ArtifactID()
        let skill = Self.skill("Repeated")
        let document = try Self.document(
            projects: [.init(id: projectID, name: "Alpha")],
            artifacts: [skill],
            assignments: [
                Self.assignment(skill, project: projectID, surface: .codexCLI),
                Self.assignment(skill, project: projectID, surface: .claudeCode),
            ])
        let model = try WorkspaceLibraryReadModel(snapshot: Self.snapshot(document))

        #expect(model.assignedItemCount(inProject: projectID) == 1)
        #expect(model.rows(inProject: projectID).count == 1)
        #expect(model.rows(inProject: projectID).first?.requestedAssignments.count == 2)
    }

    private static func skill(_ name: String) -> ArtifactRecord {
        .init(identity: .init(id: ArtifactID(), kind: .skill, displayName: name),
              authority: .centralPersonal, declaredName: name.lowercased(),
              contentDigest: .init(algorithm: .sha256TreeV1, value: String(repeating: "a", count: 64)))
    }

    private static func assignment(
        _ artifact: ArtifactRecord,
        project: ArtifactID?,
        surface: TargetSurface = .codexCLI
    ) -> AssignmentContribution {
        .init(id: WorkspaceObjectID(), artifactID: artifact.identity.id,
              destination: .init(surface: surface,
                                 scope: project == nil ? .user : .project,
                                 logicalProjectID: project),
              reason: .manual, desiredPresence: true)
    }

    private static func document(
        projects: [LogicalProjectRecord],
        artifacts: [ArtifactRecord],
        assignments: [AssignmentContribution]
    ) throws -> PortableWorkspaceDocument {
        // Every logical project also has its own artifact record.
        let projectArtifacts = projects.map {
            ArtifactRecord(identity: .init(id: $0.id, kind: .logicalProject, displayName: $0.name),
                           authority: .trackedOnly)
        }
        return try WorkspaceDocumentCoding.seal(.init(
            workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID()),
            artifacts: artifacts + projectArtifacts, logicalProjects: projects, assignments: assignments))
    }

    private static func snapshot(_ document: PortableWorkspaceDocument) -> WorkspaceApplicationSnapshot {
        .init(document: document,
              device: .init(workspaceID: document.workspaceID, deviceID: WorkspaceObjectID()))
    }
}

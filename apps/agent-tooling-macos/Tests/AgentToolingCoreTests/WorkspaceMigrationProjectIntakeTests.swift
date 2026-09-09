import Foundation
import Testing
@testable import AgentToolingCore

struct WorkspaceMigrationProjectIntakeTests {
    @Test func sharedExactRootMapsPersonalPolicyAndManagedMCPWithOriginalScopes() throws {
        let root = "/work/shared"
        let personal = profile("personal", name: "Personal", scope: .project, root: root)
        let policyProfile = profile("policy", name: "Policy", scope: .localProject, root: root)
        let policy = ManagedPolicy(id: "policy-owner", name: "Policy", sourcePath: "/policy", profiles: [policyProfile])
        let server = managedServer("server", scope: "Project", root: root)
        let intake = WorkspaceMigrationIntake(
            choices: [], issues: [.init(legacy: key(.mcpServer, server.id), displayName: server.name, reason: .managedConnection)],
            snapshot: .init(mcpServers: [server], profiles: [personal], managedPolicies: [policy])
        )
        let project = mapping(root: root, id: ArtifactID(), name: "Confirmed project")

        let reviewed = try WorkspaceMigrationProjectIntake.review(intake: intake, projects: [project])

        #expect(reviewed.requirements.count == 1)
        let requirement = try #require(reviewed.requirements.first)
        #expect(requirement.rootPath == root && requirement.canMap)
        #expect(Set(requirement.items.map(\.scope)) == [.project, .localProject])
        #expect(Set(requirement.items.map(\.legacy)) == [
            key(.configuration, personal.id),
            key(.configuration, policyProfile.id, owner: policy.id),
            key(.mcpServer, server.id),
        ])
        #expect(reviewed.projects.map(\.project.id) == [project.project.id])
        #expect(reviewed.configurationProjects == [
            key(.configuration, personal.id): project.project.id,
            key(.configuration, policyProfile.id, owner: policy.id): project.project.id,
        ])
    }

    @Test func sameDisplayNameAtDistinctRootsRequiresDistinctConfirmedIDs() throws {
        let first = profile("one", name: "Same", scope: .project, root: "/work/one")
        let second = profile("two", name: "Same", scope: .localProject, root: "/work/two")
        let intake = WorkspaceMigrationIntake(choices: [], issues: [], snapshot: .init(profiles: [first, second]))
        let firstProject = mapping(root: "/work/one", id: ArtifactID(), name: "Same")
        let secondProject = mapping(root: "/work/two", id: ArtifactID(), name: "Same")

        let reviewed = try WorkspaceMigrationProjectIntake.review(intake: intake, projects: [secondProject, firstProject])

        #expect(reviewed.requirements.map(\.rootPath) == ["/work/one", "/work/two"])
        #expect(Set(reviewed.configurationProjects.values) == [firstProject.project.id, secondProject.project.id])
    }

    @Test func missingAndInvalidRootsStayVisibleButCannotBeMapped() throws {
        let missing = profile("missing", name: "Missing", scope: .project, root: nil)
        let invalid = profile("invalid", name: "Invalid", scope: .localProject, root: "/work/../invalid")
        let intake = WorkspaceMigrationIntake(choices: [], issues: [], snapshot: .init(profiles: [missing, invalid]))

        let reviewed = try WorkspaceMigrationProjectIntake.review(intake: intake, projects: [])

        #expect(reviewed.projects.isEmpty)
        #expect(reviewed.configurationProjects.isEmpty)
        #expect(reviewed.requirements.count == 2)
        #expect(reviewed.requirements.allSatisfy { !$0.canMap })
        #expect(Set(reviewed.requirements.flatMap(\.items).map(\.legacy)) == [
            key(.configuration, missing.id), key(.configuration, invalid.id),
        ])
    }

    @Test func duplicateAndUnreferencedMappingsAreRejected() throws {
        let firstProfile = profile("project", name: "Project", scope: .project, root: "/work/project")
        let otherProfile = profile("other", name: "Other", scope: .project, root: "/work/other")
        let intake = WorkspaceMigrationIntake(choices: [], issues: [], snapshot: .init(profiles: [firstProfile, otherProfile]))
        let first = mapping(root: "/work/project", id: ArtifactID(), name: "One")
        let duplicateRoot = mapping(root: "/work/project", id: ArtifactID(), name: "Two")
        #expect(throws: WorkspaceMigrationProjectIntakeError.duplicateRoot) {
            try WorkspaceMigrationProjectIntake.review(intake: intake, projects: [first, duplicateRoot])
        }
        let duplicateID = mapping(root: "/work/other", id: first.project.id, name: "Other")
        #expect(throws: WorkspaceMigrationProjectIntakeError.duplicateProjectID) {
            try WorkspaceMigrationProjectIntake.review(intake: intake, projects: [first, duplicateID])
        }
        #expect(throws: WorkspaceMigrationProjectIntakeError.unreferencedProject) {
            try WorkspaceMigrationProjectIntake.review(intake: intake, projects: [mapping(root: "/work/unreferenced", id: ArtifactID(), name: "Other")])
        }
    }

    @Test func whitespaceNamesAndPersonalPolicyNamespaceCollisionsAreRejectedOrKeptDistinct() throws {
        let personal = profile("same", name: "Personal", scope: .project, root: nil)
        let policyProfile = profile("same", name: "Policy", scope: .localProject, root: nil)
        let policy = ManagedPolicy(id: "personal", name: "Policy", sourcePath: "/policy", profiles: [policyProfile])
        let intake = WorkspaceMigrationIntake(choices: [], issues: [],
            snapshot: .init(profiles: [personal], managedPolicies: [policy]))
        let reviewed = try WorkspaceMigrationProjectIntake.review(intake: intake, projects: [])
        #expect(Set(reviewed.requirements.map(\.id)).count == 2)

        let mappedProfile = profile("mapped", name: "Mapped", scope: .project, root: "/work/mapped")
        let mappedIntake = WorkspaceMigrationIntake(choices: [], issues: [], snapshot: .init(profiles: [mappedProfile]))
        #expect(throws: WorkspaceMigrationProjectIntakeError.invalidProject) {
            try WorkspaceMigrationProjectIntake.review(intake: mappedIntake,
                projects: [mapping(root: "/work/mapped", id: ArtifactID(), name: "   ")])
        }
    }

    @Test func managedProjectMCPUsesOnlyTheExactConfirmedRootAndProjectID() throws {
        let root = "/work/project"
        let server = managedServer("server", scope: "This project only", root: root)
        let intake = WorkspaceMigrationIntake(
            choices: [], issues: [.init(legacy: key(.mcpServer, server.id), displayName: server.name, reason: .managedConnection)],
            snapshot: .init(mcpServers: [server])
        )
        let project = mapping(root: root, id: ArtifactID(), name: "Confirmed")
        let context = WorkspaceMigrationContext(workspaceID: WorkspaceObjectID(), deviceID: WorkspaceObjectID(),
                                                revision: .init(writerID: WorkspaceObjectID()))

        let reviewed = try WorkspaceManagedMCPMigrationIntake.review(intake: intake, context: context, projects: [project])
        let resolution = try #require(reviewed.resolutions.first)
        #expect(resolution.project?.rootPath == root)
        #expect(resolution.project?.project.id == project.project.id)
        #expect(resolution.assignments.allSatisfy {
            $0.destination.scope == .localProject && $0.destination.logicalProjectID == project.project.id
        })
        #expect(reviewed.issues.isEmpty && reviewed.intake.issues.isEmpty)
    }

    @Test func unmanagedAndBundledManagedMCPsDoNotCreateProjectRequirements() throws {
        let unmanaged = MCPServer(id: "observed", name: "Observed", summary: "Observed", endpoint: "runner", transport: .stdio,
                                  authentication: "None", scope: "Project", projectRoot: "/work/project", clients: [])
        let bundled = managedServer("bundled", scope: "Project", root: "/work/project")
        let bundledKey = key(.mcpServer, bundled.id)
        let intake = WorkspaceMigrationIntake(
            choices: [.init(legacy: key(.plugin, "plugin"), strategy: .nativePackage(
                routes: [.init(client: .codex, externalPluginID: "plugin")], children: [.init(legacy: bundledKey)]
            ))],
            issues: [.init(legacy: bundledKey, displayName: bundled.name, reason: .managedConnection)],
            snapshot: .init(mcpServers: [unmanaged, bundled])
        )

        let reviewed = try WorkspaceMigrationProjectIntake.review(intake: intake, projects: [])
        #expect(reviewed.requirements.isEmpty)
    }

    private func profile(_ id: String, name: String, scope: ToolingScope, root: String?) -> ToolingProfile {
        .init(id: id, name: name, summary: "Fixture", scope: scope, projectRoot: root,
              checks: [], enabledPlugins: [], requiredMCPs: [])
    }
    private func managedServer(_ id: String, scope: String, root: String) -> MCPServer {
        .init(id: id, name: id.capitalized, summary: "Managed", endpoint: "runner", transport: .stdio,
              authentication: "None", scope: scope, projectRoot: root,
              clients: [.init(client: .codex, state: .healthy, detail: "Configured")], definitionOrigin: .managed)
    }
    private func mapping(root: String, id: ArtifactID, name: String) -> WorkspaceMCPMigrationProject {
        .init(project: .init(id: id, name: name), rootPath: root)
    }
    private func key(_ domain: LegacyReferenceDomain, _ id: String, owner: String? = nil) -> LegacyReferenceKey {
        .init(domain: domain, identifier: id, ownerPolicyID: owner)
    }
}

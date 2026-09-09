import Darwin
import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

@MainActor
struct WorkspaceMigrationProjectSetupTests {
    @Test func projectReviewMapsOneRootForProjectAndLocalProjectMCPs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)

        await session.inspect()
        let intake = try #require(session.projectIntake)
        #expect(intake.requirements.count == 1)
        #expect(Set(intake.requirements.map(\.rootPath)) == Set([fixture.projectRoot.path]))
        #expect(intake.requirements.allSatisfy { $0.items.count == 3 })
        #expect(intake.projects.isEmpty)

        let requirement = try #require(intake.requirements.first)
        session.setProjectName("Shared project", for: requirement.id)
        await session.confirmProject(requirement.id)
        #expect(session.projectIntake?.projects.count == 1)
        #expect(session.projectNames.count == 1)
        #expect(Set(session.projectIntake?.projects.map(\.rootPath) ?? []) == Set([fixture.projectRoot.path]))
        #expect(Set(session.projectIntake?.projects.map(\.project.id) ?? []).count == 1)
        #expect(session.preview?.canPrepare == true, "\(session.preview?.issues ?? [])")
        let assignments = try #require(session.preview?.preparation?.record.document.assignments)
        #expect(Set(assignments.map { $0.destination.scope }) == [.project, .localProject])
        #expect(Set(assignments.compactMap { $0.destination.logicalProjectID }).count == 1)
        #expect(session.intake?.issues.isEmpty == true)
        await session.stage()
        #expect(session.reviewSession?.state?.journalEntry.phase == .prepared)
    }

    @Test func blankProjectNameCannotConfirmAndRepeatedInspectKeepsMapping() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()
        let requirement = try #require(session.projectIntake?.requirements.first)

        session.setProjectName("   ", for: requirement.id)
        await session.confirmProject(requirement.id)
        #expect(session.projectIntake?.projects.isEmpty == true)
        #expect(session.projectMappingErrors[requirement.id] != nil)

        session.setProjectName("Shared project", for: requirement.id)
        await session.confirmProject(requirement.id)
        let projectID = try #require(session.projectIntake?.projects.first?.project.id)
        await session.inspect()
        #expect(session.projectIntake?.projects.first?.project.id == projectID)
        #expect(session.projectNames[requirement.id] == "Shared project")
    }

    @Test func invalidRootCannotBeMapped() async throws {
        let fixture = try Fixture(invalidRoot: true)
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()
        let requirement = try #require(session.projectIntake?.requirements.first)
        #expect(requirement.canMap == false)
        session.setProjectName("Missing", for: requirement.id)
        await session.confirmProject(requirement.id)
        #expect(session.projectIntake?.projects.isEmpty == true)
        #expect(session.projectMappingErrors[requirement.id] != nil)
        #expect(session.preview?.canPrepare == false)
    }

    @Test func changedRootRequiresFreshConfirmationAndUnconfirmedRenameCannotStage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()
        let first = try #require(session.projectIntake?.requirements.first)
        session.setProjectName("Project A", for: first.id)
        await session.confirmProject(first.id)
        #expect(session.projectIsConfirmed(first.id))

        let rootB = fixture.root.appending(path: "project-b").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fixture.rewriteProjectRoot(rootB.path)
        await session.inspect()
        #expect(session.projectIntake?.projects.isEmpty == true)
        #expect(session.preview?.canPrepare == false)
        let second = try #require(session.projectIntake?.requirements.first)
        session.setProjectName("Project B", for: second.id)
        await session.confirmProject(second.id)
        #expect(session.preview?.canPrepare == true)
        session.setProjectName("Unconfirmed rename", for: second.id)
        #expect(!session.projectIsConfirmed(second.id))
        await session.stage()
        #expect(session.reviewSession == nil)
    }

    @Test func exportUnmigratedProjectFixtureWhenRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["WORKSPACE_MIGRATION_PROJECT_FIXTURE"] else { return }
        let fixture = try Fixture()
        let payload: [String: Any] = ["workspace": fixture.store.rootURL.path, "home": fixture.location.homeRoot.path,
                                      "projects": [["root": fixture.projectRoot.path, "serverIDs": ["project-mcp", "local-mcp"]]]]
        do {
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        } catch {
            fixture.remove()
            throw error
        }
    }

    private struct Fixture {
        let root: URL
        let store: WorkspaceStore
        let location: WorkspaceMigrationLegacyLocation
        let projectRoot: URL
        let snapshot: WorkspaceSnapshot

        init(invalidRoot: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "migration-project-\(UUID().uuidString)")
            store = try WorkspaceStore(rootURL: root.appending(path: "legacy"))
            let home = root.appending(path: "home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            location = .init(legacyRoot: store.rootURL, homeRoot: home)
            projectRoot = root.appending(path: "project").resolvingSymlinksInPath()
            if !invalidRoot {
                try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let rootPath = invalidRoot ? root.appending(path: "project/../other").path : projectRoot.path
            let client = ClientState(client: .codex, state: .healthy, detail: "Found", isInstalled: true)
            let first = MCPServer(id: "project-mcp", name: "Project MCP", summary: "Managed project MCP",
                endpoint: "https://project.example/v1", transport: .http, authentication: "None",
                scope: "Project", projectRoot: rootPath, clients: [client], definitionOrigin: .managed)
            let second = MCPServer(id: "local-mcp", name: "Local MCP", summary: "Managed local MCP",
                endpoint: "runner --project", transport: .stdio, authentication: "None",
                scope: "This project only", projectRoot: rootPath, clients: [client], definitionOrigin: .managed)
            let profile = ToolingProfile(id: "project-profile", name: "Project profile", summary: "Fixture",
                scope: .project, projectRoot: rootPath, checks: [], enabledPlugins: [],
                requiredMCPs: [first.id, second.id], requiredSkills: [])
            var preferences = WorkspacePreferences(enabledClients: [.codex])
            preferences.automaticallyCheckHealth = false
            snapshot = .init(mcpServers: [first, second], profiles: [profile],
                activeProfileID: profile.id, preferences: preferences)
            try store.saveWorkspaceSnapshot(snapshot)
        }

        func rewriteProjectRoot(_ path: String) throws {
            var updated = snapshot
            updated.mcpServers = updated.mcpServers.map { server in
                var copy = server
                copy.projectRoot = path
                return copy
            }
            updated.profiles = updated.profiles.map { profile in
                var copy = profile
                copy.projectRoot = path
                return copy
            }
            try store.saveWorkspaceSnapshot(updated)
        }

        func remove() {
            func unlock(_ url: URL) {
                var status = stat(); guard lstat(url.path, &status) == 0 else { return }
                _ = chmod(url.path, 0o700)
                guard status.st_mode & S_IFMT == S_IFDIR else { return }
                for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] { unlock(child) }
            }
            unlock(root)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

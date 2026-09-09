import Darwin
import Foundation
import Testing

@testable import AgentToolingCore
@testable import AgentToolingApp

@MainActor
struct WorkspaceManagedMCPMigrationSetupTests {
    @Test func inspectResolvesManagedStdioAndHTTPSWithoutPortablePromotion() async throws {
        let fixture = try Fixture(projectScope: false)
        var retainFixture = false
        defer { if !retainFixture { fixture.remove() } }
        let originalCheckpoint = try WorkspaceLegacyCheckpoint.captureSynchronously(databaseURL: fixture.store.databaseURL)

        let session = WorkspaceMigrationSetupSession(location: fixture.location)
        await session.inspect()

        let managed = try #require(session.managedConnections)
        #expect(managed.issues.isEmpty, "managed MCP issues: \(managed.issues)")
        #expect(session.intake?.issues.isEmpty == true)
        #expect(session.preview?.canPrepare == true, "\(session.preview?.issues ?? [])")
        #expect(managed.resolutions.count == 2)
        for resolution in managed.resolutions {
            #expect({ if case .deviceBound = resolution.definition.connection { return true }; return false }())
            #expect(resolution.project == nil)
            #expect(resolution.assignments.count == 2)
            #expect(resolution.assignments.allSatisfy { $0.destination.scope == .user && $0.destination.deviceIDs?.count == 1 })
        }
        let stdio = try #require(managed.resolutions.first { $0.legacyServerID == "managed-stdio" })
        #expect(stdio.deviceBinding?.destination == .stdio(executable: "runner", arguments: ["--label", "two words"]))
        #expect(stdio.deviceBinding?.authenticationRequirement == .environment)
        #expect(stdio.deviceBinding?.credentialRequirementNames == ["MCP_TOKEN"])
        #expect(stdio.definition.connection == .deviceBound(transport: .stdio))
        let https = try #require(managed.resolutions.first { $0.legacyServerID == "managed-http" })
        #expect(https.deviceBinding?.destination == .httpURL("https://mcp.example.com/v1"))
        #expect(https.deviceBinding?.authenticationRequirement == MCPAuthenticationRequirement.none)
        #expect(https.deviceBinding?.credentialRequirementNames.isEmpty == true)
        #expect(https.definition.connection == .deviceBound(transport: .http))

        let preparation = try #require(session.preview?.preparation)
        #expect(preparation.content.isEmpty)
        #expect(preparation.record.manifest.sourceCaptures.isEmpty)
        let definitions = try #require(preparation.record.document.mcpDefinitions)
        #expect(definitions.count == 2)
        #expect(definitions.allSatisfy { if case .deviceBound = $0.connection { return true }; return false })
        await session.stage()
        let review = try #require(session.reviewSession, "\(session.errorMessage ?? "missing staged review")")
        #expect(review.state?.journalEntry.phase == .prepared)
        #expect(review.state?.authoritySelection == nil)
        #expect(try WorkspaceLegacyCheckpoint.captureSynchronously(databaseURL: fixture.store.databaseURL).sha256 == originalCheckpoint.sha256)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.location.homeRoot.path).isEmpty)
        if ProcessInfo.processInfo.environment["WORKSPACE_MIGRATION_MANAGED_MCP_FIXTURE"] != nil {
            try exportIfRequested(fixture: fixture)
            retainFixture = true
        }
    }

    @Test func projectScopedManagedConnectionRemainsBlockedUntilMapping() async throws {
        let fixture = try Fixture(projectScope: true)
        defer { fixture.remove() }
        let session = WorkspaceMigrationSetupSession(location: fixture.location)

        await session.inspect()

        #expect(session.managedConnections?.issues.contains { $0.reason == .needsProjectMapping } == true)
        #expect(session.preview?.canPrepare == false)
        #expect(session.intake?.issues.isEmpty == false)
        await session.stage()
        #expect(session.reviewSession == nil)
    }

    private func exportIfRequested(fixture: Fixture) throws {
        guard let output = ProcessInfo.processInfo.environment["WORKSPACE_MIGRATION_MANAGED_MCP_FIXTURE"] else { return }
        let payload: [String: Any] = ["workspace": fixture.store.rootURL.path, "home": fixture.location.homeRoot.path]
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    }

    private struct Fixture {
        let root: URL
        let store: WorkspaceStore
        let location: WorkspaceMigrationLegacyLocation
        let snapshot: WorkspaceSnapshot

        init(projectScope: Bool) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "managed-mcp-setup-\(UUID().uuidString)")
            store = try WorkspaceStore(rootURL: root.appending(path: "legacy"))
            let home = root.appending(path: "home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            location = .init(legacyRoot: store.rootURL, homeRoot: home)
            let scope = projectScope ? "Project" : "This Mac"
            let rootPath = projectScope ? root.appending(path: "project").path : nil
            let clients: [ClientState] = [
                .init(client: .codex, state: .healthy, detail: "Found", isInstalled: true),
                .init(client: .claude, state: .healthy, detail: "Found", isInstalled: true)
            ]
            let stdio = MCPServer(id: "managed-stdio", name: "Runner", summary: "Managed runner",
                endpoint: "runner --label 'two words'", transport: .stdio, authentication: "Environment",
                scope: scope, projectRoot: rootPath, clients: clients, secretNames: ["MCP_TOKEN"], definitionOrigin: .managed)
            let https = MCPServer(id: "managed-http", name: "Remote", summary: "Managed remote",
                endpoint: "https://mcp.example.com/v1", transport: .http, authentication: "None",
                scope: scope, projectRoot: rootPath, clients: clients, definitionOrigin: .managed)
            let profile = ToolingProfile(id: "profile", name: "Profile", summary: "Managed MCP fixture",
                scope: projectScope ? .project : .user, projectRoot: rootPath, checks: [], enabledPlugins: [],
                requiredMCPs: [stdio.id, https.id], requiredSkills: [], targetBindings: [])
            var preferences = WorkspacePreferences(enabledClients: [.codex, .claude])
            preferences.automaticallyCheckHealth = false
            snapshot = WorkspaceSnapshot(mcpServers: [stdio, https], profiles: [profile],
                activeProfileID: profile.id, preferences: preferences)
            try store.saveWorkspaceSnapshot(snapshot)
        }

        func remove() {
            func unlock(_ url: URL) {
                var status = stat()
                guard lstat(url.path, &status) == 0 else { return }
                _ = chmod(url.path, 0o700)
                guard status.st_mode & S_IFMT == S_IFDIR else { return }
                for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                    unlock(child)
                }
            }
            unlock(root)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

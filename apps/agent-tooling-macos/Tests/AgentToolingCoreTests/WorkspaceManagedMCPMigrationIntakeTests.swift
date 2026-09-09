import Foundation
import Testing
@testable import AgentToolingCore

struct WorkspaceManagedMCPMigrationIntakeTests {
    @Test func preservesQuotedStdioCredentialsAuthAndClientAssignments() throws {
        var server = managed(
            id: "runner",
            endpoint: "mcp-runner --label 'two words'",
            transport: .stdio,
            scope: "This Mac",
            clients: [.claude, .gemini],
            secrets: ["API_TOKEN"]
        )
        server.authentication = "OAuth"

        let result = try review([server])
        let resolution = try #require(result.resolutions.first)
        let binding = try #require(resolution.deviceBinding)
        #expect(resolution.definition.connection == .deviceBound(transport: .stdio))
        #expect(binding.destination == .stdio(executable: "mcp-runner", arguments: ["--label", "two words"]))
        #expect(binding.credentialRequirementNames == ["API_TOKEN"])
        #expect(binding.authenticationRequirement == .oauth)
        #expect(resolution.assignments.map(\.destination.surface) == [.claudeCode, .geminiCLI])
        #expect(resolution.assignments.allSatisfy {
            $0.reason == .manual && $0.desiredPresence && $0.desiredEnabled == nil
                && $0.destination.deviceIDs == [context.deviceID]
        })
        #expect(result.intake.issues.isEmpty)
        #expect(result.issues.isEmpty)
    }

    @Test func allHTTPDestinationsRemainDeviceBoundIncludingPublicAndLocalHosts() throws {
        let publicServer = managed(id: "public", endpoint: "https://mcp.example.com/v1", transport: .http)
        let localServer = managed(id: "local", endpoint: "http://127.0.0.1:8123/mcp", transport: .http)

        let result = try review([localServer, publicServer])
        #expect(result.issues.isEmpty)
        #expect(result.resolutions.count == 2)
        for resolution in result.resolutions {
            #expect(resolution.definition.connection == .deviceBound(transport: .http))
            guard case .httpURL = resolution.deviceBinding?.destination else {
                Issue.record("Managed HTTP must retain its local destination binding.")
                continue
            }
        }
    }

    @Test func workspaceScopeRetainsExactRootAndCurrentDeviceAssignments() throws {
        var server = managed(
            id: "workspace",
            endpoint: "https://192.168.1.10/mcp",
            transport: .http,
            scope: "Workspace",
            clients: [.codex]
        )
        server.authentication = "Doppler"
        server.projectRoot = "/private/workspace"

        let result = try review([server])
        let resolution = try #require(result.resolutions.first)
        #expect(resolution.deviceBinding?.workspaceRootPath == "/private/workspace")
        #expect(resolution.deviceBinding?.authenticationRequirement == .doppler)
        #expect(resolution.assignments == [
            .init(
                id: resolution.assignments[0].id,
                artifactID: resolution.definition.artifactID,
                destination: .init(surface: .codexCLI, scope: .workspace, deviceIDs: [context.deviceID]),
                reason: .manual,
                desiredPresence: true,
                desiredEnabled: nil
            ),
        ])
    }

    @Test func repeatedAndShuffledReviewsProduceTheSameResolutionAndAssignmentIDs() throws {
        let first = managed(id: "one", endpoint: "one --flag", transport: .stdio, clients: [.claude])
        let second = managed(id: "two", endpoint: "https://example.com/mcp", transport: .http, clients: [.codex])

        let initial = try review([first, second])
        let shuffled = try review([second, first])
        #expect(initial.resolutions.map(\.legacyServerID) == shuffled.resolutions.map(\.legacyServerID))
        #expect(initial.resolutions.map(\.definition) == shuffled.resolutions.map(\.definition))
        #expect(initial.resolutions.flatMap(\.assignments).map(\.id) == shuffled.resolutions.flatMap(\.assignments).map(\.id))
    }

    @Test func malformedDefinitionsAndCredentialNamesRemainReviewIssues() throws {
        let unsafeURL = managed(id: "unsafe-url", endpoint: "https://example.com/mcp?token=value", transport: .http)
        let invalidCredential = managed(id: "credential", endpoint: "runner", transport: .stdio, secrets: ["not valid"])

        let result = try review([unsafeURL, invalidCredential])
        #expect(result.resolutions.isEmpty)
        #expect(Set(result.issues) == Set([
            .init(legacy: key("unsafe-url"), reason: .invalidDefinition),
            .init(legacy: key("credential"), reason: .invalidCredentials),
        ]))
        #expect(Set(result.intake.issues.map(\.legacy)) == [key("unsafe-url"), key("credential")])
    }

    @Test func invalidAuthenticationScopeAndDuplicateClientsAreTypedBlockers() throws {
        var badAuthentication = managed(id: "auth", endpoint: "runner", transport: .stdio)
        badAuthentication.authentication = "Future identity provider"
        let invalidScope = managed(id: "scope", endpoint: "runner", transport: .stdio, scope: "Everywhere")
        let duplicateClient = managed(id: "clients", endpoint: "runner", transport: .stdio, clients: [.claude, .claude])

        let result = try review([duplicateClient, invalidScope, badAuthentication])
        #expect(Set(result.issues) == Set([
            .init(legacy: key("auth"), reason: .invalidAuthentication),
            .init(legacy: key("scope"), reason: .invalidScope),
            .init(legacy: key("clients"), reason: .ambiguousClients),
        ]))
    }

    @Test func projectScopesRemainUnresolvedUntilLogicalProjectMappingIsExplicit() throws {
        let server = managed(id: "project", endpoint: "runner", transport: .stdio, scope: "Project")
        let result = try review([server])

        #expect(result.resolutions.isEmpty)
        #expect(result.issues == [.init(legacy: key("project"), reason: .needsProjectMapping)])
        #expect(result.intake.issues.map(\.legacy) == [key("project")])
    }

    @Test func duplicateServerIdentityAndBundledNativeChildrenAreNeverResolved() throws {
        let duplicate = managed(id: "same", endpoint: "runner", transport: .stdio)
        let duplicateResult = try review([duplicate, duplicate])
        #expect(duplicateResult.resolutions.isEmpty)
        #expect(duplicateResult.issues == [.init(legacy: key("same"), reason: .invalidIdentity)])

        let native = managed(id: "bundled", endpoint: "runner", transport: .stdio)
        let nativeKey = key("bundled")
        let intake = WorkspaceMigrationIntake(
            choices: [.init(legacy: .init(domain: .plugin, identifier: "plugin"), strategy: .nativePackage(
                routes: [.init(client: .codex, externalPluginID: "plugin")],
                children: [.init(legacy: nativeKey)]
            ))],
            issues: [.init(legacy: nativeKey, displayName: "Bundled", reason: .managedConnection)],
            snapshot: .init(mcpServers: [native])
        )
        let nativeResult = try WorkspaceManagedMCPMigrationIntake.review(intake: intake, context: context)
        #expect(nativeResult.resolutions.isEmpty)
        #expect(nativeResult.issues.isEmpty)
        #expect(nativeResult.intake.issues == intake.issues)
    }

    @Test func validResolutionsProceedWhileOnlyInvalidManagedRowsRemainBlocked() throws {
        let valid = managed(id: "valid", endpoint: "runner --name migration", transport: .stdio)
        let invalid = managed(id: "invalid", endpoint: "https://example.com/mcp?token=value", transport: .http)

        let result = try review([invalid, valid])

        #expect(result.resolutions.map(\.legacyServerID) == ["valid"])
        #expect(result.issues == [.init(legacy: key("invalid"), reason: .invalidDefinition)])
        #expect(result.intake.issues == [.init(
            legacy: key("invalid"), displayName: "Invalid", reason: .managedConnection
        )])
    }

    @Test func legacyManagedMarkerResolvesAndKeepsProfileAndCollectionMCPReferencesLive() async throws {
        var server = managed(id: "legacy-managed", endpoint: "runner --name legacy", transport: .stdio)
        server.summary = "Desired local MCP configuration"
        server.definitionOrigin = nil
        let profile = ToolingProfile(
            id: "profile", name: "Profile", summary: "Fixture", checks: [], enabledPlugins: [],
            requiredMCPs: [server.id], includedCollections: ["servers"]
        )
        let collection = ToolingCollection(
            id: "servers", name: "Servers", items: [.init(kind: .mcpServer, identifier: server.id)],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let snapshot = WorkspaceSnapshot(
            mcpServers: [server], profiles: [profile], activeProfileID: profile.id, collections: [collection]
        )
        let root = FileManager.default.temporaryDirectory.appending(
            path: "managed-mcp-intake-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try WorkspaceStore(rootURL: root)
        try legacy.saveWorkspaceSnapshot(snapshot)
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: legacy.databaseURL)
        let initial = try WorkspaceMigrationIntake.review(checkpoint: checkpoint, workspaceID: context.workspaceID)
        #expect(initial.issues == [.init(
            legacy: key(server.id), displayName: "Legacy-Managed", reason: .managedConnection
        )])

        let managed = try WorkspaceManagedMCPMigrationIntake.review(intake: initial, context: context)
        let resolution = try #require(managed.resolutions.first)
        let request = WorkspaceMigrationCandidatePreparationRequest(
            attemptID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000cab")!),
            checkpoint: checkpoint,
            legacyDatabaseURL: legacy.databaseURL,
            context: context,
            choices: managed.intake.choices,
            managedMCPResolutions: managed.resolutions
        )
        let preview = try await WorkspaceMigrationCandidatePreparationService().preview(request)
        let candidate = try #require(preview.preparation)
        #expect(preview.canPrepare)
        let state = try #require(candidate.record.document.configurationState)
        let expected = WorkspaceReference(legacy: key(server.id), resolution: .artifact(resolution.definition.artifactID))
        #expect(state.configurations.first?.requiredMCPs == [expected])
        #expect(state.collections.first?.items == [expected])
    }

    @Test func shuffledClientRowsProduceTheSameOrderedAssignmentsAndIDs() throws {
        let first = managed(id: "clients", endpoint: "runner", transport: .stdio, clients: [.gemini, .claude, .codex])
        let second = managed(id: "clients", endpoint: "runner", transport: .stdio, clients: [.codex, .gemini, .claude])

        let initial = try review([first])
        let shuffled = try review([second])
        #expect(initial.resolutions.flatMap(\.assignments) == shuffled.resolutions.flatMap(\.assignments))
        #expect(initial.resolutions.flatMap(\.assignments).map(\.destination.surface) == [.claudeCode, .codexCLI, .geminiCLI])
    }

    private let context = WorkspaceMigrationContext(
        workspaceID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000ace")!),
        deviceID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000bed")!),
        revision: .init(writerID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000bed")!))
    )

    private func review(_ servers: [MCPServer]) throws -> WorkspaceManagedMCPMigrationIntake {
        let intake = WorkspaceMigrationIntake(
            choices: [],
            issues: servers.map { .init(legacy: key($0.id), displayName: $0.name, reason: .managedConnection) },
            snapshot: .init(mcpServers: servers)
        )
        return try WorkspaceManagedMCPMigrationIntake.review(intake: intake, context: context)
    }

    private func managed(
        id: String,
        endpoint: String,
        transport: MCPTransport,
        scope: String = "This Mac",
        clients: [ClientKind] = [.claude],
        secrets: [String] = []
    ) -> MCPServer {
        .init(
            id: id,
            name: id.capitalized,
            summary: "Managed",
            endpoint: endpoint,
            transport: transport,
            authentication: "None",
            scope: scope,
            clients: clients.map { .init(client: $0, state: .healthy, detail: "Configured") },
            secretNames: secrets,
            definitionOrigin: .managed
        )
    }

    private func key(_ id: String) -> LegacyReferenceKey {
        .init(domain: .mcpServer, identifier: id)
    }
}

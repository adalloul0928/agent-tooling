import Foundation
import Testing
@testable import AgentToolingCore

struct WorkspaceManagedMCPMigrationTests {
    @Test func managedHTTPSRequiresTheExactPortableDefinitionAndNamedCredentials() throws {
        let artifactID = ArtifactID()
        let deviceID = WorkspaceObjectID()
        let server = managedServer(
            endpoint: "https://mcp.example.com/v1", transport: .http, clients: [.claude, .codex], secrets: ["MCP_TOKEN"])
        let resolution = WorkspaceManagedMCPMigrationResolution(
            legacyServerID: server.id,
            definition: .init(artifactID: artifactID, connection: .remoteHTTPS(url: server.endpoint)),
            deviceBinding: .init(artifactID: artifactID, credentialRequirementNames: ["MCP_TOKEN"]),
            assignments: assignments(artifactID: artifactID, deviceID: deviceID, scope: .user, clients: server.clients))

        try WorkspaceManagedMCPMigrationValidation.validate(
            resolution, server: server, artifactID: artifactID, deviceID: deviceID)
    }

    @Test func managedStdioPreservesQuotedArgumentVectorAndCredentials() throws {
        let artifactID = ArtifactID()
        let deviceID = WorkspaceObjectID()
        let server = managedServer(
            endpoint: "mcp-runner --label 'two words'", transport: .stdio, clients: [.gemini], secrets: ["API_TOKEN"])
        let resolution = WorkspaceManagedMCPMigrationResolution(
            legacyServerID: server.id,
            definition: .init(artifactID: artifactID, connection: .deviceBound(transport: .stdio)),
            deviceBinding: .init(
                artifactID: artifactID,
                destination: .stdio(executable: "mcp-runner", arguments: ["--label", "two words"]),
                credentialRequirementNames: ["API_TOKEN"]),
            assignments: assignments(artifactID: artifactID, deviceID: deviceID, scope: .user, clients: server.clients))

        try WorkspaceManagedMCPMigrationValidation.validate(
            resolution, server: server, artifactID: artifactID, deviceID: deviceID)
        #expect(resolution.deviceBinding?.destination == .stdio(
            executable: "mcp-runner", arguments: ["--label", "two words"]))
    }

    @Test func migrationRejectsIdentityEndpointCredentialAndInlineSecretMismatches() throws {
        let artifactID = ArtifactID()
        let deviceID = WorkspaceObjectID()
        let server = managedServer(
            endpoint: "https://mcp.example.com/v1", transport: .http, clients: [.claude], secrets: ["MCP_TOKEN"])
        let exact = WorkspaceManagedMCPMigrationResolution(
            legacyServerID: server.id,
            definition: .init(artifactID: artifactID, connection: .remoteHTTPS(url: server.endpoint)),
            deviceBinding: .init(artifactID: artifactID, credentialRequirementNames: ["MCP_TOKEN"]),
            assignments: assignments(artifactID: artifactID, deviceID: deviceID, scope: .user, clients: server.clients))
        func rejects(_ value: WorkspaceManagedMCPMigrationResolution, server: MCPServer) {
            #expect(throws: WorkspaceDomainValidationError.self) {
                try WorkspaceManagedMCPMigrationValidation.validate(value, server: server, artifactID: artifactID, deviceID: deviceID)
            }
        }

        var wrongID = exact
        wrongID.legacyServerID = "other"
        rejects(wrongID, server: server)
        var wrongEndpoint = exact
        wrongEndpoint.definition.connection = .remoteHTTPS(url: "https://other.example.com/v1")
        rejects(wrongEndpoint, server: server)
        var wrongCredentials = exact
        wrongCredentials.deviceBinding?.credentialRequirementNames = ["OTHER_TOKEN"]
        rejects(wrongCredentials, server: server)
        var wrongArtifact = exact
        wrongArtifact.definition.artifactID = ArtifactID()
        rejects(wrongArtifact, server: server)

        let unsafeServer = managedServer(endpoint: "runner --token secret", transport: .stdio, clients: [.claude])
        let unsafe = WorkspaceManagedMCPMigrationResolution(
            legacyServerID: unsafeServer.id,
            definition: .init(artifactID: artifactID, connection: .deviceBound(transport: .stdio)),
            deviceBinding: .init(artifactID: artifactID, destination: .stdio(executable: "runner", arguments: ["--token", "secret"])),
            assignments: assignments(artifactID: artifactID, deviceID: deviceID, scope: .user, clients: unsafeServer.clients))
        rejects(unsafe, server: unsafeServer)
    }

    @Test func migrationRequiresExactlyTheLegacyClientSurfacesAndDeviceOnlyDestinations() throws {
        let artifactID = ArtifactID()
        let deviceID = WorkspaceObjectID()
        let server = managedServer(endpoint: "https://mcp.example.com", transport: .http, clients: [.claude, .codex])
        let base = WorkspaceManagedMCPMigrationResolution(
            legacyServerID: server.id,
            definition: .init(artifactID: artifactID, connection: .remoteHTTPS(url: server.endpoint)),
            assignments: assignments(artifactID: artifactID, deviceID: deviceID, scope: .user, clients: server.clients))
        try WorkspaceManagedMCPMigrationValidation.validate(base, server: server, artifactID: artifactID, deviceID: deviceID)

        var missingClient = base
        missingClient.assignments.removeLast()
        #expect(throws: WorkspaceDomainValidationError.self) {
            try WorkspaceManagedMCPMigrationValidation.validate(missingClient, server: server, artifactID: artifactID, deviceID: deviceID)
        }
        var addedClient = base
        addedClient.assignments.append(assignment(
            artifactID: artifactID, deviceID: deviceID, scope: .user, surface: .geminiCLI))
        #expect(throws: WorkspaceDomainValidationError.self) {
            try WorkspaceManagedMCPMigrationValidation.validate(addedClient, server: server, artifactID: artifactID, deviceID: deviceID)
        }
        var globalDestination = base
        globalDestination.assignments[0].destination.deviceIDs = nil
        #expect(throws: WorkspaceDomainValidationError.self) {
            try WorkspaceManagedMCPMigrationValidation.validate(globalDestination, server: server, artifactID: artifactID, deviceID: deviceID)
        }
        var explicitEnablement = base
        explicitEnablement.assignments[0].desiredEnabled = true
        #expect(throws: WorkspaceDomainValidationError.self) {
            try WorkspaceManagedMCPMigrationValidation.validate(explicitEnablement, server: server, artifactID: artifactID, deviceID: deviceID)
        }
    }

    @Test func projectScopeRequiresTheExactSuppliedRootAndLogicalProject() throws {
        let artifactID = ArtifactID()
        let deviceID = WorkspaceObjectID()
        let projectID = ArtifactID()
        let server = managedServer(
            endpoint: "https://mcp.example.com", transport: .http, scope: "Project", clients: [.claude], projectRoot: "/work/project")
        let project = WorkspaceMCPMigrationProject(
            project: .init(id: projectID, name: "Project"), rootPath: "/work/project")
        let resolution = WorkspaceManagedMCPMigrationResolution(
            legacyServerID: server.id,
            definition: .init(artifactID: artifactID, connection: .remoteHTTPS(url: server.endpoint)),
            assignments: assignments(
                artifactID: artifactID, deviceID: deviceID, scope: .project, logicalProjectID: projectID, clients: server.clients),
            project: project)
        try WorkspaceManagedMCPMigrationValidation.validate(
            resolution, server: server, artifactID: artifactID, deviceID: deviceID)

        var missingProject = resolution
        missingProject.project = nil
        #expect(throws: WorkspaceDomainValidationError.self) {
            try WorkspaceManagedMCPMigrationValidation.validate(missingProject, server: server, artifactID: artifactID, deviceID: deviceID)
        }
        var wrongRoot = resolution
        wrongRoot.project = .init(project: project.project, rootPath: "/other/project")
        #expect(throws: WorkspaceDomainValidationError.self) {
            try WorkspaceManagedMCPMigrationValidation.validate(wrongRoot, server: server, artifactID: artifactID, deviceID: deviceID)
        }
        var wrongLogicalProject = resolution
        wrongLogicalProject.assignments[0].destination.logicalProjectID = ArtifactID()
        #expect(throws: WorkspaceDomainValidationError.self) {
            try WorkspaceManagedMCPMigrationValidation.validate(wrongLogicalProject, server: server, artifactID: artifactID, deviceID: deviceID)
        }

        let localServer = managedServer(
            endpoint: "https://mcp.example.com", transport: .http, scope: "This project only", clients: [.codex], projectRoot: "/work/project")
        let localResolution = WorkspaceManagedMCPMigrationResolution(
            legacyServerID: localServer.id,
            definition: .init(artifactID: artifactID, connection: .remoteHTTPS(url: localServer.endpoint)),
            assignments: assignments(
                artifactID: artifactID, deviceID: deviceID, scope: .localProject, logicalProjectID: projectID, clients: localServer.clients),
            project: project)
        try WorkspaceManagedMCPMigrationValidation.validate(
            localResolution, server: localServer, artifactID: artifactID, deviceID: deviceID)
    }

    @Test func observedLegacyDefinitionsCannotBePromotedByAnOtherwiseExactResolution() throws {
        let artifactID = ArtifactID()
        let deviceID = WorkspaceObjectID()
        let observed = MCPServer(
            id: "observed", name: "Observed", summary: "Observed", endpoint: "https://mcp.example.com", transport: .http,
            authentication: "None", scope: "This Mac", clients: [.init(client: .claude, state: .healthy, detail: "Found")],
            definitionOrigin: .observed)
        let resolution = WorkspaceManagedMCPMigrationResolution(
            legacyServerID: observed.id,
            definition: .init(artifactID: artifactID, connection: .remoteHTTPS(url: observed.endpoint)),
            assignments: assignments(artifactID: artifactID, deviceID: deviceID, scope: .user, clients: observed.clients))

        #expect(throws: WorkspaceDomainValidationError.self) {
            try WorkspaceManagedMCPMigrationValidation.validate(
                resolution, server: observed, artifactID: artifactID, deviceID: deviceID)
        }
    }

    @Test func integratedPreviewPreservesDefinitionTargetsAndCredentialRequirementsWithoutPackageCopies() throws {
        let workspaceID = WorkspaceObjectID()
        let deviceID = WorkspaceObjectID()
        let server = managedServer(endpoint: "runner --label 'two words'", transport: .stdio,
                                   clients: [.claude, .codex], secrets: ["api-token"])
        let snapshot = WorkspaceSnapshot(mcpServers: [server])
        let initial = try WorkspaceInventoryMigration.preview(snapshot: snapshot, workspaceID: workspaceID)
        var artifact = try #require(initial.artifacts.first)
        artifact.authority = .centralPersonal
        let resolution = WorkspaceManagedMCPMigrationResolution(
            legacyServerID: server.id, definition: .init(artifactID: artifact.identity.id, connection: .deviceBound(transport: .stdio)),
            deviceBinding: .init(artifactID: artifact.identity.id,
                                 destination: .stdio(executable: "runner", arguments: ["--label", "two words"]),
                                 credentialRequirementNames: ["api-token"]),
            assignments: assignments(artifactID: artifact.identity.id, deviceID: deviceID, scope: .user, clients: server.clients))
        let decision = WorkspaceInventoryMigrationResolution(legacy: .init(domain: .mcpServer, identifier: server.id), artifact: artifact)
        let preview = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, resolutions: [decision], preserving: initial.identityMap,
            deviceID: deviceID, managedMCPResolutions: [resolution])
        #expect(preview.canMigrateInventory)
        #expect(preview.artifacts.count == 1 && preview.artifacts[0].contentDigest == nil)
        #expect(preview.mcpDefinitions == [resolution.definition])
        #expect(preview.mcpBindings == [resolution.deviceBinding!])
        #expect(preview.managedMCPAssignments == resolution.assignments)
        #expect(preview.retainedLegacySnapshot.mcpServers == snapshot.mcpServers)
        let portable = try WorkspaceDocumentCoding.seal(.init(
            workspaceID: workspaceID, revision: .init(writerID: workspaceID), artifacts: preview.artifacts,
            assignments: preview.managedMCPAssignments, mcpDefinitions: preview.mcpDefinitions))
        let wire = String(decoding: try WorkspaceDocumentCoding.encode(portable), as: UTF8.self)
        #expect(!wire.contains("runner") && !wire.contains("api-token"))
        try DeviceWorkspaceState(workspaceID: workspaceID, deviceID: deviceID, mcpBindings: preview.mcpBindings)
            .validateStructure(against: portable)
        let targets = preview.managedMCPAssignments.map { assignment in
            ResolvedAssignmentTarget(selector: .init(destination: assignment.destination),
                physicalDestinationID: WorkspaceObjectID(), installedClientVersion: "test-1",
                adapterContractVersion: 1,
                componentContexts: [.init(component: .mcpServer, transport: MCPTransport.stdio.rawValue)])
        }
        let capabilities = targets.map { target in
            TargetCapabilityEvidence(surface: target.selector.surface, installedClientVersion: "test-1",
                adapterContractVersion: 1, component: .mcpServer, transport: MCPTransport.stdio.rawValue,
                scopes: [.user], support: .supported)
        }
        let assigned = WorkspaceAssignmentResolver.resolve(
            artifacts: preview.artifacts, contributions: preview.managedMCPAssignments, currentDeviceID: deviceID,
            targets: targets, capabilityEvidence: capabilities,
            portableMCPDefinitions: preview.mcpDefinitions, deviceMCPBindings: preview.mcpBindings)
        #expect(assigned.issues.isEmpty && assigned.requirements.count == 2)
        #expect(assigned.requirements.allSatisfy {
            if case .managedMCP = $0.strategy { true } else { false }
        })
        let missingDevice = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, resolutions: [decision], managedMCPResolutions: [resolution])
        #expect(!missingDevice.canMigrateInventory)
        #expect(throws: WorkspaceInventoryMigrationError.duplicateResolution) {
            try WorkspaceInventoryMigration.preview(snapshot: snapshot, workspaceID: workspaceID,
                deviceID: deviceID, managedMCPResolutions: [resolution, resolution])
        }
        #expect(throws: WorkspaceInventoryMigrationError.unknownResolution) {
            try WorkspaceInventoryMigration.preview(snapshot: .init(), workspaceID: workspaceID,
                deviceID: deviceID, managedMCPResolutions: [resolution])
        }
    }

    @Test func integratedProjectMappingsReuseOneIdentityAndRejectConflictingRoots() throws {
        let workspaceID = WorkspaceObjectID(), deviceID = WorkspaceObjectID()
        let first = managedServer(endpoint: "https://mcp.example.com", transport: .http, scope: "Project",
                                  clients: [.claude], projectRoot: "/work/project")
        let second = managedServer(id: "second", endpoint: first.endpoint, transport: .http, scope: "Project",
                                   clients: [.claude], projectRoot: "/work/project")
        let snapshot = WorkspaceSnapshot(mcpServers: [first, second])
        let initial = try WorkspaceInventoryMigration.preview(snapshot: snapshot, workspaceID: workspaceID)
        let project = WorkspaceMCPMigrationProject(project: .init(id: ArtifactID(), name: "Project"), rootPath: "/work/project")
        let decisions = initial.artifacts.map { original in
            var artifact = original; artifact.authority = .centralPersonal
            return WorkspaceInventoryMigrationResolution(
                legacy: .init(domain: .mcpServer, identifier: original.identity.aliases[0].value), artifact: artifact)
        }
        let resolutions = decisions.map { decision in
            WorkspaceManagedMCPMigrationResolution(
                legacyServerID: decision.legacy.identifier,
                definition: .init(artifactID: decision.artifact.identity.id, connection: .remoteHTTPS(url: first.endpoint)),
                assignments: assignments(artifactID: decision.artifact.identity.id, deviceID: deviceID, scope: .project,
                                         logicalProjectID: project.project.id, clients: first.clients), project: project)
        }
        let preview = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, resolutions: decisions,
            deviceID: deviceID, managedMCPResolutions: resolutions)
        #expect(preview.canMigrateInventory)
        #expect(preview.mcpProjectMappings.count == 1)
        #expect(preview.artifacts.filter { $0.identity.kind == .logicalProject }.map(\.identity.id) == [project.project.id])
        #expect(preview.managedMCPAssignments.count == 2)
        var retry = resolutions
        let replacedID = ArtifactID()
        for index in retry.indices {
            retry[index].project?.project.id = replacedID
            retry[index].assignments[0].destination.logicalProjectID = replacedID
        }
        let changedIdentity = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, resolutions: decisions,
            deviceID: deviceID, managedMCPResolutions: retry, preservingMCPProjectMappings: preview.mcpProjectMappings)
        #expect(!changedIdentity.canMigrateInventory)
        let stable = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, resolutions: decisions,
            deviceID: deviceID, managedMCPResolutions: resolutions, preservingMCPProjectMappings: preview.mcpProjectMappings)
        #expect(stable.canMigrateInventory && stable.logicalProjects == preview.logicalProjects)
        var conflicting = resolutions
        conflicting[1].project?.project.id = ArtifactID()
        conflicting[1].assignments[0].destination.logicalProjectID = conflicting[1].project?.project.id
        let rejected = try WorkspaceInventoryMigration.preview(
            snapshot: snapshot, workspaceID: workspaceID, resolutions: decisions,
            deviceID: deviceID, managedMCPResolutions: conflicting)
        #expect(!rejected.canMigrateInventory)
        #expect(rejected.issues.contains { $0.kind == .invalidResolution })
    }

    @Test func workspaceRootsAndAuthenticationRemainDeviceLocalAndExplicit() throws {
        let artifactID = ArtifactID(), deviceID = WorkspaceObjectID()
        var server = managedServer(endpoint: "https://192.168.1.10/mcp", transport: .http, scope: "Workspace",
                                   clients: [.codex], projectRoot: "/work/workspace")
        server.authentication = "OAuth"
        let resolution = WorkspaceManagedMCPMigrationResolution(
            legacyServerID: server.id, definition: .init(artifactID: artifactID, connection: .deviceBound(transport: .http)),
            deviceBinding: .init(artifactID: artifactID, destination: .httpURL(server.endpoint),
                                 authenticationRequirement: .oauth, workspaceRootPath: server.projectRoot),
            assignments: assignments(artifactID: artifactID, deviceID: deviceID, scope: .workspace, clients: server.clients))
        try WorkspaceManagedMCPMigrationValidation.validate(resolution, server: server, artifactID: artifactID, deviceID: deviceID)
        var missingRoot = resolution
        missingRoot.deviceBinding?.workspaceRootPath = nil
        #expect(throws: WorkspaceDomainValidationError.self) {
            try WorkspaceManagedMCPMigrationValidation.validate(missingRoot, server: server, artifactID: artifactID, deviceID: deviceID)
        }
        var missingAuth = resolution
        missingAuth.deviceBinding?.authenticationRequirement = .none
        #expect(throws: WorkspaceDomainValidationError.self) {
            try WorkspaceManagedMCPMigrationValidation.validate(missingAuth, server: server, artifactID: artifactID, deviceID: deviceID)
        }
        server.authentication = "Unknown future mechanism"
        #expect(throws: WorkspaceDomainValidationError.self) {
            try WorkspaceManagedMCPMigrationValidation.validate(resolution, server: server, artifactID: artifactID, deviceID: deviceID)
        }
        server.authentication = "OAuth"; server.scope = "Account"; server.projectRoot = nil
        #expect(throws: WorkspaceDomainValidationError.self) {
            try WorkspaceManagedMCPMigrationValidation.validate(resolution, server: server, artifactID: artifactID, deviceID: deviceID)
        }
    }

    private func managedServer(
        id: String = "managed",
        endpoint: String,
        transport: MCPTransport,
        scope: String = "This Mac",
        clients: [ClientKind],
        secrets: [String] = [],
        projectRoot: String? = nil
    ) -> MCPServer {
        MCPServer(
            id: id, name: "Managed", summary: "Managed", endpoint: endpoint, transport: transport,
            authentication: "None", scope: scope, projectRoot: projectRoot,
            clients: clients.map { .init(client: $0, state: .healthy, detail: "Configured") },
            secretNames: secrets, definitionOrigin: .managed)
    }

    private func assignments(
        artifactID: ArtifactID,
        deviceID: WorkspaceObjectID,
        scope: ToolingScope,
        logicalProjectID: ArtifactID? = nil,
        clients: [ClientState]
    ) -> [AssignmentContribution] {
        clients.map { client in
            assignment(artifactID: artifactID, deviceID: deviceID, scope: scope,
                       logicalProjectID: logicalProjectID, surface: surface(for: client.client))
        }
    }

    private func assignment(
        artifactID: ArtifactID,
        deviceID: WorkspaceObjectID,
        scope: ToolingScope,
        logicalProjectID: ArtifactID? = nil,
        surface: TargetSurface
    ) -> AssignmentContribution {
        .init(
            artifactID: artifactID,
            destination: .init(surface: surface, scope: scope, logicalProjectID: logicalProjectID, deviceIDs: [deviceID]),
            reason: .manual,
            desiredPresence: true,
            desiredEnabled: nil)
    }

    private func surface(for client: ClientKind) -> TargetSurface {
        switch client {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .gemini: .geminiCLI
        }
    }
}

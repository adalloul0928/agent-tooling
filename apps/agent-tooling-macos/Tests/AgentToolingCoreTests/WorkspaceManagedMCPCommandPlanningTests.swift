import Foundation
import Testing

@testable import AgentToolingCore

struct WorkspaceManagedMCPCommandPlanningTests {
    @Test(arguments: [TargetSurface.claudeCode, .codexCLI, .geminiCLI])
    func userHTTPCommandsExactlyMatchTheNativeCommandContract(_ surface: TargetSurface) throws {
        let fixture = try Fixture(surface: surface)
        let plan = try fixture.plan()
        let client = try #require(surface.client)
        let destination = try MCPDefinitionValidator.validate(fixture.endpoint, transport: .http)

        #expect(plan.arguments == MCPClientCommand.addArguments(
            serverID: fixture.serverID,
            transport: .http,
            destination: destination,
            client: client,
            scope: .user))
        #expect(plan.executable == MCPClientCommand.executable(for: client))
        #expect(plan.executableURL == fixture.executableURL)
        #expect(plan.workingDirectoryPath == nil)
    }

    @Test func stdioPreservesTheReviewedArgumentVectorWithoutShellReparsing() throws {
        let binding = DeviceMCPDefinitionBinding(
            artifactID: Fixture.artifactID,
            destination: .stdio(
                executable: "mcp-runner",
                arguments: ["--label", "two words", "--empty", ""]))
        let fixture = try Fixture(
            surface: .claudeCode,
            connection: .deviceBound(transport: .stdio),
            binding: binding)

        let plan = try fixture.plan()

        #expect(plan.arguments == [
            "mcp", "add", "--transport", "stdio", "--scope", "user",
            fixture.serverID, "--", "mcp-runner", "--label", "two words", "--empty", "",
        ])
    }

    @Test func projectAndLocalProjectUseOnlyTheCurrentDeviceLogicalProjectRoot() throws {
        let project = try Fixture(surface: .claudeCode, scope: .project, projectRoot: "/work/project")
        let projectPlan = try project.plan()
        #expect(projectPlan.workingDirectoryPath == "/work/project")
        #expect(projectPlan.arguments.contains("project"))

        let local = try Fixture(surface: .geminiCLI, scope: .localProject, projectRoot: "/work/local")
        let localPlan = try local.plan()
        #expect(localPlan.workingDirectoryPath == "/work/local")
        #expect(localPlan.arguments == [
            "mcp", "add", "--scope", "project", "--transport", "http",
            local.serverID, local.endpoint,
        ])
    }

    @Test func workspaceUsesOnlyTheTypedDeviceBindingRoot() throws {
        let binding = DeviceMCPDefinitionBinding(
            artifactID: Fixture.artifactID,
            workspaceRootPath: "/work/workspace")
        let fixture = try Fixture(surface: .claudeCode, scope: .workspace, binding: binding)

        #expect(try fixture.plan().workingDirectoryPath == "/work/workspace")

        var missing = try Fixture(surface: .claudeCode, scope: .workspace, binding: binding)
        missing.device.mcpBindings = []
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidRequirement) {
            _ = try missing.plan()
        }
    }

    @Test func missingAndAmbiguousProjectMappingsCannotProduceACommand() throws {
        let missing = try Fixture(surface: .claudeCode, scope: .project, projectRoot: nil)
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.missingProjectRoot(Fixture.projectID)) {
            _ = try missing.plan()
        }

        var ambiguous = try Fixture(surface: .claudeCode, scope: .project, projectRoot: "/work/project")
        ambiguous.device.projectRoots?.append(.init(projectID: Fixture.projectID, rootPath: "/work/other"))
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidWorkspace) {
            _ = try ambiguous.plan()
        }
    }

    @Test func codexNonUserAndNonCLISurfacesAreRejected() throws {
        let codex = try Fixture(surface: .codexCLI, scope: .project, projectRoot: "/work/project")
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.unsupportedScope(.project, .codex)) {
            _ = try codex.plan()
        }

        let desktop = try Fixture(surface: .claudeDesktop)
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.unsupportedSurface(.claudeDesktop)) {
            _ = try desktop.plan()
        }
    }

    @Test func exactCapturedCapabilityIsRequiredAndUnknownSupportNeverBecomesAPlan() throws {
        var missing = try Fixture(surface: .claudeCode)
        missing.device.capabilityEvidence = []
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidCapability) {
            _ = try missing.plan()
        }

        var unknown = try Fixture(surface: .claudeCode)
        unknown.capability.support = .unknown(reason: "adapter has not probed this contract")
        unknown.device.capabilityEvidence = [unknown.capability]
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.unsupportedCapability) {
            _ = try unknown.plan()
        }

        var wrongVersion = try Fixture(surface: .claudeCode)
        wrongVersion.capability.installedClientVersion = "different"
        wrongVersion.device.capabilityEvidence = [wrongVersion.capability]
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidCapability) {
            _ = try wrongVersion.plan()
        }
    }

    @Test func reviewedIdentifierAndCLIPathCannotBeInferredOrSubstituted() throws {
        let fixture = try Fixture(surface: .claudeCode)
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidNativeServerIdentifier) {
            _ = try fixture.plan(serverID: "--global")
        }
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidCLIURL) {
            _ = try fixture.plan(executableURL: URL(fileURLWithPath: "/usr/local/bin/codex"))
        }
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidCLIURL) {
            _ = try fixture.plan(executableURL: URL(string: "https://example.com/claude")!)
        }
    }

    @Test func typedDefinitionBindingAndRequirementMustMatchTheValidatedWorkspace() throws {
        var fixture = try Fixture(surface: .claudeCode)
        fixture.requirement.transport = MCPTransport.stdio.rawValue
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidRequirement) {
            _ = try fixture.plan()
        }

        let validBinding = DeviceMCPDefinitionBinding(
            artifactID: Fixture.artifactID,
            destination: .stdio(executable: "runner", arguments: []))
        var unsafe = try Fixture(
            surface: .claudeCode,
            connection: .deviceBound(transport: .stdio),
            binding: validBinding)
        let unsafeBinding = DeviceMCPDefinitionBinding(
            artifactID: Fixture.artifactID,
            destination: .stdio(executable: "runner", arguments: ["--token", "secret"]))
        unsafe.device.mcpBindings = [unsafeBinding]
        if case .managedMCP(let definition, _) = unsafe.requirement.strategy {
            unsafe.requirement.strategy = .managedMCP(definition: definition, deviceBinding: unsafeBinding)
        }
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidWorkspace) {
            _ = try unsafe.plan()
        }
    }

    @Test func omittedOpposingContributionCannotHideFullAssignmentConflict() throws {
        var fixture = try Fixture(surface: .claudeCode)
        fixture.document.assignments[0].desiredEnabled = true
        var opposing = fixture.requirement.contributions[0]
        opposing.id = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000109")!)
        opposing.destination.surface = .codexCLI
        opposing.desiredEnabled = false
        fixture.document.assignments.append(opposing)
        fixture.document = try WorkspaceDocumentCoding.seal(fixture.document)

        #expect(throws: WorkspaceManagedMCPCommandPlanningError.unsupportedEnablement) {
            _ = try fixture.plan()
        }
    }

    @Test func omittedTargetForAnotherApplicableAssignmentBlocksTheSelectedRequirement() throws {
        var fixture = try Fixture(surface: .claudeCode)
        var omitted = fixture.requirement.contributions[0]
        omitted.id = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000110")!)
        omitted.destination.surface = .codexCLI
        fixture.document.assignments.append(omitted)
        fixture.document = try WorkspaceDocumentCoding.seal(fixture.document)

        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidRequirement) {
            _ = try fixture.plan()
        }
    }

    @Test func selectedTargetMustAppearExactlyOnceInTheCompleteCapture() throws {
        var missing = try Fixture(surface: .claudeCode)
        missing.resolvedTargets = []
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidRequirement) {
            _ = try missing.plan()
        }

        var duplicate = try Fixture(surface: .claudeCode)
        duplicate.resolvedTargets.append(duplicate.target)
        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidRequirement) {
            _ = try duplicate.plan()
        }
    }

    @Test func anotherDevicesExplicitDisablementDoesNotBlockCurrentDevicePresence() throws {
        var fixture = try Fixture(surface: .claudeCode)
        var remote = fixture.requirement.contributions[0]
        remote.id = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000111")!)
        remote.destination.deviceIDs = [WorkspaceObjectID(
            UUID(uuidString: "00000000-0000-0000-0000-000000000112")!)]
        remote.desiredEnabled = false
        fixture.document.assignments.append(remote)
        fixture.document = try WorkspaceDocumentCoding.seal(fixture.document)

        #expect(throws: Never.self) { _ = try fixture.plan() }
    }

    @Test func aliasedPhysicalTargetWithoutAContributingSelectorCannotBeChosen() throws {
        var fixture = try Fixture(surface: .claudeCode)
        let unrelated = ResolvedAssignmentTarget(
            selector: .init(surface: .codexCLI, scope: .user),
            physicalDestinationID: fixture.target.physicalDestinationID,
            installedClientVersion: "1.0.0",
            adapterContractVersion: 1,
            componentContexts: [.init(component: .mcpServer, transport: MCPTransport.http.rawValue)])
        fixture.target = unrelated
        fixture.resolvedTargets.append(unrelated)

        #expect(throws: WorkspaceManagedMCPCommandPlanningError.invalidRequirement) {
            _ = try fixture.plan()
        }
    }

    @Test(arguments: [true, false])
    func explicitEnablementIsNotExpressedByTheConfigureCommand(_ enabled: Bool) throws {
        var fixture = try Fixture(surface: .claudeCode)
        fixture.document.assignments[0].desiredEnabled = enabled
        fixture.document = try WorkspaceDocumentCoding.seal(fixture.document)
        fixture.requirement.contributions[0].desiredEnabled = enabled
        fixture.requirement.desiredEnabled = enabled

        #expect(throws: WorkspaceManagedMCPCommandPlanningError.unsupportedEnablement) {
            _ = try fixture.plan()
        }
    }

    private struct Fixture {
        static let artifactID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
        static let projectID = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-000000000102")!)
        static let deviceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000103")!)
        static let physicalID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000104")!)

        let serverID = "reviewed-server"
        let endpoint = "https://mcp.example.com/v1"
        var document: PortableWorkspaceDocument
        var device: DeviceWorkspaceState
        var requirement: EffectiveAssignmentRequirement
        var target: ResolvedAssignmentTarget
        var resolvedTargets: [ResolvedAssignmentTarget]
        var capability: TargetCapabilityEvidence
        var executableURL: URL

        init(
            surface: TargetSurface,
            scope: ToolingScope = .user,
            projectRoot: String? = nil,
            connection: PortableMCPConnection = .remoteHTTPS(url: "https://mcp.example.com/v1"),
            binding: DeviceMCPDefinitionBinding? = nil
        ) throws {
            let logicalProjectID: ArtifactID? = scope == .project || scope == .localProject ? Self.projectID : nil
            let destination = PortableDestination(
                surface: surface,
                scope: scope,
                logicalProjectID: logicalProjectID,
                deviceIDs: [Self.deviceID])
            let contribution = AssignmentContribution(
                id: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000105")!),
                artifactID: Self.artifactID,
                destination: destination,
                reason: .manual,
                desiredPresence: true,
                desiredEnabled: nil)
            let definition = PortableMCPDefinitionRecord(
                artifactID: Self.artifactID,
                connection: connection)
            var artifacts = [ArtifactRecord(
                identity: .init(id: Self.artifactID, kind: .mcpServer, displayName: "Managed server"),
                authority: .centralPersonal,
                declaredName: serverID)]
            var projects: [LogicalProjectRecord] = []
            if logicalProjectID != nil {
                artifacts.append(ArtifactRecord(
                    identity: .init(id: Self.projectID, kind: .logicalProject, displayName: "Project"),
                    authority: .trackedOnly))
                projects = [.init(id: Self.projectID, name: "Project")]
            }
            let resolvedDocument = try WorkspaceDocumentCoding.seal(PortableWorkspaceDocument(
                workspaceID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000106")!),
                revision: .init(
                    id: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000107")!),
                    writerID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000108")!),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
                artifacts: artifacts,
                logicalProjects: projects,
                assignments: [contribution],
                mcpDefinitions: [definition]))
            let resolvedCapability = TargetCapabilityEvidence(
                surface: surface,
                installedClientVersion: "1.0.0",
                adapterContractVersion: 1,
                component: .mcpServer,
                transport: connection.transport.rawValue,
                scopes: [scope],
                support: .supported,
                observedAt: Date(timeIntervalSince1970: 1_700_000_000))
            let resolvedDevice = DeviceWorkspaceState(
                workspaceID: resolvedDocument.workspaceID,
                deviceID: Self.deviceID,
                capabilityEvidence: [resolvedCapability],
                mcpBindings: binding.map { [$0] } ?? [],
                projectRoots: projectRoot.map { [.init(projectID: Self.projectID, rootPath: $0)] } ?? [])
            let resolvedTarget = ResolvedAssignmentTarget(
                selector: .init(destination: destination),
                physicalDestinationID: Self.physicalID,
                installedClientVersion: "1.0.0",
                adapterContractVersion: 1,
                componentContexts: [.init(component: .mcpServer, transport: connection.transport.rawValue)])
            let resolved = WorkspaceAssignmentResolver.resolve(
                artifacts: resolvedDocument.artifacts,
                contributions: resolvedDocument.assignments,
                currentDeviceID: resolvedDevice.deviceID,
                targets: [resolvedTarget],
                capabilityEvidence: resolvedDevice.capabilityEvidence,
                portableMCPDefinitions: resolvedDocument.mcpDefinitions ?? [],
                deviceMCPBindings: resolvedDevice.mcpBindings ?? [])
            guard resolved.issues.isEmpty, let resolvedRequirement = resolved.requirements.first else {
                throw FixtureError.couldNotResolve
            }
            document = resolvedDocument
            device = resolvedDevice
            requirement = resolvedRequirement
            target = resolvedTarget
            resolvedTargets = [resolvedTarget]
            capability = resolvedCapability
            executableURL = URL(fileURLWithPath: "/usr/local/bin/\(MCPClientCommand.executable(for: surface.client!))")
            try device.validateStructure(against: document)
        }

        func plan(
            serverID: String? = nil,
            executableURL: URL? = nil
        ) throws -> WorkspaceManagedMCPCommandPlan {
            try WorkspaceManagedMCPCommandPlanning.plan(
                document: document,
                device: device,
                requirement: requirement,
                resolvedTargets: resolvedTargets,
                target: target,
                capability: capability,
                nativeServerIdentifier: serverID ?? self.serverID,
                executableURL: executableURL ?? self.executableURL)
        }

        private enum FixtureError: Error { case couldNotResolve }
    }
}

import Foundation

public enum WorkspaceManagedMCPCommandPlanningError: Error, Equatable, Sendable {
    case invalidWorkspace
    case invalidRequirement
    case unsupportedEnablement
    case unsupportedSurface(TargetSurface)
    case invalidCapability
    case unsupportedCapability
    case invalidNativeServerIdentifier
    case invalidCLIURL
    case unsupportedScope(ToolingScope, ClientKind)
    case missingProjectRoot(ArtifactID)
    case ambiguousProjectRoot(ArtifactID)
    case missingWorkspaceRoot
    case invalidDestination
}

/// One reviewed native CLI invocation derived from an already resolved A1
/// requirement. This value performs no process execution and makes no claim
/// about authentication, remote health, or successful configuration.
public struct WorkspaceManagedMCPCommandPlan: Equatable, Sendable {
    public let artifactID: ArtifactID
    public let physicalDestinationID: WorkspaceObjectID
    public let surface: TargetSurface
    public let scope: ToolingScope
    public let nativeServerIdentifier: String
    public let executableURL: URL
    public let executable: String
    public let arguments: [String]
    public let workingDirectoryPath: String?

    public init(
        artifactID: ArtifactID,
        physicalDestinationID: WorkspaceObjectID,
        surface: TargetSurface,
        scope: ToolingScope,
        nativeServerIdentifier: String,
        executableURL: URL,
        executable: String,
        arguments: [String],
        workingDirectoryPath: String?
    ) {
        self.artifactID = artifactID
        self.physicalDestinationID = physicalDestinationID
        self.surface = surface
        self.scope = scope
        self.nativeServerIdentifier = nativeServerIdentifier
        self.executableURL = executableURL
        self.executable = executable
        self.arguments = arguments
        self.workingDirectoryPath = workingDirectoryPath
    }
}

public enum WorkspaceManagedMCPCommandPlanning {
    public static func plan(
        document: PortableWorkspaceDocument,
        device: DeviceWorkspaceState,
        requirement: EffectiveAssignmentRequirement,
        resolvedTargets: [ResolvedAssignmentTarget],
        target: ResolvedAssignmentTarget,
        capability: TargetCapabilityEvidence,
        nativeServerIdentifier: String,
        executableURL: URL
    ) throws -> WorkspaceManagedMCPCommandPlan {
        do {
            try document.validateStructure()
            try device.validateStructure(against: document)
        } catch {
            throw WorkspaceManagedMCPCommandPlanningError.invalidWorkspace
        }

        guard requirement.component == .mcpServer,
              requirement.physicalDestinationID == target.physicalDestinationID,
              resolvedTargets.filter({ $0 == target }).count == 1,
              requirement.contributions.contains(where: {
                  ResolvedAssignmentSelector(destination: $0.destination) == target.selector
              }) else {
            throw WorkspaceManagedMCPCommandPlanningError.invalidRequirement
        }
        let artifactContributions = document.assignments.filter {
            $0.artifactID == requirement.artifactID
        }
        let applicableContributions = artifactContributions.filter {
            $0.destination.deviceIDs?.contains(device.deviceID) ?? true
        }
        guard requirement.desiredEnabled == nil,
              applicableContributions.allSatisfy({ $0.desiredEnabled == nil }) else {
            throw WorkspaceManagedMCPCommandPlanningError.unsupportedEnablement
        }
        let assignmentResolution = WorkspaceAssignmentResolver.resolve(
            artifacts: document.artifacts,
            contributions: artifactContributions,
            currentDeviceID: device.deviceID,
            targets: resolvedTargets,
            capabilityEvidence: device.capabilityEvidence,
            portableMCPDefinitions: document.mcpDefinitions ?? [],
            deviceMCPBindings: device.mcpBindings ?? [])
        if assignmentResolution.issues.contains(where: {
            $0.kind == .unsupportedCapability || $0.kind == .unknownCapability
        }) {
            throw WorkspaceManagedMCPCommandPlanningError.unsupportedCapability
        }
        if assignmentResolution.issues.contains(where: {
            $0.kind == .missingCapabilityEvidence
                || $0.kind == .contradictoryCapabilityEvidence
                || $0.kind == .invalidResolvedTarget
        }) {
            throw WorkspaceManagedMCPCommandPlanningError.invalidCapability
        }
        guard assignmentResolution.issues.isEmpty,
              assignmentResolution.requirements.filter({ $0 == requirement }).count == 1 else {
            throw WorkspaceManagedMCPCommandPlanningError.invalidRequirement
        }

        let client: ClientKind
        switch target.selector.surface {
        case .claudeCode: client = .claude
        case .codexCLI: client = .codex
        case .geminiCLI: client = .gemini
        default: throw WorkspaceManagedMCPCommandPlanningError.unsupportedSurface(target.selector.surface)
        }
        let expectedExecutable = MCPClientCommand.executable(for: client)
        guard NativeSkillDestination.isValidRoot(executableURL),
              executableURL.lastPathComponent == expectedExecutable else {
            throw WorkspaceManagedMCPCommandPlanningError.invalidCLIURL
        }
        guard OperationCommandPolicy.isSafeMCPIdentifier(nativeServerIdentifier) else {
            throw WorkspaceManagedMCPCommandPlanningError.invalidNativeServerIdentifier
        }
        guard MCPClientCommand.supportsScope(target.selector.scope, client: client) else {
            throw WorkspaceManagedMCPCommandPlanningError.unsupportedScope(target.selector.scope, client)
        }

        guard case .managedMCP(let definition, let strategyBinding) = requirement.strategy,
              definition.artifactID == requirement.artifactID,
              requirement.transport == definition.connection.transport.rawValue,
              document.mcpDefinitions?.filter({ $0.artifactID == requirement.artifactID }) == [definition]
        else {
            throw WorkspaceManagedMCPCommandPlanningError.invalidRequirement
        }
        let deviceBindings = device.mcpBindings?.filter { $0.artifactID == requirement.artifactID } ?? []
        guard deviceBindings.count <= 1,
              (deviceBindings.first == strategyBinding || (deviceBindings.isEmpty && strategyBinding == nil)) else {
            throw WorkspaceManagedMCPCommandPlanningError.invalidRequirement
        }

        let transport = definition.connection.transport
        guard target.installedClientVersion?.isEmpty == false,
              target.adapterContractVersion > 0,
              target.componentContexts.filter({
                  $0.component == .mcpServer && $0.transport == transport.rawValue
              }).count == 1 else {
            throw WorkspaceManagedMCPCommandPlanningError.invalidCapability
        }
        let matchingCapabilities = device.capabilityEvidence.filter {
            $0.surface == target.selector.surface
                && $0.installedClientVersion == target.installedClientVersion
                && $0.adapterContractVersion == target.adapterContractVersion
                && $0.component == .mcpServer
                && $0.transport == transport.rawValue
                && $0.scopes.contains(target.selector.scope)
        }
        guard matchingCapabilities.count == 1, matchingCapabilities.first == capability else {
            throw WorkspaceManagedMCPCommandPlanningError.invalidCapability
        }
        guard case .supported = capability.support else {
            throw WorkspaceManagedMCPCommandPlanningError.unsupportedCapability
        }

        let workingDirectory = try workingDirectory(
            selector: target.selector,
            binding: strategyBinding,
            device: device,
            client: client)
        let destination: ValidatedMCPDestination
        do {
            switch definition.connection {
            case .remoteHTTPS(let url):
                destination = try MCPDefinitionValidator.validate(url, transport: .http)
            case .deviceBound(let expectedTransport):
                guard let bindingDestination = strategyBinding?.destination,
                      bindingDestination.transport == expectedTransport else {
                    throw WorkspaceManagedMCPCommandPlanningError.invalidDestination
                }
                switch bindingDestination {
                case .httpURL(let url):
                    destination = try MCPDefinitionValidator.validate(url, transport: .http)
                case .stdio(let executable, let arguments):
                    let command = [executable] + arguments
                    try MCPDefinitionValidator.validateCommandArguments(command)
                    destination = .init(endpoint: "", command: command)
                }
            }
        } catch let error as WorkspaceManagedMCPCommandPlanningError {
            throw error
        } catch {
            throw WorkspaceManagedMCPCommandPlanningError.invalidDestination
        }

        return .init(
            artifactID: requirement.artifactID,
            physicalDestinationID: requirement.physicalDestinationID,
            surface: target.selector.surface,
            scope: target.selector.scope,
            nativeServerIdentifier: nativeServerIdentifier,
            executableURL: executableURL,
            executable: expectedExecutable,
            arguments: MCPClientCommand.addArguments(
                serverID: nativeServerIdentifier,
                transport: transport,
                destination: destination,
                client: client,
                scope: target.selector.scope),
            workingDirectoryPath: workingDirectory)
    }

    private static func workingDirectory(
        selector: ResolvedAssignmentSelector,
        binding: DeviceMCPDefinitionBinding?,
        device: DeviceWorkspaceState,
        client: ClientKind
    ) throws -> String? {
        switch selector.scope {
        case .user:
            guard selector.logicalProjectID == nil else {
                throw WorkspaceManagedMCPCommandPlanningError.invalidRequirement
            }
            return nil
        case .project, .localProject:
            guard let projectID = selector.logicalProjectID else {
                throw WorkspaceManagedMCPCommandPlanningError.invalidRequirement
            }
            let roots = device.projectRoots?.filter { $0.projectID == projectID } ?? []
            guard !roots.isEmpty else {
                throw WorkspaceManagedMCPCommandPlanningError.missingProjectRoot(projectID)
            }
            guard roots.count == 1 else {
                throw WorkspaceManagedMCPCommandPlanningError.ambiguousProjectRoot(projectID)
            }
            return roots[0].rootPath
        case .workspace:
            guard selector.logicalProjectID == nil, let root = binding?.workspaceRootPath else {
                throw WorkspaceManagedMCPCommandPlanningError.missingWorkspaceRoot
            }
            return root
        case .managed, .account, .session:
            throw WorkspaceManagedMCPCommandPlanningError.unsupportedScope(selector.scope, client)
        }
    }
}

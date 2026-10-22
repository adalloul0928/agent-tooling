import Foundation

enum WorkspaceManagedMCPCommandPlanningError: Error, Equatable, Sendable {
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
    /// When the step replaces a registration the app already has under this
    /// name, the arguments of the command that removes it, run first with the
    /// same tool: an app refuses to add a name it already holds. Nil for a
    /// plain add, and for Kiro CLI, whose add takes `--force` instead. The
    /// review shows this command above the add, and the operations builder
    /// runs both from this one value, so what is shown is what runs.
    public let preArguments: [String]?
    /// What the replaced registration starts, as the app's own configuration
    /// records it, when that could be read: the old path the review names.
    public let replacedCommand: String?
    /// Whether `arguments` take the connection out of the app rather than
    /// add it: Agent Tooling's own connection, removed where this Mac no
    /// longer asks for it (D10).
    let isRemoval: Bool

    public init(
        artifactID: ArtifactID,
        physicalDestinationID: WorkspaceObjectID,
        surface: TargetSurface,
        scope: ToolingScope,
        nativeServerIdentifier: String,
        executableURL: URL,
        executable: String,
        arguments: [String],
        workingDirectoryPath: String?,
        preArguments: [String]? = nil,
        replacedCommand: String? = nil,
        isRemoval: Bool = false
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
        self.preArguments = preArguments
        self.replacedCommand = replacedCommand
        self.isRemoval = isRemoval
    }
}

public enum WorkspaceManagedMCPCommandPlanning {
    /// `replacing` says the app already has a registration under this name
    /// and the step changes it (the planner's `replacesExisting`): the plan
    /// then removes it first (D30), and `replacedCommand` is what it started.
    public static func plan(
        document: PortableWorkspaceDocument,
        device: DeviceWorkspaceState,
        requirement: EffectiveAssignmentRequirement,
        resolvedTargets: [ResolvedAssignmentTarget],
        target: ResolvedAssignmentTarget,
        capability: TargetCapabilityEvidence,
        nativeServerIdentifier: String,
        executableURL: URL,
        replacing: Bool = false,
        replacedCommand: String? = nil
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
            })
        else {
            throw WorkspaceManagedMCPCommandPlanningError.invalidRequirement
        }
        let artifactContributions = document.assignments.filter {
            $0.artifactID == requirement.artifactID
        }
        let applicableContributions = artifactContributions.filter {
            $0.destination.deviceIDs?.contains(device.deviceID) ?? true
        }
        guard requirement.desiredEnabled == nil,
            applicableContributions.allSatisfy({ $0.desiredEnabled == nil })
        else {
            throw WorkspaceManagedMCPCommandPlanningError.unsupportedEnablement
        }
        let assignmentResolution = WorkspaceAssignmentResolver.resolve(
            artifacts: document.artifacts,
            contributions: artifactContributions,
            currentDeviceID: device.deviceID,
            targets: resolvedTargets,
            capabilityEvidence: device.capabilityEvidence,
            portableMCPDefinitions: document.mcpDefinitions ?? [],
            deviceMCPBindings: device.mcpBindings ?? [],
            deviceRegistry: document.deviceRegistry)
        // Only this destination's issues count, plus any the resolver could not
        // pin to a destination; a connection asked for elsewhere too is judged
        // there. See the same rule in `WorkspaceNativePluginCommandPlanning`.
        let issues = assignmentResolution.issues.filter {
            $0.physicalDestinationID == nil || $0.physicalDestinationID == target.physicalDestinationID
        }
        if issues.contains(where: {
            $0.kind == .unsupportedCapability || $0.kind == .unknownCapability
        }) {
            throw WorkspaceManagedMCPCommandPlanningError.unsupportedCapability
        }
        if issues.contains(where: {
            $0.kind == .missingCapabilityEvidence
                || $0.kind == .contradictoryCapabilityEvidence
                || $0.kind == .invalidResolvedTarget
        }) {
            throw WorkspaceManagedMCPCommandPlanningError.invalidCapability
        }
        guard issues.isEmpty,
            assignmentResolution.requirements.filter({ $0 == requirement }).count == 1
        else {
            throw WorkspaceManagedMCPCommandPlanningError.invalidRequirement
        }

        guard let client = TargetSurfaceCapability.managedMCPClient(for: target.selector.surface) else {
            throw WorkspaceManagedMCPCommandPlanningError.unsupportedSurface(target.selector.surface)
        }
        let expectedExecutable = MCPClientCommand.executable(for: client)
        guard NativeSkillDestination.isValidRoot(executableURL),
            executableURL.lastPathComponent == expectedExecutable
        else {
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
            deviceBindings.first == strategyBinding || (deviceBindings.isEmpty && strategyBinding == nil)
        else {
            throw WorkspaceManagedMCPCommandPlanningError.invalidRequirement
        }

        let transport = definition.connection.transport
        guard target.installedClientVersion?.isEmpty == false,
            target.adapterContractVersion > 0,
            target.componentContexts.filter({
                $0.component == .mcpServer && $0.transport == transport.rawValue
            }).count == 1
        else {
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
                    bindingDestination.transport == expectedTransport
                else {
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
            workingDirectoryPath: workingDirectory,
            preArguments: replacing
                ? removalBeforeAdd(serverID: nativeServerIdentifier, client: client, scope: target.selector.scope) : nil,
            replacedCommand: replacing ? replacedCommand : nil)
    }

    /// The command that takes the connection `nativeServerIdentifier` out of
    /// the app at `surface`, for the person (`scope` must be the user's own):
    /// the step a planned `.removeManagedConnection` runs. The app's own
    /// tool must be the file the locator found for that app, and the name a
    /// safe identifier, as for an add; nothing about the connection's
    /// definition is needed, since nothing is started. Every app removes by
    /// name, Kiro CLI included.
    public static func removal(
        artifactID: ArtifactID, physicalDestinationID: WorkspaceObjectID, surface: TargetSurface, scope: ToolingScope,
        nativeServerIdentifier: String, executableURL: URL
    ) throws -> WorkspaceManagedMCPCommandPlan {
        guard let client = TargetSurfaceCapability.managedMCPClient(for: surface) else {
            throw WorkspaceManagedMCPCommandPlanningError.unsupportedSurface(surface)
        }
        let expectedExecutable = MCPClientCommand.executable(for: client)
        guard NativeSkillDestination.isValidRoot(executableURL), executableURL.lastPathComponent == expectedExecutable else {
            throw WorkspaceManagedMCPCommandPlanningError.invalidCLIURL
        }
        guard OperationCommandPolicy.isSafeMCPIdentifier(nativeServerIdentifier) else {
            throw WorkspaceManagedMCPCommandPlanningError.invalidNativeServerIdentifier
        }
        guard scope == .user else { throw WorkspaceManagedMCPCommandPlanningError.unsupportedScope(scope, client) }
        return .init(
            artifactID: artifactID, physicalDestinationID: physicalDestinationID, surface: surface, scope: scope,
            nativeServerIdentifier: nativeServerIdentifier, executableURL: executableURL, executable: expectedExecutable,
            arguments: MCPClientCommand.removeArguments(serverID: nativeServerIdentifier, client: client, scope: scope),
            workingDirectoryPath: nil, isRemoval: true)
    }

    /// The removal a replacement runs before its add: every app but Kiro CLI
    /// refuses to add a name it already holds, and Kiro CLI's add replaces
    /// with `--force`, so it needs none.
    static func removalBeforeAdd(serverID: String, client: ClientKind, scope: ToolingScope) -> [String]? {
        client == .kiro ? nil : MCPClientCommand.removeArguments(serverID: serverID, client: client, scope: scope)
    }

    /// What the stdio server `name` starts in `observation`'s app, as the
    /// app's own configuration files register it for the person, or nil when
    /// none does: the old path a replacement names in its review, the
    /// registration its removal takes out. A project's entry of the same name
    /// is not that registration. Reads those files only, as the check of
    /// Agent Tooling's own connection reads them.
    public static func registeredCommand(named name: String, in observation: TargetObservation) -> String? {
        SetupAuditor.userScopeServers(configurationPaths: observation.configurationPaths)[name]?.command
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

import Foundation

public enum WorkspaceNativePluginCommandPlanningError: Error, Equatable, Sendable {
    case invalidWorkspace
    case invalidRequirement
    case unsupportedEnablement
    case unsupportedSurface(TargetSurface)
    case unsupportedScope(ToolingScope, ClientKind)
    case invalidCapability
    case unsupportedCapability
    case invalidReviewedInstall
    case invalidCLIURL
    case blockedByManagedPolicy
    case unresolvedManagedPolicy
}

/// One reviewed native plugin installation command. The plan neither executes
/// the command nor claims that the plugin is installed, enabled, or usable.
public struct WorkspaceNativePluginCommandPlan: Equatable, Sendable {
    public let artifactID: ArtifactID
    public let physicalDestinationID: WorkspaceObjectID
    public let surface: TargetSurface
    public let scope: ToolingScope
    public let externalPluginID: String
    public let executableURL: URL
    public let executable: String
    public let arguments: [String]

    public init(
        artifactID: ArtifactID,
        physicalDestinationID: WorkspaceObjectID,
        surface: TargetSurface,
        scope: ToolingScope,
        externalPluginID: String,
        executableURL: URL,
        executable: String,
        arguments: [String]
    ) {
        self.artifactID = artifactID
        self.physicalDestinationID = physicalDestinationID
        self.surface = surface
        self.scope = scope
        self.externalPluginID = externalPluginID
        self.executableURL = executableURL
        self.executable = executable
        self.arguments = arguments
    }
}

/// Admits only an install route captured from a reviewed current marketplace.
/// Native ownership identifies the update owner, but cannot manufacture an
/// install command. Removal and update have separate intent and evidence.
public enum WorkspaceNativePluginCommandPlanning {
    public static func plan(
        document: PortableWorkspaceDocument,
        device: DeviceWorkspaceState,
        requirement: EffectiveAssignmentRequirement,
        resolvedTargets: [ResolvedAssignmentTarget],
        target: ResolvedAssignmentTarget,
        capability: TargetCapabilityEvidence,
        reviewedInstall: NativeInstall,
        executableURL: URL
    ) throws -> WorkspaceNativePluginCommandPlan {
        do {
            try document.validateStructure()
            try device.validateStructure(against: document)
        } catch {
            throw WorkspaceNativePluginCommandPlanningError.invalidWorkspace
        }

        guard requirement.component == .plugin,
              requirement.transport == nil,
              requirement.physicalDestinationID == target.physicalDestinationID,
              resolvedTargets.filter({ $0 == target }).count == 1,
              requirement.contributions.contains(where: {
                  ResolvedAssignmentSelector(destination: $0.destination) == target.selector
              }) else {
            throw WorkspaceNativePluginCommandPlanningError.invalidRequirement
        }

        let artifactContributions = document.assignments.filter {
            $0.artifactID == requirement.artifactID
        }
        let applicableContributions = artifactContributions.filter {
            $0.destination.deviceIDs?.contains(device.deviceID) ?? true
        }
        guard requirement.desiredEnabled == nil,
              applicableContributions.allSatisfy({ $0.desiredEnabled == nil }) else {
            throw WorkspaceNativePluginCommandPlanningError.unsupportedEnablement
        }

        let resolution = WorkspaceAssignmentResolver.resolve(
            artifacts: document.artifacts,
            contributions: artifactContributions,
            currentDeviceID: device.deviceID,
            targets: resolvedTargets,
            capabilityEvidence: device.capabilityEvidence)
        // Only this destination's issues count, plus any the resolver could not
        // pin to a destination. The package may be asked for elsewhere too, and
        // a destination with no route for it (a Claude Code package asked for
        // in Codex, say) is that destination's exclusion, not a reason to
        // refuse the command here. Judging every destination at once left every
        // package with a foreign-client assignment without a command.
        let issues = resolution.issues.filter {
            $0.physicalDestinationID == nil || $0.physicalDestinationID == target.physicalDestinationID
        }
        if issues.contains(where: {
            $0.kind == .unsupportedCapability || $0.kind == .unknownCapability
        }) {
            throw WorkspaceNativePluginCommandPlanningError.unsupportedCapability
        }
        if issues.contains(where: {
            $0.kind == .missingCapabilityEvidence
                || $0.kind == .contradictoryCapabilityEvidence
                || $0.kind == .invalidResolvedTarget
        }) {
            throw WorkspaceNativePluginCommandPlanningError.invalidCapability
        }
        guard issues.isEmpty,
              resolution.requirements.filter({ $0 == requirement }).count == 1 else {
            throw WorkspaceNativePluginCommandPlanningError.invalidRequirement
        }

        let client: ClientKind
        switch target.selector.surface {
        case .claudeCode: client = .claude
        case .codexCLI: client = .codex
        default:
            throw WorkspaceNativePluginCommandPlanningError.unsupportedSurface(target.selector.surface)
        }
        guard target.selector.scope == .user, target.selector.logicalProjectID == nil else {
            throw WorkspaceNativePluginCommandPlanningError.unsupportedScope(target.selector.scope, client)
        }

        guard case .nativePlugin(let route) = requirement.strategy,
              route.client == client,
              let artifact = document.artifacts.first(where: { $0.identity.id == requirement.artifactID }),
              artifact.identity.kind == .nativePlugin,
              artifact.identity.parentPackageID == nil,
              artifact.authority == .nativeOwned,
              artifact.nativeRoutes.filter({ $0.client == client }) == [route],
              OperationCommandPolicy.isSafePluginIdentifier(route.externalPluginID) else {
            throw WorkspaceNativePluginCommandPlanningError.invalidRequirement
        }

        try validateManagedPolicy(document.configurationState, artifactID: requirement.artifactID)

        guard target.installedClientVersion?.isEmpty == false,
              target.adapterContractVersion > 0,
              target.componentContexts.filter({ $0.component == .plugin && $0.transport == nil }).count == 1 else {
            throw WorkspaceNativePluginCommandPlanningError.invalidCapability
        }
        let matchingCapabilities = device.capabilityEvidence.filter {
            $0.surface == target.selector.surface
                && $0.installedClientVersion == target.installedClientVersion
                && $0.adapterContractVersion == target.adapterContractVersion
                && $0.component == .plugin
                && $0.transport == nil
                && $0.scopes.contains(.user)
        }
        guard matchingCapabilities.count == 1, matchingCapabilities.first == capability else {
            throw WorkspaceNativePluginCommandPlanningError.invalidCapability
        }
        guard case .supported = capability.support else {
            throw WorkspaceNativePluginCommandPlanningError.unsupportedCapability
        }

        let expectedExecutable: String
        let expectedArguments: [String]
        switch client {
        case .claude:
            expectedExecutable = "claude"
            expectedArguments = ["plugin", "install", route.externalPluginID, "--scope", "user"]
        case .codex:
            expectedExecutable = "codex"
            expectedArguments = ["plugin", "add", route.externalPluginID]
        case .gemini:
            throw WorkspaceNativePluginCommandPlanningError.unsupportedSurface(target.selector.surface)
        }
        guard reviewedInstall.client == client,
              reviewedInstall.scope == .user,
              reviewedInstall.executable == expectedExecutable,
              reviewedInstall.arguments == expectedArguments else {
            throw WorkspaceNativePluginCommandPlanningError.invalidReviewedInstall
        }
        guard NativeSkillDestination.isValidRoot(executableURL),
              executableURL.lastPathComponent == expectedExecutable else {
            throw WorkspaceNativePluginCommandPlanningError.invalidCLIURL
        }
        do {
            try OperationCommandPolicy(
                libraryURL: URL(fileURLWithPath: "/"),
                gitBackupRoot: URL(fileURLWithPath: "/")
            ).validate(executable: expectedExecutable, arguments: expectedArguments)
        } catch {
            throw WorkspaceNativePluginCommandPlanningError.invalidReviewedInstall
        }

        return .init(
            artifactID: requirement.artifactID,
            physicalDestinationID: requirement.physicalDestinationID,
            surface: target.selector.surface,
            scope: .user,
            externalPluginID: route.externalPluginID,
            executableURL: executableURL,
            executable: expectedExecutable,
            arguments: expectedArguments)
    }

    private static func validateManagedPolicy(
        _ state: WorkspaceConfigurationState?, artifactID: ArtifactID
    ) throws {
        for blocked in state?.managedPolicies.flatMap(\.blockedPlugins) ?? [] {
            switch blocked.resolution {
            case .artifact(let blockedID) where blockedID == artifactID:
                throw WorkspaceNativePluginCommandPlanningError.blockedByManagedPolicy
            case .unresolved:
                throw WorkspaceNativePluginCommandPlanningError.unresolvedManagedPolicy
            case .artifact, .object:
                continue
            }
        }
    }
}

import Foundation

public struct ResolvedAssignmentSelector: Hashable, Sendable {
    public var surface: TargetSurface
    public var scope: ToolingScope
    public var logicalProjectID: ArtifactID?

    public init(surface: TargetSurface, scope: ToolingScope, logicalProjectID: ArtifactID? = nil) {
        self.surface = surface
        self.scope = scope
        self.logicalProjectID = logicalProjectID
    }

    public init(destination: PortableDestination) {
        self.init(
            surface: destination.surface,
            scope: destination.scope,
            logicalProjectID: destination.logicalProjectID
        )
    }
}

public struct ResolvedTargetComponentContext: Hashable, Sendable {
    public var component: ComponentKind
    public var transport: String?

    public init(component: ComponentKind, transport: String? = nil) {
        self.component = component
        self.transport = transport
    }
}

/// Adapter-captured target identity. This is not a path or an actionable write plan.
public struct ResolvedAssignmentTarget: Hashable, Sendable {
    public var selector: ResolvedAssignmentSelector
    public var physicalDestinationID: WorkspaceObjectID
    public var installedClientVersion: String?
    public var adapterContractVersion: UInt
    public var componentContexts: [ResolvedTargetComponentContext]

    public init(
        selector: ResolvedAssignmentSelector,
        physicalDestinationID: WorkspaceObjectID,
        installedClientVersion: String?,
        adapterContractVersion: UInt,
        componentContexts: [ResolvedTargetComponentContext]
    ) {
        self.selector = selector
        self.physicalDestinationID = physicalDestinationID
        self.installedClientVersion = installedClientVersion
        self.adapterContractVersion = adapterContractVersion
        self.componentContexts = componentContexts
    }
}

public struct MCPAssignmentDefinitionEvidence: Hashable, Sendable {
    public var artifactID: ArtifactID
    public var transport: String

    public init(artifactID: ArtifactID, transport: String) {
        self.artifactID = artifactID
        self.transport = transport
    }
}

/// Digest captured by a content-store reader. Matching it proves identity of
/// available bytes for planning, not that a destination write is safe or ready.
public struct AssignmentContentEvidence: Hashable, Sendable {
    public var artifactID: ArtifactID
    public var digest: ContentDigest

    public init(artifactID: ArtifactID, digest: ContentDigest) {
        self.artifactID = artifactID
        self.digest = digest
    }
}

public enum EffectiveAssignmentStrategy: Hashable, Sendable {
    case content
    case nativePlugin(route: NativePackageRoute)
    /// Definition intent only. Destination mutation still requires the later
    /// reviewed adapter plan; no package bytes are invented for this record.
    case managedMCP(
        definition: PortableMCPDefinitionRecord,
        deviceBinding: DeviceMCPDefinitionBinding?
    )
}

public struct EffectiveAssignmentRequirement: Hashable, Sendable {
    public var artifactID: ArtifactID
    public var physicalDestinationID: WorkspaceObjectID
    public var component: ComponentKind
    public var transport: String?
    public var desiredEnabled: Bool?
    public var strategy: EffectiveAssignmentStrategy
    /// Original records remain independent; preset reasons are Apply-once and are never expanded here.
    public var contributions: [AssignmentContribution]

    public init(
        artifactID: ArtifactID,
        physicalDestinationID: WorkspaceObjectID,
        component: ComponentKind,
        transport: String?,
        desiredEnabled: Bool?,
        strategy: EffectiveAssignmentStrategy,
        contributions: [AssignmentContribution]
    ) {
        self.artifactID = artifactID
        self.physicalDestinationID = physicalDestinationID
        self.component = component
        self.transport = transport
        self.desiredEnabled = desiredEnabled
        self.strategy = strategy
        self.contributions = contributions
    }
}

public enum WorkspaceAssignmentIssueKind: String, Hashable, Sendable {
    case duplicateContributionID
    case invalidDesiredPresence
    case unknownArtifact
    case duplicateArtifactIdentity
    case invalidDestinationSelector
    case missingResolvedTarget
    case duplicateResolvedTarget
    case invalidResolvedTarget
    case unsupportedArtifactKind
    case trackedOnlyOwnership
    case nativeChildAssignment
    case missingNativeRoute
    case ambiguousNativeRoute
    case invalidNativeRoute
    case missingMCPDefinition
    case ambiguousMCPDefinition
    case invalidMCPTransport
    case invalidManagedMCPDefinition
    case missingDeviceMCPBinding
    case ambiguousDeviceMCPBinding
    case invalidDeviceMCPBinding
    case contradictoryMCPDefinition
    case missingTargetComponentContext
    case contradictoryTargetComponentContext
    case missingCapabilityEvidence
    case contradictoryCapabilityEvidence
    case unsupportedCapability
    case unknownCapability
    case missingMaterializedContent
    case ambiguousContentEvidence
    case conflictingEnabledIntent
    case incompatiblePhysicalStrategies
}

public struct WorkspaceAssignmentIssue: Hashable, Sendable {
    public var kind: WorkspaceAssignmentIssueKind
    public var contributionIDs: [WorkspaceObjectID]
    public var artifactID: ArtifactID?
    public var physicalDestinationID: WorkspaceObjectID?

    public init(
        kind: WorkspaceAssignmentIssueKind,
        contributionIDs: [WorkspaceObjectID] = [],
        artifactID: ArtifactID? = nil,
        physicalDestinationID: WorkspaceObjectID? = nil
    ) {
        self.kind = kind
        self.contributionIDs = contributionIDs.sorted()
        self.artifactID = artifactID
        self.physicalDestinationID = physicalDestinationID
    }
}

public struct WorkspaceAssignmentResolution: Hashable, Sendable {
    public var requirements: [EffectiveAssignmentRequirement]
    public var issues: [WorkspaceAssignmentIssue]
    /// Contributions deliberately selecting no device, or another device, are preserved in wire intent but ignored here.
    public var ignoredContributionIDs: [WorkspaceObjectID]

    public init(
        requirements: [EffectiveAssignmentRequirement],
        issues: [WorkspaceAssignmentIssue],
        ignoredContributionIDs: [WorkspaceObjectID]
    ) {
        self.requirements = requirements
        self.issues = issues
        self.ignoredContributionIDs = ignoredContributionIDs
    }
}

/// Reduces portable assignment intent for one device. The caller supplies a
/// structurally validated portable graph; this narrow array API cannot validate
/// source, project, or preset references. A returned requirement still needs
/// S3/Y2 staging, destination-baseline validation and reviewed apply.
public enum WorkspaceAssignmentResolver {
    public static func resolve(
        artifacts: [ArtifactRecord],
        contributions: [AssignmentContribution],
        currentDeviceID: WorkspaceObjectID,
        targets: [ResolvedAssignmentTarget],
        capabilityEvidence: [TargetCapabilityEvidence],
        mcpDefinitions: [MCPAssignmentDefinitionEvidence] = [],
        contentEvidence: [AssignmentContentEvidence] = [],
        portableMCPDefinitions: [PortableMCPDefinitionRecord] = [],
        deviceMCPBindings: [DeviceMCPDefinitionBinding] = []
    ) -> WorkspaceAssignmentResolution {
        let artifactsByID = Dictionary(grouping: artifacts, by: { $0.identity.id })
        let contributionGroups = Dictionary(grouping: contributions, by: \.id)
        let duplicateContributionIDs = Set(contributionGroups.compactMap { $0.value.count > 1 ? $0.key : nil })
        let targetGroups = Dictionary(grouping: targets, by: \.selector)
        let definitionGroups = Dictionary(grouping: mcpDefinitions, by: \.artifactID)
        let portableDefinitionGroups = Dictionary(grouping: portableMCPDefinitions, by: \.artifactID)
        let deviceBindingGroups = Dictionary(grouping: deviceMCPBindings, by: \.artifactID)
        let contentGroups = Dictionary(grouping: contentEvidence, by: \.artifactID)
        var issues = Set<WorkspaceAssignmentIssue>()
        var ignored = Set<WorkspaceObjectID>()
        var accepted: [AcceptedContribution] = []
        var physicalIntents: [PhysicalIntent] = []

        for contribution in contributions.sorted(by: contributionOrder) {
            let contributionID = contribution.id
            if duplicateContributionIDs.contains(contributionID) {
                issues.insert(.init(
                    kind: .duplicateContributionID,
                    contributionIDs: [contributionID],
                    artifactID: contribution.artifactID
                ))
                continue
            }
            guard contribution.desiredPresence else {
                issues.insert(.init(
                    kind: .invalidDesiredPresence,
                    contributionIDs: [contributionID],
                    artifactID: contribution.artifactID
                ))
                continue
            }
            guard applies(contribution.destination.deviceIDs, to: currentDeviceID) else {
                ignored.insert(contributionID)
                continue
            }
            let artifactRecords = artifactsByID[contribution.artifactID] ?? []
            guard artifactRecords.count == 1, let artifact = artifactRecords.first else {
                issues.insert(.init(
                    kind: artifactRecords.isEmpty ? .unknownArtifact : .duplicateArtifactIdentity,
                    contributionIDs: [contributionID],
                    artifactID: contribution.artifactID
                ))
                continue
            }
            guard validSelector(contribution.destination) else {
                issues.insert(issue(.invalidDestinationSelector, contribution))
                continue
            }
            guard artifact.identity.parentPackageID == nil || artifact.authority != .nativeOwned else {
                issues.insert(issue(.nativeChildAssignment, contribution))
                continue
            }
            guard artifact.authority != .trackedOnly else {
                issues.insert(issue(.trackedOnlyOwnership, contribution))
                continue
            }
            guard let component = component(for: artifact.identity.kind) else {
                issues.insert(issue(.unsupportedArtifactKind, contribution))
                continue
            }

            let selector = ResolvedAssignmentSelector(destination: contribution.destination)
            let matchingTargets = targetGroups[selector] ?? []
            guard matchingTargets.count == 1, let target = matchingTargets.first else {
                issues.insert(issue(
                    matchingTargets.isEmpty ? .missingResolvedTarget : .duplicateResolvedTarget,
                    contribution
                ))
                continue
            }
            physicalIntents.append(.init(
                contribution: contribution,
                key: .init(artifactID: contribution.artifactID, physicalDestinationID: target.physicalDestinationID)
            ))
            guard target.adapterContractVersion > 0,
                let installedVersion = validText(target.installedClientVersion),
                wellFormedComponentContexts(target.componentContexts)
            else {
                issues.insert(issue(.invalidResolvedTarget, contribution, physical: target.physicalDestinationID))
                continue
            }

            let transport: String?
            var managedMCPStrategy: EffectiveAssignmentStrategy?
            if component == .mcpServer {
                let typedDefinitions = portableDefinitionGroups[contribution.artifactID] ?? []
                let isManagedStandalone = artifact.authority == .centralPersonal
                    && artifact.identity.parentPackageID == nil && artifact.contentDigest == nil
                if isManagedStandalone || !typedDefinitions.isEmpty {
                    guard typedDefinitions.count == 1, let definition = typedDefinitions.first else {
                        issues.insert(issue(
                            typedDefinitions.isEmpty ? .missingMCPDefinition : .ambiguousMCPDefinition,
                            contribution,
                            physical: target.physicalDestinationID
                        ))
                        continue
                    }
                    do {
                        try WorkspaceMCPDefinitionValidation.validatePortable([definition], artifacts: [artifact])
                    } catch {
                        issues.insert(issue(
                            .invalidManagedMCPDefinition, contribution, physical: target.physicalDestinationID))
                        continue
                    }
                    let bindings = deviceBindingGroups[contribution.artifactID] ?? []
                    guard bindings.count <= 1 else {
                        issues.insert(issue(
                            .ambiguousDeviceMCPBinding, contribution, physical: target.physicalDestinationID))
                        continue
                    }
                    let binding = bindings.first
                    if case .deviceBound = definition.connection, binding == nil {
                        issues.insert(issue(
                            .missingDeviceMCPBinding, contribution, physical: target.physicalDestinationID))
                        continue
                    }
                    if contribution.destination.scope == .workspace,
                       binding?.workspaceRootPath == nil {
                        issues.insert(issue(
                            .missingDeviceMCPBinding, contribution, physical: target.physicalDestinationID))
                        continue
                    }
                    if let binding {
                        do {
                            try WorkspaceMCPDefinitionValidation.validateDevice(
                                [binding], definitions: [definition])
                        } catch {
                            issues.insert(issue(
                                .invalidDeviceMCPBinding, contribution, physical: target.physicalDestinationID))
                            continue
                        }
                    }
                    let legacyDefinitions = definitionGroups[contribution.artifactID] ?? []
                    if !legacyDefinitions.isEmpty {
                        guard legacyDefinitions.count == 1,
                              let legacyDefinition = legacyDefinitions.first,
                              let legacyTransport = validText(legacyDefinition.transport),
                              legacyTransport == definition.connection.transport.rawValue else {
                            issues.insert(issue(
                                .contradictoryMCPDefinition, contribution, physical: target.physicalDestinationID))
                            continue
                        }
                    }
                    transport = definition.connection.transport.rawValue
                    managedMCPStrategy = .managedMCP(definition: definition, deviceBinding: binding)
                } else {
                    let definitions = definitionGroups[contribution.artifactID] ?? []
                    guard definitions.count == 1, let definition = definitions.first else {
                        issues.insert(issue(
                            definitions.isEmpty ? .missingMCPDefinition : .ambiguousMCPDefinition,
                            contribution,
                            physical: target.physicalDestinationID
                        ))
                        continue
                    }
                    guard let value = validText(definition.transport) else {
                        issues.insert(issue(.invalidMCPTransport, contribution, physical: target.physicalDestinationID))
                        continue
                    }
                    transport = value
                }
            } else {
                transport = nil
            }

            let contexts = target.componentContexts.filter { $0.component == component && $0.transport == transport }
            guard contexts.count == 1 else {
                issues.insert(issue(
                    contexts.isEmpty ? .missingTargetComponentContext : .contradictoryTargetComponentContext,
                    contribution,
                    physical: target.physicalDestinationID
                ))
                continue
            }
            let matchingEvidence = capabilityEvidence.filter {
                $0.surface == selector.surface
                    && $0.installedClientVersion == installedVersion
                    && $0.adapterContractVersion == target.adapterContractVersion
                    && $0.component == component
                    && $0.transport == transport
                    && $0.scopes.contains(selector.scope)
            }
            guard matchingEvidence.count == 1, let evidence = matchingEvidence.first else {
                issues.insert(issue(
                    matchingEvidence.isEmpty ? .missingCapabilityEvidence : .contradictoryCapabilityEvidence,
                    contribution,
                    physical: target.physicalDestinationID
                ))
                continue
            }
            guard validCapabilityEvidence(evidence) else {
                issues.insert(issue(.contradictoryCapabilityEvidence, contribution, physical: target.physicalDestinationID))
                continue
            }
            switch evidence.support {
            case .unsupported:
                issues.insert(issue(.unsupportedCapability, contribution, physical: target.physicalDestinationID))
                continue
            case .unknown:
                issues.insert(issue(.unknownCapability, contribution, physical: target.physicalDestinationID))
                continue
            case .supported:
                break
            }

            let strategy: EffectiveAssignmentStrategy
            if let managedMCPStrategy {
                strategy = managedMCPStrategy
            } else if artifact.authority == .nativeOwned {
                guard artifact.identity.parentPackageID == nil, artifact.identity.kind == .nativePlugin,
                    let client = selector.surface.client
                else {
                    issues.insert(issue(.nativeChildAssignment, contribution, physical: target.physicalDestinationID))
                    continue
                }
                guard Set(artifact.nativeRoutes.map(\.client)).count == artifact.nativeRoutes.count else {
                    issues.insert(issue(.ambiguousNativeRoute, contribution, physical: target.physicalDestinationID))
                    continue
                }
                guard artifact.nativeRoutes.allSatisfy({ validNativePluginID($0.externalPluginID) }) else {
                    issues.insert(issue(.invalidNativeRoute, contribution, physical: target.physicalDestinationID))
                    continue
                }
                let routes = artifact.nativeRoutes.filter { $0.client == client }
                guard routes.count == 1, let route = routes.first else {
                    issues.insert(issue(
                        routes.isEmpty ? .missingNativeRoute : .ambiguousNativeRoute,
                        contribution,
                        physical: target.physicalDestinationID
                    ))
                    continue
                }
                strategy = .nativePlugin(route: route)
            } else {
                let captured = contentGroups[contribution.artifactID] ?? []
                guard captured.count <= 1 else {
                    issues.insert(issue(.ambiguousContentEvidence, contribution, physical: target.physicalDestinationID))
                    continue
                }
                guard let captured = captured.first, let expected = artifact.contentDigest,
                    validDigest(expected), validDigest(captured.digest), captured.digest == expected else {
                    issues.insert(issue(.missingMaterializedContent, contribution, physical: target.physicalDestinationID))
                    continue
                }
                strategy = .content
            }
            accepted.append(.init(
                contribution: contribution,
                physicalDestinationID: target.physicalDestinationID,
                component: component,
                transport: transport,
                strategy: strategy
            ))
        }

        let intentGroups = Dictionary(grouping: physicalIntents, by: \.key)
        var conflictingEnabledKeys = Set<RequirementKey>()
        for key in intentGroups.keys.sorted(by: requirementKeyOrder) {
            guard let values = intentGroups[key] else { continue }
            let explicitEnabled = Set(values.compactMap { $0.contribution.desiredEnabled })
            guard explicitEnabled.count > 1 else { continue }
            conflictingEnabledKeys.insert(key)
            issues.insert(.init(
                kind: .conflictingEnabledIntent,
                contributionIDs: values.map(\.contribution.id),
                artifactID: key.artifactID,
                physicalDestinationID: key.physicalDestinationID
            ))
        }
        let grouped = Dictionary(grouping: accepted) {
            RequirementKey(artifactID: $0.contribution.artifactID, physicalDestinationID: $0.physicalDestinationID)
        }
        let blockedPhysicalKeys = Set(issues.compactMap { issue -> RequirementKey? in
            guard let artifactID = issue.artifactID, let destinationID = issue.physicalDestinationID else { return nil }
            return .init(artifactID: artifactID, physicalDestinationID: destinationID)
        })
        // When invalid or duplicate input prevents physical resolution, the
        // resolver cannot prove another surface is independent. Conservatively
        // suppress this artifact while leaving other artifacts unaffected.
        let blockedArtifacts = Set(issues.compactMap { issue -> ArtifactID? in
            issue.physicalDestinationID == nil ? issue.artifactID : nil
        })
        var requirements: [EffectiveAssignmentRequirement] = []
        for key in grouped.keys.sorted(by: requirementKeyOrder) {
            guard let values = grouped[key] else { continue }
            guard !conflictingEnabledKeys.contains(key), !blockedPhysicalKeys.contains(key),
                !blockedArtifacts.contains(key.artifactID)
            else { continue }
            let contributionIDs = values.map(\.contribution.id).sorted()
            let explicitEnabled = Set(values.compactMap { $0.contribution.desiredEnabled })
            let strategies = Set(values.map(\.strategy))
            let components = Set(values.map(\.component))
            let transports = Set(values.map(\.transport))
            guard strategies.count == 1, components.count == 1, transports.count == 1,
                let strategy = strategies.first, let component = components.first
            else {
                issues.insert(.init(
                    kind: .incompatiblePhysicalStrategies,
                    contributionIDs: contributionIDs,
                    artifactID: key.artifactID,
                    physicalDestinationID: key.physicalDestinationID
                ))
                continue
            }
            requirements.append(.init(
                artifactID: key.artifactID,
                physicalDestinationID: key.physicalDestinationID,
                component: component,
                transport: values[0].transport,
                desiredEnabled: explicitEnabled.first,
                strategy: strategy,
                contributions: values.map(\.contribution).sorted(by: contributionOrder)
            ))
        }

        requirements.sort(by: requirementOrder)
        return .init(
            requirements: requirements,
            issues: issues.sorted(by: issueOrder),
            ignoredContributionIDs: ignored.sorted()
        )
    }

    private struct AcceptedContribution {
        var contribution: AssignmentContribution
        var physicalDestinationID: WorkspaceObjectID
        var component: ComponentKind
        var transport: String?
        var strategy: EffectiveAssignmentStrategy
    }

    private struct PhysicalIntent {
        var contribution: AssignmentContribution
        var key: RequirementKey
    }

    private struct RequirementKey: Hashable {
        var artifactID: ArtifactID
        var physicalDestinationID: WorkspaceObjectID
    }

    private static func applies(_ deviceIDs: [WorkspaceObjectID]?, to currentDeviceID: WorkspaceObjectID) -> Bool {
        deviceIDs?.contains(currentDeviceID) ?? true
    }

    private static func validSelector(_ destination: PortableDestination) -> Bool {
        if let deviceIDs = destination.deviceIDs, Set(deviceIDs).count != deviceIDs.count { return false }
        return switch destination.scope {
        case .project, .localProject: destination.logicalProjectID != nil
        case .user, .workspace, .managed, .account, .session: destination.logicalProjectID == nil
        }
    }

    private static func component(for kind: ArtifactKind) -> ComponentKind? {
        switch kind {
        case .skill: .skill
        case .mcpServer: .mcpServer
        case .package, .nativePlugin: .plugin
        case .preset, .logicalProject: nil
        }
    }

    private static func validText(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 256,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return value
    }

    private static func validCapabilityEvidence(_ evidence: TargetCapabilityEvidence) -> Bool {
        guard evidence.adapterContractVersion > 0,
            Set(evidence.scopes).count == evidence.scopes.count,
            validText(evidence.installedClientVersion) != nil
        else { return false }
        if let transport = evidence.transport,
            transport.count > 128 || transport.isEmpty
                || transport.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return false
        }
        switch evidence.support {
        case .supported:
            return true
        case .unsupported(let reason), .unknown(let reason):
            return !reason.isEmpty && reason.count <= 2_048
                && !reason.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }

    private static func validNativePluginID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 512
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validDigest(_ digest: ContentDigest) -> Bool {
        digest.value.count == 64 && digest.value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func wellFormedComponentContexts(_ values: [ResolvedTargetComponentContext]) -> Bool {
        values.allSatisfy {
            $0.component == .mcpServer ? validText($0.transport) != nil : $0.transport == nil
        }
    }

    private static func issue(
        _ kind: WorkspaceAssignmentIssueKind,
        _ contribution: AssignmentContribution,
        physical: WorkspaceObjectID? = nil
    ) -> WorkspaceAssignmentIssue {
        .init(
            kind: kind,
            contributionIDs: [contribution.id],
            artifactID: contribution.artifactID,
            physicalDestinationID: physical
        )
    }

    private static func contributionOrder(_ lhs: AssignmentContribution, _ rhs: AssignmentContribution) -> Bool {
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        if lhs.artifactID != rhs.artifactID { return lhs.artifactID < rhs.artifactID }
        return destinationKey(lhs.destination).lexicographicallyPrecedes(destinationKey(rhs.destination))
    }

    private static func destinationKey(_ value: PortableDestination) -> [String] {
        [value.surface.rawValue, value.scope.rawValue, value.logicalProjectID?.rawValue.uuidString ?? "",
         value.deviceIDs?.map { $0.rawValue.uuidString }.sorted().joined(separator: ",") ?? "*"]
    }

    private static func requirementKeyOrder(_ lhs: RequirementKey, _ rhs: RequirementKey) -> Bool {
        lhs.artifactID == rhs.artifactID
            ? lhs.physicalDestinationID < rhs.physicalDestinationID : lhs.artifactID < rhs.artifactID
    }

    private static func requirementOrder(_ lhs: EffectiveAssignmentRequirement, _ rhs: EffectiveAssignmentRequirement) -> Bool {
        if lhs.artifactID != rhs.artifactID { return lhs.artifactID < rhs.artifactID }
        return lhs.physicalDestinationID < rhs.physicalDestinationID
    }

    private static func issueOrder(_ lhs: WorkspaceAssignmentIssue, _ rhs: WorkspaceAssignmentIssue) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.artifactID != rhs.artifactID {
            return (lhs.artifactID?.rawValue.uuidString ?? "") < (rhs.artifactID?.rawValue.uuidString ?? "")
        }
        if lhs.physicalDestinationID != rhs.physicalDestinationID {
            return (lhs.physicalDestinationID?.rawValue.uuidString ?? "")
                < (rhs.physicalDestinationID?.rawValue.uuidString ?? "")
        }
        return lhs.contributionIDs.map { $0.rawValue.uuidString }.joined(separator: ",")
            < rhs.contributionIDs.map { $0.rawValue.uuidString }.joined(separator: ",")
    }
}

import Foundation

/// What this device has actually seen at one destination. Absence of an entry
/// means "not observed", which is different from "observed absent"; neither is
/// ever taken as proof that a destination is already correct.
public struct WorkspaceDeploymentObservation: Hashable, Sendable {
    public let artifactID: ArtifactID
    public let physicalDestinationID: WorkspaceObjectID
    public let isPresent: Bool
    public let isEnabled: Bool?
    /// The content this destination currently holds, when it could be measured.
    public let contentDigest: ContentDigest?

    public init(
        artifactID: ArtifactID,
        physicalDestinationID: WorkspaceObjectID,
        isPresent: Bool,
        isEnabled: Bool? = nil,
        contentDigest: ContentDigest? = nil
    ) {
        self.artifactID = artifactID
        self.physicalDestinationID = physicalDestinationID
        self.isPresent = isPresent
        self.isEnabled = isEnabled
        self.contentDigest = contentDigest
    }
}

public enum WorkspaceDeploymentAction: Hashable, Sendable {
    /// Materialize the library's approved content at this destination.
    case installContent(digest: ContentDigest)
    /// Replace content that differs from the library's approved revision.
    case updateContent(from: ContentDigest?, to: ContentDigest)
    /// Ask the native client to install a whole package it owns.
    case installNativePackage(route: NativePackageRoute)
    /// Add or reconfigure a managed connection this device holds locally.
    case configureManagedConnection(transport: MCPTransport)
    /// Remove a copy this app installed that is no longer requested here.
    case removeContent(installed: ContentDigest)
}

public enum WorkspaceDeploymentExclusionReason: String, Hashable, Sendable, CaseIterable {
    /// The library holds no verified content for this item.
    case missingContent
    /// Tracked items record what exists; they are not deployed.
    case trackedOwnership
    /// A bundled member is delivered by its package.
    case packageMember
    /// This device has no reviewed install route for a native package.
    case missingNativeRoute
    /// The adapter cannot express this scope or this on/off request.
    case unsupportedByAdapter
    /// The resolver could not produce a usable requirement.
    case needsAssignmentReview
    /// The destination already holds exactly this, by observation.
    case alreadyPresent
}

public struct WorkspaceDeploymentExclusion: Hashable, Sendable {
    public let artifactID: ArtifactID?
    public let physicalDestinationID: WorkspaceObjectID?
    public let reason: WorkspaceDeploymentExclusionReason
    /// Static description. Never contains a path, endpoint or credential.
    public let detail: String
}

public struct WorkspaceDeploymentItem: Hashable, Sendable {
    public let artifactID: ArtifactID
    public let displayName: String
    public let physicalDestinationID: WorkspaceObjectID
    public let surface: TargetSurface
    public let scope: ToolingScope
    public let logicalProjectID: ArtifactID?
    public let action: WorkspaceDeploymentAction
    public let desiredEnabled: Bool?
    /// Every independent reason this destination is required, preserved so
    /// removing one contribution cannot silently remove the whole requirement.
    public let reasons: [AssignmentReason]
}

/// One thing this app installed, at one place.
public struct WorkspaceDeploymentInstallKey: Hashable, Sendable {
    public let artifactID: ArtifactID
    public let physicalDestinationID: WorkspaceObjectID

    public init(artifactID: ArtifactID, physicalDestinationID: WorkspaceObjectID) {
        self.artifactID = artifactID
        self.physicalDestinationID = physicalDestinationID
    }
}

public struct WorkspaceDeploymentPlan: Sendable {
    public let items: [WorkspaceDeploymentItem]
    public let exclusions: [WorkspaceDeploymentExclusion]
    /// The resolver's own output, carried through unchanged.
    ///
    /// The command bridges take a requirement and a target and re-check both
    /// against the document themselves. They cannot be handed a reconstruction:
    /// a requirement built a second time from the same inputs is not the one
    /// this plan was made from, and the point of the bridge's checks is that
    /// the thing being approved is the thing that was resolved.
    public let requirements: [EffectiveAssignmentRequirement]
    public let resolvedTargets: [ResolvedAssignmentTarget]
    public var isEmpty: Bool { items.isEmpty }

    public init(
        items: [WorkspaceDeploymentItem],
        exclusions: [WorkspaceDeploymentExclusion],
        requirements: [EffectiveAssignmentRequirement] = [],
        resolvedTargets: [ResolvedAssignmentTarget] = []
    ) {
        self.items = items
        self.exclusions = exclusions
        self.requirements = requirements
        self.resolvedTargets = resolvedTargets
    }
}

/// Turns committed assignment intent into one reviewable list of what would
/// change on this device, and an explicit list of what would not and why.
///
/// It is pure. It reads no filesystem, runs no client, and proves nothing about
/// whether an adapter will accept an item: producing an item here is a request
/// for the existing reviewed operation path, not evidence of installation.
/// Anything it cannot express is excluded by name rather than attempted.
public enum WorkspaceDeploymentPlanner {
    public static func plan(
        document: PortableWorkspaceDocument,
        device: DeviceWorkspaceState,
        targets: [ResolvedAssignmentTarget],
        /// What the central content store actually holds, measured by the
        /// caller. Without it an item is excluded rather than assumed present.
        availableContent: [AssignmentContentEvidence] = [],
        observations: [WorkspaceDeploymentObservation] = [],
        /// Destinations the caller proved this app installed itself. Only these
        /// can ever be offered for removal; anything else stays untouched.
        provenInstalls: Set<WorkspaceDeploymentInstallKey> = [],
        nativeInstallRoutes: Set<NativePackageRoute> = []
    ) -> WorkspaceDeploymentPlan {
        var items: [WorkspaceDeploymentItem] = []
        var exclusions: [WorkspaceDeploymentExclusion] = []
        func exclude(
            _ reason: WorkspaceDeploymentExclusionReason,
            _ artifactID: ArtifactID?,
            _ destination: WorkspaceObjectID?,
            _ detail: String
        ) {
            exclusions.append(.init(artifactID: artifactID, physicalDestinationID: destination,
                                    reason: reason, detail: detail))
        }

        let resolution = WorkspaceAssignmentResolver.resolve(
            artifacts: document.artifacts,
            contributions: document.assignments,
            currentDeviceID: device.deviceID,
            targets: targets,
            capabilityEvidence: device.capabilityEvidence,
            contentEvidence: availableContent,
            portableMCPDefinitions: document.mcpDefinitions ?? [],
            deviceMCPBindings: device.mcpBindings ?? [])

        for issue in resolution.issues {
            exclude(reason(for: issue.kind), issue.artifactID, issue.physicalDestinationID,
                    describe(issue.kind))
        }

        let artifacts = Dictionary(document.artifacts.map { ($0.identity.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let targetsByID = Dictionary(targets.map { ($0.physicalDestinationID, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let observed = Dictionary(observations.map {
            (ObservationKey(artifactID: $0.artifactID, destination: $0.physicalDestinationID), $0)
        }, uniquingKeysWith: { first, _ in first })

        for requirement in resolution.requirements.sorted(by: order) {
            guard let artifact = artifacts[requirement.artifactID],
                  let target = targetsByID[requirement.physicalDestinationID] else {
                exclude(.needsAssignmentReview, requirement.artifactID, requirement.physicalDestinationID,
                        "This request no longer matches a known item or destination.")
                continue
            }
            guard artifact.identity.parentPackageID == nil else {
                exclude(.packageMember, artifact.identity.id, requirement.physicalDestinationID,
                        "Bundled tools are delivered by their package.")
                continue
            }
            let current = observed[.init(artifactID: artifact.identity.id,
                                         destination: requirement.physicalDestinationID)]
            let action: WorkspaceDeploymentAction
            switch requirement.strategy {
            case .content:
                guard artifact.authority != .trackedOnly else {
                    exclude(.trackedOwnership, artifact.identity.id, requirement.physicalDestinationID,
                            "Tracked items record what exists; the library does not install them.")
                    continue
                }
                guard let digest = artifact.contentDigest else {
                    exclude(.missingContent, artifact.identity.id, requirement.physicalDestinationID,
                            "The library holds no verified content for this item yet.")
                    continue
                }
                if let current, current.isPresent {
                    guard current.contentDigest != digest else {
                        exclude(.alreadyPresent, artifact.identity.id, requirement.physicalDestinationID,
                                "This destination already holds the approved version.")
                        continue
                    }
                    action = .updateContent(from: current.contentDigest, to: digest)
                } else {
                    action = .installContent(digest: digest)
                }

            case .nativePlugin(let route):
                guard nativeInstallRoutes.contains(route) else {
                    exclude(.missingNativeRoute, artifact.identity.id, requirement.physicalDestinationID,
                            "This Mac has no reviewed install route for this app's package.")
                    continue
                }
                // A native package's own client owns enable/disable; asking for
                // it here would be an install claim the adapter cannot make.
                guard requirement.desiredEnabled == nil else {
                    exclude(.unsupportedByAdapter, artifact.identity.id, requirement.physicalDestinationID,
                            "Turning an app-managed package on or off is done in that app.")
                    continue
                }
                if let current, current.isPresent {
                    exclude(.alreadyPresent, artifact.identity.id, requirement.physicalDestinationID,
                            "This app already reports the package installed.")
                    continue
                }
                action = .installNativePackage(route: route)

            case .managedMCP(let definition, let binding):
                guard binding != nil else {
                    exclude(.needsAssignmentReview, artifact.identity.id, requirement.physicalDestinationID,
                            "This connection has no local setup on this Mac yet.")
                    continue
                }
                if let current, current.isPresent, current.isEnabled == requirement.desiredEnabled {
                    exclude(.alreadyPresent, artifact.identity.id, requirement.physicalDestinationID,
                            "This connection is already set up here as requested.")
                    continue
                }
                action = .configureManagedConnection(transport: definition.connection.transport)
            }

            items.append(.init(
                artifactID: artifact.identity.id,
                displayName: artifact.identity.displayName,
                physicalDestinationID: requirement.physicalDestinationID,
                surface: target.selector.surface,
                scope: target.selector.scope,
                logicalProjectID: target.selector.logicalProjectID,
                action: action,
                desiredEnabled: requirement.desiredEnabled,
                reasons: uniqueReasons(requirement.contributions)))
        }
        // Anything this app installed that nobody asks for any more is offered
        // for removal. A copy someone else put there is never touched.
        let requested = Set(resolution.requirements.map {
            WorkspaceDeploymentInstallKey(artifactID: $0.artifactID,
                                          physicalDestinationID: $0.physicalDestinationID)
        })
        for key in provenInstalls.subtracting(requested).sorted(by: keyOrder) {
            guard let observation = observed[.init(artifactID: key.artifactID,
                                                   destination: key.physicalDestinationID)],
                  observation.isPresent, let digest = observation.contentDigest else {
                // Without a measurement there is nothing to prove it is safe to
                // remove, so it is left where it is.
                continue
            }
            guard let target = targetsByID[key.physicalDestinationID] else { continue }
            items.append(.init(
                artifactID: key.artifactID,
                displayName: artifacts[key.artifactID]?.identity.displayName ?? "Removed item",
                physicalDestinationID: key.physicalDestinationID,
                surface: target.selector.surface, scope: target.selector.scope,
                logicalProjectID: target.selector.logicalProjectID,
                action: .removeContent(installed: digest), desiredEnabled: nil, reasons: []))
        }
        return .init(items: items, exclusions: exclusions.sorted(by: order),
                     requirements: resolution.requirements, resolvedTargets: targets)
    }
}

private extension WorkspaceDeploymentPlanner {
    struct ObservationKey: Hashable {
        let artifactID: ArtifactID
        let destination: WorkspaceObjectID
    }

    /// Independent reasons stay independent; a preset contribution is never
    /// collapsed into a manual one, so removing either keeps the other.
    static func uniqueReasons(_ contributions: [AssignmentContribution]) -> [AssignmentReason] {
        var seen = Set<String>()
        var reasons: [AssignmentReason] = []
        for contribution in contributions {
            let key: String
            switch contribution.reason {
            case .manual: key = "manual"
            case .preset(let id): key = "preset:" + id.rawValue.uuidString
            case .onboarding(let id): key = "onboarding:" + id.rawValue.uuidString
            case .projectDeclaration(let id): key = "project:" + id.rawValue.uuidString
            }
            if seen.insert(key).inserted { reasons.append(contribution.reason) }
        }
        return reasons
    }

    static func reason(for kind: WorkspaceAssignmentIssueKind) -> WorkspaceDeploymentExclusionReason {
        switch kind {
        case .trackedOnlyOwnership: .trackedOwnership
        case .missingMaterializedContent, .ambiguousContentEvidence: .missingContent
        case .nativeChildAssignment: .packageMember
        case .missingNativeRoute, .ambiguousNativeRoute, .invalidNativeRoute: .missingNativeRoute
        case .unsupportedCapability, .unknownCapability, .missingCapabilityEvidence,
             .contradictoryCapabilityEvidence: .unsupportedByAdapter
        default: .needsAssignmentReview
        }
    }

    static func describe(_ kind: WorkspaceAssignmentIssueKind) -> String {
        switch kind {
        case .trackedOnlyOwnership: "Tracked items record what exists; the library does not install them."
        case .missingMaterializedContent:
            "The library holds no verified content for this item yet."
        case .ambiguousContentEvidence:
            "This item has more than one recorded content version in the library."
        case .nativeChildAssignment: "Bundled tools are delivered by their package."
        case .missingNativeRoute, .ambiguousNativeRoute, .invalidNativeRoute:
            "This app's package has no single confirmed route on this Mac."
        case .unsupportedCapability, .unknownCapability:
            "The installed app version does not support this destination."
        case .missingCapabilityEvidence, .contradictoryCapabilityEvidence:
            "This Mac has no dependable record of what the installed app supports."
        // Naming the check that refused is what makes this actionable.
        default: "This request needs review before it can be applied: \(kind.rawValue)."
        }
    }

    static func order(_ lhs: EffectiveAssignmentRequirement, _ rhs: EffectiveAssignmentRequirement) -> Bool {
        let left = [lhs.artifactID.rawValue.uuidString, lhs.physicalDestinationID.rawValue.uuidString]
        let right = [rhs.artifactID.rawValue.uuidString, rhs.physicalDestinationID.rawValue.uuidString]
        return left.lexicographicallyPrecedes(right)
    }

    static func keyOrder(_ lhs: WorkspaceDeploymentInstallKey, _ rhs: WorkspaceDeploymentInstallKey) -> Bool {
        let left = [lhs.artifactID.rawValue.uuidString, lhs.physicalDestinationID.rawValue.uuidString]
        let right = [rhs.artifactID.rawValue.uuidString, rhs.physicalDestinationID.rawValue.uuidString]
        return left.lexicographicallyPrecedes(right)
    }

    static func order(_ lhs: WorkspaceDeploymentExclusion, _ rhs: WorkspaceDeploymentExclusion) -> Bool {
        let left = [lhs.reason.rawValue, lhs.artifactID?.rawValue.uuidString ?? "", lhs.detail]
        let right = [rhs.reason.rawValue, rhs.artifactID?.rawValue.uuidString ?? "", rhs.detail]
        return left.lexicographicallyPrecedes(right)
    }
}

import Foundation

public struct SourceRootBinding: Codable, Hashable, Sendable {
    public var sourceRootID: WorkspaceObjectID
    public var checkoutPath: String
    public var worktreeIdentity: String?
    public var credentialReferenceID: String?
    public var observedRevision: SourceRevision?
    public var hasUnpublishedChanges: Bool?

    public init(
        sourceRootID: WorkspaceObjectID,
        checkoutPath: String,
        worktreeIdentity: String? = nil,
        credentialReferenceID: String? = nil,
        observedRevision: SourceRevision? = nil,
        hasUnpublishedChanges: Bool? = nil
    ) {
        self.sourceRootID = sourceRootID
        self.checkoutPath = checkoutPath
        self.worktreeIdentity = worktreeIdentity
        self.credentialReferenceID = credentialReferenceID
        self.observedRevision = observedRevision
        self.hasUnpublishedChanges = hasUnpublishedChanges
    }
}

public enum DestinationWritePolicy: String, Codable, Sendable {
    case reviewedReplacement, noClobberApplyOnce
}

public struct LinkedDestinationBinding: Codable, Hashable, Sendable {
    public var id: WorkspaceObjectID
    public var selector: PortableDestination
    public var resolvedPath: String
    public var writePolicy: DestinationWritePolicy

    public init(
        id: WorkspaceObjectID = WorkspaceObjectID(),
        selector: PortableDestination,
        resolvedPath: String,
        writePolicy: DestinationWritePolicy
    ) {
        self.id = id
        self.selector = selector
        self.resolvedPath = resolvedPath
        self.writePolicy = writePolicy
    }
}

public struct DeploymentBaseline: Codable, Hashable, Sendable {
    public var artifactID: ArtifactID
    public var destinationID: WorkspaceObjectID
    public var deployedContent: ContentDigest
    public var lastReceiptID: WorkspaceObjectID?

    public init(
        artifactID: ArtifactID,
        destinationID: WorkspaceObjectID,
        deployedContent: ContentDigest,
        lastReceiptID: WorkspaceObjectID? = nil
    ) {
        self.artifactID = artifactID
        self.destinationID = destinationID
        self.deployedContent = deployedContent
        self.lastReceiptID = lastReceiptID
    }
}

public enum CapabilitySupport: Hashable, Sendable {
    case supported
    case unsupported(reason: String)
    case unknown(reason: String)
}

extension CapabilitySupport: Codable {
    private enum Kind: String, Codable { case supported, unsupported, unknown }
    private enum CodingKeys: String, CodingKey { case kind, payload }
    private enum PayloadKeys: String, CodingKey { case reason }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .supported: self = .supported
        case .unsupported:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            self = .unsupported(reason: try payload.decode(String.self, forKey: .reason))
        case .unknown:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            self = .unknown(reason: try payload.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .supported: try container.encode(Kind.supported, forKey: .kind)
        case .unsupported(let reason):
            try container.encode(Kind.unsupported, forKey: .kind)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(reason, forKey: .reason)
        case .unknown(let reason):
            try container.encode(Kind.unknown, forKey: .kind)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(reason, forKey: .reason)
        }
    }
}

public struct TargetCapabilityEvidence: Codable, Hashable, Sendable {
    public var surface: TargetSurface
    public var installedClientVersion: String?
    public var adapterContractVersion: UInt
    public var component: ComponentKind
    public var transport: String?
    public var scopes: [ToolingScope]
    public var support: CapabilitySupport
    public var observedAt: Date

    public init(
        surface: TargetSurface,
        installedClientVersion: String? = nil,
        adapterContractVersion: UInt,
        component: ComponentKind,
        transport: String? = nil,
        scopes: [ToolingScope] = [],
        support: CapabilitySupport,
        observedAt: Date = .now
    ) {
        self.surface = surface
        self.installedClientVersion = installedClientVersion
        self.adapterContractVersion = adapterContractVersion
        self.component = component
        self.transport = transport
        self.scopes = scopes
        self.support = support
        self.observedAt = observedAt
    }
}

public struct DeviceWorkspaceState: Codable, Hashable, Sendable {
    public static let currentSchemaVersion: UInt = 4

    public var schemaVersion: UInt
    public var workspaceID: WorkspaceObjectID
    public var deviceID: WorkspaceObjectID
    public var sourceLocations: [SourceRootBinding]
    public var destinations: [LinkedDestinationBinding]
    public var observations: [TargetObservation]
    public var capabilityEvidence: [TargetCapabilityEvidence]
    public var deploymentBaselines: [DeploymentBaseline]
    public var pendingPlanIDs: [WorkspaceObjectID]
    public var receiptIDs: [WorkspaceObjectID]
    public var configurationState: WorkspaceConfigurationDeviceState?
    /// Commands, local endpoints and credential names never enter portable bytes.
    public var mcpBindings: [DeviceMCPDefinitionBinding]?
    public var applicationState: DeviceApplicationState?
    public var projectRoots: [DeviceProjectRootBinding]?
    /// Captured display/update observations; never used as desired ownership.
    public var inventoryState: DeviceInventoryState?

    public init(
        schemaVersion: UInt = Self.currentSchemaVersion,
        workspaceID: WorkspaceObjectID,
        deviceID: WorkspaceObjectID = WorkspaceObjectID(),
        sourceLocations: [SourceRootBinding] = [],
        destinations: [LinkedDestinationBinding] = [],
        observations: [TargetObservation] = [],
        capabilityEvidence: [TargetCapabilityEvidence] = [],
        deploymentBaselines: [DeploymentBaseline] = [],
        pendingPlanIDs: [WorkspaceObjectID] = [],
        receiptIDs: [WorkspaceObjectID] = [],
        configurationState: WorkspaceConfigurationDeviceState? = .init(),
        mcpBindings: [DeviceMCPDefinitionBinding]? = nil,
        applicationState: DeviceApplicationState? = nil,
        projectRoots: [DeviceProjectRootBinding]? = nil,
        inventoryState: DeviceInventoryState? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.sourceLocations = sourceLocations
        self.destinations = destinations
        self.observations = observations
        self.capabilityEvidence = capabilityEvidence
        self.deploymentBaselines = deploymentBaselines
        self.pendingPlanIDs = pendingPlanIDs
        self.receiptIDs = receiptIDs
        self.configurationState = configurationState
        self.mcpBindings = mcpBindings ?? (schemaVersion >= 3 ? [] : nil)
        self.applicationState = applicationState ?? (schemaVersion >= 4 ? .init() : nil)
        self.projectRoots = projectRoots ?? (schemaVersion >= 4 ? [] : nil)
        self.inventoryState = inventoryState ?? (schemaVersion >= 4 ? .init() : nil)
    }

    public func validateStructure(against portable: PortableWorkspaceDocument? = nil) throws {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw WorkspaceDomainValidationError.unsupportedVersion(schemaVersion)
        }
        guard (schemaVersion == 1 && configurationState == nil && mcpBindings == nil && applicationState == nil && projectRoots == nil && inventoryState == nil)
            || (schemaVersion == 2 && configurationState != nil && mcpBindings == nil && applicationState == nil && projectRoots == nil && inventoryState == nil)
            || (schemaVersion == 3 && configurationState != nil && mcpBindings != nil && applicationState == nil && projectRoots == nil && inventoryState == nil)
            || (schemaVersion == 4 && configurationState != nil && mcpBindings != nil && applicationState != nil && projectRoots != nil && inventoryState != nil) else {
            throw WorkspaceDomainValidationError.invalidField("device schema feature version")
        }
        if let portable, configurationState != nil, portable.configurationState == nil {
            // An empty v2 device supplement can accompany a legacy v1 document.
            guard configurationState == WorkspaceConfigurationDeviceState() else {
                throw WorkspaceDomainValidationError.missingReference("portable configuration state")
            }
        }
        try configurationState?.validate(against: portable?.configurationState)
        try applicationState?.validate(against: portable.map { $0.configurationState ?? .init() })
        try inventoryState?.validate(against: portable)
        if let projectRoots {
            try requireUnique(projectRoots.map(\.projectID), field: "device project roots")
            try requireUnique(projectRoots.map(\.rootPath), field: "device project root paths")
            let projects = portable.map { Set($0.logicalProjects.map(\.id)) }
            for binding in projectRoots {
                try WorkspaceDomainValidation.requireAbsolutePath(binding.rootPath, field: "device project root")
                if let projects, !projects.contains(binding.projectID) {
                    throw WorkspaceDomainValidationError.missingReference("device project root logical project")
                }
            }
            if let configuration = configurationState {
                for record in portable?.configurationState?.configurations ?? [] {
                    guard let projectID = record.logicalProjectID,
                          let root = projectRoots.first(where: { $0.projectID == projectID }),
                          let configurationRoot = configuration.configurationBindings.first(where: { $0.configurationID == record.id }) else { continue }
                    guard root.rootPath == configurationRoot.projectRoot else {
                        throw WorkspaceDomainValidationError.invalidField("configuration project root mapping")
                    }
                }
            }
        }
        if !observations.isEmpty {
            try WorkspaceSnapshotValidator.validate(
                WorkspaceSnapshot(targetObservations: observations, activeProfileID: ""), mode: .localState)
        }
        if let mcpBindings {
            if let portable, let definitions = portable.mcpDefinitions {
                try WorkspaceMCPDefinitionValidation.validatePortable(definitions, artifacts: portable.artifacts)
            }
            // With a portable document present, an absent older-version field
            // means no definitions, not permission to accept unbound device data.
            try WorkspaceMCPDefinitionValidation.validateDevice(mcpBindings,
                definitions: portable.map { $0.mcpDefinitions ?? [] })
        }
        if let portable, portable.workspaceID != workspaceID {
            throw WorkspaceDomainValidationError.missingReference("device workspace ID")
        }
        try requireUnique(sourceLocations.map(\.sourceRootID), field: "device source roots")
        try requireUnique(destinations.map(\.id), field: "device destinations")
        try requireUnique(pendingPlanIDs, field: "pending plan IDs")
        try requireUnique(receiptIDs, field: "receipt IDs")

        let sourceIDs = portable.map { Set($0.sources.map(\.id)) }
        for source in sourceLocations {
            if let sourceIDs, !sourceIDs.contains(source.sourceRootID) {
                throw WorkspaceDomainValidationError.missingReference("device source root")
            }
            try WorkspaceDomainValidation.requireAbsolutePath(source.checkoutPath, field: "source checkout path")
            if let identity = source.worktreeIdentity {
                try WorkspaceDomainValidation.requireText(identity, field: "worktree identity", maximum: 1_024)
            }
            if let reference = source.credentialReferenceID {
                try WorkspaceDomainValidation.requireText(reference, field: "credential reference", maximum: 512)
            }
            if let revision = source.observedRevision {
                try WorkspaceDomainValidation.requireRevision(revision, field: "observed source revision")
            }
        }

        let projectIDs = portable.map { Set($0.logicalProjects.map(\.id)) }
        for destination in destinations {
            try WorkspaceDomainValidation.requireAbsolutePath(destination.resolvedPath, field: "destination path")
            switch destination.selector.scope {
            case .project, .localProject:
                guard destination.selector.logicalProjectID != nil else {
                    throw WorkspaceDomainValidationError.missingReference("project destination logical project")
                }
            case .user, .workspace, .managed, .account, .session:
                guard destination.selector.logicalProjectID == nil else {
                    throw WorkspaceDomainValidationError.invalidField("non-project destination logical project")
                }
            }
            if let projectID = destination.selector.logicalProjectID, let projectIDs, !projectIDs.contains(projectID) {
                throw WorkspaceDomainValidationError.missingReference("destination logical project")
            }
            if let deviceIDs = destination.selector.deviceIDs {
                try requireUnique(deviceIDs, field: "destination devices")
            }
        }

        let destinationIDs = Set(destinations.map(\.id))
        let artifactIDs = portable.map { Set($0.artifacts.map(\.identity.id)) }
        var baselineKeys: Set<BaselineKey> = []
        for baseline in deploymentBaselines {
            guard destinationIDs.contains(baseline.destinationID) else {
                throw WorkspaceDomainValidationError.missingReference("deployment destination")
            }
            if let artifactIDs, !artifactIDs.contains(baseline.artifactID) {
                throw WorkspaceDomainValidationError.missingReference("deployment artifact")
            }
            try WorkspaceDomainValidation.requireDigest(baseline.deployedContent.value, field: "deployment digest")
            guard baselineKeys.insert(.init(artifactID: baseline.artifactID, destinationID: baseline.destinationID)).inserted else {
                throw WorkspaceDomainValidationError.duplicate("deployment baseline")
            }
        }

        for evidence in capabilityEvidence {
            guard evidence.adapterContractVersion > 0 else {
                throw WorkspaceDomainValidationError.invalidField("adapter contract version")
            }
            try requireUnique(evidence.scopes, field: "capability scopes")
            if let version = evidence.installedClientVersion {
                try WorkspaceDomainValidation.requireText(version, field: "installed client version", maximum: 256)
            }
            if let transport = evidence.transport {
                try WorkspaceDomainValidation.requireText(transport, field: "capability transport", maximum: 128)
            }
            switch evidence.support {
            case .supported: break
            case .unsupported(let reason), .unknown(let reason):
                try WorkspaceDomainValidation.requireText(reason, field: "capability reason", maximum: 2_048)
            }
        }
    }

    func canonicalized() -> Self {
        var value = self
        value.configurationState = value.configurationState?.canonicalized()
        value.applicationState = value.applicationState?.canonicalized()
        value.inventoryState = value.inventoryState?.canonicalized()
        value.projectRoots?.sort { $0.projectID < $1.projectID }
        value.mcpBindings = value.mcpBindings?.map { binding in
            var binding = binding
            binding.credentialRequirementNames.sort()
            return binding
        }.sorted { $0.artifactID < $1.artifactID }
        value.sourceLocations.sort { $0.sourceRootID < $1.sourceRootID }
        value.destinations = value.destinations.map { destination in
            var destination = destination
            destination.selector.deviceIDs?.sort()
            return destination
        }.sorted { $0.id < $1.id }
        value.observations.sort {
            if $0.surface != $1.surface { return $0.surface.rawValue < $1.surface.rawValue }
            return $0.lastScannedAt < $1.lastScannedAt
        }
        value.observations = value.observations.map { observation in
            var observation = observation
            observation.lastScannedAt = WorkspaceDomainValidation.canonicalDate(observation.lastScannedAt)
            return observation
        }
        value.capabilityEvidence = value.capabilityEvidence.map { evidence in
            var evidence = evidence
            evidence.scopes.sort { $0.rawValue < $1.rawValue }
            evidence.observedAt = WorkspaceDomainValidation.canonicalDate(evidence.observedAt)
            return evidence
        }.sorted {
            let lhs = "\($0.surface.rawValue)|\($0.component.rawValue)|\($0.transport ?? "")|\($0.adapterContractVersion)"
            let rhs = "\($1.surface.rawValue)|\($1.component.rawValue)|\($1.transport ?? "")|\($1.adapterContractVersion)"
            return lhs < rhs
        }
        value.deploymentBaselines.sort {
            $0.artifactID == $1.artifactID ? $0.destinationID < $1.destinationID : $0.artifactID < $1.artifactID
        }
        value.pendingPlanIDs.sort()
        value.receiptIDs.sort()
        return value
    }

    private struct BaselineKey: Hashable {
        var artifactID: ArtifactID
        var destinationID: WorkspaceObjectID
    }

    private func requireUnique<T: Hashable>(_ values: [T], field: String) throws {
        guard Set(values).count == values.count else { throw WorkspaceDomainValidationError.duplicate(field) }
    }
}

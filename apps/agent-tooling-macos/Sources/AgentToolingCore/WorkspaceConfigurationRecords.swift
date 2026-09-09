import Foundation

public enum LegacyReferenceDomain: String, Codable, CaseIterable, Hashable, Sendable {
    case skill, plugin, mcpServer, configuration, collection, catalogSource, policy

    var isArtifact: Bool {
        switch self {
        case .skill, .plugin, .mcpServer: true
        case .configuration, .collection, .catalogSource, .policy: false
        }
    }
}

public struct LegacyReferenceKey: Codable, Hashable, Sendable {
    public var domain: LegacyReferenceDomain
    public var identifier: String
    /// Namespaces a managed-policy configuration whose legacy ID may equal a personal profile ID.
    public var ownerPolicyID: String?

    public init(domain: LegacyReferenceDomain, identifier: String, ownerPolicyID: String? = nil) {
        self.domain = domain
        self.identifier = identifier
        self.ownerPolicyID = ownerPolicyID
    }
}

public enum WorkspaceReferenceResolution: Codable, Hashable, Sendable {
    case artifact(ArtifactID)
    case object(WorkspaceObjectID)
    case unresolved
}

public struct WorkspaceReference: Codable, Hashable, Sendable {
    public var legacy: LegacyReferenceKey
    public var resolution: WorkspaceReferenceResolution

    public init(legacy: LegacyReferenceKey, resolution: WorkspaceReferenceResolution) {
        self.legacy = legacy
        self.resolution = resolution
    }
}

public struct WorkspaceMigrationIdentityEntry: Codable, Hashable, Sendable {
    public var legacy: LegacyReferenceKey
    /// The reserved UUID. Artifact references construct ArtifactID from this same UUID.
    public var objectID: WorkspaceObjectID

    public init(legacy: LegacyReferenceKey, objectID: WorkspaceObjectID) {
        self.legacy = legacy
        self.objectID = objectID
    }
}

public enum WorkspaceConfigurationOrigin: Codable, Hashable, Sendable {
    case personal
    case managedPolicy(policyID: WorkspaceObjectID)
}

public struct WorkspaceConfigurationCheckDefinition: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var manual: Bool

    public init(id: String, name: String, manual: Bool = false) {
        self.id = id
        self.name = name
        self.manual = manual
    }
}

public struct WorkspaceConfigurationTargetBinding: Codable, Hashable, Sendable {
    public var item: WorkspaceReference
    public var client: ClientKind
    public var enabled: Bool?

    public init(item: WorkspaceReference, client: ClientKind, enabled: Bool? = nil) {
        self.item = item
        self.client = client
        self.enabled = enabled
    }
}

public struct WorkspaceConfigurationRecord: Codable, Hashable, Sendable {
    public var id: WorkspaceObjectID
    public var name: String
    public var summary: String
    public var origin: WorkspaceConfigurationOrigin
    public var inheritedFrom: WorkspaceReference?
    public var scope: ToolingScope
    public var logicalProjectID: ArtifactID?
    public var enabledPlugins: [WorkspaceReference]
    public var requiredMCPs: [WorkspaceReference]
    public var requiredSkills: [WorkspaceReference]
    public var includedCollections: [WorkspaceReference]
    public var checkDefinitions: [WorkspaceConfigurationCheckDefinition]
    /// Nil inherits or reaches the legacy fallback; empty is an explicit replacement with no targets.
    public var targetBindings: [WorkspaceConfigurationTargetBinding]?

    public init(
        id: WorkspaceObjectID = WorkspaceObjectID(),
        name: String,
        summary: String = "",
        origin: WorkspaceConfigurationOrigin = .personal,
        inheritedFrom: WorkspaceReference? = nil,
        scope: ToolingScope = .user,
        logicalProjectID: ArtifactID? = nil,
        enabledPlugins: [WorkspaceReference] = [],
        requiredMCPs: [WorkspaceReference] = [],
        requiredSkills: [WorkspaceReference] = [],
        includedCollections: [WorkspaceReference] = [],
        checkDefinitions: [WorkspaceConfigurationCheckDefinition] = [],
        targetBindings: [WorkspaceConfigurationTargetBinding]? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.origin = origin
        self.inheritedFrom = inheritedFrom
        self.scope = scope
        self.logicalProjectID = logicalProjectID
        self.enabledPlugins = enabledPlugins
        self.requiredMCPs = requiredMCPs
        self.requiredSkills = requiredSkills
        self.includedCollections = includedCollections
        self.checkDefinitions = checkDefinitions
        self.targetBindings = targetBindings
    }
}

public struct WorkspaceManagedPolicyRecord: Codable, Hashable, Sendable {
    public var id: WorkspaceObjectID
    public var name: String
    public var requiredPlugins: [WorkspaceReference]
    public var requiredMCPs: [WorkspaceReference]
    public var blockedPlugins: [WorkspaceReference]
    public var configurations: [WorkspaceReference]

    public init(
        id: WorkspaceObjectID = WorkspaceObjectID(),
        name: String,
        requiredPlugins: [WorkspaceReference] = [],
        requiredMCPs: [WorkspaceReference] = [],
        blockedPlugins: [WorkspaceReference] = [],
        configurations: [WorkspaceReference] = []
    ) {
        self.id = id
        self.name = name
        self.requiredPlugins = requiredPlugins
        self.requiredMCPs = requiredMCPs
        self.blockedPlugins = blockedPlugins
        self.configurations = configurations
    }
}

public struct WorkspaceCollectionRecord: Codable, Hashable, Sendable {
    public var id: WorkspaceObjectID
    public var name: String
    public var summary: String
    public var items: [WorkspaceReference]
    public var createdAt: Date

    public init(
        id: WorkspaceObjectID = WorkspaceObjectID(), name: String, summary: String = "",
        items: [WorkspaceReference] = [], createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.items = items
        self.createdAt = createdAt
    }
}

public struct WorkspaceTagAssignment: Codable, Hashable, Sendable {
    public var item: WorkspaceReference
    public var tags: [String]

    public init(item: WorkspaceReference, tags: [String]) {
        self.item = item
        self.tags = tags
    }
}

public struct WorkspaceCatalogSourceRecord: Codable, Hashable, Sendable {
    public var id: WorkspaceObjectID
    public var name: String
    public var kind: SourceKind
    /// Credential-free HTTP(S) catalog identity. Local paths belong in device state.
    public var remoteLocation: String?
    public var isOptionalBackup: Bool

    public init(
        id: WorkspaceObjectID = WorkspaceObjectID(), name: String, kind: SourceKind,
        remoteLocation: String? = nil, isOptionalBackup: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.remoteLocation = remoteLocation
        self.isOptionalBackup = isOptionalBackup
    }
}

public enum WorkspaceLegacyRelationshipKind: String, Codable, Hashable, Sendable {
    case pluginSkill, pluginProfile, skillBundle
}

public struct WorkspaceLegacyRelationshipRecord: Codable, Hashable, Sendable {
    public var kind: WorkspaceLegacyRelationshipKind
    public var source: WorkspaceReference
    public var destination: WorkspaceReference

    public init(kind: WorkspaceLegacyRelationshipKind, source: WorkspaceReference, destination: WorkspaceReference) {
        self.kind = kind
        self.source = source
        self.destination = destination
    }
}

public struct WorkspaceConfigurationState: Codable, Hashable, Sendable {
    public var configurations: [WorkspaceConfigurationRecord]
    public var managedPolicies: [WorkspaceManagedPolicyRecord]
    public var collections: [WorkspaceCollectionRecord]
    public var tagAssignments: [WorkspaceTagAssignment]
    public var catalogSources: [WorkspaceCatalogSourceRecord]
    public var legacyRelationships: [WorkspaceLegacyRelationshipRecord]
    public var identityMap: [WorkspaceMigrationIdentityEntry]
    public var defaultConfigurationID: WorkspaceObjectID?

    public init(
        configurations: [WorkspaceConfigurationRecord] = [],
        managedPolicies: [WorkspaceManagedPolicyRecord] = [],
        collections: [WorkspaceCollectionRecord] = [],
        tagAssignments: [WorkspaceTagAssignment] = [],
        catalogSources: [WorkspaceCatalogSourceRecord] = [],
        legacyRelationships: [WorkspaceLegacyRelationshipRecord] = [],
        identityMap: [WorkspaceMigrationIdentityEntry] = [],
        defaultConfigurationID: WorkspaceObjectID? = nil
    ) {
        self.configurations = configurations
        self.managedPolicies = managedPolicies
        self.collections = collections
        self.tagAssignments = tagAssignments
        self.catalogSources = catalogSources
        self.legacyRelationships = legacyRelationships
        self.identityMap = identityMap
        self.defaultConfigurationID = defaultConfigurationID
    }

    func validate(artifacts: [ArtifactRecord], logicalProjects: [LogicalProjectRecord]) throws {
        try unique(configurations.map(\.id), "configuration IDs")
        try unique(managedPolicies.map(\.id), "policy IDs")
        try unique(collections.map(\.id), "collection IDs")
        try unique(catalogSources.map(\.id), "catalog source IDs")
        try unique(identityMap.map(\.legacy), "legacy aliases")
        try unique(identityMap.map(\.objectID), "legacy reserved identities")

        let objectIDs = configurations.map(\.id) + managedPolicies.map(\.id) + collections.map(\.id)
            + catalogSources.map(\.id)
        let allUUIDs = artifacts.map(\.identity.id.rawValue) + objectIDs.map(\.rawValue)
        try unique(allUUIDs, "workspace object identities")

        let artifactsByID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.identity.id, $0) })
        let configurationsByID = Dictionary(uniqueKeysWithValues: configurations.map { ($0.id, $0) })
        let policiesByID = Dictionary(uniqueKeysWithValues: managedPolicies.map { ($0.id, $0) })
        let collectionIDs = Set(collections.map(\.id))
        let catalogSourceIDs = Set(catalogSources.map(\.id))
        let projectIDs = Set(logicalProjects.map(\.id))
        let identityByLegacy = Dictionary(uniqueKeysWithValues: identityMap.map { ($0.legacy, $0) })
        var objectDomains: [WorkspaceObjectID: LegacyReferenceDomain] = [:]
        for id in configurationsByID.keys { objectDomains[id] = .configuration }
        for id in policiesByID.keys { objectDomains[id] = .policy }
        for id in collectionIDs { objectDomains[id] = .collection }
        for id in catalogSourceIDs { objectDomains[id] = .catalogSource }

        for allocation in identityMap {
            try validate(allocation.legacy)
            try validateAllocation(
                allocation, artifactsByID: artifactsByID, objectDomains: objectDomains)
        }
        for reference in allReferences() {
            try validateLiveResolution(
                reference, artifactsByID: artifactsByID, objectDomains: objectDomains,
                identityByLegacy: identityByLegacy)
        }

        if let defaultConfigurationID, configurationsByID[defaultConfigurationID] == nil {
            throw WorkspaceDomainValidationError.missingReference("default configuration")
        }

        for configuration in configurations {
            try text(configuration.name, "configuration name", 4_096)
            try optionalText(configuration.summary, "configuration summary", 65_536)
            guard let configurationIdentity = identityMap.first(where: {
                $0.legacy.domain == .configuration && $0.objectID == configuration.id
            }) else { throw WorkspaceDomainValidationError.missingReference("configuration identity alias") }
            switch configuration.scope {
            case .project, .localProject:
                guard let projectID = configuration.logicalProjectID, projectIDs.contains(projectID) else {
                    throw WorkspaceDomainValidationError.missingReference("configuration logical project")
                }
            case .user, .workspace, .managed, .account, .session:
                guard configuration.logicalProjectID == nil else {
                    throw WorkspaceDomainValidationError.invalidField("non-project configuration logical project")
                }
            }
            if let parent = configuration.inheritedFrom {
                try requireReference(parent, domain: .configuration, identityByLegacy: identityByLegacy, allowUnresolved: false)
                guard case .object(let parentID) = parent.resolution, configurationsByID[parentID] != nil else {
                    throw WorkspaceDomainValidationError.missingReference("configuration parent")
                }
            }
            switch configuration.origin {
            case .personal:
                guard configurationIdentity.legacy.ownerPolicyID == nil else {
                    throw WorkspaceDomainValidationError.invalidField("personal configuration owner namespace")
                }
            case .managedPolicy(let policyID):
                guard let policy = policiesByID[policyID],
                    let policyIdentity = identityMap.first(where: {
                        $0.legacy.domain == .policy && $0.objectID == policyID
                    }),
                    configurationIdentity.legacy.ownerPolicyID == policyIdentity.legacy.identifier,
                    policy.configurations.contains(where: {
                        if case .object(let id) = $0.resolution { return id == configuration.id }
                        return false
                    })
                else {
                    throw WorkspaceDomainValidationError.missingReference("configuration policy")
                }
            }
            try validateArtifactReferences(configuration.enabledPlugins, domain: .plugin, identityByLegacy: identityByLegacy)
            try validateArtifactReferences(configuration.requiredMCPs, domain: .mcpServer, identityByLegacy: identityByLegacy)
            try validateArtifactReferences(configuration.requiredSkills, domain: .skill, identityByLegacy: identityByLegacy)
            try validateReferences(configuration.includedCollections, domain: .collection, identityByLegacy: identityByLegacy)
            guard configuration.includedCollections.allSatisfy({
                if case .object(let id) = $0.resolution { return collectionIDs.contains(id) }
                return false
            }) else { throw WorkspaceDomainValidationError.missingReference("included collection") }
            try unique(configuration.checkDefinitions.map(\.id), "configuration checks")
            for check in configuration.checkDefinitions {
                try text(check.id, "configuration check ID", 512)
                try text(check.name, "configuration check name", 4_096)
            }
            if let bindings = configuration.targetBindings {
                try unique(bindings.map { TargetKey(reference: $0.item.legacy, client: $0.client) }, "target bindings")
                for binding in bindings {
                    guard binding.item.legacy.domain.isArtifact else {
                        throw WorkspaceDomainValidationError.invalidField("target binding item kind")
                    }
                    try requireReference(
                        binding.item, domain: binding.item.legacy.domain,
                        identityByLegacy: identityByLegacy, allowUnresolved: true)
                }
            }
        }
        try validateConfigurationCycles(configurationsByID)

        for policy in managedPolicies {
            try text(policy.name, "policy name", 4_096)
            guard identityMap.contains(where: { $0.legacy.domain == .policy && $0.objectID == policy.id }) else {
                throw WorkspaceDomainValidationError.missingReference("policy identity alias")
            }
            try validateArtifactReferences(policy.requiredPlugins, domain: .plugin, identityByLegacy: identityByLegacy)
            try validateArtifactReferences(policy.requiredMCPs, domain: .mcpServer, identityByLegacy: identityByLegacy)
            try validateArtifactReferences(policy.blockedPlugins, domain: .plugin, identityByLegacy: identityByLegacy)
            let required = Set(policy.requiredPlugins.map(\.legacy))
            guard required.isDisjoint(with: policy.blockedPlugins.map(\.legacy)) else {
                throw WorkspaceDomainValidationError.conflictingAssignment("managed policy plugin")
            }
            try validateReferences(policy.configurations, domain: .configuration, identityByLegacy: identityByLegacy)
            for reference in policy.configurations {
                guard case .object(let configurationID) = reference.resolution,
                    configurationsByID[configurationID]?.origin == .managedPolicy(policyID: policy.id)
                else { throw WorkspaceDomainValidationError.missingReference("policy configuration") }
            }
        }

        for collection in collections {
            try text(collection.name, "collection name", 4_096)
            try optionalText(collection.summary, "collection summary", 65_536)
            guard identityMap.contains(where: { $0.legacy.domain == .collection && $0.objectID == collection.id }) else {
                throw WorkspaceDomainValidationError.missingReference("collection identity alias")
            }
            try unique(collection.items.map(\.legacy), "collection items")
            for item in collection.items {
                guard item.legacy.domain.isArtifact else {
                    throw WorkspaceDomainValidationError.invalidField("collection item kind")
                }
                try requireReference(item, domain: item.legacy.domain, identityByLegacy: identityByLegacy, allowUnresolved: true)
            }
        }

        try unique(tagAssignments.map(\.item.legacy), "tag assignments")
        for assignment in tagAssignments {
            guard assignment.item.legacy.domain.isArtifact else {
                throw WorkspaceDomainValidationError.invalidField("tag item kind")
            }
            try requireReference(
                assignment.item, domain: assignment.item.legacy.domain,
                identityByLegacy: identityByLegacy, allowUnresolved: true)
            try unique(assignment.tags.map { $0.lowercased() }, "tags")
            for tag in assignment.tags {
                guard ToolingTag.normalized(tag) == tag else {
                    throw WorkspaceDomainValidationError.invalidField("tag")
                }
            }
        }

        for source in catalogSources {
            try text(source.name, "catalog source name", 4_096)
            guard identityMap.contains(where: { $0.legacy.domain == .catalogSource && $0.objectID == source.id }) else {
                throw WorkspaceDomainValidationError.missingReference("catalog source identity alias")
            }
            if let location = source.remoteLocation { try validateRemoteCatalog(location) }
        }

        try unique(legacyRelationships, "legacy relationships")
        for relationship in legacyRelationships {
            switch relationship.kind {
            case .pluginSkill:
                try requireReference(relationship.source, domain: .plugin, identityByLegacy: identityByLegacy, allowUnresolved: true)
                try requireReference(relationship.destination, domain: .skill, identityByLegacy: identityByLegacy, allowUnresolved: true)
            case .pluginProfile:
                try requireReference(relationship.source, domain: .plugin, identityByLegacy: identityByLegacy, allowUnresolved: true)
                try requireReference(relationship.destination, domain: .configuration, identityByLegacy: identityByLegacy, allowUnresolved: false)
            case .skillBundle:
                try requireReference(relationship.source, domain: .skill, identityByLegacy: identityByLegacy, allowUnresolved: true)
                try requireReference(relationship.destination, domain: .plugin, identityByLegacy: identityByLegacy, allowUnresolved: true)
            }
        }
    }

    func canonicalized() -> Self {
        var value = self
        value.configurations = value.configurations.map { configuration in
            var configuration = configuration
            configuration.enabledPlugins.sort(by: referenceSort)
            configuration.requiredMCPs.sort(by: referenceSort)
            configuration.requiredSkills.sort(by: referenceSort)
            configuration.includedCollections.sort(by: referenceSort)
            configuration.targetBindings?.sort {
                $0.item.legacy == $1.item.legacy
                    ? $0.client.rawValue < $1.client.rawValue : referenceSort($0.item, $1.item)
            }
            return configuration
        }.sorted { $0.id < $1.id }
        value.managedPolicies = value.managedPolicies.map { policy in
            var policy = policy
            policy.requiredPlugins.sort(by: referenceSort)
            policy.requiredMCPs.sort(by: referenceSort)
            policy.blockedPlugins.sort(by: referenceSort)
            policy.configurations.sort(by: referenceSort)
            return policy
        }.sorted { $0.id < $1.id }
        value.collections = value.collections.map { collection in
            var collection = collection
            collection.items.sort(by: referenceSort)
            collection.createdAt = WorkspaceDomainValidation.canonicalDate(collection.createdAt)
            return collection
        }.sorted { $0.id < $1.id }
        value.tagAssignments = value.tagAssignments.map { assignment in
            var assignment = assignment
            assignment.tags.sort()
            return assignment
        }.sorted { referenceSort($0.item, $1.item) }
        value.catalogSources.sort { $0.id < $1.id }
        value.legacyRelationships.sort {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.source != $1.source { return referenceSort($0.source, $1.source) }
            return referenceSort($0.destination, $1.destination)
        }
        value.identityMap.sort {
            legacyKeySort($0.legacy, $1.legacy)
        }
        return value
    }

    private struct TargetKey: Hashable { var reference: LegacyReferenceKey; var client: ClientKind }

    private func validateConfigurationCycles(_ configurations: [WorkspaceObjectID: WorkspaceConfigurationRecord]) throws {
        for id in configurations.keys {
            var visited: Set<WorkspaceObjectID> = []
            var current: WorkspaceObjectID? = id
            while let cursor = current {
                guard visited.insert(cursor).inserted else {
                    throw WorkspaceDomainValidationError.invalidField("configuration inheritance cycle")
                }
                if let parent = configurations[cursor]?.inheritedFrom,
                    case .object(let parentID) = parent.resolution { current = parentID }
                else { current = nil }
            }
        }
    }

    private func validateAllocation(
        _ allocation: WorkspaceMigrationIdentityEntry,
        artifactsByID: [ArtifactID: ArtifactRecord],
        objectDomains: [WorkspaceObjectID: LegacyReferenceDomain]
    ) throws {
        if allocation.legacy.domain.isArtifact {
            guard objectDomains[allocation.objectID] == nil else {
                throw WorkspaceDomainValidationError.duplicate("artifact and object identity")
            }
            let artifactID = ArtifactID(allocation.objectID.rawValue)
            if let artifact = artifactsByID[artifactID],
                !artifactKindMatches(artifact.identity.kind, allocation.legacy.domain)
            {
                throw WorkspaceDomainValidationError.invalidField("artifact legacy identity")
            }
            return
        }
        guard artifactsByID[ArtifactID(allocation.objectID.rawValue)] == nil,
            objectDomains[allocation.objectID] == allocation.legacy.domain
        else {
            throw WorkspaceDomainValidationError.invalidField("object legacy identity")
        }
    }

    private func validateLiveResolution(
        _ reference: WorkspaceReference,
        artifactsByID: [ArtifactID: ArtifactRecord],
        objectDomains: [WorkspaceObjectID: LegacyReferenceDomain],
        identityByLegacy: [LegacyReferenceKey: WorkspaceMigrationIdentityEntry]
    ) throws {
        switch reference.resolution {
        case .artifact(let id):
            guard reference.legacy.domain.isArtifact, let artifact = artifactsByID[id],
                artifactKindMatches(artifact.identity.kind, reference.legacy.domain)
            else { throw WorkspaceDomainValidationError.missingReference("resolved artifact") }
        case .object(let id):
            guard objectDomains[id] == reference.legacy.domain else {
                throw WorkspaceDomainValidationError.missingReference("resolved workspace object")
            }
        case .unresolved:
            guard reference.legacy.domain.isArtifact,
                let allocation = identityByLegacy[reference.legacy],
                artifactsByID[ArtifactID(allocation.objectID.rawValue)] == nil
            else {
                throw WorkspaceDomainValidationError.missingReference("unresolved workspace object")
            }
        }
    }

    private func allReferences() -> [WorkspaceReference] {
        var result: [WorkspaceReference] = []
        for configuration in configurations {
            if let parent = configuration.inheritedFrom { result.append(parent) }
            result += configuration.enabledPlugins + configuration.requiredMCPs + configuration.requiredSkills
                + configuration.includedCollections + (configuration.targetBindings?.map(\.item) ?? [])
        }
        for policy in managedPolicies {
            result += policy.requiredPlugins + policy.requiredMCPs + policy.blockedPlugins + policy.configurations
        }
        for collection in collections { result += collection.items }
        result += tagAssignments.map(\.item)
        for relationship in legacyRelationships { result += [relationship.source, relationship.destination] }
        return result
    }

    private func requireReference(
        _ reference: WorkspaceReference, domain: LegacyReferenceDomain,
        identityByLegacy: [LegacyReferenceKey: WorkspaceMigrationIdentityEntry], allowUnresolved: Bool
    ) throws {
        guard reference.legacy.domain == domain, let allocation = identityByLegacy[reference.legacy] else {
            throw WorkspaceDomainValidationError.missingReference("legacy reference")
        }
        switch reference.resolution {
        case .artifact(let id):
            guard domain.isArtifact, id.rawValue == allocation.objectID.rawValue else {
                throw WorkspaceDomainValidationError.invalidField("artifact reference identity")
            }
        case .object(let id):
            guard !domain.isArtifact, id == allocation.objectID else {
                throw WorkspaceDomainValidationError.invalidField("object reference identity")
            }
        case .unresolved where allowUnresolved && domain.isArtifact: break
        case .unresolved:
            throw WorkspaceDomainValidationError.missingReference("resolved legacy reference")
        }
    }

    private func validateArtifactReferences(
        _ references: [WorkspaceReference], domain: LegacyReferenceDomain,
        identityByLegacy: [LegacyReferenceKey: WorkspaceMigrationIdentityEntry]
    ) throws {
        try validateReferences(references, domain: domain, identityByLegacy: identityByLegacy, allowUnresolved: true)
    }

    private func validateReferences(
        _ references: [WorkspaceReference], domain: LegacyReferenceDomain,
        identityByLegacy: [LegacyReferenceKey: WorkspaceMigrationIdentityEntry], allowUnresolved: Bool = false
    ) throws {
        try unique(references.map(\.legacy), "legacy references")
        for reference in references {
            try requireReference(reference, domain: domain, identityByLegacy: identityByLegacy, allowUnresolved: allowUnresolved)
        }
    }

    private func validate(_ key: LegacyReferenceKey) throws {
        try text(key.identifier, "legacy identifier", 512)
        if let owner = key.ownerPolicyID {
            guard key.domain == .configuration else {
                throw WorkspaceDomainValidationError.invalidField("legacy owner namespace")
            }
            try text(owner, "legacy owner policy", 512)
        }
    }

    private func artifactKindMatches(_ kind: ArtifactKind, _ domain: LegacyReferenceDomain) -> Bool {
        switch domain {
        case .skill: kind == .skill
        case .plugin: kind == .package || kind == .nativePlugin
        case .mcpServer: kind == .mcpServer
        case .configuration, .collection, .catalogSource, .policy: false
        }
    }

    private func validateRemoteCatalog(_ value: String) throws {
        guard let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
            ["http", "https"].contains(scheme), parts.host?.isEmpty == false,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { throw WorkspaceDomainValidationError.invalidField("catalog source remote location") }
    }

    private func text(_ value: String, _ field: String, _ maximum: Int) throws {
        try WorkspaceDomainValidation.requireText(value, field: field, maximum: maximum)
    }

    private func optionalText(_ value: String, _ field: String, _ maximum: Int) throws {
        if !value.isEmpty { try text(value, field, maximum) }
    }

    private func unique<T: Hashable>(_ values: [T], _ field: String) throws {
        guard Set(values).count == values.count else { throw WorkspaceDomainValidationError.duplicate(field) }
    }
}

private func referenceSort(_ lhs: WorkspaceReference, _ rhs: WorkspaceReference) -> Bool {
    legacyKeySort(lhs.legacy, rhs.legacy)
}

private func legacyKeySort(_ left: LegacyReferenceKey, _ right: LegacyReferenceKey) -> Bool {
    if left.domain != right.domain { return left.domain.rawValue < right.domain.rawValue }
    if left.ownerPolicyID != right.ownerPolicyID { return (left.ownerPolicyID ?? "") < (right.ownerPolicyID ?? "") }
    return left.identifier < right.identifier
}

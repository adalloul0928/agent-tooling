import Foundation

/// Local bindings and observations for portable configuration intent. These
/// records never participate in the portable revision digest or Git sync.
public struct WorkspaceConfigurationDeviceState: Codable, Hashable, Sendable {
    public var activeConfigurationOverrideID: WorkspaceObjectID?
    public var configurationBindings: [ConfigurationDeviceBinding]
    public var checkObservations: [ConfigurationCheckObservation]
    public var catalogSources: [CatalogSourceDeviceState]
    public var policyImports: [ManagedPolicyDeviceImport]

    public init(
        activeConfigurationOverrideID: WorkspaceObjectID? = nil,
        configurationBindings: [ConfigurationDeviceBinding] = [],
        checkObservations: [ConfigurationCheckObservation] = [],
        catalogSources: [CatalogSourceDeviceState] = [],
        policyImports: [ManagedPolicyDeviceImport] = []
    ) {
        self.activeConfigurationOverrideID = activeConfigurationOverrideID
        self.configurationBindings = configurationBindings
        self.checkObservations = checkObservations
        self.catalogSources = catalogSources
        self.policyImports = policyImports
    }

    func validate(against portable: WorkspaceConfigurationState?) throws {
        func unique<T: Hashable>(_ values: [T], _ field: String) throws {
            guard Set(values).count == values.count else { throw WorkspaceDomainValidationError.duplicate(field) }
        }
        let configurations = portable.map { Set($0.configurations.map(\.id)) }
        func requireConfiguration(_ id: WorkspaceObjectID) throws {
            if let configurations, !configurations.contains(id) {
                throw WorkspaceDomainValidationError.missingReference("device configuration")
            }
        }
        if let activeConfigurationOverrideID { try requireConfiguration(activeConfigurationOverrideID) }
        try unique(configurationBindings.map(\.configurationID), "configuration device bindings")
        for binding in configurationBindings {
            try requireConfiguration(binding.configurationID)
            try WorkspaceDomainValidation.requireAbsolutePath(binding.projectRoot, field: "configuration project root")
        }
        try unique(checkObservations.map { CheckKey(configurationID: $0.configurationID, checkID: $0.checkID) }, "check observations")
        for observation in checkObservations {
            try requireConfiguration(observation.configurationID)
            try WorkspaceDomainValidation.requireText(observation.checkID, field: "check ID", maximum: 512)
            if let portable {
                guard portable.configurations.first(where: { $0.id == observation.configurationID })?
                    .checkDefinitions.contains(where: { $0.id == observation.checkID }) == true
                else { throw WorkspaceDomainValidationError.missingReference("device configuration check") }
            }
        }
        try unique(catalogSources.map(\.catalogSourceID), "catalog device state")
        let catalogIDs = portable.map { Set($0.catalogSources.map(\.id)) }
        for source in catalogSources {
            if let catalogIDs, !catalogIDs.contains(source.catalogSourceID) {
                throw WorkspaceDomainValidationError.missingReference("device catalog source")
            }
            if let location = source.localLocation {
                try WorkspaceDomainValidation.requireAbsolutePath(location, field: "local catalog location")
            }
        }
        try unique(policyImports.map(\.policyID), "policy imports")
        let policyIDs = portable.map { Set($0.managedPolicies.map(\.id)) }
        for policy in policyImports {
            if let policyIDs, !policyIDs.contains(policy.policyID) {
                throw WorkspaceDomainValidationError.missingReference("device managed policy")
            }
            try WorkspaceDomainValidation.requireAbsolutePath(policy.sourcePath, field: "policy import source")
        }
    }

    func canonicalized() -> Self {
        var value = self
        value.configurationBindings.sort { $0.configurationID < $1.configurationID }
        value.checkObservations.sort {
            $0.configurationID == $1.configurationID ? $0.checkID < $1.checkID : $0.configurationID < $1.configurationID
        }
        value.catalogSources = value.catalogSources.map {
            var source = $0
            source.lastRefreshedAt = source.lastRefreshedAt.map(WorkspaceDomainValidation.canonicalDate)
            return source
        }.sorted { $0.catalogSourceID < $1.catalogSourceID }
        value.policyImports = value.policyImports.map {
            var policy = $0
            policy.importedAt = WorkspaceDomainValidation.canonicalDate(policy.importedAt)
            return policy
        }.sorted { $0.policyID < $1.policyID }
        return value
    }

    private struct CheckKey: Hashable {
        let configurationID: WorkspaceObjectID
        let checkID: String
    }
}

public struct ConfigurationDeviceBinding: Codable, Hashable, Sendable {
    public var configurationID: WorkspaceObjectID
    public var projectRoot: String

    public init(configurationID: WorkspaceObjectID, projectRoot: String) {
        self.configurationID = configurationID
        self.projectRoot = projectRoot
    }
}

public struct ConfigurationCheckObservation: Codable, Hashable, Sendable {
    public var configurationID: WorkspaceObjectID
    public var checkID: String
    public var detail: String
    public var state: HealthState

    public init(configurationID: WorkspaceObjectID, checkID: String, detail: String, state: HealthState) {
        self.configurationID = configurationID
        self.checkID = checkID
        self.detail = detail
        self.state = state
    }
}

public struct CatalogSourceDeviceState: Codable, Hashable, Sendable {
    public var catalogSourceID: WorkspaceObjectID
    public var localLocation: String?
    public var lastRefreshedAt: Date?
    public var lastRevision: String?
    public var trustSummary: String

    public init(
        catalogSourceID: WorkspaceObjectID, localLocation: String? = nil,
        lastRefreshedAt: Date? = nil, lastRevision: String? = nil, trustSummary: String
    ) {
        self.catalogSourceID = catalogSourceID
        self.localLocation = localLocation
        self.lastRefreshedAt = lastRefreshedAt
        self.lastRevision = lastRevision
        self.trustSummary = trustSummary
    }
}

public struct ManagedPolicyDeviceImport: Codable, Hashable, Sendable {
    public var policyID: WorkspaceObjectID
    public var sourcePath: String
    public var importedAt: Date

    public init(policyID: WorkspaceObjectID, sourcePath: String, importedAt: Date) {
        self.policyID = policyID
        self.sourcePath = sourcePath
        self.importedAt = importedAt
    }
}

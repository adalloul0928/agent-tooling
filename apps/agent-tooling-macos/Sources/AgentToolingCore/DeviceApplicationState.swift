import Foundation

public struct DeviceProjectRootBinding: Codable, Hashable, Sendable {
    public var projectID: ArtifactID
    public var rootPath: String
    public init(projectID: ArtifactID, rootPath: String) { self.projectID = projectID; self.rootPath = rootPath }
}

public struct DeviceWorkspacePreferences: Codable, Hashable, Sendable {
    public var automaticallyCheckHealth: Bool
    public var enabledClients: [ClientKind]

    public init(automaticallyCheckHealth: Bool = true, enabledClients: [ClientKind] = ClientKind.allCases) {
        self.automaticallyCheckHealth = automaticallyCheckHealth
        self.enabledClients = enabledClients.sorted { $0.rawValue < $1.rawValue }
    }

    public init(_ value: WorkspacePreferences) {
        self.init(automaticallyCheckHealth: value.automaticallyCheckHealth, enabledClients: Array(value.enabledClients))
    }

    public var workspacePreferences: WorkspacePreferences {
        .init(automaticallyCheckHealth: automaticallyCheckHealth, enabledClients: Set(enabledClients))
    }
}

public struct DeviceApplicationState: Codable, Hashable, Sendable {
    public var preferences: DeviceWorkspacePreferences
    public var backupConfiguration: BackupConfiguration
    public var encryptedSyncConfiguration: EncryptedSyncConfiguration
    public var importedRepositoryPath: String?
    public var activities: [ActivityReceipt]
    public var operationReceipts: [OperationReceipt]
    public var accountSurfaces: [AccountSurface]
    public var connectors: [ConnectorRecord]
    public var marketplacePackages: [MarketplacePackage]
    public var catalogSourceIDs: [UUID]

    public init(
        preferences: DeviceWorkspacePreferences = .init(), backupConfiguration: BackupConfiguration = .init(),
        encryptedSyncConfiguration: EncryptedSyncConfiguration = .init(), importedRepositoryPath: String? = nil,
        activities: [ActivityReceipt] = [], operationReceipts: [OperationReceipt] = [],
        accountSurfaces: [AccountSurface] = [], connectors: [ConnectorRecord] = [],
        marketplacePackages: [MarketplacePackage] = [], catalogSourceIDs: [UUID] = []
    ) {
        self.preferences = preferences; self.backupConfiguration = backupConfiguration
        self.encryptedSyncConfiguration = encryptedSyncConfiguration; self.importedRepositoryPath = importedRepositoryPath
        self.activities = activities; self.operationReceipts = operationReceipts
        self.accountSurfaces = accountSurfaces; self.connectors = connectors; self.marketplacePackages = marketplacePackages
        self.catalogSourceIDs = catalogSourceIDs.sorted { $0.uuidString < $1.uuidString }
    }

    public init(snapshot: WorkspaceSnapshot) {
        self.init(preferences: .init(snapshot.preferences), backupConfiguration: snapshot.backupConfiguration,
                  encryptedSyncConfiguration: snapshot.encryptedSyncConfiguration,
                  importedRepositoryPath: snapshot.importedRepositoryPath, activities: snapshot.activities,
                  operationReceipts: snapshot.operationReceipts, accountSurfaces: snapshot.accountSurfaces,
                  connectors: snapshot.connectors, marketplacePackages: snapshot.marketplacePackages,
                  catalogSourceIDs: snapshot.sources.map(\.id))
    }

    public func apply(to snapshot: inout WorkspaceSnapshot) throws {
        try validate()
        snapshot.preferences = preferences.workspacePreferences; snapshot.backupConfiguration = backupConfiguration
        snapshot.encryptedSyncConfiguration = encryptedSyncConfiguration; snapshot.importedRepositoryPath = importedRepositoryPath
        snapshot.activities = activities; snapshot.operationReceipts = operationReceipts
        snapshot.accountSurfaces = accountSurfaces; snapshot.connectors = connectors; snapshot.marketplacePackages = marketplacePackages
    }

    public func validate(against configuration: WorkspaceConfigurationState? = nil) throws {
        guard Set(catalogSourceIDs).count == catalogSourceIDs.count else {
            throw WorkspaceDomainValidationError.duplicate("device application catalog sources")
        }
        if let configuration {
            let live = Set(configuration.catalogSources.map(\.id))
            let mapped = Set(configuration.identityMap.compactMap { entry -> UUID? in
                guard entry.legacy.domain == .catalogSource, live.contains(entry.objectID) else { return nil }
                return UUID(uuidString: entry.legacy.identifier)
            })
            guard Set(catalogSourceIDs).isSubset(of: mapped) else {
                throw WorkspaceDomainValidationError.missingReference("device application catalog source")
            }
        }
        guard Set(preferences.enabledClients).count == preferences.enabledClients.count else {
            throw WorkspaceDomainValidationError.duplicate("device preference clients")
        }
        var snapshot = WorkspaceSnapshot()
        snapshot.activeProfileID = ""; snapshot.preferences = preferences.workspacePreferences
        snapshot.backupConfiguration = backupConfiguration; snapshot.encryptedSyncConfiguration = encryptedSyncConfiguration
        snapshot.importedRepositoryPath = importedRepositoryPath; snapshot.activities = activities; snapshot.operationReceipts = operationReceipts
        snapshot.accountSurfaces = accountSurfaces; snapshot.connectors = connectors; snapshot.marketplacePackages = marketplacePackages
        snapshot.sources = catalogSourceIDs.map { .init(id: $0, name: "Migration catalog", kind: .localFolder, location: "/device/catalog") }
        try WorkspaceSnapshotValidator.validate(snapshot, mode: .localState)
    }

    func canonicalized() -> Self {
        var value = self
        let date = WorkspaceDomainValidation.canonicalDate
        value.preferences.enabledClients.sort { $0.rawValue < $1.rawValue }
        value.backupConfiguration.lastExportAt = value.backupConfiguration.lastExportAt.map(date)
        value.encryptedSyncConfiguration.lastExportAt = value.encryptedSyncConfiguration.lastExportAt.map(date)
        value.encryptedSyncConfiguration.lastImportAt = value.encryptedSyncConfiguration.lastImportAt.map(date)
        value.activities = value.activities.map { receipt in
            var receipt = receipt
            receipt.date = date(receipt.date)
            return receipt
        }
        value.operationReceipts = value.operationReceipts.map { receipt in
            var receipt = receipt
            receipt.createdAt = date(receipt.createdAt)
            receipt.results = receipt.results.map { result in
                var result = result
                result.startedAt = date(result.startedAt)
                result.finishedAt = date(result.finishedAt)
                return result
            }
            return receipt
        }
        value.accountSurfaces = value.accountSurfaces.map { surface in
            var surface = surface
            surface.lastVerifiedAt = surface.lastVerifiedAt.map(date)
            return surface
        }
        value.connectors = value.connectors.map { connector in
            var connector = connector
            connector.bindings = connector.bindings.map { binding in
                var binding = binding
                binding.lastVerifiedAt = binding.lastVerifiedAt.map(date)
                return binding
            }
            return connector
        }
        value.marketplacePackages = value.marketplacePackages.map { package in
            var package = package
            if let update = package.lastUpdate {
                package.lastUpdate = .init(date: date(update.date), origin: update.origin)
            }
            return package
        }
        value.accountSurfaces.sort { $0.id.uuidString < $1.id.uuidString }
        value.connectors.sort { $0.id.uuidString < $1.id.uuidString }
        value.marketplacePackages.sort { $0.id < $1.id }
        value.catalogSourceIDs.sort { $0.uuidString < $1.uuidString }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case preferences, backupConfiguration, encryptedSyncConfiguration, importedRepositoryPath
        case activities, operationReceipts, accountSurfaces, connectors, marketplacePackages, catalogSourceIDs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preferences = try c.decode(DeviceWorkspacePreferences.self, forKey: .preferences)
        backupConfiguration = try c.decode(BackupConfiguration.self, forKey: .backupConfiguration)
        encryptedSyncConfiguration = try c.decode(EncryptedSyncConfiguration.self, forKey: .encryptedSyncConfiguration)
        importedRepositoryPath = try c.decodeIfPresent(String.self, forKey: .importedRepositoryPath)
        activities = try c.decode([ActivityReceipt].self, forKey: .activities)
        operationReceipts = try c.decode([OperationReceipt].self, forKey: .operationReceipts)
        accountSurfaces = try c.decode([AccountSurface].self, forKey: .accountSurfaces)
        connectors = try c.decode([ConnectorRecord].self, forKey: .connectors)
        marketplacePackages = try c.decode([DeviceMarketplaceSnapshot].self, forKey: .marketplacePackages).map(\.package)
        catalogSourceIDs = try c.decode([UUID].self, forKey: .catalogSourceIDs)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(preferences, forKey: .preferences)
        try c.encode(backupConfiguration, forKey: .backupConfiguration)
        try c.encode(encryptedSyncConfiguration, forKey: .encryptedSyncConfiguration)
        try c.encodeIfPresent(importedRepositoryPath, forKey: .importedRepositoryPath)
        try c.encode(activities, forKey: .activities)
        try c.encode(operationReceipts, forKey: .operationReceipts)
        try c.encode(accountSurfaces, forKey: .accountSurfaces)
        try c.encode(connectors, forKey: .connectors)
        try c.encode(marketplacePackages.map(DeviceMarketplaceSnapshot.init), forKey: .marketplacePackages)
        try c.encode(catalogSourceIDs, forKey: .catalogSourceIDs)
    }
}

import Foundation

public struct DeviceProjectRootBinding: Codable, Hashable, Sendable {
    public var projectID: ArtifactID
    public var rootPath: String
    public init(projectID: ArtifactID, rootPath: String) {
        self.projectID = projectID
        self.rootPath = rootPath
    }
}

/// How often this Mac looks for newer versions of what the library holds.
public enum UpdateCheckCadence: String, Codable, CaseIterable, Hashable, Sendable {
    /// Each time the app opens, alongside the launch scan.
    case onOpen
    /// Once a day at most, on the first open after the previous check aged out.
    case daily
    /// Only when somebody presses Check.
    case manual

    public var title: String {
        switch self {
        case .onOpen: "When the app opens"
        case .daily: "Once a day"
        case .manual: "Only when I ask"
        }
    }

    /// The rule in a sentence, for the settings row that holds the picker.
    public var detail: String {
        switch self {
        case .onOpen: "Sources are compared each time Agent Tooling opens."
        case .daily: "Sources are compared at most once a day, when Agent Tooling opens."
        case .manual: "Sources are compared only when you press Check now."
        }
    }

    /// Whether a check that last ran at `last` is due at `now`.
    public func isDue(lastChecked last: Date?, now: Date) -> Bool {
        switch self {
        case .manual: false
        case .onOpen: true
        case .daily: last.map { now.timeIntervalSince($0) >= 24 * 60 * 60 } ?? true
        }
    }
}

/// What happens once an update for one kind of tool is known about.
public enum UpdateInstallPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    /// Install it, leave a receipt, say so afterwards.
    case automatic
    /// Show it and wait for the person to press Update.
    case ask

    public var title: String {
        switch self {
        case .automatic: "Install automatically"
        case .ask: "Ask me first"
        }
    }
}

/// The update policy, one setting per kind of tool so a person can let skills
/// flow and keep a hand on connections, or the other way round. Each kind has
/// its own entry because the risk of a silent update differs: a skill is text
/// an agent reads, a connection is a program an agent talks to.
public struct UpdatePolicy: Codable, Hashable, Sendable {
    public var cadence: UpdateCheckCadence
    public var skills: UpdateInstallPolicy
    public var plugins: UpdateInstallPolicy
    public var mcpServers: UpdateInstallPolicy

    public init(
        cadence: UpdateCheckCadence = .onOpen,
        skills: UpdateInstallPolicy = .ask,
        plugins: UpdateInstallPolicy = .ask,
        mcpServers: UpdateInstallPolicy = .ask
    ) {
        self.cadence = cadence
        self.skills = skills
        self.plugins = plugins
        self.mcpServers = mcpServers
    }

    public func policy(for kind: ToolingItemKind) -> UpdateInstallPolicy {
        switch kind {
        case .skill: skills
        case .plugin: plugins
        case .mcpServer: mcpServers
        }
    }

    public mutating func setPolicy(_ policy: UpdateInstallPolicy, for kind: ToolingItemKind) {
        switch kind {
        case .skill: skills = policy
        case .plugin: plugins = policy
        case .mcpServer: mcpServers = policy
        }
    }

    /// Whether any kind installs on its own, which is what decides if a check
    /// may write anything without a person watching.
    public var installsAnythingAutomatically: Bool {
        [skills, plugins, mcpServers].contains(.automatic)
    }
}

/// Which of the assistant's own runs this Mac allows. Each switch is separate,
/// because each says something different about what is read and whether it
/// leaves this Mac.
public struct AssistantRunConsent: Codable, Hashable, Sendable {
    /// The weekly checkup review: the signed-in assistant reads the checkup,
    /// the apps' configuration folders and redacted conversation summaries.
    /// Leaves this Mac.
    public var weeklyReview: Bool
    /// The daily deep dive: redacted summaries of recent history sent to the
    /// assistant. Leaves this Mac.
    public var dailyDeepDive: Bool
    /// The local keyword scan of the same history, which keeps counts only.
    /// Stays on this Mac.
    public var localInsights: Bool

    public init(weeklyReview: Bool, dailyDeepDive: Bool, localInsights: Bool) {
        self.weeklyReview = weeklyReview
        self.dailyDeepDive = dailyDeepDive
        self.localInsights = localInsights
    }

    /// Nothing runs on its own. What a new setup records until somebody turns
    /// a run on.
    public static let off = AssistantRunConsent(weeklyReview: false, dailyDeepDive: false, localInsights: false)

    /// What a workspace made before this choice existed has been doing: the
    /// weekly review and the daily deep dive, and no local scan.
    public static let existingBehaviour = AssistantRunConsent(weeklyReview: true, dailyDeepDive: true, localInsights: false)
}

public struct DeviceWorkspacePreferences: Codable, Hashable, Sendable {
    public var automaticallyCheckHealth: Bool
    public var enabledClients: [ClientKind]
    /// The clients somebody explicitly chose on this Mac, or `nil` when nobody
    /// has chosen yet. Distinct from `enabledClients` (kept for older builds):
    /// with no explicit choice the app shows the clients its scan actually
    /// found, and an undetected client stays out of the way until it is either
    /// installed or deliberately turned on.
    public var chosenClients: [ClientKind]?
    /// Folders somebody explicitly recorded as holding client tools, on top of
    /// the fixed install roots the locator always checks. Absolute paths only;
    /// recorded through a reviewed action, never inferred from `PATH` silently.
    public var customToolDirectories: [String]?
    /// When to look for updates and what to do with them. `nil` in a store
    /// written before the setting existed, and read as the default then.
    public var updatePolicy: UpdatePolicy?
    /// When this Mac last looked for updates, for the daily cadence.
    public var lastUpdateCheck: Date?
    /// Folders this Mac looks in for projects, besides the ones Claude Code has
    /// run in: each one's immediate children that look like projects (a Git
    /// checkout, or agent configuration at the top). Device-local, like the
    /// folder bindings: paths on this Mac mean nothing on another.
    public var projectScanRoots: [String]?
    /// Which of the assistant's own runs this Mac allows. `nil` in a store
    /// made before the choice existed, which keeps doing what it did; a new
    /// setup records an explicit value.
    public var assistantRuns: AssistantRunConsent?
    /// Whether project discovery also reads the folder names in Claude Code's
    /// history. `nil` in a store made before the choice existed, read as on.
    public var findsProjectsFromClaudeHistory: Bool?

    public init(
        automaticallyCheckHealth: Bool = true,
        enabledClients: [ClientKind] = ClientKind.allCases,
        chosenClients: [ClientKind]? = nil,
        customToolDirectories: [String]? = nil,
        updatePolicy: UpdatePolicy? = nil,
        lastUpdateCheck: Date? = nil,
        projectScanRoots: [String]? = nil,
        assistantRuns: AssistantRunConsent? = nil,
        findsProjectsFromClaudeHistory: Bool? = nil
    ) {
        self.automaticallyCheckHealth = automaticallyCheckHealth
        self.enabledClients = enabledClients.sorted { $0.rawValue < $1.rawValue }
        self.chosenClients = chosenClients?.sorted { $0.rawValue < $1.rawValue }
        self.customToolDirectories = customToolDirectories
        self.updatePolicy = updatePolicy
        self.lastUpdateCheck = lastUpdateCheck
        self.projectScanRoots = projectScanRoots
        self.assistantRuns = assistantRuns
        self.findsProjectsFromClaudeHistory = findsProjectsFromClaudeHistory
    }

    /// The policy in force: what was chosen, else the default.
    public var effectiveUpdatePolicy: UpdatePolicy { updatePolicy ?? UpdatePolicy() }

    /// The runs in force: what was chosen, else what a workspace made before
    /// the choice existed has always done.
    public var effectiveAssistantRuns: AssistantRunConsent { assistantRuns ?? .existingBehaviour }

    public init(_ value: WorkspacePreferences) {
        self.init(automaticallyCheckHealth: value.automaticallyCheckHealth, enabledClients: Array(value.enabledClients))
    }

    public var workspacePreferences: WorkspacePreferences {
        .init(automaticallyCheckHealth: automaticallyCheckHealth, enabledClients: Set(enabledClients))
    }
}

/// Explicit `chosenClients` takes precedence. Legacy `enabledClients` may be
/// a saved default and cannot establish an explicit choice.
/// Otherwise show clients with runnable commands in the latest scan; config
/// files alone do not qualify. Before a scan, or if none are runnable, show
/// every client so setup remains accessible.
public enum ClientVisibilityPolicy {
    public static func effectiveEnabledClients(
        preferences: DeviceWorkspacePreferences?,
        observations: [TargetObservation]
    ) -> Set<ClientKind> {
        if let chosen = preferences?.chosenClients { return Set(chosen) }
        guard !observations.isEmpty else { return Set(ClientKind.allCases) }
        let present = Set(observations.filter(\.commandAvailable).compactMap { $0.surface.client })
        return present.isEmpty ? Set(ClientKind.allCases) : present
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
        self.preferences = preferences
        self.backupConfiguration = backupConfiguration
        self.encryptedSyncConfiguration = encryptedSyncConfiguration
        self.importedRepositoryPath = importedRepositoryPath
        self.activities = activities
        self.operationReceipts = operationReceipts
        self.accountSurfaces = accountSurfaces
        self.connectors = connectors
        self.marketplacePackages = marketplacePackages
        self.catalogSourceIDs = catalogSourceIDs.sorted { $0.uuidString < $1.uuidString }
    }

    public init(snapshot: WorkspaceSnapshot) {
        self.init(
            preferences: .init(snapshot.preferences), backupConfiguration: snapshot.backupConfiguration,
            encryptedSyncConfiguration: snapshot.encryptedSyncConfiguration,
            importedRepositoryPath: snapshot.importedRepositoryPath, activities: snapshot.activities,
            operationReceipts: snapshot.operationReceipts, accountSurfaces: snapshot.accountSurfaces,
            connectors: snapshot.connectors, marketplacePackages: snapshot.marketplacePackages,
            catalogSourceIDs: snapshot.sources.map(\.id))
    }

    public func apply(to snapshot: inout WorkspaceSnapshot) throws {
        try validate()
        snapshot.preferences = preferences.workspacePreferences
        snapshot.backupConfiguration = backupConfiguration
        snapshot.encryptedSyncConfiguration = encryptedSyncConfiguration
        snapshot.importedRepositoryPath = importedRepositoryPath
        snapshot.activities = activities
        snapshot.operationReceipts = operationReceipts
        snapshot.accountSurfaces = accountSurfaces
        snapshot.connectors = connectors
        snapshot.marketplacePackages = marketplacePackages
    }

    public func validate(against configuration: WorkspaceConfigurationState? = nil) throws {
        guard Set(catalogSourceIDs).count == catalogSourceIDs.count else {
            throw WorkspaceDomainValidationError.duplicate("device application catalog sources")
        }
        if let configuration {
            let live = Set(configuration.catalogSources.map(\.id))
            let mapped = Set(
                configuration.identityMap.compactMap { entry -> UUID? in
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
        if let chosen = preferences.chosenClients {
            guard Set(chosen).count == chosen.count else {
                throw WorkspaceDomainValidationError.duplicate("device chosen clients")
            }
        }
        if let directories = preferences.customToolDirectories {
            guard Set(directories).count == directories.count else {
                throw WorkspaceDomainValidationError.duplicate("device custom tool directories")
            }
            for directory in directories {
                try WorkspaceDomainValidation.requireAbsolutePath(directory, field: "device custom tool directory")
            }
        }
        var snapshot = WorkspaceSnapshot()
        snapshot.activeProfileID = ""
        snapshot.preferences = preferences.workspacePreferences
        snapshot.backupConfiguration = backupConfiguration
        snapshot.encryptedSyncConfiguration = encryptedSyncConfiguration
        snapshot.importedRepositoryPath = importedRepositoryPath
        snapshot.activities = activities
        snapshot.operationReceipts = operationReceipts
        snapshot.accountSurfaces = accountSurfaces
        snapshot.connectors = connectors
        snapshot.marketplacePackages = marketplacePackages
        snapshot.sources = catalogSourceIDs.map {
            .init(id: $0, name: "Migration catalog", kind: .localFolder, location: "/device/catalog")
        }
        try WorkspaceSnapshotValidator.validate(snapshot, mode: .localState)
    }

    func canonicalized() -> Self {
        var value = self
        let date = WorkspaceDomainValidation.canonicalDate
        value.preferences.enabledClients.sort { $0.rawValue < $1.rawValue }
        value.preferences.chosenClients?.sort { $0.rawValue < $1.rawValue }
        value.preferences.customToolDirectories?.sort()
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

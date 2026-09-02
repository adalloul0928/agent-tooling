import Foundation

public enum ToolingScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case user
    case project
    case localProject
    case workspace
    case managed
    case account
    case session

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .user: "This Mac"
        case .project: "Project"
        case .localProject: "This project only"
        case .workspace: "Workspace"
        case .managed: "Managed"
        case .account: "Account"
        case .session: "Current session"
        }
    }
}

public typealias ClientScope = ToolingScope

public enum TargetSurface: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case claudeDesktop
    case claudeCloud
    case codexCLI
    case codexDesktop
    case codexCloud
    case geminiCLI
    case geminiIDE
    case geminiCloud

    public var id: String { rawValue }
    public var client: ClientKind? {
        switch self {
        case .claudeCode, .claudeDesktop, .claudeCloud: .claude
        case .codexCLI, .codexDesktop, .codexCloud: .codex
        case .geminiCLI, .geminiIDE, .geminiCloud: .gemini
        }
    }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .claudeCloud: "Claude.ai"
        case .codexCLI: "Codex CLI"
        case .codexDesktop: "Codex Desktop"
        case .codexCloud: "Codex cloud"
        case .geminiCLI: "Gemini CLI"
        case .geminiIDE: "Gemini IDE"
        case .geminiCloud: "Gemini web"
        }
    }

    public var isCloud: Bool {
        switch self {
        case .claudeCloud, .codexCloud, .geminiCloud: true
        default: false
        }
    }
}

public typealias ClientTarget = TargetSurface

public enum ComponentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case skill
    case plugin
    case mcpServer
    case connector
    case agent
    case command
    case hook
    case profile

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .mcpServer: "MCP server"
        default: rawValue.capitalized
        }
    }
}

public enum LifecycleState: String, Codable, CaseIterable, Sendable {
    case discovered
    case reviewed
    case installed
    case configured
    case authenticated
    case enabled
    case active
    case verified
    case manual
    case unsupported
}

public struct TargetCapabilities: Codable, Hashable, Sendable {
    public var supportsPluginInstall: Bool
    public var supportsProjectScope: Bool
    public var supportsLocalMarketplace: Bool
    public var supportsMCPAuthentication: Bool
    public var supportsConnectorDiscovery: Bool
    public var requiresNewSession: Bool
    public var requiresRestart: Bool
    public var supportsMachineReadableOutput: Bool

    public init(
        supportsPluginInstall: Bool,
        supportsProjectScope: Bool,
        supportsLocalMarketplace: Bool,
        supportsMCPAuthentication: Bool,
        supportsConnectorDiscovery: Bool,
        requiresNewSession: Bool,
        requiresRestart: Bool,
        supportsMachineReadableOutput: Bool
    ) {
        self.supportsPluginInstall = supportsPluginInstall
        self.supportsProjectScope = supportsProjectScope
        self.supportsLocalMarketplace = supportsLocalMarketplace
        self.supportsMCPAuthentication = supportsMCPAuthentication
        self.supportsConnectorDiscovery = supportsConnectorDiscovery
        self.requiresNewSession = requiresNewSession
        self.requiresRestart = requiresRestart
        self.supportsMachineReadableOutput = supportsMachineReadableOutput
    }
}

public struct ObservedSkillMetadata: Codable, Hashable, Sendable {
    public var path: String
    public var source: String
    public var providerPluginID: String?

    public init(path: String, source: String, providerPluginID: String? = nil) {
        self.path = path
        self.source = source
        self.providerPluginID = providerPluginID
    }
}

public struct ObservedPluginMetadata: Codable, Hashable, Sendable {
    public var name: String
    public var source: String
    public var scope: String
    public var revision: String?
    public var enabled: Bool
    public var skillIDs: [String]
    public var mcpServerIDs: [String]

    public init(
        name: String,
        source: String,
        scope: String,
        revision: String? = nil,
        enabled: Bool,
        skillIDs: [String] = [],
        mcpServerIDs: [String] = []
    ) {
        self.name = name
        self.source = source
        self.scope = scope
        self.revision = revision
        self.enabled = enabled
        self.skillIDs = skillIDs
        self.mcpServerIDs = mcpServerIDs
    }
}

public struct ObservedMCPMetadata: Codable, Hashable, Sendable {
    public var transport: String
    public var authentication: String
    public var source: String
    public var enabled: Bool

    public init(transport: String, authentication: String, source: String, enabled: Bool = true) {
        self.transport = transport
        self.authentication = authentication
        self.source = source
        self.enabled = enabled
    }
}

public struct TargetObservation: Identifiable, Codable, Hashable, Sendable {
    public var id: String { surface.rawValue }
    public var surface: TargetSurface
    public var installed: Bool
    public var commandAvailable: Bool
    public var version: String?
    public var configurationPaths: [String]
    public var discoveredSkills: [String]
    public var discoveredPlugins: [String]
    public var discoveredMCPServers: [String]
    public var skillMetadata: [String: ObservedSkillMetadata]
    public var pluginMetadata: [String: ObservedPluginMetadata]
    public var mcpMetadata: [String: ObservedMCPMetadata]
    public var capabilities: TargetCapabilities
    public var lastScannedAt: Date
    public var notes: [String]

    /// A configuration file can be observed even when the command-line app is
    /// absent. Command-based actions must use this value rather than `installed`.
    public var isCommandAvailable: Bool { commandAvailable }

    public init(
        surface: TargetSurface,
        installed: Bool,
        commandAvailable: Bool? = nil,
        version: String? = nil,
        configurationPaths: [String] = [],
        discoveredSkills: [String] = [],
        discoveredPlugins: [String] = [],
        discoveredMCPServers: [String] = [],
        skillMetadata: [String: ObservedSkillMetadata] = [:],
        pluginMetadata: [String: ObservedPluginMetadata] = [:],
        mcpMetadata: [String: ObservedMCPMetadata] = [:],
        capabilities: TargetCapabilities,
        lastScannedAt: Date = .now,
        notes: [String] = []
    ) {
        self.surface = surface
        self.installed = installed
        self.commandAvailable = commandAvailable ?? (version != nil)
        self.version = version
        self.configurationPaths = configurationPaths
        self.discoveredSkills = discoveredSkills
        self.discoveredPlugins = discoveredPlugins
        self.discoveredMCPServers = discoveredMCPServers
        self.skillMetadata = skillMetadata
        self.pluginMetadata = pluginMetadata
        self.mcpMetadata = mcpMetadata
        self.capabilities = capabilities
        self.lastScannedAt = lastScannedAt
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case surface, installed, commandAvailable, version, configurationPaths, discoveredSkills, discoveredPlugins, discoveredMCPServers
        case skillMetadata, pluginMetadata, mcpMetadata, capabilities, lastScannedAt, notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surface = try container.decode(TargetSurface.self, forKey: .surface)
        installed = try container.decode(Bool.self, forKey: .installed)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        commandAvailable = try container.decodeIfPresent(Bool.self, forKey: .commandAvailable) ?? (version != nil)
        configurationPaths = try container.decodeIfPresent([String].self, forKey: .configurationPaths) ?? []
        discoveredSkills = try container.decodeIfPresent([String].self, forKey: .discoveredSkills) ?? []
        discoveredPlugins = try container.decodeIfPresent([String].self, forKey: .discoveredPlugins) ?? []
        discoveredMCPServers = try container.decodeIfPresent([String].self, forKey: .discoveredMCPServers) ?? []
        skillMetadata = try container.decodeIfPresent([String: ObservedSkillMetadata].self, forKey: .skillMetadata) ?? [:]
        pluginMetadata = try container.decodeIfPresent([String: ObservedPluginMetadata].self, forKey: .pluginMetadata) ?? [:]
        mcpMetadata = try container.decodeIfPresent([String: ObservedMCPMetadata].self, forKey: .mcpMetadata) ?? [:]
        capabilities = try container.decode(TargetCapabilities.self, forKey: .capabilities)
        lastScannedAt = try container.decodeIfPresent(Date.self, forKey: .lastScannedAt) ?? .now
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

public struct WorkspaceSnapshot: Codable, Sendable {
    public var skills: [Skill]
    public var mcpServers: [MCPServer]
    public var plugins: [Plugin]
    public var profiles: [ToolingProfile]
    public var activities: [ActivityReceipt]
    public var operationReceipts: [OperationReceipt]
    public var targetObservations: [TargetObservation]
    public var sources: [ToolingSource]
    public var marketplacePackages: [MarketplacePackage]
    public var accountSurfaces: [AccountSurface]
    public var connectors: [ConnectorRecord]
    public var activeProfileID: String
    public var importedRepositoryPath: String?
    public var backupConfiguration: BackupConfiguration
    public var encryptedSyncConfiguration: EncryptedSyncConfiguration
    public var preferences: WorkspacePreferences
    public var managedPolicies: [ManagedPolicy]
    /// Reusable shelves a configuration can be built from. Added after the
    /// first shipping snapshot format, so it decodes as empty for older state.
    public var collections: [ToolingCollection]
    /// Tags live beside the inventory, not inside it, because observed
    /// records are rebuilt on every setup check.
    public var tagAssignments: [TagAssignment]

    public init(
        skills: [Skill] = [],
        mcpServers: [MCPServer] = [],
        plugins: [Plugin] = [],
        profiles: [ToolingProfile] = [],
        activities: [ActivityReceipt] = [],
        operationReceipts: [OperationReceipt] = [],
        targetObservations: [TargetObservation] = [],
        sources: [ToolingSource] = [],
        marketplacePackages: [MarketplacePackage] = [],
        accountSurfaces: [AccountSurface] = [],
        connectors: [ConnectorRecord] = [],
        activeProfileID: String = "local-library",
        importedRepositoryPath: String? = nil,
        backupConfiguration: BackupConfiguration = .init(),
        encryptedSyncConfiguration: EncryptedSyncConfiguration = .init(),
        preferences: WorkspacePreferences = .init(),
        managedPolicies: [ManagedPolicy] = [],
        collections: [ToolingCollection] = [],
        tagAssignments: [TagAssignment] = []
    ) {
        self.skills = skills
        self.mcpServers = mcpServers
        self.plugins = plugins
        self.profiles = profiles
        self.activities = activities
        self.operationReceipts = operationReceipts
        self.targetObservations = targetObservations
        self.sources = sources
        self.marketplacePackages = marketplacePackages
        self.accountSurfaces = accountSurfaces
        self.connectors = connectors
        self.activeProfileID = activeProfileID
        self.importedRepositoryPath = importedRepositoryPath
        self.backupConfiguration = backupConfiguration
        self.encryptedSyncConfiguration = encryptedSyncConfiguration
        self.preferences = preferences
        self.managedPolicies = managedPolicies
        self.collections = collections
        self.tagAssignments = tagAssignments
    }

    private enum CodingKeys: String, CodingKey {
        case skills, mcpServers, plugins, profiles, activities, operationReceipts, targetObservations, sources, marketplacePackages,
            accountSurfaces, connectors, activeProfileID, importedRepositoryPath, backupConfiguration, encryptedSyncConfiguration,
            preferences, managedPolicies, collections, tagAssignments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skills = try container.decodeIfPresent([Skill].self, forKey: .skills) ?? []
        mcpServers = try container.decodeIfPresent([MCPServer].self, forKey: .mcpServers) ?? []
        plugins = try container.decodeIfPresent([Plugin].self, forKey: .plugins) ?? []
        profiles = try container.decodeIfPresent([ToolingProfile].self, forKey: .profiles) ?? []
        activities = try container.decodeIfPresent([ActivityReceipt].self, forKey: .activities) ?? []
        operationReceipts = try container.decodeIfPresent([OperationReceipt].self, forKey: .operationReceipts) ?? []
        targetObservations = try container.decodeIfPresent([TargetObservation].self, forKey: .targetObservations) ?? []
        sources = try container.decodeIfPresent([ToolingSource].self, forKey: .sources) ?? []
        marketplacePackages = try container.decodeIfPresent([MarketplacePackage].self, forKey: .marketplacePackages) ?? []
        accountSurfaces = try container.decodeIfPresent([AccountSurface].self, forKey: .accountSurfaces) ?? []
        connectors = try container.decodeIfPresent([ConnectorRecord].self, forKey: .connectors) ?? []
        activeProfileID = try container.decodeIfPresent(String.self, forKey: .activeProfileID) ?? "local-library"
        importedRepositoryPath = try container.decodeIfPresent(String.self, forKey: .importedRepositoryPath)
        backupConfiguration = try container.decodeIfPresent(BackupConfiguration.self, forKey: .backupConfiguration) ?? .init()
        encryptedSyncConfiguration =
            try container.decodeIfPresent(EncryptedSyncConfiguration.self, forKey: .encryptedSyncConfiguration) ?? .init()
        preferences = try container.decodeIfPresent(WorkspacePreferences.self, forKey: .preferences) ?? .init()
        managedPolicies = try container.decodeIfPresent([ManagedPolicy].self, forKey: .managedPolicies) ?? []
        collections = try container.decodeIfPresent([ToolingCollection].self, forKey: .collections) ?? []
        tagAssignments = try container.decodeIfPresent([TagAssignment].self, forKey: .tagAssignments) ?? []
    }
}

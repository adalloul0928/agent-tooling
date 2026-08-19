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

public enum SourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case localFolder
    case gitRepository
    case claudeMarketplace
    case openAIPluginDirectory
    case geminiExtensionGallery
    case agentPlugins
    case mcpRegistry

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .localFolder: "Local folder"
        case .gitRepository: "Git repository"
        case .claudeMarketplace: "Claude marketplace"
        case .openAIPluginDirectory: "OpenAI plugin directory"
        case .geminiExtensionGallery: "Gemini extension gallery"
        case .agentPlugins: "Agent Plugins"
        case .mcpRegistry: "MCP registry"
        }
    }
}

public struct ToolingSource: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: SourceKind
    public var location: String
    public var isOptionalBackup: Bool
    public var lastRefreshedAt: Date?
    public var lastRevision: String?
    public var trustSummary: String

    public init(
        id: UUID = UUID(),
        name: String,
        kind: SourceKind,
        location: String,
        isOptionalBackup: Bool = false,
        lastRefreshedAt: Date? = nil,
        lastRevision: String? = nil,
        trustSummary: String = "Not reviewed"
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.location = location
        self.isOptionalBackup = isOptionalBackup
        self.lastRefreshedAt = lastRefreshedAt
        self.lastRevision = lastRevision
        self.trustSummary = trustSummary
    }
}

public struct MarketplacePackage: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var publisher: String
    public var summary: String
    public var sourceID: UUID?
    public var sourceName: String
    public var revision: String?
    public var license: String?
    public var components: Set<ComponentKind>
    public var supportedClients: Set<ClientKind>
    public var authentication: String?
    public var hasExecutableContent: Bool
    public var trustSummary: String
    public var location: String
    public var isInstalled: Bool
    public var nativeInstalls: [NativeInstall]

    public init(
        id: String,
        name: String,
        publisher: String,
        summary: String,
        sourceID: UUID? = nil,
        sourceName: String,
        revision: String? = nil,
        license: String? = nil,
        components: Set<ComponentKind>,
        supportedClients: Set<ClientKind>,
        authentication: String? = nil,
        hasExecutableContent: Bool = false,
        trustSummary: String = "Review required",
        location: String,
        isInstalled: Bool = false,
        nativeInstalls: [NativeInstall] = []
    ) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.summary = summary
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.revision = revision
        self.license = license
        self.components = components
        self.supportedClients = supportedClients
        self.authentication = authentication
        self.hasExecutableContent = hasExecutableContent
        self.trustSummary = trustSummary
        self.location = location
        self.isInstalled = isInstalled
        self.nativeInstalls = nativeInstalls
    }

    public var installedClients: Set<ClientKind> {
        Set(nativeInstalls.filter { $0.reportsInstalled(in: self) }.map(\.client))
    }
}

/// A vendor-provided installation route. Packages can expose more than one
/// route, but Agent Tooling only executes the one the user explicitly chooses.
public struct NativeInstall: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(client.rawValue):\(executable):\(arguments.joined(separator: "\u{1F}"))" }
    public var client: ClientKind
    public var executable: String
    public var arguments: [String]
    public var removalArguments: [String]?
    public var scope: ToolingScope
    public var detail: String
    /// Installation is client-specific. This stays optional so snapshots made
    /// before route-level state was introduced remain decodable.
    public var isInstalled: Bool?

    public init(
        client: ClientKind,
        executable: String,
        arguments: [String],
        removalArguments: [String]? = nil,
        scope: ToolingScope = .user,
        detail: String,
        isInstalled: Bool? = nil
    ) {
        self.client = client
        self.executable = executable
        self.arguments = arguments
        self.removalArguments = removalArguments
        self.scope = scope
        self.detail = detail
        self.isInstalled = isInstalled
    }

    /// A legacy package-level flag is unambiguous only when there is one route.
    public func reportsInstalled(in package: MarketplacePackage) -> Bool {
        isInstalled ?? (package.nativeInstalls.count == 1 && package.isInstalled)
    }
}

public enum OperationKind: String, Codable, CaseIterable, Sendable {
    case scan
    case createSkill
    case installSkill
    case installPlugin
    case configureMCP
    case importSource
    case exportBackup
    case restoreBackup
    case exportEncryptedSync
    case restoreEncryptedSync
    case doctor
    case guidedAccountCheck
}

public enum OperationStepKind: String, Codable, CaseIterable, Sendable {
    case createDirectory
    case verifyCleanGitRepository
    case writeFile
    case writeEncryptedArchive
    case copyDirectory
    case replaceManagedLibrary
    case command
    case scan
    case openURL
    case manual
}

public struct OperationStep: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: OperationStepKind
    public var title: String
    public var detail: String
    public var executable: String?
    public var arguments: [String]
    public var sourcePath: String?
    /// SHA-256 of a reviewed source tree. Copy operations recompute this from
    /// the staged copy before committing so a changed source cannot bypass the
    /// review sheet.
    public var sourceFingerprint: String?
    public var destinationPath: String?
    /// Optional working directory for a native command. The engine accepts it
    /// only when it exactly matches the separately reviewed project root.
    public var currentDirectoryPath: String?
    /// The user-selected project root that authorizes a project-scoped skill
    /// destination. It is intentionally carried on the reviewed operation
    /// step instead of broadening the engine's global write allowlist.
    public var projectRootPath: String?
    public var contents: String?
    public var url: String?
    public var isReversible: Bool
    public var requiresUserAction: Bool
    /// Preflight and integrity checks stop the plan when they fail. Ordinary
    /// client-specific steps continue so one unavailable client does not hide
    /// successful work completed for another client.
    public var stopsOnFailure: Bool?

    public init(
        id: UUID = UUID(),
        kind: OperationStepKind,
        title: String,
        detail: String,
        executable: String? = nil,
        arguments: [String] = [],
        sourcePath: String? = nil,
        sourceFingerprint: String? = nil,
        destinationPath: String? = nil,
        currentDirectoryPath: String? = nil,
        projectRootPath: String? = nil,
        contents: String? = nil,
        url: String? = nil,
        isReversible: Bool = true,
        requiresUserAction: Bool = false,
        stopsOnFailure: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.executable = executable
        self.arguments = arguments
        self.sourcePath = sourcePath
        self.sourceFingerprint = sourceFingerprint
        self.destinationPath = destinationPath
        self.currentDirectoryPath = currentDirectoryPath
        self.projectRootPath = projectRootPath
        self.contents = contents
        self.url = url
        self.isReversible = isReversible
        self.requiresUserAction = requiresUserAction
        self.stopsOnFailure = stopsOnFailure ? true : nil
    }

    public var shouldStopOnFailure: Bool { stopsOnFailure == true }

    public var renderedCommand: String? {
        guard let executable else { return nil }
        let command = ([executable] + arguments).map(Self.shellEscaped).joined(separator: " ")
        return SensitiveValueRedactor.redact(command)
    }

    private static func shellEscaped(_ value: String) -> String {
        value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            ? value : "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}

enum SensitiveValueRedactor {
    private static let credentialPatterns = [
        "(?i)https?://[^/@\\s]+@",
        "(?i)https?://[^\\s?#]+\\?[^\\s#]*(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|token|secret|password)=[^&\\s#]+",
        "(?im)(^|[ \\t])--?(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|token|secret|password)(?:=|[ \\t]+)[^\\s]+",
        "(?i)(api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|token|secret|password)\\s*[:=]\\s*[^\\s]+",
        "(?i)bearer\\s+[A-Za-z0-9._~+/-]+",
        "sk-[A-Za-z0-9_-]{16,}",
    ]

    static func containsCredentialValue(in text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return credentialPatterns.contains { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
            return expression.firstMatch(in: text, range: range) != nil
        }
    }

    static func redact(_ text: String) -> String {
        var value = text
        let replacements: [(pattern: String, replacement: String)] = [
            ("(?i)(https?://)[^/@\\s]+@", "$1[redacted]@"),
            ("(?i)(https?://[^\\s?#]+)\\?[^\\s#]+", "$1?[redacted]"),
            (
                "(?im)(^|[ \\t])(--?(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|token|secret|password)(?:=|[ \\t]+))[^\\s]+",
                "$1$2[redacted]"
            ),
            (
                "(?i)(api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|token|secret|password)\\s*[:=]\\s*[^\\s]+",
                "$1=[redacted]"
            ),
            (
                "(?m)(^|[ \\t])([A-Z0-9_]*(?:API_KEY|ACCESS_TOKEN|AUTH_TOKEN|CLIENT_SECRET|PASSWORD|SECRET|TOKEN))[ \\t]+[^\\s]+",
                "$1$2 [redacted]"
            ),
            ("(?i)bearer\\s+[A-Za-z0-9._~+/-]+", "Bearer [redacted]"),
            ("sk-[A-Za-z0-9_-]+", "[redacted]"),
        ]
        for replacement in replacements {
            guard let expression = try? NSRegularExpression(pattern: replacement.pattern) else { continue }
            let range = NSRange(value.startIndex..., in: value)
            value = expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement.replacement)
        }
        return value
    }
}

public struct OperationPlan: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: OperationKind
    public var title: String
    public var summary: String
    public var targetSurfaces: [TargetSurface]
    public var scope: ToolingScope
    public var steps: [OperationStep]
    public var createdAt: Date
    public var requiresConfirmation: Bool

    public init(
        id: UUID = UUID(),
        kind: OperationKind,
        title: String,
        summary: String,
        targetSurfaces: [TargetSurface] = [],
        scope: ToolingScope = .user,
        steps: [OperationStep],
        createdAt: Date = .now,
        requiresConfirmation: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.targetSurfaces = targetSurfaces
        self.scope = scope
        self.steps = steps
        self.createdAt = createdAt
        self.requiresConfirmation = requiresConfirmation
    }
}

public enum OperationStepStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case succeeded
    case failed
    case skipped
    case manual
}

public struct OperationStepResult: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var stepID: UUID
    public var status: OperationStepStatus
    public var output: String
    public var startedAt: Date
    public var finishedAt: Date

    public init(id: UUID = UUID(), stepID: UUID, status: OperationStepStatus, output: String, startedAt: Date, finishedAt: Date) {
        self.id = id
        self.stepID = stepID
        self.status = status
        self.output = output
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct OperationReceipt: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var planID: UUID
    public var kind: OperationKind
    public var title: String
    public var state: HealthState
    public var targetSurfaces: [TargetSurface]
    public var results: [OperationStepResult]
    public var createdAt: Date
    public var verificationSummary: String

    public init(
        id: UUID = UUID(),
        planID: UUID,
        kind: OperationKind,
        title: String,
        state: HealthState,
        targetSurfaces: [TargetSurface],
        results: [OperationStepResult],
        createdAt: Date = .now,
        verificationSummary: String
    ) {
        self.id = id
        self.planID = planID
        self.kind = kind
        self.title = title
        self.state = state
        self.targetSurfaces = targetSurfaces
        self.results = results
        self.createdAt = createdAt
        self.verificationSummary = verificationSummary
    }
}

public struct AccountSurface: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var surface: TargetSurface
    public var name: String
    public var status: LifecycleState
    public var guidance: String
    public var verificationURL: String?
    public var lastVerifiedAt: Date?

    public init(
        id: UUID = UUID(),
        surface: TargetSurface,
        name: String,
        status: LifecycleState,
        guidance: String,
        verificationURL: String? = nil,
        lastVerifiedAt: Date? = nil
    ) {
        self.id = id
        self.surface = surface
        self.name = name
        self.status = status
        self.guidance = guidance
        self.verificationURL = verificationURL
        self.lastVerifiedAt = lastVerifiedAt
    }
}

/// Connector metadata is intentionally separate from credentials. The record
/// says which product owns authorization and where it is expected to appear;
/// passwords, OAuth refresh tokens, and secret values never enter WorkspaceStore.
public enum ConnectionOwner: String, Codable, CaseIterable, Identifiable, Sendable {
    case localClient
    case account
    case externalSecretManager
    case organizationAdmin

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .localClient: "Local client"
        case .account: "Product account"
        case .externalSecretManager: "Secret manager"
        case .organizationAdmin: "Organization admin"
        }
    }
}

public struct ConnectionBinding: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var target: TargetSurface
    public var scope: ToolingScope
    public var status: LifecycleState
    public var guidance: String
    public var lastVerifiedAt: Date?

    public init(
        id: UUID = UUID(), target: TargetSurface, scope: ToolingScope, status: LifecycleState = .manual, guidance: String,
        lastVerifiedAt: Date? = nil
    ) {
        self.id = id
        self.target = target
        self.scope = scope
        self.status = status
        self.guidance = guidance
        self.lastVerifiedAt = lastVerifiedAt
    }
}

public struct ConnectorRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var provider: String
    public var ownership: ConnectionOwner
    public var description: String
    public var secretReferenceNames: [String]
    public var bindings: [ConnectionBinding]

    public init(
        id: UUID = UUID(), name: String, provider: String, ownership: ConnectionOwner, description: String,
        secretReferenceNames: [String] = [], bindings: [ConnectionBinding]
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.ownership = ownership
        self.description = description
        self.secretReferenceNames = secretReferenceNames
        self.bindings = bindings
    }
}

public struct BackupConfiguration: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var location: String?
    public var remoteName: String?
    public var lastExportAt: Date?

    public init(isEnabled: Bool = false, location: String? = nil, remoteName: String? = nil, lastExportAt: Date? = nil) {
        self.isEnabled = isEnabled
        self.location = location
        self.remoteName = remoteName
        self.lastExportAt = lastExportAt
    }
}

public struct EncryptedSyncConfiguration: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var location: String?
    public var lastExportAt: Date?
    public var lastImportAt: Date?

    public init(isEnabled: Bool = false, location: String? = nil, lastExportAt: Date? = nil, lastImportAt: Date? = nil) {
        self.isEnabled = isEnabled
        self.location = location
        self.lastExportAt = lastExportAt
        self.lastImportAt = lastImportAt
    }
}

public struct WorkspacePreferences: Codable, Hashable, Sendable {
    public var automaticallyCheckHealth: Bool

    public init(automaticallyCheckHealth: Bool = true) {
        self.automaticallyCheckHealth = automaticallyCheckHealth
    }

    private enum CodingKeys: String, CodingKey {
        case confirmWrites
        case automaticallyCheckHealth
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `confirmWrites` was a user preference in early local snapshots. It
        // is intentionally decoded and ignored now that write review is a
        // product invariant.
        _ = try container.decodeIfPresent(Bool.self, forKey: .confirmWrites)
        automaticallyCheckHealth = try container.decodeIfPresent(Bool.self, forKey: .automaticallyCheckHealth) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(automaticallyCheckHealth, forKey: .automaticallyCheckHealth)
    }
}

/// Portable, admin-authored desired-state policy. The source itself is chosen
/// by the organization (for example a checked-out repository or managed sync
/// folder); this app imports a reviewed local copy and never fetches policy in
/// the background.
public struct ManagedPolicy: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var sourcePath: String
    public var importedAt: Date
    public var requiredPluginIDs: [String]
    public var requiredMCPIDs: [String]
    public var blockedPluginIDs: [String]
    public var profiles: [ToolingProfile]

    public init(
        id: String, name: String, sourcePath: String, importedAt: Date = .now, requiredPluginIDs: [String] = [],
        requiredMCPIDs: [String] = [], blockedPluginIDs: [String] = [], profiles: [ToolingProfile] = []
    ) {
        self.id = id
        self.name = name
        self.sourcePath = sourcePath
        self.importedAt = importedAt
        self.requiredPluginIDs = requiredPluginIDs
        self.requiredMCPIDs = requiredMCPIDs
        self.blockedPluginIDs = blockedPluginIDs
        self.profiles = profiles
    }
}

public struct BackupConflict: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(kind):\(identifier)" }
    public var kind: String
    public var identifier: String
    public var localSummary: String
    public var backupSummary: String

    public init(kind: String, identifier: String, localSummary: String, backupSummary: String) {
        self.kind = kind
        self.identifier = identifier
        self.localSummary = localSummary
        self.backupSummary = backupSummary
    }
}

public struct BackupImportPreview: Sendable {
    public var backupURL: URL
    public var snapshot: WorkspaceSnapshot
    public var lock: BackupLock
    public var conflicts: [BackupConflict]
    public var plan: OperationPlan

    public init(backupURL: URL, snapshot: WorkspaceSnapshot, lock: BackupLock, conflicts: [BackupConflict], plan: OperationPlan) {
        self.backupURL = backupURL
        self.snapshot = snapshot
        self.lock = lock
        self.conflicts = conflicts
        self.plan = plan
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
        managedPolicies: [ManagedPolicy] = []
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
    }

    private enum CodingKeys: String, CodingKey {
        case skills, mcpServers, plugins, profiles, activities, operationReceipts, targetObservations, sources, marketplacePackages,
            accountSurfaces, connectors, activeProfileID, importedRepositoryPath, backupConfiguration, encryptedSyncConfiguration,
            preferences, managedPolicies
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
    }
}

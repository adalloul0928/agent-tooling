import Foundation

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
    public var provenance: PackageProvenance?
    public var requestedCredentialNames: [String]?
    public var ownership: PackageOwnership?
    public var updateStatus: PackageUpdateStatus?
    public var conflicts: [PackageConflict]?

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
        nativeInstalls: [NativeInstall] = [],
        provenance: PackageProvenance? = nil,
        requestedCredentialNames: [String]? = nil,
        ownership: PackageOwnership? = nil,
        updateStatus: PackageUpdateStatus? = nil,
        conflicts: [PackageConflict]? = nil
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
        self.provenance = provenance
        self.requestedCredentialNames = requestedCredentialNames
        self.ownership = ownership
        self.updateStatus = updateStatus
        self.conflicts = conflicts
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

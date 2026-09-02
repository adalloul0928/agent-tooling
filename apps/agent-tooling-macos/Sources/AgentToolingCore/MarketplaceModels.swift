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
    /// The only update time the app can defend, together with what produced it.
    /// `nil` means no catalog or file system fact was observed — never "old".
    public var lastUpdate: PackageUpdateRecord?
    /// Tools the publisher declared for an MCP server. `nil` means the catalog
    /// published no tool list at all, which reads differently from a server
    /// that declares zero tools, so the two are never collapsed.
    public var tools: [MCPToolDescriptor]?

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
        conflicts: [PackageConflict]? = nil,
        lastUpdate: PackageUpdateRecord? = nil,
        tools: [MCPToolDescriptor]? = nil
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
        self.lastUpdate = lastUpdate
        self.tools = tools
    }

    public var installedClients: Set<ClientKind> {
        Set(nativeInstalls.filter { $0.reportsInstalled(in: self) }.map(\.client))
    }

    /// The catalog this listing came from. Remote providers record it in
    /// provenance; the native client catalogs are recognized by the identifier
    /// prefix they are published under, and anything else is a folder or Git
    /// checkout the user added.
    public var catalogKind: SourceKind? {
        if let kind = provenance?.source.kind { return kind }
        if id.hasPrefix("claude:") { return .claudeMarketplace }
        if id.hasPrefix("codex:") { return .openAIPluginDirectory }
        if id.hasPrefix("mcp-registry:") { return .mcpRegistry }
        return nil
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

/// An update time and the observation that produced it. The two origins are
/// different claims — a catalog's own record versus a file on this Mac — so the
/// origin travels with the date and is stated wherever the date is shown.
public struct PackageUpdateRecord: Codable, Hashable, Sendable {
    public enum Origin: String, Codable, CaseIterable, Sendable {
        case catalogListing
        case localFiles

        /// Written to read as a clause directly after the date.
        public var measurement: String {
            switch self {
            case .catalogListing: "the date the catalog recorded for this listing"
            case .localFiles: "the newest file modification time in the package folder on this Mac"
            }
        }

        public var displayName: String {
            switch self {
            case .catalogListing: "Catalog listing"
            case .localFiles: "Local files"
            }
        }
    }

    public var date: Date
    public var origin: Origin

    public init(date: Date, origin: Origin) {
        self.date = date
        self.origin = origin
    }

    public var summary: String {
        "\(date.formatted(date: .abbreviated, time: .omitted)) — \(origin.measurement)."
    }
}

/// MCP's own tool annotations. Every hint is optional on purpose: an absent
/// hint is an absent claim, and the app never fills one in for the publisher.
public struct MCPToolAnnotations: Codable, Hashable, Sendable {
    public var readOnly: Bool?
    public var destructive: Bool?
    public var idempotent: Bool?
    public var openWorld: Bool?

    public init(readOnly: Bool? = nil, destructive: Bool? = nil, idempotent: Bool? = nil, openWorld: Bool? = nil) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
        self.openWorld = openWorld
    }

    public var isEmpty: Bool {
        readOnly == nil && destructive == nil && idempotent == nil && openWorld == nil
    }

    /// The labels a person should see, in review order: the destructive claim
    /// first, then the reassuring ones. Only declared hints appear.
    public var declaredLabels: [String] {
        var labels: [String] = []
        if destructive == true { labels.append("Destructive") }
        if readOnly == true { labels.append("Read-only") }
        if readOnly == false { labels.append("Writes") }
        if destructive == false { labels.append("Non-destructive") }
        if idempotent == true { labels.append("Idempotent") }
        if idempotent == false { labels.append("Not idempotent") }
        if openWorld == true { labels.append("Open world") }
        if openWorld == false { labels.append("Closed world") }
        return labels
    }
}

/// One property of a tool's input or output schema. Only a field's name and
/// declared type are kept; defaults and examples are dropped at decode time so
/// no value from a catalog can reach a display or a plan.
public struct MCPSchemaField: Identifiable, Codable, Hashable, Sendable {
    public var name: String
    public var type: String?
    public var isRequired: Bool
    public var isSecretLike: Bool

    public var id: String { name }

    public init(name: String, type: String? = nil, isRequired: Bool = false, isSecretLike: Bool? = nil) {
        self.name = name
        self.type = type
        self.isRequired = isRequired
        self.isSecretLike = isSecretLike ?? SecretFieldMasking.isSecretLike(name)
    }
}

/// A tool an MCP server declares in its catalog listing. This is the
/// publisher's own description; Agent Tooling never starts a server to
/// enumerate its tools, so every display says where the list came from.
public struct MCPToolDescriptor: Identifiable, Codable, Hashable, Sendable {
    public var name: String
    public var title: String?
    public var summary: String?
    public var annotations: MCPToolAnnotations
    public var inputFields: [MCPSchemaField]
    public var outputFields: [MCPSchemaField]
    /// Distinguishes "no schema was published" from "a schema with no fields".
    public var declaresInputSchema: Bool
    public var declaresOutputSchema: Bool

    public var id: String { name }

    public init(
        name: String,
        title: String? = nil,
        summary: String? = nil,
        annotations: MCPToolAnnotations = MCPToolAnnotations(),
        inputFields: [MCPSchemaField] = [],
        outputFields: [MCPSchemaField] = [],
        declaresInputSchema: Bool = false,
        declaresOutputSchema: Bool = false
    ) {
        self.name = name
        self.title = title
        self.summary = summary
        self.annotations = annotations
        self.inputFields = inputFields
        self.outputFields = outputFields
        self.declaresInputSchema = declaresInputSchema
        self.declaresOutputSchema = declaresOutputSchema
    }

    public var displayName: String { title ?? name }
}

/// Agent Tooling stores no secret values anywhere, so a field whose name reads
/// like a credential is masked in every display and only ever identified by
/// name. The match is deliberately generous: masking one field too many costs a
/// person nothing, and missing one costs them a secret.
public enum SecretFieldMasking {
    public static let placeholder = "••••••••"

    private static let secretTokens: Set<String> = [
        "key", "keys", "apikey", "accesskey", "privatekey", "secretkey", "token", "tokens", "accesstoken", "authtoken",
        "refreshtoken", "secret", "secrets", "clientsecret", "password", "passwd", "pwd", "passphrase", "credential",
        "credentials", "auth", "authorization", "bearer", "signature", "session",
    ]

    public static func isSecretLike(_ name: String) -> Bool {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if secretTokens.contains(normalized) { return true }
        return tokens(in: name).contains { secretTokens.contains($0) }
    }

    /// A masked rendering for anything that could be a value. Values are never
    /// stored, so this exists to keep a stray one out of a display.
    public static func maskedValue(_ value: String?) -> String {
        _ = value
        return placeholder
    }

    private static func tokens(in name: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in name {
            if character.isLetter || character.isNumber {
                if character.isUppercase, let last = current.last, !last.isUppercase {
                    tokens.append(current.lowercased())
                    current = ""
                }
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current.lowercased())
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current.lowercased()) }
        return tokens
    }
}

extension ToolingScope {
    /// Claude Code's own install-scope wording, used verbatim wherever the
    /// Marketplace states the scope an install will use. A scope Claude does
    /// not name falls back to the app-wide vocabulary rather than inventing one.
    public var marketplaceInstallTitle: String {
        switch self {
        case .user: "User (all projects)"
        case .project: "Project (shared with team)"
        case .localProject: "Local (personal, not committed)"
        default: displayName
        }
    }

    public var marketplaceInstallDetail: String {
        switch self {
        case .user: "Installs for your user account and is available in every project on this Mac."
        case .project: "Installs into the project's checked-in configuration, shared with everyone on the team."
        case .localProject: "Installs into the project's local configuration, personal to you and not committed."
        default: "The install route reports this scope as \(displayName)."
        }
    }
}

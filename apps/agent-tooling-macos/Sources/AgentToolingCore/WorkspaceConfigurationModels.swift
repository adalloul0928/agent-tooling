import Foundation

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
/// passwords, OAuth refresh tokens and secret values never enter the workspace.
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
    public var enabledClients: Set<ClientKind>

    public init(automaticallyCheckHealth: Bool = true, enabledClients: Set<ClientKind> = Set(ClientKind.allCases)) {
        self.enabledClients = enabledClients
        self.automaticallyCheckHealth = automaticallyCheckHealth
    }

    private enum CodingKeys: String, CodingKey {
        case confirmWrites
        case automaticallyCheckHealth
        case enabledClients
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `confirmWrites` was a user preference in early local snapshots. It
        // is intentionally decoded and ignored now that write review is a
        // product invariant.
        _ = try container.decodeIfPresent(Bool.self, forKey: .confirmWrites)
        enabledClients = try container.decodeIfPresent(Set<ClientKind>.self, forKey: .enabledClients) ?? Set(ClientKind.allCases)
        automaticallyCheckHealth = try container.decodeIfPresent(Bool.self, forKey: .automaticallyCheckHealth) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(automaticallyCheckHealth, forKey: .automaticallyCheckHealth)
        try container.encode(enabledClients, forKey: .enabledClients)
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

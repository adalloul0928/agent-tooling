import Foundation

public struct WorkspaceObjectID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard value == value.lowercased(), let uuid = UUID(uuidString: value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a lowercase canonical UUID."))
        }
        rawValue = uuid
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString.lowercased() < rhs.rawValue.uuidString.lowercased()
    }
}

public struct ArtifactID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard value == value.lowercased(), let uuid = UUID(uuidString: value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a lowercase canonical artifact UUID."))
        }
        rawValue = uuid
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString.lowercased() < rhs.rawValue.uuidString.lowercased()
    }
}

public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case package, skill, mcpServer, nativePlugin, preset, logicalProject
}

public struct ExternalAlias: Codable, Hashable, Sendable {
    public var namespace: String
    public var value: String

    public init(namespace: String, value: String) {
        self.namespace = namespace
        self.value = value
    }
}

public struct ArtifactIdentity: Codable, Hashable, Sendable {
    public var id: ArtifactID
    public var kind: ArtifactKind
    public var displayName: String
    public var aliases: [ExternalAlias]
    public var parentPackageID: ArtifactID?
    public var derivedFrom: ArtifactID?

    public init(
        id: ArtifactID = ArtifactID(),
        kind: ArtifactKind,
        displayName: String,
        aliases: [ExternalAlias] = [],
        parentPackageID: ArtifactID? = nil,
        derivedFrom: ArtifactID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.aliases = aliases
        self.parentPackageID = parentPackageID
        self.derivedFrom = derivedFrom
    }
}

public enum ContentAuthority: Hashable, Sendable {
    case centralPersonal
    case centralUpstream(subscriptionID: WorkspaceObjectID)
    case nativeOwned
    case attachedAuthoring(sourceRootID: WorkspaceObjectID)
    case trackedOnly
}

extension ContentAuthority: Codable {
    private enum Kind: String, Codable { case centralPersonal, centralUpstream, nativeOwned, attachedAuthoring, trackedOnly }
    private enum CodingKeys: String, CodingKey { case kind, payload }
    private enum PayloadKeys: String, CodingKey { case subscriptionID, sourceRootID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .centralPersonal: self = .centralPersonal
        case .trackedOnly: self = .trackedOnly
        case .centralUpstream:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            self = .centralUpstream(subscriptionID: try payload.decode(WorkspaceObjectID.self, forKey: .subscriptionID))
        case .nativeOwned: self = .nativeOwned
        case .attachedAuthoring:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            self = .attachedAuthoring(sourceRootID: try payload.decode(WorkspaceObjectID.self, forKey: .sourceRootID))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .centralPersonal: try container.encode(Kind.centralPersonal, forKey: .kind)
        case .trackedOnly: try container.encode(Kind.trackedOnly, forKey: .kind)
        case .centralUpstream(let id):
            try container.encode(Kind.centralUpstream, forKey: .kind)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(id, forKey: .subscriptionID)
        case .nativeOwned: try container.encode(Kind.nativeOwned, forKey: .kind)
        case .attachedAuthoring(let id):
            try container.encode(Kind.attachedAuthoring, forKey: .kind)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(id, forKey: .sourceRootID)
        }
    }
}

public struct NativePackageRoute: Codable, Hashable, Sendable {
    public var client: ClientKind
    public var externalPluginID: String

    public init(client: ClientKind, externalPluginID: String) {
        self.client = client
        self.externalPluginID = externalPluginID
    }
}

public enum SourceRevisionKind: String, Codable, CaseIterable, Sendable {
    case gitCommitSHA1, gitCommitSHA256, semanticVersion, opaquePublisherRevision
}

public struct SourceRevision: Codable, Hashable, Sendable {
    public var kind: SourceRevisionKind
    public var value: String

    public init(kind: SourceRevisionKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

public enum ContentDigestAlgorithm: String, Codable, Sendable { case sha256TreeV1 }

public struct ContentDigest: Codable, Hashable, Sendable {
    public var algorithm: ContentDigestAlgorithm
    public var value: String

    public init(algorithm: ContentDigestAlgorithm = .sha256TreeV1, value: String) {
        self.algorithm = algorithm
        self.value = value
    }
}

public enum DocumentDigestAlgorithm: String, Codable, Sendable { case sha256CanonicalJSONV1 }

public struct DocumentDigest: Codable, Hashable, Sendable {
    public static let unsealed = DocumentDigest(value: String(repeating: "0", count: 64))

    public var algorithm: DocumentDigestAlgorithm
    public var value: String

    public init(algorithm: DocumentDigestAlgorithm = .sha256CanonicalJSONV1, value: String) {
        self.algorithm = algorithm
        self.value = value
    }
}

public struct UpstreamLock: Codable, Hashable, Sendable {
    public var publisherID: String
    public var sourceRootID: WorkspaceObjectID
    public var requestedRef: String
    public var approvedRevision: SourceRevision
    public var approvedContent: ContentDigest
    public var packageRelativePath: String

    public init(
        publisherID: String,
        sourceRootID: WorkspaceObjectID,
        requestedRef: String,
        approvedRevision: SourceRevision,
        approvedContent: ContentDigest,
        packageRelativePath: String
    ) {
        self.publisherID = publisherID
        self.sourceRootID = sourceRootID
        self.requestedRef = requestedRef
        self.approvedRevision = approvedRevision
        self.approvedContent = approvedContent
        self.packageRelativePath = packageRelativePath
    }
}

public struct ArtifactRecord: Codable, Hashable, Sendable {
    public var identity: ArtifactIdentity
    public var authority: ContentAuthority
    public var declaredName: String?
    public var packageRelativePath: String?
    public var contentDigest: ContentDigest?
    public var nativeRoutes: [NativePackageRoute]

    public init(
        identity: ArtifactIdentity,
        authority: ContentAuthority,
        declaredName: String? = nil,
        packageRelativePath: String? = nil,
        contentDigest: ContentDigest? = nil,
        nativeRoutes: [NativePackageRoute] = []
    ) {
        self.identity = identity
        self.authority = authority
        self.declaredName = declaredName
        self.packageRelativePath = packageRelativePath
        self.contentDigest = contentDigest
        self.nativeRoutes = nativeRoutes
    }
}

public enum SourceRootRole: String, Codable, Sendable { case publisherRepository, attachedAuthoring }

public struct PortableSourceDescriptor: Codable, Hashable, Sendable {
    public var id: WorkspaceObjectID
    public var role: SourceRootRole
    public var repositoryURL: String?
    public var requestedRef: String?
    public var packageRelativePaths: [String]

    public init(
        id: WorkspaceObjectID = WorkspaceObjectID(),
        role: SourceRootRole,
        repositoryURL: String? = nil,
        requestedRef: String? = nil,
        packageRelativePaths: [String] = []
    ) {
        self.id = id
        self.role = role
        self.repositoryURL = repositoryURL
        self.requestedRef = requestedRef
        self.packageRelativePaths = packageRelativePaths
    }
}

public struct UpstreamSubscription: Codable, Hashable, Sendable {
    public var id: WorkspaceObjectID
    public var artifactID: ArtifactID
    public var sourceID: WorkspaceObjectID
    public var lock: UpstreamLock

    public init(
        id: WorkspaceObjectID = WorkspaceObjectID(), artifactID: ArtifactID, sourceID: WorkspaceObjectID, lock: UpstreamLock
    ) {
        self.id = id
        self.artifactID = artifactID
        self.sourceID = sourceID
        self.lock = lock
    }
}

public struct LogicalProjectRecord: Codable, Hashable, Sendable {
    public var id: ArtifactID
    public var name: String
    public var repositoryHints: [String]

    public init(id: ArtifactID = ArtifactID(), name: String, repositoryHints: [String] = []) {
        self.id = id
        self.name = name
        self.repositoryHints = repositoryHints
    }
}

public struct PortableDestination: Codable, Hashable, Sendable {
    public var surface: TargetSurface
    public var scope: ToolingScope
    public var logicalProjectID: ArtifactID?
    /// Nil targets all enrolled devices. Empty targets none.
    public var deviceIDs: [WorkspaceObjectID]?

    public init(
        surface: TargetSurface,
        scope: ToolingScope,
        logicalProjectID: ArtifactID? = nil,
        deviceIDs: [WorkspaceObjectID]? = nil
    ) {
        self.surface = surface
        self.scope = scope
        self.logicalProjectID = logicalProjectID
        self.deviceIDs = deviceIDs
    }
}

public enum AssignmentReason: Hashable, Sendable {
    case manual
    case preset(presetID: ArtifactID)
    case onboarding(configurationID: WorkspaceObjectID)
    case projectDeclaration(projectID: ArtifactID)
}

extension AssignmentReason: Codable {
    private enum Kind: String, Codable { case manual, preset, onboarding, projectDeclaration }
    private enum CodingKeys: String, CodingKey { case kind, payload }
    private enum PayloadKeys: String, CodingKey { case presetID, configurationID, projectID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .manual: self = .manual
        case .preset:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            self = .preset(presetID: try payload.decode(ArtifactID.self, forKey: .presetID))
        case .onboarding:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            self = .onboarding(configurationID: try payload.decode(WorkspaceObjectID.self, forKey: .configurationID))
        case .projectDeclaration:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            self = .projectDeclaration(projectID: try payload.decode(ArtifactID.self, forKey: .projectID))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual: try container.encode(Kind.manual, forKey: .kind)
        case .preset(let id):
            try container.encode(Kind.preset, forKey: .kind)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(id, forKey: .presetID)
        case .onboarding(let id):
            try container.encode(Kind.onboarding, forKey: .kind)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(id, forKey: .configurationID)
        case .projectDeclaration(let id):
            try container.encode(Kind.projectDeclaration, forKey: .kind)
            var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            try payload.encode(id, forKey: .projectID)
        }
    }
}

public struct AssignmentContribution: Codable, Hashable, Sendable {
    public var id: WorkspaceObjectID
    public var artifactID: ArtifactID
    public var destination: PortableDestination
    public var reason: AssignmentReason
    public var desiredPresence: Bool
    public var desiredEnabled: Bool?

    public init(
        id: WorkspaceObjectID = WorkspaceObjectID(),
        artifactID: ArtifactID,
        destination: PortableDestination,
        reason: AssignmentReason,
        desiredPresence: Bool = true,
        desiredEnabled: Bool? = nil
    ) {
        self.id = id
        self.artifactID = artifactID
        self.destination = destination
        self.reason = reason
        self.desiredPresence = desiredPresence
        self.desiredEnabled = desiredEnabled
    }
}

public struct PresetRecord: Codable, Hashable, Sendable {
    public var id: ArtifactID
    public var name: String
    public var revision: UInt64
    public var memberArtifactIDs: [ArtifactID]

    public init(id: ArtifactID = ArtifactID(), name: String, revision: UInt64 = 1, memberArtifactIDs: [ArtifactID] = []) {
        self.id = id
        self.name = name
        self.revision = revision
        self.memberArtifactIDs = memberArtifactIDs
    }
}

public struct ArtifactTombstone: Codable, Hashable, Sendable {
    public var artifactID: ArtifactID
    public var aliases: [ExternalAlias]
    public var deletedInRevisionID: WorkspaceObjectID

    public init(artifactID: ArtifactID, aliases: [ExternalAlias] = [], deletedInRevisionID: WorkspaceObjectID) {
        self.artifactID = artifactID
        self.aliases = aliases
        self.deletedInRevisionID = deletedInRevisionID
    }
}

public enum WorkspaceDomainValidationError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion(UInt)
    case invalidField(String)
    case duplicate(String)
    case missingReference(String)
    case conflictingAssignment(String)
    case digestMismatch
    case nonCanonicalOrUnsupportedContent

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Unsupported workspace document version: \(version)."
        case .invalidField(let field): "Invalid workspace field: \(field)."
        case .duplicate(let field): "Duplicate workspace value: \(field)."
        case .missingReference(let field): "Missing workspace reference: \(field)."
        case .conflictingAssignment(let field): "Conflicting workspace assignment: \(field)."
        case .digestMismatch: "The workspace document digest does not match its canonical contents."
        case .nonCanonicalOrUnsupportedContent:
            "The workspace data is noncanonical or contains unsupported fields."
        }
    }
}

enum WorkspaceDomainValidation {
    static func canonicalDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    static func requireText(_ value: String, field: String, maximum: Int = 4_096) throws {
        guard !value.isEmpty, value.count <= maximum,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw WorkspaceDomainValidationError.invalidField(field) }
    }

    static func requireDigest(_ value: String, field: String) throws {
        guard value.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw WorkspaceDomainValidationError.invalidField(field)
        }
    }

    static func requirePortablePath(_ value: String, field: String, allowRootDot: Bool = false) throws {
        if allowRootDot, value == "." { return }
        guard !value.isEmpty, value.count <= 4_096, !value.hasPrefix("/"), !value.contains("\\"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw WorkspaceDomainValidationError.invalidField(field) }
    }

    static func requireAbsolutePath(_ value: String, field: String) throws {
        guard value.hasPrefix("/"), value.count <= 8_192,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            URL(fileURLWithPath: value).standardizedFileURL.path == value
        else { throw WorkspaceDomainValidationError.invalidField(field) }
    }

    static func requireCredentialFreeHTTPS(_ value: String, field: String) throws {
        guard value.count <= 4_096, let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
            parts.host != nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { throw WorkspaceDomainValidationError.invalidField(field) }
    }

    static func requireRevision(_ revision: SourceRevision, field: String) throws {
        switch revision.kind {
        case .gitCommitSHA1:
            guard revision.value.count == 40, isLowerHex(revision.value) else {
                throw WorkspaceDomainValidationError.invalidField(field)
            }
        case .gitCommitSHA256:
            guard revision.value.count == 64, isLowerHex(revision.value) else {
                throw WorkspaceDomainValidationError.invalidField(field)
            }
        case .semanticVersion, .opaquePublisherRevision:
            try requireText(revision.value, field: field, maximum: 256)
        }
    }

    private static func isLowerHex(_ value: String) -> Bool {
        value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

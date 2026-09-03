import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct AgentPluginAuthor: Codable, Hashable, Sendable {
    public var name: String?
    public var email: String?
    public var url: String?

    public init(name: String? = nil, email: String? = nil, url: String? = nil) {
        self.name = name
        self.email = email
        self.url = url
    }
}

public struct AgentPluginManifest: Codable, Hashable, Sendable {
    public static let schemaIdentifier = "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"

    public var schema: String
    public var name: String
    public var version: String?
    public var description: String?
    public var author: AgentPluginAuthor?
    public var homepage: String?
    public var repository: String?
    public var license: String?
    public var keywords: [String]?
    public var extensions: [String: JSONValue]?

    public init(
        schema: String = Self.schemaIdentifier,
        name: String,
        version: String? = nil,
        description: String? = nil,
        author: AgentPluginAuthor? = nil,
        homepage: String? = nil,
        repository: String? = nil,
        license: String? = nil,
        keywords: [String]? = nil,
        extensions: [String: JSONValue]? = nil
    ) throws {
        self.schema = schema
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.homepage = homepage
        self.repository = repository
        self.license = license
        self.keywords = keywords
        self.extensions = extensions
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case name, version, description, author, homepage, repository, license, keywords, extensions
    }

    public static func decodeAndValidate(_ data: Data) throws -> AgentPluginManifest {
        let manifest = try AgentToolingCoding.decoder().decode(AgentPluginManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        guard schema == Self.schemaIdentifier else { throw AgentPluginValidationError.unsupportedSchema(schema) }
        guard Self.isValidName(name) else { throw AgentPluginValidationError.invalidName(name) }
        try Self.validateText(version, field: "version", maximumCharacters: 8_192)
        try Self.validateText(description, field: "description", maximumCharacters: 8_192, allowsLineBreaks: true)
        try Self.validateText(homepage, field: "homepage", maximumCharacters: 8_192)
        try Self.validateText(repository, field: "repository", maximumCharacters: 8_192)
        try Self.validateText(license, field: "license", maximumCharacters: 8_192)
        if let author {
            try Self.validateText(author.name, field: "author.name", maximumCharacters: 1_024)
            try Self.validateText(author.email, field: "author.email", maximumCharacters: 1_024)
            try Self.validateText(author.url, field: "author.url", maximumCharacters: 1_024)
        }
        if let keywords,
            keywords.count > 256
                || keywords.contains(where: { $0.isEmpty || $0.count > 128 || Self.containsControlCharacters($0, allowsLineBreaks: false) })
        {
            throw AgentPluginValidationError.invalidField("keywords")
        }
        if let extensions {
            for namespace in extensions.keys where !Self.isValidExtensionNamespace(namespace) {
                throw AgentPluginValidationError.invalidExtensionNamespace(namespace)
            }
            for value in extensions.values {
                guard case .object = value else { throw AgentPluginValidationError.invalidField("extensions") }
            }
        }
    }

    public static func isValidName(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        let alphaNumeric = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        guard (1...64).contains(value.count),
            value.unicodeScalars.allSatisfy(allowed.contains),
            let first = value.unicodeScalars.first,
            let last = value.unicodeScalars.last,
            alphaNumeric.contains(first),
            alphaNumeric.contains(last),
            !value.contains("--"),
            !value.contains("..")
        else { return false }
        return true
    }

    private static func isValidExtensionNamespace(_ value: String) -> Bool {
        guard value.contains("."), value.count <= 253 else { return false }
        return value.split(separator: ".").allSatisfy { component in
            guard let first = component.first, let last = component.last, first.isLetter || first.isNumber,
                last.isLetter || last.isNumber
            else { return false }
            return component.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static func validateText(
        _ value: String?, field: String, maximumCharacters: Int, allowsLineBreaks: Bool = false
    ) throws {
        guard let value else { return }
        guard value.count <= maximumCharacters, !containsControlCharacters(value, allowsLineBreaks: allowsLineBreaks) else {
            throw AgentPluginValidationError.invalidField(field)
        }
    }

    private static func containsControlCharacters(_ value: String, allowsLineBreaks: Bool) -> Bool {
        value.unicodeScalars.contains { scalar in
            guard CharacterSet.controlCharacters.contains(scalar) else { return false }
            return !allowsLineBreaks || ![0x09, 0x0A, 0x0D].contains(scalar.value)
        }
    }
}

public struct PackageIdentity: Codable, Hashable, Sendable {
    public var name: String
    public var version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }

    public var lockedDescription: String { version.map { "\(name)@\($0)" } ?? name }
}

public struct PackageSource: Codable, Hashable, Sendable {
    public var kind: SourceKind
    public var location: String

    public init(kind: SourceKind, location: String) {
        self.kind = kind
        self.location = location
    }
}

public struct SourceLock: Codable, Hashable, Sendable {
    public var revision: String?
    public var digest: String?

    public init(revision: String? = nil, digest: String? = nil) {
        self.revision = revision
        self.digest = digest
    }
}

public struct PackageProvenance: Codable, Hashable, Sendable {
    public var source: PackageSource
    public var lock: SourceLock?
    public var publisher: String?

    public init(source: PackageSource, lock: SourceLock? = nil, publisher: String? = nil) {
        self.source = source
        self.lock = lock
        self.publisher = publisher
    }
}

public enum PackageOwnership: String, Codable, CaseIterable, Sendable {
    case managed
    case nativeClient
    case unmanaged

    public var displayName: String {
        switch self {
        case .managed: "Managed by Agent Tooling"
        case .nativeClient: "Managed by the native client"
        case .unmanaged: "Unmanaged local installation"
        }
    }
}

public enum PackageUpdateStatus: String, Codable, CaseIterable, Sendable {
    case current
    case updateAvailable
    case locallyModified
    case conflict
    case unknown

    public var displayName: String {
        switch self {
        case .current: "Current"
        case .updateAvailable: "Update available"
        case .locallyModified: "Locally modified"
        case .conflict: "Source conflict"
        case .unknown: "Not checked"
        }
    }
}

public struct PackageConflict: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var summary: String

    public init(id: String, summary: String) {
        self.id = id
        self.summary = summary
    }
}

enum AgentPluginValidationError: LocalizedError, Sendable {
    case unsupportedSchema(String)
    case invalidName(String)
    case invalidField(String)
    case invalidExtensionNamespace(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let schema): "Unsupported Agent Plugins schema: \(schema)"
        case .invalidName(let name): "Invalid Agent Plugins package name: \(name)"
        case .invalidField(let field): "Invalid Agent Plugins manifest field: \(field)"
        case .invalidExtensionNamespace(let namespace): "Invalid Agent Plugins extension namespace: \(namespace)"
        }
    }
}

import Foundation

/// A non-fatal exception defined by the Agent Plugins 1.0 manifest loader.
public struct AgentPluginManifestDiagnostic: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case ignoredUnknownRootField(String)
        case ignoredNonObjectExtensions
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

public struct AgentPluginManifestLoadResult: Hashable, Sendable {
    /// A metadata projection only. Use `rawManifestData` when preserving a package.
    public var manifest: AgentPluginManifest
    public var diagnostics: [AgentPluginManifestDiagnostic]
    /// The exact input bytes. This is the preservation authority for opaque data;
    /// encoding `manifest` is not a byte-preserving rewrite operation.
    public var rawManifestData: Data
    /// Names under an object-valued `extensions` field. Their values are opaque.
    public var extensionNamespaces: [String]

    public init(
        manifest: AgentPluginManifest,
        diagnostics: [AgentPluginManifestDiagnostic],
        rawManifestData: Data,
        extensionNamespaces: [String]
    ) {
        self.manifest = manifest
        self.diagnostics = diagnostics
        self.rawManifestData = rawManifestData
        self.extensionNamespaces = extensionNamespaces
    }
}

/// Optional application ingestion limits. These are not Agent Plugins schema
/// requirements and are deliberately opt-in for callers that need them.
public struct AgentPluginManifestIngestionPolicy: Hashable, Sendable {
    public var maximumStringCharacters: Int?
    public var maximumCharactersByField: [String: Int]
    public var maximumKeywords: Int?
    public var maximumKeywordCharacters: Int?
    public var rejectsControlCharacters: Bool

    public init(
        maximumStringCharacters: Int? = nil,
        maximumCharactersByField: [String: Int] = [:],
        maximumKeywords: Int? = nil,
        maximumKeywordCharacters: Int? = nil,
        rejectsControlCharacters: Bool = false
    ) {
        self.maximumStringCharacters = maximumStringCharacters
        self.maximumCharactersByField = maximumCharactersByField
        self.maximumKeywords = maximumKeywords
        self.maximumKeywordCharacters = maximumKeywordCharacters
        self.rejectsControlCharacters = rejectsControlCharacters
    }
}

public enum AgentPluginManifestPolicyError: LocalizedError, Sendable {
    case maximumStringCharacters(field: String)
    case maximumKeywords
    case maximumKeywordCharacters
    case controlCharacters(field: String)

    public var errorDescription: String? {
        switch self {
        case .maximumStringCharacters(let field): "Manifest ingestion limit exceeded for \(field)"
        case .maximumKeywords: "Manifest ingestion keyword limit exceeded"
        case .maximumKeywordCharacters: "Manifest ingestion keyword length limit exceeded"
        case .controlCharacters(let field): "Manifest ingestion control-character policy rejected \(field)"
        }
    }
}

enum AgentPluginManifestLoader {
    private static let allowedRootFields: Set<String> = [
        "$schema", "name", "version", "description", "author", "homepage",
        "repository", "license", "keywords", "extensions",
    ]

    struct DecodedManifestResult {
        var manifest: AgentPluginManifest
        var diagnostics: [AgentPluginManifestDiagnostic]
        var extensionNamespaces: [String]
    }

    private struct DynamicKey: CodingKey, Hashable {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    private struct DecodedManifest: Decodable {
        var schema: String
        var name: String
        var version: String?
        var description: String?
        var author: AgentPluginAuthor?
        var homepage: String?
        var repository: String?
        var license: String?
        var keywords: [String]?
        var bestEffortExtensions: [String: JSONValue]?
        var extensionNamespaces: [String]
        var diagnostics: [AgentPluginManifestDiagnostic]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            diagnostics = container.allKeys
                .map(\.stringValue)
                .filter { !AgentPluginManifestLoader.allowedRootFields.contains($0) }
                .sorted()
                .map { AgentPluginManifestDiagnostic(kind: .ignoredUnknownRootField($0)) }

            schema = try Self.requiredString(container, field: "$schema")
            name = try Self.requiredString(container, field: "name")
            version = try Self.optionalString(container, field: "version")
            description = try Self.optionalString(container, field: "description")
            homepage = try Self.optionalString(container, field: "homepage")
            repository = try Self.optionalString(container, field: "repository")
            license = try Self.optionalString(container, field: "license")
            author = try Self.optionalAuthor(container)
            keywords = try Self.optionalKeywords(container)

            let extensionsKey = DynamicKey(stringValue: "extensions")!
            if container.contains(extensionsKey) {
                do {
                    let namespaces = try container.nestedContainer(keyedBy: DynamicKey.self, forKey: extensionsKey)
                    extensionNamespaces = namespaces.allKeys.map(\.stringValue).sorted()
                    // This is a convenience projection only. Namespace values are never
                    // validated, and a value JSONValue cannot represent must not fail loading.
                    bestEffortExtensions = try? container.decode([String: JSONValue].self, forKey: extensionsKey)
                } catch {
                    diagnostics.append(AgentPluginManifestDiagnostic(kind: .ignoredNonObjectExtensions))
                    extensionNamespaces = []
                    bestEffortExtensions = nil
                }
            } else {
                extensionNamespaces = []
                bestEffortExtensions = nil
            }
        }

        private static func requiredString(
            _ container: KeyedDecodingContainer<DynamicKey>, field: String
        ) throws -> String {
            let key = DynamicKey(stringValue: field)!
            guard container.contains(key) else { throw AgentPluginValidationError.invalidField(field) }
            do {
                return try container.decode(String.self, forKey: key)
            } catch {
                throw AgentPluginValidationError.invalidField(field)
            }
        }

        private static func optionalString(
            _ container: KeyedDecodingContainer<DynamicKey>, field: String
        ) throws -> String? {
            let key = DynamicKey(stringValue: field)!
            guard container.contains(key) else { return nil }
            do {
                return try container.decode(String.self, forKey: key)
            } catch {
                throw AgentPluginValidationError.invalidField(field)
            }
        }

        private static func optionalAuthor(
            _ container: KeyedDecodingContainer<DynamicKey>
        ) throws -> AgentPluginAuthor? {
            let key = DynamicKey(stringValue: "author")!
            guard container.contains(key) else { return nil }
            let author: KeyedDecodingContainer<DynamicKey>
            do {
                author = try container.nestedContainer(keyedBy: DynamicKey.self, forKey: key)
            } catch {
                throw AgentPluginValidationError.invalidField("author")
            }
            let allowed = Set(["name", "email", "url"])
            guard allowed.isSuperset(of: author.allKeys.map(\.stringValue)) else {
                throw AgentPluginValidationError.invalidField("author")
            }
            return AgentPluginAuthor(
                name: try Self.optionalAuthorString(author, field: "name"),
                email: try Self.optionalAuthorString(author, field: "email"),
                url: try Self.optionalAuthorString(author, field: "url")
            )
        }

        private static func optionalAuthorString(
            _ author: KeyedDecodingContainer<DynamicKey>, field: String
        ) throws -> String? {
            let key = DynamicKey(stringValue: field)!
            guard author.contains(key) else { return nil }
            do {
                return try author.decode(String.self, forKey: key)
            } catch {
                throw AgentPluginValidationError.invalidField("author.\(field)")
            }
        }

        private static func optionalKeywords(
            _ container: KeyedDecodingContainer<DynamicKey>
        ) throws -> [String]? {
            let key = DynamicKey(stringValue: "keywords")!
            guard container.contains(key) else { return nil }
            do {
                return try container.decode([String].self, forKey: key)
            } catch {
                throw AgentPluginValidationError.invalidField("keywords")
            }
        }
    }

    static func load(
        _ data: Data,
        ingestionPolicy: AgentPluginManifestIngestionPolicy?
    ) throws -> AgentPluginManifestLoadResult {
        let decoded: DecodedManifest
        do {
            decoded = try AgentToolingCoding.decoder().decode(DecodedManifest.self, from: data)
        } catch let error as AgentPluginValidationError {
            throw error
        } catch {
            throw AgentPluginValidationError.invalidField("root")
        }
        let result = try manifest(from: decoded, ingestionPolicy: ingestionPolicy)
        return AgentPluginManifestLoadResult(
            manifest: result.manifest,
            diagnostics: result.diagnostics,
            rawManifestData: data,
            extensionNamespaces: result.extensionNamespaces
        )
    }

    static func manifest(
        from decoder: any Decoder,
        ingestionPolicy: AgentPluginManifestIngestionPolicy?
    ) throws -> DecodedManifestResult {
        try manifest(from: DecodedManifest(from: decoder), ingestionPolicy: ingestionPolicy)
    }

    private static func manifest(
        from decoded: DecodedManifest,
        ingestionPolicy: AgentPluginManifestIngestionPolicy?
    ) throws -> DecodedManifestResult {
        let schema = decoded.schema
        let name = decoded.name
        guard schema == AgentPluginManifest.schemaIdentifier else {
            throw AgentPluginValidationError.unsupportedSchema(schema)
        }
        guard AgentPluginManifest.isValidName(name) else { throw AgentPluginValidationError.invalidName(name) }

        try validateIngestionPolicy(
            ingestionPolicy,
            strings: [
                ("$schema", schema), ("name", name), ("version", decoded.version),
                ("description", decoded.description), ("homepage", decoded.homepage),
                ("repository", decoded.repository), ("license", decoded.license),
                ("author.name", decoded.author?.name), ("author.email", decoded.author?.email), ("author.url", decoded.author?.url),
            ],
            keywords: decoded.keywords
        )

        return DecodedManifestResult(
            manifest: AgentPluginManifest.loadedManifest(
                schema: schema, name: name, version: decoded.version, description: decoded.description, author: decoded.author,
                homepage: decoded.homepage, repository: decoded.repository, license: decoded.license, keywords: decoded.keywords,
                extensions: decoded.bestEffortExtensions
            ),
            diagnostics: decoded.diagnostics,
            extensionNamespaces: decoded.extensionNamespaces
        )
    }

    private static func validateIngestionPolicy(
        _ policy: AgentPluginManifestIngestionPolicy?,
        strings: [(String, String?)],
        keywords: [String]?
    ) throws {
        guard let policy else { return }
        for (field, value) in strings {
            guard let value else { continue }
            if let maximum = policy.maximumStringCharacters, value.count > maximum {
                throw AgentPluginManifestPolicyError.maximumStringCharacters(field: field)
            }
            if let maximum = policy.maximumCharactersByField[field], value.count > maximum {
                throw AgentPluginManifestPolicyError.maximumStringCharacters(field: field)
            }
            if policy.rejectsControlCharacters,
                value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            {
                throw AgentPluginManifestPolicyError.controlCharacters(field: field)
            }
        }
        if let maximum = policy.maximumKeywords, (keywords?.count ?? 0) > maximum {
            throw AgentPluginManifestPolicyError.maximumKeywords
        }
        for (index, keyword) in (keywords ?? []).enumerated() {
            if let maximum = policy.maximumKeywordCharacters, keyword.count > maximum {
                throw AgentPluginManifestPolicyError.maximumKeywordCharacters
            }
            if policy.rejectsControlCharacters,
                keyword.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            {
                throw AgentPluginManifestPolicyError.controlCharacters(field: "keywords[\(index)]")
            }
        }
    }
}

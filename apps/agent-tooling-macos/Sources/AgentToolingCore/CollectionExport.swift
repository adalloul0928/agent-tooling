import Foundation

/// One item as it appears in an exported Collection: enough to recognise and
/// re-create the entry, and nothing that could carry a credential.
public struct ExportedToolingItem: Codable, Sendable, Equatable {
    public var kind: ToolingItemKind
    public var identifier: String
    public var name: String
    public var summary: String
    public var scope: String
    public var tags: [String]
    /// MCP servers only. The destination is redacted before it is written, so
    /// user info and query strings never leave this Mac.
    public var destination: String?
    public var transport: String?
    /// Names of the credentials the recipient must supply themselves. Never a
    /// value — only the name of the thing they have to go and set up.
    public var requiredCredentialNames: [String]?
    /// Plugins only.
    public var source: String?

    public init(
        kind: ToolingItemKind,
        identifier: String,
        name: String,
        summary: String = "",
        scope: String = "",
        tags: [String] = [],
        destination: String? = nil,
        transport: String? = nil,
        requiredCredentialNames: [String]? = nil,
        source: String? = nil
    ) {
        self.kind = kind
        self.identifier = identifier
        self.name = name
        self.summary = summary
        self.scope = scope
        self.tags = tags
        self.destination = destination
        self.transport = transport
        self.requiredCredentialNames = requiredCredentialNames
        self.source = source
    }
}

/// A Collection written out as a plain file. Files outlive vendors: both
/// products in this space that bet on hosted sharing have since shut down, so
/// the shareable artifact here is a document on disk, not an account.
public struct CollectionExportDocument: Codable, Sendable, Equatable {
    public static let format = "agent-tooling.collection"
    public static let currentFormatVersion = 1
    /// Deliberately close to Docker's wording, which is the clearest statement
    /// of this promise anyone in this space has shipped.
    public static let securityNote = "Credentials are not included in shared collections for security reasons."

    public var format: String
    public var formatVersion: Int
    public var exportedAt: Date
    public var securityNote: String
    public var name: String
    public var summary: String
    public var items: [ExportedToolingItem]
    /// Items that were listed in the Collection but are no longer present in
    /// the local inventory. Named so the recipient knows the shelf is partial.
    public var unresolvedItems: [ToolingItemReference]

    public init(
        format: String = CollectionExportDocument.format,
        formatVersion: Int = CollectionExportDocument.currentFormatVersion,
        exportedAt: Date = .now,
        securityNote: String = CollectionExportDocument.securityNote,
        name: String,
        summary: String = "",
        items: [ExportedToolingItem] = [],
        unresolvedItems: [ToolingItemReference] = []
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.securityNote = securityNote
        self.name = name
        self.summary = summary
        self.items = items
        self.unresolvedItems = unresolvedItems
    }
}

enum CollectionExportError: LocalizedError, Sendable {
    case unknownCollection
    case credentialMaterialPresent

    var errorDescription: String? {
        switch self {
        case .unknownCollection: "The selected collection is no longer available."
        case .credentialMaterialPresent:
            "The export was stopped because it still contained credential-like material. No file was written."
        }
    }
}

public enum CollectionExporter {
    public static let fileExtension = "json"

    /// Builds the document. Every string that leaves the app is redacted, and
    /// machine-local project folders are dropped rather than redacted, because
    /// a shared shelf has no use for another person's directory layout.
    public static func document(
        for collection: ToolingCollection,
        skills: [Skill],
        plugins: [Plugin],
        mcpServers: [MCPServer],
        tags: [ToolingItemReference: [String]] = [:],
        exportedAt: Date = .now
    ) -> CollectionExportDocument {
        var items: [ExportedToolingItem] = []
        var unresolved: [ToolingItemReference] = []

        for reference in collection.items {
            let itemTags = ToolingTag.normalizedList(tags[reference] ?? [])
            switch reference.kind {
            case .skill:
                guard let skill = skills.first(where: { $0.id == reference.identifier }) else {
                    unresolved.append(reference)
                    continue
                }
                items.append(
                    ExportedToolingItem(
                        kind: .skill,
                        identifier: skill.id,
                        name: redacted(skill.displayName.isEmpty ? skill.name : skill.displayName),
                        summary: redacted(skill.summary),
                        scope: redacted(skill.scope),
                        tags: itemTags
                    ))
            case .plugin:
                guard let plugin = plugins.first(where: { $0.id == reference.identifier }) else {
                    unresolved.append(reference)
                    continue
                }
                items.append(
                    ExportedToolingItem(
                        kind: .plugin,
                        identifier: plugin.id,
                        name: redacted(plugin.name),
                        summary: redacted(plugin.summary),
                        scope: redacted(plugin.scope),
                        tags: itemTags,
                        source: redacted(plugin.source)
                    ))
            case .mcpServer:
                guard let server = mcpServers.first(where: { $0.id == reference.identifier }) else {
                    unresolved.append(reference)
                    continue
                }
                items.append(
                    ExportedToolingItem(
                        kind: .mcpServer,
                        identifier: server.id,
                        name: redacted(server.name),
                        summary: redacted(server.summary),
                        scope: redacted(server.scope),
                        tags: itemTags,
                        destination: sanitizedDestination(server.endpoint),
                        transport: server.transport.rawValue,
                        requiredCredentialNames: server.secretNames.map(redacted).sorted()
                    ))
            }
        }

        return CollectionExportDocument(
            exportedAt: exportedAt,
            name: redacted(collection.name),
            summary: redacted(collection.summary),
            items: items,
            unresolvedItems: unresolved
        )
    }

    /// Encodes and refuses to hand back bytes that still look like a secret.
    /// Redaction is the mechanism; this is the check that the mechanism worked.
    ///
    /// The test is that redacting the finished bytes changes nothing — there
    /// was no credential material left to take out. Asking instead whether the
    /// bytes still *look* like a credential would fail on redaction's own
    /// placeholder, since `--token [redacted]` matches the same pattern the
    /// original did.
    public static func encode(_ document: CollectionExportDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CollectionExportError.credentialMaterialPresent
        }
        guard SensitiveValueRedactor.redact(text) == text else {
            throw CollectionExportError.credentialMaterialPresent
        }
        return data
    }

    /// A stable, Finder-friendly file name derived from the collection name.
    public static func suggestedFileName(for collection: ToolingCollection) -> String {
        let base = (try? WorkspaceLibrary.normalizedIdentifier(collection.name)) ?? collection.id
        return "\(base)-collection.\(fileExtension)"
    }

    private static func redacted(_ value: String) -> String {
        SensitiveValueRedactor.redact(value)
    }

    /// A web destination is stripped structurally rather than pattern-matched:
    /// user info, query and fragment are dropped outright, because a shared
    /// shelf needs to say *where* a server lives and nothing more. Anything
    /// that is not a web URL — a stdio command line — falls back to redaction.
    private static func sanitizedDestination(_ value: String) -> String {
        guard var components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme)
        else {
            return redacted(value)
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? redacted(value)
    }
}

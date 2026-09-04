import Darwin
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
    /// MCP servers only. Remote HTTP(S) identities are stripped of credentials;
    /// local URLs and stdio command lines are omitted entirely.
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
    case localLocationPresent

    var errorDescription: String? {
        switch self {
        case .unknownCollection: "The selected collection is no longer available."
        case .credentialMaterialPresent:
            "The export was stopped because it still contained credential-like material. No file was written."
        case .localLocationPresent:
            "The export was stopped because it still contained a machine-local location. No file was written."
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
                        identifier: portableText(skill.id),
                        name: portableText(skill.displayName.isEmpty ? skill.name : skill.displayName),
                        summary: portableText(skill.summary),
                        scope: portableText(skill.scope),
                        tags: itemTags.map(portableText)
                    ))
            case .plugin:
                guard let plugin = plugins.first(where: { $0.id == reference.identifier }) else {
                    unresolved.append(reference)
                    continue
                }
                items.append(
                    ExportedToolingItem(
                        kind: .plugin,
                        identifier: portableText(plugin.id),
                        name: portableText(plugin.name),
                        summary: portableText(plugin.summary),
                        scope: portableText(plugin.scope),
                        tags: itemTags.map(portableText),
                        source: sanitizedSource(plugin.source)
                    ))
            case .mcpServer:
                guard let server = mcpServers.first(where: { $0.id == reference.identifier }) else {
                    unresolved.append(reference)
                    continue
                }
                items.append(
                    ExportedToolingItem(
                        kind: .mcpServer,
                        identifier: portableText(server.id),
                        name: portableText(server.name),
                        summary: portableText(server.summary),
                        scope: portableText(server.scope),
                        tags: itemTags.map(portableText),
                        destination: sanitizedDestination(server.endpoint, transport: server.transport),
                        transport: server.transport.rawValue,
                        requiredCredentialNames: server.secretNames.map(portableText).sorted()
                    ))
            }
        }

        return CollectionExportDocument(
            exportedAt: exportedAt,
            name: portableText(collection.name),
            summary: portableText(collection.summary),
            items: items,
            unresolvedItems: unresolved.map {
                ToolingItemReference(kind: $0.kind, identifier: portableText($0.identifier))
            }
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
        guard !containsLocalLocation(in: text) else {
            throw CollectionExportError.localLocationPresent
        }
        return data
    }

    /// A stable, Finder-friendly file name derived from the collection name.
    public static func suggestedFileName(for collection: ToolingCollection) -> String {
        let portableName = portableText(collection.name)
        let portableID = portableText(collection.id)
        let base = (try? WorkspaceLibrary.normalizedIdentifier(portableName)) ?? portableID
        return "\(base)-collection.\(fileExtension)"
    }

    private static func portableText(_ value: String) -> String {
        var result = SensitiveValueRedactor.redact(value)
        for pattern in localLocationPatterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "$1[local location omitted]",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    private static func sanitizedSource(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let components = URLComponents(string: trimmed), components.scheme != nil {
            return sanitizedRemoteURL(trimmed)
        }
        // Local inventory labels and relative folders are not useful to a
        // recipient. Preserve only a portable marketplace-style identity.
        guard
            trimmed.range(
                of: #"^[A-Z0-9][A-Z0-9._-]*(?:@[A-Z0-9][A-Z0-9._-]*)?$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        else { return nil }
        return portableText(trimmed)
    }

    private static func sanitizedDestination(_ value: String, transport: MCPTransport) -> String? {
        guard transport == .http else {
            // A stdio endpoint is an executable plus arbitrary argv. Even a
            // seemingly portable command can carry a project or config path.
            return nil
        }
        return sanitizedRemoteURL(value)
    }

    /// Preserve only a public HTTP(S) identity. Loopback, private, single-label,
    /// file and other local destinations are meaningful only on this Mac.
    private static func sanitizedRemoteURL(_ value: String) -> String? {
        guard var components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = components.host?.lowercased(),
            !isLocalHost(host)
        else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string.map(portableText)
    }

    private static func isLocalHost(_ host: String) -> Bool {
        var normalized = host.lowercased()
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") {
            normalized.removeFirst()
            normalized.removeLast()
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if normalized == "localhost" {
            return true
        }
        if [".localhost", ".local", ".lan", ".home", ".internal"].contains(where: normalized.hasSuffix) {
            return true
        }
        if normalized.contains(":") {
            var address = in6_addr()
            guard normalized.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
                return true
            }
            let bytes = withUnsafeBytes(of: &address) { Array($0) }
            let unspecified = bytes.allSatisfy { $0 == 0 }
            let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let uniqueLocal = bytes[0] & 0xfe == 0xfc
            let linkOrSiteLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 != 0
            let multicast = bytes[0] == 0xff
            if unspecified || loopback || uniqueLocal || linkOrSiteLocal || multicast {
                return true
            }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return isLocalIPv4(Array(bytes.suffix(4)))
            }
            return false
        }
        if !normalized.contains(".") {
            return true
        }
        let labels = normalized.split(separator: ".")
        let numericLabels = labels.compactMap { Int($0) }
        if numericLabels.count == labels.count {
            guard labels.count == 4,
                labels.allSatisfy({ $0 == "0" || !$0.hasPrefix("0") }),
                numericLabels.allSatisfy({ (0...255).contains($0) })
            else { return true }
            return isLocalIPv4(numericLabels)
        }
        return false
    }

    private static func isLocalIPv4(_ octets: [Int]) -> Bool {
        octets[0] == 0 || octets[0] == 10 || octets[0] == 127
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    private static func isLocalIPv4(_ octets: [UInt8]) -> Bool {
        isLocalIPv4(octets.map(Int.init))
    }

    private static func containsLocalLocation(in value: String) -> Bool {
        localLocationPatterns.contains {
            value.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Capture group one preserves the delimiter while replacing the location.
    /// Consume the remainder of the field, rather than stopping at whitespace:
    /// local project and bundle names commonly contain spaces, and retaining a
    /// suffix would still disclose part of the machine-local location.
    private static let localLocationPatterns = [
        #"(^|[\s\"'=:\[(])(?:~?/)(?!/)[^\r\n\"'<>]*"#,
        #"(^|[\s\"'=:\[(])(?:\$HOME|\$\{HOME\})/[^\r\n\"'<>]*"#,
        #"(^|[\s\"'=:\[(])(?:[A-Z]:\\)[^\r\n\"'<>]*"#,
        #"(^|[\s\"'=:\[(])file://[^\r\n\"'<>]*"#,
    ]

}

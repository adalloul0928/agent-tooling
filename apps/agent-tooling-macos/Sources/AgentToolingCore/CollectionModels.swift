import Foundation

/// The three things a Collection can hold. Grouping stops at the package
/// boundary: a whole skill, a whole plugin, a whole MCP server. Individual
/// tools inside a server are never addressed here, because server-level
/// grouping has proved sufficient in comparable products and per-tool
/// membership makes every list an order of magnitude longer.
public enum ToolingItemKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case skill
    case plugin
    case mcpServer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .skill: "Skill"
        case .plugin: "Plugin"
        case .mcpServer: "MCP server"
        }
    }

    public var pluralDisplayName: String {
        switch self {
        case .skill: "Skills"
        case .plugin: "Plugins"
        case .mcpServer: "MCP servers"
        }
    }
}

/// A kind-qualified pointer at an inventory record. Identifiers are only
/// unique within a kind, so membership and tagging both key on the pair.
public struct ToolingItemReference: Identifiable, Codable, Hashable, Sendable {
    public var kind: ToolingItemKind
    public var identifier: String

    public init(kind: ToolingItemKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }

    public var id: String { "\(kind.rawValue):\(identifier)" }
}

/// Reusable material a Configuration is built from — a shelf, not a contract.
///
/// A Collection is never "active" on its own. It becomes real only when a
/// Configuration includes it, and even then including it changes desired
/// state; it never writes to a client on its own.
public struct ToolingCollection: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var summary: String
    public var items: [ToolingItemReference]
    public var createdAt: Date

    public init(
        id: String,
        name: String,
        summary: String = "",
        items: [ToolingItemReference] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.items = items
        self.createdAt = createdAt
    }

    public func contains(_ item: ToolingItemReference) -> Bool {
        items.contains(item)
    }

    public var itemCount: Int { items.count }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, items, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        items = try container.decodeIfPresent([ToolingItemReference].self, forKey: .items) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    }
}

/// Tags live beside the inventory rather than inside it. Observed skills,
/// plugins and MCP servers are rebuilt from scratch on every scan, so a tag
/// stored on the record itself would be erased by the next setup check.
public struct TagAssignment: Identifiable, Codable, Hashable, Sendable {
    public var item: ToolingItemReference
    public var tags: [String]

    public init(item: ToolingItemReference, tags: [String]) {
        self.item = item
        self.tags = tags
    }

    public var id: String { item.id }
}

/// Normalization shared by the model layer, the validator and the editors, so
/// a tag typed three different ways is still one tag.
public enum ToolingTag {
    public static let maximumLength = 48
    public static let maximumTagsPerItem = 32

    /// Trims, collapses internal whitespace and rejects anything empty, too
    /// long, or carrying control characters. Display casing is preserved.
    public static func normalized(_ value: String) -> String? {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty,
            collapsed.count <= maximumLength,
            !collapsed.unicodeScalars.contains(where: { $0.value < 0x20 && ![0x09, 0x0A, 0x0D].contains($0.value) })
        else { return nil }
        return collapsed
    }

    /// Case-insensitive de-duplication that keeps the first spelling seen,
    /// then orders the result the way a person reads a list.
    public static func normalizedList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard let tag = normalized(value) else { continue }
            guard seen.insert(tag.lowercased()).inserted else { continue }
            result.append(tag)
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func matches(_ tag: String, _ other: String) -> Bool {
        tag.compare(other, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

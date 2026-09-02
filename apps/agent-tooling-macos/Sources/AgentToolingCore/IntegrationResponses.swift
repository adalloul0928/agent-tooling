import Foundation

/// Response shapes shared by every local integration surface: the
/// `agent-tooling` CLI helper and the stdio MCP server both encode these, so a
/// change to one cannot silently drift from the other.
///
/// Everything here is read-only and describes state. No type in this file can
/// express an approval, a plan, or a command.
public enum IntegrationResponseLimits {
    public static let schemaVersion = 1
    public static let searchDefaultLimit = 100
    public static let searchMaximumLimit = 100
    public static let searchQueryMaximumCharacters = 512
    public static let identifierMaximumCharacters = 256
    public static let nameMaximumCharacters = 512
    public static let descriptionMaximumCharacters = 2_048
}

public struct IntegrationSearchResult: Codable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var name: String
    public var description: String?
    public var source: String?
    public var scope: String?
    public var targets: [String]
    public var status: String?

    public init(
        id: String,
        kind: String,
        name: String,
        description: String? = nil,
        source: String? = nil,
        scope: String? = nil,
        targets: [String] = [],
        status: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.description = description
        self.source = source
        self.scope = scope
        self.targets = targets
        self.status = status
    }
}

public struct IntegrationSearchResponse: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var results: [IntegrationSearchResult]
    public var totalResults: Int
    public var truncated: Bool

    public init(
        schemaVersion: Int = IntegrationResponseLimits.schemaVersion,
        results: [IntegrationSearchResult],
        totalResults: Int,
        truncated: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.results = results
        self.totalResults = totalResults
        self.truncated = truncated
    }
}

public struct IntegrationRequestResponse: Codable, Hashable, Sendable {
    public struct Reference: Codable, Hashable, Sendable {
        public var id: UUID
        public var state: String

        public init(id: UUID, state: String) {
            self.id = id
            self.state = state
        }
    }

    public var schemaVersion: Int
    public var request: Reference

    public init(schemaVersion: Int = IntegrationResponseLimits.schemaVersion, request: Reference) {
        self.schemaVersion = schemaVersion
        self.request = request
    }
}

public struct DoctorReport: Codable, Sendable {
    public var schemaVersion: Int
    public var isHealthy: Bool
    public var unavailableTargets: [TargetSurface]
    public var observations: [TargetObservation]

    public init(
        schemaVersion: Int = IntegrationResponseLimits.schemaVersion,
        isHealthy: Bool,
        unavailableTargets: [TargetSurface],
        observations: [TargetObservation]
    ) {
        self.schemaVersion = schemaVersion
        self.isHealthy = isHealthy
        self.unavailableTargets = unavailableTargets
        self.observations = observations
    }
}

/// Bounding and path-stripping applied to every value that leaves the process
/// for a local integration.
public enum IntegrationTextSanitizer {
    public static func bounded(_ value: String, maximum: Int) -> String {
        String(value.prefix(maximum))
    }

    public static func boundedOptional(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : bounded(trimmed, maximum: maximum)
    }

    /// Drops a value that names a location on this machine. A package source
    /// is useful to an integration only when it is a portable name.
    public static func nonPathSource(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
        return trimmed
    }

    public static func isSafeIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
            CharacterSet.alphanumerics.contains(first),
            value.count <= IntegrationResponseLimits.identifierMaximumCharacters
        else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:@+-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func containsUnsupportedControlCharacter(_ value: String, allowsLineBreaks: Bool = false) -> Bool {
        value.unicodeScalars.contains { scalar in
            if allowsLineBreaks, scalar == "\n" || scalar == "\r" || scalar == "\t" { return false }
            return CharacterSet.controlCharacters.contains(scalar)
        }
    }

    public static func matches(_ normalizedQuery: String, values: [String]) -> Bool {
        normalizedQuery.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
    }

    public static func targetName(_ target: ClientKind) -> String {
        switch target {
        case .codex: "codex"
        case .claude: "claude-code"
        case .gemini: "gemini"
        }
    }

    public static func uniqueTargetNames(_ targets: [ClientKind]) -> [String] {
        Set(targets.map(targetName)).sorted()
    }

    /// Parses the shared `codex,claude-code,gemini` target vocabulary. Returns
    /// `nil` for anything unrecognized so each caller can raise its own error.
    public static func parseTargets(_ rawValue: String) -> [ClientKind]? {
        var targets: Set<ClientKind> = []
        for rawTarget in rawValue.split(separator: ",", omittingEmptySubsequences: false) {
            switch rawTarget.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "codex": targets.insert(.codex)
            case "claude", "claude-code": targets.insert(.claude)
            case "gemini", "gemini-cli": targets.insert(.gemini)
            default: return nil
            }
        }
        guard !targets.isEmpty else { return nil }
        return targets.sorted { $0.rawValue < $1.rawValue }
    }
}

/// The one encoder that turns workspace state into integration search results.
public enum IntegrationSearchIndex {
    public static func response(
        for snapshot: WorkspaceSnapshot,
        query: String,
        kinds: Set<String>? = nil,
        limit: Int = IntegrationResponseLimits.searchDefaultLimit
    ) -> IntegrationSearchResponse {
        var results = self.results(in: snapshot, query: query)
        if let kinds { results = results.filter { kinds.contains($0.kind) } }
        let limited = Array(results.prefix(max(0, limit)))
        return IntegrationSearchResponse(
            results: limited,
            totalResults: results.count,
            truncated: limited.count < results.count
        )
    }

    public static func results(in snapshot: WorkspaceSnapshot, query: String) -> [IntegrationSearchResult] {
        let normalizedQuery = query.lowercased()
        var results: [IntegrationSearchResult] = []

        results.append(
            contentsOf: snapshot.skills.compactMap { skill in
                guard IntegrationTextSanitizer.isSafeIdentifier(skill.id),
                    IntegrationTextSanitizer.matches(
                        normalizedQuery,
                        values: [skill.id, skill.displayName, skill.summary, skill.bundle, skill.scope]
                    )
                else { return nil }
                return IntegrationSearchResult(
                    id: skill.id,
                    kind: "skill",
                    name: IntegrationTextSanitizer.bounded(skill.displayName, maximum: IntegrationResponseLimits.nameMaximumCharacters),
                    description: IntegrationTextSanitizer.boundedOptional(
                        skill.summary,
                        maximum: IntegrationResponseLimits.descriptionMaximumCharacters
                    ),
                    source: IntegrationTextSanitizer.boundedOptional(
                        IntegrationTextSanitizer.nonPathSource(skill.bundle),
                        maximum: IntegrationResponseLimits.nameMaximumCharacters
                    ),
                    scope: IntegrationTextSanitizer.boundedOptional(skill.scope, maximum: IntegrationResponseLimits.nameMaximumCharacters),
                    targets: IntegrationTextSanitizer.uniqueTargetNames(skill.clients.map(\.client)),
                    status: skill.owned ? "Managed" : "Observed"
                )
            })
        results.append(
            contentsOf: snapshot.mcpServers.compactMap { server in
                guard IntegrationTextSanitizer.isSafeIdentifier(server.id),
                    IntegrationTextSanitizer.matches(normalizedQuery, values: [server.id, server.name, server.summary, server.scope])
                else { return nil }
                return IntegrationSearchResult(
                    id: server.id,
                    kind: "mcp-server",
                    name: IntegrationTextSanitizer.bounded(server.name, maximum: IntegrationResponseLimits.nameMaximumCharacters),
                    description: IntegrationTextSanitizer.boundedOptional(
                        server.summary,
                        maximum: IntegrationResponseLimits.descriptionMaximumCharacters
                    ),
                    source: server.isManagedDefinition ? "Managed library" : "Local configuration",
                    scope: IntegrationTextSanitizer.boundedOptional(server.scope, maximum: IntegrationResponseLimits.nameMaximumCharacters),
                    targets: IntegrationTextSanitizer.uniqueTargetNames(server.clients.map(\.client)),
                    status: server.aggregateState.rawValue.capitalized
                )
            })
        results.append(
            contentsOf: snapshot.plugins.compactMap { plugin in
                guard IntegrationTextSanitizer.isSafeIdentifier(plugin.id),
                    IntegrationTextSanitizer.matches(
                        normalizedQuery,
                        values: [plugin.id, plugin.name, plugin.summary, plugin.source, plugin.scope]
                    )
                else { return nil }
                return IntegrationSearchResult(
                    id: plugin.id,
                    kind: "plugin",
                    name: IntegrationTextSanitizer.bounded(plugin.name, maximum: IntegrationResponseLimits.nameMaximumCharacters),
                    description: IntegrationTextSanitizer.boundedOptional(
                        plugin.summary,
                        maximum: IntegrationResponseLimits.descriptionMaximumCharacters
                    ),
                    source: IntegrationTextSanitizer.boundedOptional(
                        IntegrationTextSanitizer.nonPathSource(plugin.source),
                        maximum: IntegrationResponseLimits.nameMaximumCharacters
                    ),
                    scope: IntegrationTextSanitizer.boundedOptional(plugin.scope, maximum: IntegrationResponseLimits.nameMaximumCharacters),
                    targets: IntegrationTextSanitizer.uniqueTargetNames(plugin.clients.map(\.client)),
                    status: plugin.installed ? "Installed" : "Available"
                )
            })

        results.sort {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return results
    }
}

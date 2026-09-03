import Foundation

/// Reads a reviewed local policy manifest. A policy is data only: no scripts,
/// shell commands, hooks, credentials, or unrecognized fields are accepted.
final class PolicyService {
    static let schema = "agent-tooling-policy/v1"

    private enum Limit {
        static let fileBytes = 1_048_576
        static let profiles = 128
        static let rules = 1_024
        static let checksPerProfile = 256
        static let identifierCharacters = 256
        static let nameCharacters = 256
        static let summaryCharacters = 4_096
        static let pathCharacters = 4_096
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func load(at url: URL) throws -> ManagedPolicy {
        let source = url.standardizedFileURL
        guard source.isFileURL else { throw PolicyError.invalidSource(url.absoluteString) }
        let values: URLResourceValues
        do {
            values = try source.resourceValues(forKeys: [
                .contentModificationDateKey, .fileResourceIdentifierKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
        } catch {
            throw PolicyError.invalidSource(source.path(percentEncoded: false))
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PolicyError.invalidSource(source.path(percentEncoded: false))
        }
        guard let fileSize = values.fileSize, fileSize >= 0, fileSize <= Limit.fileBytes else {
            throw PolicyError.fileTooLarge(Limit.fileBytes)
        }
        let sourceIdentifier = values.fileResourceIdentifier.map { String(describing: $0) }

        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Limit.fileBytes + 1) ?? Data()
        guard data.count <= Limit.fileBytes, data.count == fileSize else {
            throw PolicyError.changedWhileReading(source.path(percentEncoded: false))
        }
        let document: PolicyDocument
        do {
            document = try JSONDecoder().decode(PolicyDocument.self, from: data)
        } catch {
            throw PolicyError.invalidDocument(error.localizedDescription)
        }

        guard document.schema == Self.schema else { throw PolicyError.unsupportedSchema(document.schema) }
        let id = try normalizedConfigurationID(document.id)
        let name = try boundedText(document.name, field: "policy name", maximum: Limit.nameCharacters, required: true)
        guard document.profiles.count <= Limit.profiles else { throw PolicyError.tooManyProfiles(Limit.profiles) }

        let requiredPluginIDs = try normalizedRules(document.requiredPluginIDs, field: "required plugin")
        let requiredMCPIDs = try normalizedRules(document.requiredMCPIDs, field: "required MCP server")
        let blockedPluginIDs = try normalizedRules(document.blockedPluginIDs, field: "blocked plugin")
        let required = Set(requiredPluginIDs)
        let blocked = Set(blockedPluginIDs)
        if let conflict = required.intersection(blocked).sorted().first {
            throw PolicyError.conflictingPluginRule(conflict)
        }

        let profiles = try document.profiles.map(makeProfile(from:))
        guard Set(profiles.map(\.id)).count == profiles.count else { throw PolicyError.duplicateProfileID }
        try validateInheritance(in: profiles)

        // Re-check after reading so a replaced file cannot be silently recorded
        // as a different filesystem kind than the one that was reviewed.
        let finalValues = try source.resourceValues(forKeys: [
            .contentModificationDateKey, .fileResourceIdentifierKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard finalValues.isRegularFile == true,
            finalValues.isSymbolicLink != true,
            finalValues.fileSize == data.count,
            finalValues.contentModificationDate == values.contentModificationDate,
            finalValues.fileResourceIdentifier.map({ String(describing: $0) }) == sourceIdentifier
        else {
            throw PolicyError.changedWhileReading(source.path(percentEncoded: false))
        }

        return ManagedPolicy(
            id: id,
            name: name,
            sourcePath: source.path(percentEncoded: false),
            requiredPluginIDs: requiredPluginIDs,
            requiredMCPIDs: requiredMCPIDs,
            blockedPluginIDs: blockedPluginIDs,
            profiles: profiles
        )
    }

    private func makeProfile(from template: PolicyProfileTemplate) throws -> ToolingProfile {
        let profileID = try normalizedConfigurationID(template.id)
        let profileName = try boundedText(
            template.name, field: "configuration \(profileID) name", maximum: Limit.nameCharacters, required: true)
        let summary = try boundedText(template.summary, field: "configuration \(profileID) summary", maximum: Limit.summaryCharacters)
        let parentID = try template.inheritedFrom.map(normalizedConfigurationID)
        let projectRoot = try normalizedProjectRoot(template.projectRoot, profileID: profileID)
        guard template.checks.count <= Limit.checksPerProfile else {
            throw PolicyError.tooManyChecks(profileID, Limit.checksPerProfile)
        }

        let checks = try template.checks.map { check -> ProfileCheck in
            let checkID = try normalizedConfigurationID(check.id)
            return ProfileCheck(
                id: checkID,
                name: try boundedText(check.name, field: "check \(checkID) name", maximum: Limit.nameCharacters, required: true),
                detail: try boundedText(check.detail, field: "check \(checkID) detail", maximum: Limit.summaryCharacters),
                state: check.state,
                manual: check.manual
            )
        }
        guard Set(checks.map(\.id)).count == checks.count else { throw PolicyError.duplicateCheckID(profileID) }

        return ToolingProfile(
            id: profileID,
            name: profileName,
            summary: summary,
            inheritedFrom: parentID,
            scope: .managed,
            projectRoot: projectRoot,
            checks: checks,
            enabledPlugins: try normalizedRules(template.enabledPlugins, field: "configuration \(profileID) plugin"),
            requiredMCPs: try normalizedRules(template.requiredMCPs, field: "configuration \(profileID) MCP server")
        )
    }

    private func validateInheritance(in profiles: [ToolingProfile]) throws {
        let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        for profile in profiles {
            if let parent = profile.inheritedFrom, profilesByID[parent] == nil {
                throw PolicyError.missingParent(profile.id, parent)
            }
            var chain: Set<String> = []
            var current: String? = profile.id
            while let currentID = current {
                guard chain.insert(currentID).inserted else { throw PolicyError.inheritanceCycle(currentID) }
                current = profilesByID[currentID]?.inheritedFrom
            }
        }
    }

    private func normalizedConfigurationID(_ rawValue: String) throws -> String {
        guard rawValue.count <= Limit.identifierCharacters else { throw PolicyError.invalidProfileID(rawValue) }
        do {
            return try WorkspaceLibrary.normalizedIdentifier(rawValue)
        } catch {
            throw PolicyError.invalidProfileID(rawValue)
        }
    }

    private func normalizedRules(_ values: [String], field: String) throws -> [String] {
        guard values.count <= Limit.rules else { throw PolicyError.tooManyRules(field, Limit.rules) }
        var result: [String] = []
        var seen: Set<String> = []
        for rawValue in values {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                value.count <= Limit.identifierCharacters,
                !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                !value.hasPrefix("-")
            else {
                throw PolicyError.invalidRule(field, rawValue)
            }
            guard seen.insert(value).inserted else { throw PolicyError.duplicateRule(field, value) }
            result.append(value)
        }
        return result.sorted()
    }

    private func boundedText(_ rawValue: String, field: String, maximum: Int, required: Bool = false) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !required || !value.isEmpty,
            value.count <= maximum,
            !value.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw PolicyError.invalidText(field, maximum)
        }
        return value
    }

    private func normalizedProjectRoot(_ rawValue: String?, profileID: String) throws -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.count <= Limit.pathCharacters,
            value.hasPrefix("/"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw PolicyError.invalidProjectRoot(profileID)
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path(percentEncoded: false)
    }
}

private struct PolicyDocument: Decodable {
    var schema: String
    var id: String
    var name: String
    var requiredPluginIDs: [String]
    var requiredMCPIDs: [String]
    var blockedPluginIDs: [String]
    var profiles: [PolicyProfileTemplate]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, id, name, requiredPluginIDs, requiredMCPIDs, blockedPluginIDs, profiles
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        requiredPluginIDs = try container.decodeIfPresent([String].self, forKey: .requiredPluginIDs) ?? []
        requiredMCPIDs = try container.decodeIfPresent([String].self, forKey: .requiredMCPIDs) ?? []
        blockedPluginIDs = try container.decodeIfPresent([String].self, forKey: .blockedPluginIDs) ?? []
        profiles = try container.decodeIfPresent([PolicyProfileTemplate].self, forKey: .profiles) ?? []
    }
}

private struct PolicyProfileTemplate: Decodable {
    var id: String
    var name: String
    var summary: String
    var inheritedFrom: String?
    var projectRoot: String?
    var checks: [PolicyCheckTemplate]
    var enabledPlugins: [String]
    var requiredMCPs: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, summary, inheritedFrom, projectRoot, checks, enabledPlugins, requiredMCPs
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        inheritedFrom = try container.decodeIfPresent(String.self, forKey: .inheritedFrom)
        projectRoot = try container.decodeIfPresent(String.self, forKey: .projectRoot)
        checks = try container.decodeIfPresent([PolicyCheckTemplate].self, forKey: .checks) ?? []
        enabledPlugins = try container.decodeIfPresent([String].self, forKey: .enabledPlugins) ?? []
        requiredMCPs = try container.decodeIfPresent([String].self, forKey: .requiredMCPs) ?? []
    }
}

private struct PolicyCheckTemplate: Decodable {
    var id: String
    var name: String
    var detail: String
    var state: HealthState
    var manual: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, detail, state, manual
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        state = try container.decodeIfPresent(HealthState.self, forKey: .state) ?? .pending
        manual = try container.decodeIfPresent(Bool.self, forKey: .manual) ?? false
    }
}

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    let keys = try decoder.container(keyedBy: AnyCodingKey.self).allKeys.map(\.stringValue)
    let unknown = Set(keys).subtracting(allowed).sorted()
    guard unknown.isEmpty else {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized field\(unknown.count == 1 ? "" : "s"): \(unknown.joined(separator: ", "))."))
    }
}

enum PolicyError: LocalizedError, Sendable {
    case invalidSource(String)
    case fileTooLarge(Int)
    case invalidDocument(String)
    case unsupportedSchema(String)
    case invalidProfileID(String)
    case invalidProjectRoot(String)
    case invalidText(String, Int)
    case tooManyProfiles(Int)
    case tooManyChecks(String, Int)
    case tooManyRules(String, Int)
    case invalidRule(String, String)
    case duplicateRule(String, String)
    case duplicateProfileID
    case duplicateCheckID(String)
    case missingParent(String, String)
    case inheritanceCycle(String)
    case conflictingPluginRule(String)
    case changedWhileReading(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource(let path): "The managed-policy source must be a regular, non-symlinked local file: \(path)."
        case .fileTooLarge(let maximum): "The managed-policy file exceeds the \(maximum)-byte safety limit."
        case .invalidDocument(let detail): "The managed-policy document is invalid: \(detail)"
        case .unsupportedSchema(let schema): "Unsupported managed-policy schema: \(schema)."
        case .invalidProfileID(let id): "The managed policy contains an invalid configuration identifier: \(id)."
        case .invalidProjectRoot(let id): "Managed configuration \(id) has an invalid project root. Use an absolute local path or omit it."
        case .invalidText(let field, let maximum): "The managed-policy \(field) is invalid or exceeds \(maximum) characters."
        case .tooManyProfiles(let maximum): "A managed policy can contain at most \(maximum) configurations."
        case .tooManyChecks(let id, let maximum): "Managed configuration \(id) can contain at most \(maximum) checks."
        case .tooManyRules(let field, let maximum): "A managed policy can contain at most \(maximum) \(field) rules."
        case .invalidRule(let field, let id): "The managed policy contains an invalid \(field) identifier: \(id)."
        case .duplicateRule(let field, let id): "The managed policy repeats the \(field) identifier \(id)."
        case .duplicateProfileID: "Managed configuration identifiers must be unique."
        case .duplicateCheckID(let id): "Managed configuration \(id) contains duplicate check identifiers."
        case .missingParent(let id, let parent): "Managed configuration \(id) inherits from missing configuration \(parent)."
        case .inheritanceCycle(let id): "Managed configuration inheritance contains a cycle at \(id)."
        case .conflictingPluginRule(let id): "The managed policy both requires and blocks plugin \(id)."
        case .changedWhileReading(let path): "The managed-policy file changed while it was being inspected: \(path)"
        }
    }
}

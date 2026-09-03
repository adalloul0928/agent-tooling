import Foundation

public struct ValidatedConfigurationFields: Sendable, Equatable {
    public var name: String
    public var summary: String
    public var projectRoot: String?

    public init(name: String, summary: String, projectRoot: String?) {
        self.name = name
        self.summary = summary
        self.projectRoot = projectRoot
    }
}

public enum ConfigurationValidator {
    public static let editableScopes: Set<ToolingScope> = [.user, .project, .localProject, .workspace]
    public static let maximumNameLength = 128
    public static let maximumSummaryLength = 4_096
    public static let maximumProjectPathLength = 4_096
    public static let maximumDesiredStateItems = 1_024
    public static let maximumDesiredStateIDLength = 512

    public static func validateProfile(
        name: String,
        summary: String,
        scope: ToolingScope,
        projectRoot: String?,
        fileManager: FileManager = .default
    ) throws -> ValidatedConfigurationFields {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard editableScopes.contains(scope) else {
            throw ConfigurationValidationError.unsupportedScope
        }
        guard !normalizedName.isEmpty,
            normalizedName.count <= maximumNameLength,
            !normalizedName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            (try? WorkspaceLibrary.normalizedIdentifier(normalizedName)) != nil
        else {
            throw ConfigurationValidationError.invalidName
        }
        let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedSummary.count <= maximumSummaryLength,
            !normalizedSummary.unicodeScalars.contains(where: isUnsafeControlCharacter)
        else {
            throw ConfigurationValidationError.invalidSummary
        }
        let root = try normalizedScopedRoot(
            scope: scope,
            value: projectRoot,
            noun: "configuration",
            fileManager: fileManager
        )
        return ValidatedConfigurationFields(name: normalizedName, summary: normalizedSummary, projectRoot: root)
    }

    public static func normalizedScopedRoot(
        scope: ToolingScope,
        value: String?,
        noun: String,
        fileManager: FileManager = .default
    ) throws -> String? {
        guard scope != .user else { return nil }
        let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawValue.isEmpty,
            rawValue.count <= maximumProjectPathLength,
            rawValue.hasPrefix("/"),
            !rawValue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ConfigurationValidationError.missingProjectRoot(noun)
        }
        let directURL = URL(fileURLWithPath: rawValue, isDirectory: true).standardizedFileURL
        let directValues = try? directURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directValues?.isSymbolicLink != true else {
            throw ConfigurationValidationError.invalidProjectRoot(noun, rawValue)
        }
        let url = directURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ConfigurationValidationError.invalidProjectRoot(noun, rawValue)
        }
        return url.path(percentEncoded: false)
    }

    public static func normalizedDesiredStateIDs(_ values: [String], kind: String) throws -> [String] {
        guard values.count <= maximumDesiredStateItems else {
            throw ConfigurationValidationError.tooManyItems(kind)
        }
        var result = Set<String>()
        for rawValue in values {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                value.count <= maximumDesiredStateIDLength,
                !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw ConfigurationValidationError.invalidItem(kind, rawValue)
            }
            guard !value.hasPrefix("-") else {
                throw ConfigurationValidationError.invalidItem(kind, rawValue)
            }
            result.insert(value)
        }
        return result.sorted()
    }

    private static func isUnsafeControlCharacter(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 && ![0x09, 0x0A, 0x0D].contains(scalar.value)
    }
}

enum ConfigurationValidationError: LocalizedError, Sendable {
    case unsupportedScope
    case invalidName
    case invalidSummary
    case missingProjectRoot(String)
    case invalidProjectRoot(String, String)
    case tooManyItems(String)
    case invalidItem(String, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedScope: "Choose This Mac, Project, This project only, or Workspace scope."
        case .invalidName:
            "Give the configuration a name that produces a unique identifier of at most 64 letters, numbers, and single hyphens."
        case .invalidSummary: "The configuration summary must be at most 4,096 characters and contain only normal text controls."
        case .missingProjectRoot(let noun): "Choose an existing project folder for this \(noun)'s project or workspace scope."
        case .invalidProjectRoot(let noun, let path): "The selected project folder for this \(noun) is not available: \(path)."
        case .tooManyItems(let kind): "The configuration contains too many \(kind) entries."
        case .invalidItem(let kind, let value): "The configuration contains an invalid \(kind) identifier: \(value)."
        }
    }
}

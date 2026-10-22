import Foundation

public enum ConfigurationValidator {
    public static let editableScopes: Set<ToolingScope> = [.user, .project, .localProject, .workspace]
    public static let maximumProjectPathLength = 4_096

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

import Foundation

public enum NativeSkillDestinationError: Error, Equatable, Sendable {
    case unsupportedScope
    case invalidHomeURL
    case missingProjectRoot
    case invalidProjectRoot
    case invalidSkillID
}

/// Pure routing for native CLI skill directories. Callers must establish any
/// filesystem facts, including project-root existence and symlink safety,
/// before passing roots to this type.
public enum NativeSkillDestination {
    public static func directory(
        client: ClientKind,
        homeURL: URL,
        scope: ToolingScope,
        projectRoot: URL?
    ) throws -> URL {
        let home = try validatedRoot(homeURL, error: .invalidHomeURL)
        let root: URL
        switch scope {
        case .user:
            root = home
        case .project:
            guard let projectRoot else { throw NativeSkillDestinationError.missingProjectRoot }
            root = try validatedRoot(projectRoot, error: .invalidProjectRoot)
        case .localProject, .workspace, .managed, .account, .session:
            throw NativeSkillDestinationError.unsupportedScope
        }

        let relativeDirectory: String
        switch client {
        case .claude: relativeDirectory = ".claude/skills"
        case .codex: relativeDirectory = ".agents/skills"
        case .gemini: relativeDirectory = ".gemini/skills"
        }
        return root.appending(path: relativeDirectory, directoryHint: .isDirectory)
    }

    public static func skillURL(
        client: ClientKind,
        skillID: String,
        homeURL: URL,
        scope: ToolingScope,
        projectRoot: URL?
    ) throws -> URL {
        try validateSkillID(skillID)
        return try directory(client: client, homeURL: homeURL, scope: scope, projectRoot: projectRoot)
            .appending(path: skillID, directoryHint: .isDirectory)
    }

    private static func validatedRoot(_ value: URL, error: NativeSkillDestinationError) throws -> URL {
        guard isValidRoot(value) else { throw error }
        return value
    }

    /// Lexical validation only. Foundation standardization can change the
    /// trailing directory marker based on existence; routing must not consult
    /// the filesystem or reject an otherwise identical existing directory.
    static func isValidRoot(_ value: URL) -> Bool {
        guard value.isFileURL, value.host == nil || value.host == "" || value.host == "localhost",
              value.query == nil, value.fragment == nil, value.user == nil, value.password == nil else { return false }
        let path = value.path(percentEncoded: false)
        let parts = path.split(separator: "/")
        return path.hasPrefix("/") && !path.contains("//") && !parts.contains(".") && !parts.contains("..")
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validateSkillID(_ value: String) throws {
        guard !value.isEmpty,
              value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw NativeSkillDestinationError.invalidSkillID }
    }
}

import Foundation

public enum WorkspaceIdentifierError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
}

/// The name a tool goes by on disk and in a client's own configuration.
///
/// Deliberately narrow: lowercase letters, digits and single hyphens. These end
/// up as directory names and as identifiers a client parses, so anything that
/// could be read as a path, a flag or a shell token is refused rather than
/// escaped. A name that needs escaping somewhere is a name that will be
/// unescaped wrongly somewhere else.
public enum WorkspaceLibrary {
    public static let maximumIdentifierLength = 64
    /// A skill's own one-line purpose, and the longest project path this build
    /// will record. Both are bounds on text people supply, kept here beside the
    /// identifier rules for the same reason: everything in this file limits what
    /// a name or a path may be before it reaches a file system or a client.
    public static let maximumPurposeLength = 4_096
    public static let maximumProjectPathLength = 4_096
    /// What a skill may declare about when it applies. Bounded so a pasted
    /// definition cannot make an unbounded amount of text load into every
    /// session that reads it.
    public static let maximumTriggerCount = 20
    public static let maximumTriggerLength = 512
    public static let maximumNegativeTriggerLength = 4_096

    public static func normalizedIdentifier(_ rawValue: String) throws -> String {
        let lowered = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !lowered.isEmpty,
              lowered.count <= maximumIdentifierLength,
              lowered.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !lowered.hasPrefix("-"),
              !lowered.hasSuffix("-"),
              !lowered.contains("--")
        else {
            throw WorkspaceIdentifierError.invalidIdentifier(rawValue)
        }
        return lowered
    }
}

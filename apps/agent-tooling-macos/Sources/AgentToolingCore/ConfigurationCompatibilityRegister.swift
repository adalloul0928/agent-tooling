import Foundation

/// One recorded fact about a vendor's configuration, with where it came from
/// and what this build does about it.
///
/// The register exists so a vendor change is a review obligation rather than a
/// silent drift: every setting an adapter claims to understand must appear
/// here, and a test enforces that. Nothing here is generated from vendor
/// documentation automatically — a changed upstream schema is something a
/// person reads and decides about.
public struct ConfigurationCompatibilityEntry: Hashable, Sendable {
    public enum Direction: String, Hashable, Sendable {
        /// This build reads and explains the value.
        case read
        /// This build reads it and can write it back into a supported layer.
        case readAndWrite
    }

    public let surface: TargetSurface
    public let key: String
    /// The releases this fact was recorded against.
    public let versionRange: String
    /// The vendor page this was read from.
    public let sourceURL: String
    public let direction: Direction
    /// Why anything is not supported, in the same terms the app uses.
    public let limitation: String?

    public init(
        surface: TargetSurface,
        key: String,
        versionRange: String,
        sourceURL: String,
        direction: Direction,
        limitation: String? = nil
    ) {
        self.surface = surface
        self.key = key
        self.versionRange = versionRange
        self.sourceURL = sourceURL
        self.direction = direction
        self.limitation = limitation
    }
}

public enum ConfigurationCompatibilityRegister {
    public static let recordedOn = "2026-09-09"

    public static let entries: [ConfigurationCompatibilityEntry] = [
        .init(surface: .claudeCode, key: "model", versionRange: "2.x",
              sourceURL: "https://code.claude.com/docs/en/settings", direction: .readAndWrite),
        .init(surface: .claudeCode, key: "permissions.allow", versionRange: "2.x",
              sourceURL: "https://code.claude.com/docs/en/settings", direction: .readAndWrite,
              limitation: "Layers combine; writing replaces only this file's own list."),
        .init(surface: .claudeCode, key: "permissions.deny", versionRange: "2.x",
              sourceURL: "https://code.claude.com/docs/en/settings", direction: .readAndWrite,
              limitation: "Layers combine; writing replaces only this file's own list."),
        .init(surface: .claudeCode, key: "hooks", versionRange: "2.x",
              sourceURL: "https://code.claude.com/docs/en/settings", direction: .read,
              limitation: "Hook definitions may need a native trust step this build cannot grant."),
        .init(surface: .claudeCode, key: "env", versionRange: "2.x",
              sourceURL: "https://code.claude.com/docs/en/settings", direction: .read,
              limitation: "Values can carry secrets, so this build reports rather than edits them."),
        .init(surface: .claudeCode, key: "includeCoAuthoredBy", versionRange: "2.x",
              sourceURL: "https://code.claude.com/docs/en/settings", direction: .readAndWrite),
        .init(surface: .claudeCode, key: "cleanupPeriodDays", versionRange: "2.x",
              sourceURL: "https://code.claude.com/docs/en/settings", direction: .readAndWrite),
        .init(surface: .codexCLI, key: "model", versionRange: "0.134.0+",
              sourceURL: "https://learn.chatgpt.com/docs/config-file/config-basic", direction: .read,
              limitation: "TOML keeps comments and formatting this build cannot reproduce faithfully."),
        .init(surface: .codexCLI, key: "model_provider", versionRange: "0.134.0+",
              sourceURL: "https://learn.chatgpt.com/docs/config-file/config-basic", direction: .read,
              limitation: "TOML keeps comments and formatting this build cannot reproduce faithfully."),
        .init(surface: .codexCLI, key: "approval_policy", versionRange: "0.134.0+",
              sourceURL: "https://learn.chatgpt.com/docs/config-file/config-basic", direction: .read,
              limitation: "TOML keeps comments and formatting this build cannot reproduce faithfully."),
        .init(surface: .codexCLI, key: "sandbox_mode", versionRange: "0.134.0+",
              sourceURL: "https://learn.chatgpt.com/docs/config-file/config-basic", direction: .read,
              limitation: "TOML keeps comments and formatting this build cannot reproduce faithfully."),
        .init(surface: .codexCLI, key: "profile", versionRange: "0.134.0+",
              sourceURL: "https://learn.chatgpt.com/docs/config-file/config-advanced", direction: .read,
              limitation: "Named profiles moved to separate files in 0.134.0; older layouts are read, never rewritten."),
        .init(surface: .codexCLI, key: "mcp_servers", versionRange: "0.134.0+",
              sourceURL: "https://learn.chatgpt.com/docs/config-file/config-advanced", direction: .read,
              limitation: "Recorded by name only; this build does not interpret a server table's contents."),
    ]

    public static func entry(surface: TargetSurface, key: String) -> ConfigurationCompatibilityEntry? {
        entries.first { $0.surface == surface && $0.key == key }
    }

    /// True when this build would write the setting rather than only explain it.
    public static func isWritable(surface: TargetSurface, key: String) -> Bool {
        entry(surface: surface, key: key)?.direction == .readAndWrite
    }
}

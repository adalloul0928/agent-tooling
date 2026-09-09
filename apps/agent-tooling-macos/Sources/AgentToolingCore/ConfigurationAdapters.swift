import Foundation

/// A dotted release, compared numerically so "0.9" sorts below "0.134".
struct ClientVersion: Comparable, Sendable {
    let components: [Int]

    init?(_ text: String?) {
        guard let text else { return nil }
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var values: [Int] = []
        for part in parts {
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            values.append(value)
        }
        guard !values.isEmpty else { return nil }
        components = values
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// Claude Code's documented layering. Managed policy constrains lower layers,
/// and hook and instruction lists combine rather than replace.
public struct ClaudeCodeConfigurationAdapter: ConfigurationAdapter {
    public let surface: TargetSurface = .claudeCode

    public init() {}

    public func precedence(installedClientVersion: String?) -> [ConfigurationLayerKind] {
        [.managedPolicy, .commandLine, .session, .localProject, .project, .user, .builtInDefault]
    }

    public func activeLayers(installedClientVersion: String?) -> Set<ConfigurationLayerKind> {
        Set(precedence(installedClientVersion: installedClientVersion))
    }

    public func settings(installedClientVersion: String?) -> [ConfigurationSettingDefinition] {
        [
            .init(key: "model", displayName: "Model", rule: .replace, requiresNewSession: true),
            .init(key: "permissions.allow", displayName: "Allowed tools",
                  rule: .combineList, requiresNewSession: true),
            .init(key: "permissions.deny", displayName: "Denied tools",
                  rule: .combineList, requiresNewSession: true),
            .init(key: "hooks", displayName: "Hooks", rule: .combineList, requiresNewSession: true),
            .init(key: "env", displayName: "Environment", rule: .replace, requiresNewSession: true),
            .init(key: "includeCoAuthoredBy", displayName: "Co-authored-by attribution",
                  rule: .replace, requiresNewSession: false),
            .init(key: "cleanupPeriodDays", displayName: "Transcript retention",
                  rule: .replace, requiresNewSession: false),
        ]
    }
}

/// Codex reads one local configuration plus an optional named profile. Profiles
/// moved to separate `<name>.config.toml` files in 0.134.0, so both documented
/// layouts stay readable and neither is rewritten on discovery.
public struct CodexConfigurationAdapter: ConfigurationAdapter {
    /// Codex moved named profiles into separate files in this release.
    public static let separateProfileFilesFrom = "0.134.0"

    public let surface: TargetSurface = .codexCLI
    /// Which profile file layout this Mac's installed release uses.
    public var usesSeparateProfileFiles: Bool

    public init(installedClientVersion: String? = nil) {
        let installed = ClientVersion(installedClientVersion)
        let boundary = ClientVersion(Self.separateProfileFilesFrom)!
        // An unknown version claims neither layout.
        usesSeparateProfileFiles = installed.map { $0 >= boundary } ?? false
    }

    /// Codex has no managed-policy layer and no project settings file; a
    /// project's trust state gates whether its directory is used at all.
    public func precedence(installedClientVersion: String?) -> [ConfigurationLayerKind] {
        [.commandLine, .session, .project, .user, .builtInDefault]
    }

    public func activeLayers(installedClientVersion: String?) -> Set<ConfigurationLayerKind> {
        Set(precedence(installedClientVersion: installedClientVersion))
    }

    public func settings(installedClientVersion: String?) -> [ConfigurationSettingDefinition] {
        [
            .init(key: "model", displayName: "Model", rule: .replace, requiresNewSession: true),
            .init(key: "model_provider", displayName: "Model provider",
                  rule: .replace, requiresNewSession: true),
            .init(key: "approval_policy", displayName: "Approval policy",
                  rule: .replace, requiresNewSession: true),
            .init(key: "sandbox_mode", displayName: "Sandbox", rule: .replace, requiresNewSession: true),
            .init(key: "profile", displayName: "Active profile", rule: .replace, requiresNewSession: true),
            .init(key: "mcp_servers", displayName: "MCP servers",
                  rule: .combineList, requiresNewSession: true),
        ]
    }
}

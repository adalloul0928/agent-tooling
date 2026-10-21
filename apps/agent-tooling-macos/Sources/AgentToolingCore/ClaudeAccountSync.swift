import Foundation

/// Protects account-synced skills and plugins from local inventory and writes.
/// Claude owns `~/.claude/skills/synced/` and reserved plugin origins, so local
/// changes would be overwritten and would not update the hosted account.
/// Sources: https://code.claude.com/docs/en/skills and
/// https://code.claude.com/docs/en/plugins/loading (Claude Code 2.1.300).
public enum ClaudeAccountSync {
    /// The folder under a Claude skills location that Claude Code keeps for
    /// downloaded account skills. Claude Code skips a skill authored at this
    /// name in any capitalization.
    public static let syncedSkillsFolderName = "synced"

    /// The namespace a synced skill answers to when its short name is taken,
    /// as in `/anthropic-skills:pdf`. A local skill folder named this way does
    /// not load outside a plugin.
    public static let syncedSkillNamespace = "anthropic-skills"

    /// Plugin origins Claude Code reserves. `synced` is the account's;
    /// `inline` is a session-only `--plugin-dir` plugin; `skills-dir` is a
    /// skill folder that carries a plugin manifest. None of them comes from a
    /// marketplace, so none of them can be installed, updated, or removed with
    /// a marketplace command.
    public static let syncedPluginOrigin = "synced"
    public static let reservedPluginOrigins: Set<String> = [syncedPluginOrigin, "inline", "skills-dir"]

    /// `~/.claude/skills/synced`.
    public static func syncedSkillsDirectory(homeURL: URL) -> URL {
        homeURL.appending(path: ".claude/skills", directoryHint: .isDirectory)
            .appending(path: syncedSkillsFolderName, directoryHint: .isDirectory)
    }

    /// Whether a top-level folder name under a Claude skills location is one
    /// Claude Code keeps for itself rather than loading as an authored skill.
    public static func isReservedSkillFolderName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == syncedSkillsFolderName
            || lowered == syncedSkillNamespace
            || lowered.hasPrefix(syncedSkillNamespace + ":")
    }

    /// Whether a path is the synced skills folder or anything inside it.
    /// Compared case-insensitively, on the reserved component the way Claude
    /// Code itself treats the name, and on the folders above it the way a
    /// case-insensitive volume does: this is a check that keeps the app's
    /// hands off, so any spelling of the folder is still the account's.
    public static func isInsideSyncedSkills(_ url: URL, homeURL: URL) -> Bool {
        let spellings = [url.standardizedFileURL, url.resolvingSymlinksInPath().standardizedFileURL]
        let candidates = Set(spellings.map { $0.path(percentEncoded: false) })
        // Only a path with a component that may be spelled `synced` can be
        // inside the folder. Any other is answered here, without a look at
        // `~/.claude`, so a scan of another app's skills never looks there.
        guard candidates.contains(where: hasSyncedComponent) else { return false }
        // The inventory reports skills at their resolved paths, so a `~/.claude`
        // that is itself a link is compared both as named and as resolved.
        // Following it is a look at `~/.claude/skills`, which a trace is told of.
        let skillsRoot = homeURL.appending(path: ".claude/skills", directoryHint: .isDirectory)
        defer { ScanTrace.read(skillsRoot) }
        let skillsRoots = [skillsRoot.standardizedFileURL, skillsRoot.resolvingSymlinksInPath().standardizedFileURL]
        let syncedFolders = Set(skillsRoots.map { $0.appending(path: syncedSkillsFolderName).path(percentEncoded: false) })
        return syncedFolders.contains { folder in
            candidates.contains { PathContainment.mightBeContained(normalizedChild: $0, inNormalizedRoot: folder) }
        }
    }

    /// Whether one of the path's components may name the synced folder, as
    /// `PathContainment.mightBeContained` compares names. The path is split
    /// at every separator scalar, as that comparison does, so a name that
    /// begins with a combining mark still starts its own component.
    private static func hasSyncedComponent(_ path: String) -> Bool {
        path.unicodeScalars.split(separator: "/").contains {
            PathContainment.mightBeSamePath(String($0), syncedSkillsFolderName)
        }
    }

    /// The origin after the last `@`, or nil when the identifier has none.
    public static func origin(ofPluginID id: String) -> String? {
        guard let at = id.lastIndex(of: "@"), at != id.startIndex else { return nil }
        let origin = id[id.index(after: at)...]
        return origin.isEmpty ? nil : String(origin)
    }

    /// The plugin's own name: the identifier without its origin.
    public static func pluginName(ofPluginID id: String) -> String {
        guard let at = id.lastIndex(of: "@"), at != id.startIndex else { return id }
        return String(id[..<at])
    }

    /// Whether a Claude Code plugin identifier is one the account supplies.
    public static func isSyncedPluginID(_ id: String) -> Bool {
        origin(ofPluginID: id) == syncedPluginOrigin
    }

    /// Whether a Claude Code plugin identifier names an origin no marketplace
    /// can use, so no marketplace command can act on it.
    public static func hasReservedOrigin(_ id: String) -> Bool {
        origin(ofPluginID: id).map(reservedPluginOrigins.contains) ?? false
    }

    /// The identifier Claude Code loads an account plugin under.
    public static func syncedPluginID(name: String) -> String {
        "\(name)@\(syncedPluginOrigin)"
    }
}

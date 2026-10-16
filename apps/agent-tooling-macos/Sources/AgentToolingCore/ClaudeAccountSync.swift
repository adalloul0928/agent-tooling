import Foundation

/// What Claude Code reserves for content it downloads from a claude.ai account.
///
/// A terminal session signed in with a claude.ai subscription downloads the
/// account's skills into `~/.claude/skills/synced/` and loads the account's
/// plugins as `<name>@synced`. Both are the account's, not this Mac's: Claude
/// Code overwrites or removes them on its next sync, and an edit made to them
/// here never reaches claude.ai. This app therefore never inventories them as
/// local tools, never offers to adopt, move, or remove them, and never builds
/// an install, update, or removal command for a reserved origin.
///
/// Verified against https://code.claude.com/docs/en/skills ("Reserved name
/// `synced`", "Where synced skills load") and
/// https://code.claude.com/docs/en/plugins/loading ("Plugins synced from
/// claude.ai": the origin names `inline`, `skills-dir` and `synced` are
/// reserved, so no marketplace can use them), and against Claude Code 2.1.300.
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
        // The inventory reports skills at their resolved paths, so a `~/.claude`
        // that is itself a link is compared both as named and as resolved.
        let skillsRoot = homeURL.appending(path: ".claude/skills", directoryHint: .isDirectory)
        let skillsRoots = [skillsRoot.standardizedFileURL, skillsRoot.resolvingSymlinksInPath().standardizedFileURL]
        let syncedFolders = Set(skillsRoots.map { $0.appending(path: syncedSkillsFolderName).path(percentEncoded: false) })
        let spellings = [url.standardizedFileURL, url.resolvingSymlinksInPath().standardizedFileURL]
        let candidates = Set(spellings.map { $0.path(percentEncoded: false) })
        return syncedFolders.contains { folder in
            candidates.contains { PathContainment.mightBeContained(normalizedChild: $0, inNormalizedRoot: folder) }
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

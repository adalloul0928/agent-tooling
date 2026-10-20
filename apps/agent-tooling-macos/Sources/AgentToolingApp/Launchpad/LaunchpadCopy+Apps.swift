import AgentToolingCore

/// Your apps (S02) and its empty Mac (V01): the words around the tiles, the
/// lines under each one, the two ways to look again, and what VoiceOver says
/// for the row and for each tile.
extension LaunchpadCopy.Apps {
    static let eyebrow = "Your coding agents"
    static let title = "Choose the apps this Mac manages"
    static let subtitle =
        "Codex, Claude Code, Gemini CLI and Kiro CLI are the coding agents Agent Tooling works with. Here they are your apps, under Apps in the sidebar."
    /// V01: nothing from any of the four apps was found.
    static let emptyTitle = "No apps found on this Mac yet"
    /// V01's bridge line. On an empty Mac "Here they are your apps" would
    /// promise apps that are not there; it still teaches the word.
    static let emptySubtitle =
        "Codex, Claude Code, Gemini CLI and Kiro CLI are the coding agents Agent Tooling works with. Once one is installed, it is one of your apps, under Apps in the sidebar."

    // The lines under a tile.

    static let foundAt = "Found at"
    static let notFound = "Not found"
    /// Under an app that was not found: opens the folders the locator
    /// checked.
    static let whereLooked = "Where Agent Tooling looked…"
    static let whereLookedTitle = "Where Agent Tooling looked"
    static func nothingFound(_ app: String) -> String {
        "Nothing from \(app) was found on this Mac."
    }

    /// A vendor's install page. It leaves Agent Tooling, so it is drawn with
    /// `arrow.up.right` after the words.
    static func howToInstall(_ app: String) -> String {
        "How to install \(app)"
    }

    /// The folders a lookup checks, in the order checked, as one sentence:
    /// "/opt/homebrew/bin, /usr/local/bin, ~/.local/bin, …, the system
    /// folders, mise and asdf shims, ~/bin."
    static func lookedIn(_ folders: [String]) -> String {
        folders.joined(separator: ", ") + "."
    }

    /// `/usr/bin`, `/bin`, `/usr/sbin` and `/sbin`, said once.
    static let systemFolders = "the system folders"
    /// mise's and asdf's shims, said once.
    static let shims = "mise and asdf shims"

    // The actions under the well.

    static let lookAgainWithLoginShell = "Look again with my login shell"
    static let lookAgain = "Look again"
    /// The login-shell button while the shell is asked.
    static let looking = "Looking…"
    /// What the login shell found that the fixed folders did not.
    static func loginShellFound(_ apps: String) -> String {
        "Your login shell found \(apps)."
    }

    static func loginShellFoundNothing(_ apps: String) -> String {
        "Your login shell does not know \(apps) either."
    }

    // The fine print.

    static let onlyLooked = "Agent Tooling has only looked for each app’s command. Nothing has been opened or run yet."
    static let turningOff = "Turning an app off changes nothing in it."
    /// V01's one line.
    static let worksWithout = "Your library works without an app; turn one on when it is installed."

    // The primary.

    /// "Manage 3 apps", "Manage 1 app".
    static func manage(_ count: Int) -> String {
        "Manage \(CountNoun.app.phrase(count))"
    }

    static let continueWithoutApps = "Continue without apps"

    // What VoiceOver says.

    /// The tile row as one sentence: "Apps: Codex, Claude Code and Gemini CLI
    /// found; Kiro CLI not found". Either half is left out when it is empty.
    static func rowSummary(found: [String], notFound: [String]) -> String {
        let parts = [
            found.isEmpty ? nil : "\(LaunchpadCopy.list(found)) found",
            notFound.isEmpty ? nil : "\(LaunchpadCopy.list(notFound)) not found",
        ].compactMap { $0 }
        return "Apps: " + parts.joined(separator: "; ")
    }

    /// One tile as a toggle: "Codex, found at /opt/homebrew/bin/codex,
    /// managed"; "Kiro CLI, not found, not managed".
    static func tileLabel(_ app: String, foundAt path: String?, managed: Bool) -> String {
        let found = path.map { "found at \($0)" } ?? "not found"
        let state = managed ? "managed" : "not managed"
        return "\(app), \(found), \(state)"
    }

    /// What a tile's key does: "Command-1 turns it off".
    static func tileHint(key: String, turnsOff: Bool) -> String {
        let way = turnsOff ? "off" : "on"
        return "\(key) turns it \(way)"
    }

    /// Posted once detection is drawn: "Found 3 of 4 apps."
    static func foundAnnouncement(_ found: Int, of total: Int) -> String {
        found == 0 ? "Found none of the \(total) apps." : "Found \(found) of \(total) apps."
    }
}

extension CountNoun {
    fileprivate static let app = CountNoun("app")
}

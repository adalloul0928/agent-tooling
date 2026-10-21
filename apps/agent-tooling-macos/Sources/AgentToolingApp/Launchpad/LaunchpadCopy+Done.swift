import AgentToolingCore
import Foundation

/// Done (S22): what happened, what is left for later, what runs on its own.
///
/// A name and its version, and a "·" and the words before it, are joined by
/// a space that never breaks a line (`glue`), so no line starts with "·" and
/// no version stands apart from its app.
extension LaunchpadCopy.Done {
    /// A space a line never breaks at.
    static let glue = "\u{00A0}"

    // The header.

    static let eyebrow = "What happened"

    /// "Set up, with 2 things left", or "All set" when nothing is.
    static func title(left: Int) -> String {
        left == 0 ? "All set" : "Set up, with \(CountNoun.thing.phrase(left)) left"
    }

    /// "Juniper · Saturday, October 17 · Run setup again from Settings ›
    /// General."
    static func subtitle(device: String?, date: String) -> String {
        let again = LaunchpadCopy.FinishSetup.runSetupAgain
        guard let device, !device.isEmpty else { return "\(date) · \(again)" }
        return "\(device) · \(date) · \(again)"
    }

    // What happened.

    /// "3 apps looked after: Codex 0.164.0, Claude Code 2.1.304, Gemini CLI
    /// 0.38.2 · Kiro CLI not found"; on an empty Mac, "0 apps looked after ·
    /// Codex, Claude Code, Gemini CLI and Kiro CLI not found".
    static func appsLookedAfter(_ apps: [(name: String, version: String?)], notFound: [String]) -> String {
        let named = apps.map { app in
            bound([app.name, app.version].compactMap { $0 }.joined(separator: " "))
        }
        var text = "\(CountNoun.app.phrase(apps.count)) looked after"
        if !named.isEmpty { text += ": " + named.joined(separator: ", ") }
        if !notFound.isEmpty { text += "\(glue)· \(LaunchpadCopy.list(notFound)) not found" }
        return text
    }

    /// "13 tools in your library (9 entries)".
    static func library(tools: Int, entries: Int) -> String {
        "\(CountNoun.tool.phrase(tools)) in your library (\(CountNoun.entry.phrase(entries)))"
    }

    /// On a join: "14 tools in your library (Db Migrations was found here)".
    static func library(tools: Int, foundHere names: [String]) -> String {
        let was = names.count == 1 ? "was" : "were"
        return "\(CountNoun.tool.phrase(tools)) in your library (\(LaunchpadCopy.list(names)) \(was) found here)"
    }

    /// "2 are now yours: Release Notes, Frontend Design".
    static func nowYours(_ names: [String]) -> String {
        let are = names.count == 1 ? "is" : "are"
        return "\(names.count) \(are) now yours: \(names.joined(separator: ", "))"
    }

    /// Two clauses of one line, the second bound to the first: "13 tools in
    /// your library (9 entries) · 2 are now yours: …".
    static func joined(_ first: String, _ second: String) -> String {
        "\(first)\(glue)· \(second)"
    }

    /// "Supabase’s contents appear after the next check."
    static func contentsAfterTheNextCheck(_ names: [String]) -> String {
        let owners = LaunchpadCopy.list(names.map(possessive))
        return "\(owners) contents appear after the next check."
    }

    /// "Supabase’s".
    private static func possessive(_ name: String) -> String {
        "\(name)’s"
    }

    /// "4 changes installed in 2 apps"; "1 change applied in 1 app" once a
    /// step took something out of an app, as the review's title said Apply.
    static func installed(changes: Int, apps: Int, hasRemoval: Bool = false) -> String {
        "\(installed(changes: changes, hasRemoval: hasRemoval)) in \(CountNoun.app.phrase(apps))"
    }

    /// "2 changes installed", when some did not finish and the apps are
    /// named with those instead.
    static func installed(changes: Int, hasRemoval: Bool = false) -> String {
        "\(CountNoun.change.phrase(changes)) \(hasRemoval ? "applied" : "installed")"
    }

    static let nothingInstalled = "Nothing was installed"

    /// "Nothing was installed", or "Nothing was changed" once a step would
    /// have taken something out.
    static func nothingInstalled(hasRemoval: Bool) -> String {
        hasRemoval ? "Nothing was changed" : nothingInstalled
    }

    /// "1 left alone (Frontend Design in Codex)".
    static func leftAlone(_ count: Int, named names: [String]) -> String {
        names.isEmpty ? "\(count) left alone" : "\(count) left alone (\(LaunchpadCopy.list(names)))"
    }

    /// "Frontend Design in Codex".
    static func item(_ name: String, in app: String) -> String {
        "\(name) in \(app)"
    }

    /// "1 did not finish (Claude Code)", or "1 did not finish" when no app
    /// is known.
    static func didNotFinish(_ count: Int, in apps: [String] = []) -> String {
        apps.isEmpty ? "\(count) did not finish" : "\(count) did not finish (\(LaunchpadCopy.list(apps)))"
    }

    /// "Agent Tooling connected to Codex and Claude Code".
    static func connected(to apps: String) -> String {
        "Agent Tooling connected to \(apps)"
    }

    /// "Synced just now with https://github.com/you/agent-tooling-workspace.git
    /// · ready for your other Mac". A join's ends at the address.
    static func synced(_ when: String, with address: String, readyForOtherMac: Bool) -> String {
        let synced = "Synced \(when) with \(LaunchpadCopy.Done.address(address))"
        return readyForOtherMac ? "\(synced)\(glue)· ready for your other Mac" : synced
    }

    /// Shares with a repository, with no pass finished yet this launch.
    static func shares(with address: String) -> String {
        "Shares this library with \(LaunchpadCopy.Done.address(address))"
    }

    /// The assistant's own runs as setup left them: "Weekly checkup review
    /// on, with Claude Code · daily deep dive off".
    static func assistantRuns(weekly: Bool, deepDive: Bool, with assistant: String) -> String {
        switch (weekly, deepDive) {
        case (true, false): "Weekly checkup review on, with \(assistant)\(glue)· daily deep dive off"
        case (true, true): "Weekly checkup review and daily deep dive on, with \(assistant)"
        case (false, true): "Daily deep dive on, with \(assistant)\(glue)· weekly checkup review off"
        case (false, false): "Weekly checkup review and daily deep dive off"
        }
    }

    /// "After the next check, Gemini CLI also shows Release Notes, because it
    /// reads ~/.agents/skills."
    static func alsoShows(_ app: String, _ skill: String, reading folder: String) -> String {
        "After the next check, \(app) also shows \(skill), because it reads \(folder)."
    }

    // Left for later.

    /// "Left for later · 2".
    static func leftForLater(_ count: Int) -> String {
        "Left for later · \(count)"
    }

    /// "Home adds 2 suggestions".
    static func homeAdds(_ count: Int) -> String {
        "Home adds \(CountNoun.suggestion.phrase(count))"
    }

    /// "4 things left on Checkup".
    static func leftOnCheckup(_ count: Int) -> String {
        "\(CountNoun.thing.phrase(count)) left on Checkup"
    }

    /// The Checkup card while the audit that Done runs is under way.
    static let checking = "Checking…"

    /// "Webapp Testing unmanaged in Codex and in Claude Code".
    static func unmanaged(_ name: String, in apps: [String]) -> String {
        let places = LaunchpadCopy.list(apps.map(inApp))
        return "\(name) unmanaged \(places)"
    }

    /// "in Codex".
    private static func inApp(_ app: String) -> String {
        "in \(app)"
    }

    /// "Context7 and Playwright each configured in two apps".
    static func configuredSeparately(_ names: [String], apps: Int) -> String {
        let each = names.count > 1 ? " each" : ""
        return "\(LaunchpadCopy.list(names))\(each) configured in \(LaunchpadCopy.FinishSetup.spelled(apps)) apps"
    }

    /// Checkup's subjects, one clause per kind: "Webapp Testing unmanaged in
    /// Codex and in Claude Code; Context7 and Playwright each configured in
    /// two apps".
    static func subjects(_ clauses: [String]) -> String {
        clauses.joined(separator: "; ")
    }

    /// "Agent Tooling is not connected to Cedar’s apps yet".
    static func notConnected(device: String?) -> String {
        guard let device, !device.isEmpty else { return "Agent Tooling is not connected to this Mac’s apps yet" }
        return "Agent Tooling is not connected to \(device)’s apps yet"
    }

    /// "4 changes wait for your review".
    static func waitForReview(_ count: Int) -> String {
        let wait = count == 1 ? "waits" : "wait"
        return "\(CountNoun.change.phrase(count)) \(wait) for your review"
    }

    // What runs on its own.

    static let runsOnItsOwn = "Runs on its own"
    static let onlyWhileOpen = "only while Agent Tooling is open"
    static let whenItOpens = "When it opens:"
    static let onceADay = "Once a day:"
    static let weekly = "Weekly:"
    static let daily = "Daily:"
    static let afterAChange = "After a change:"
    static let checkAppsPart = "check apps"
    static let lookForUpdates = "look for updates"
    static let syncWithOtherMacs = "sync with your other Macs"
    static let nothingRuns = "Nothing runs on its own."

    /// "the checkup review, with Claude Code".
    static func checkupReview(with assistant: String) -> String {
        "the checkup review, with \(assistant)"
    }

    /// "the deep dive, with Claude Code".
    static func deepDive(with assistant: String) -> String {
        "the deep dive, with \(assistant)"
    }

    /// "sync with your other Macs, at most every 15 minutes".
    static func syncAtMost(everyMinutes minutes: Int) -> String {
        "\(syncWithOtherMacs), at most every \(minutes) minutes"
    }

    /// One part of what runs, spoken: "When it opens: check apps, look for
    /// updates".
    static func run(_ lead: String, _ text: String) -> String {
        "\(lead) \(text)"
    }

    // The key strip: keys of the main window, taught here and never bound
    // on the stage.

    static let keySearch = "Search everything"
    static let keyReview = "Review changes"
    static let keyCheckApps = "Check apps"

    /// "Search everything, Command-K".
    static func key(_ action: String, spoken keys: String) -> String {
        "\(action), \(keys)"
    }

    // The bookend tiles.

    static let notFound = "Not found"
    static let skipped = "Skipped"

    /// "Apps: Codex, Claude Code and Gemini CLI looked after; Kiro CLI not
    /// found".
    static func tilesLabel(lookedAfter: [String], notFound: [String]) -> String {
        var parts: [String] = []
        if !lookedAfter.isEmpty { parts.append("\(LaunchpadCopy.list(lookedAfter)) looked after") }
        if !notFound.isEmpty { parts.append("\(LaunchpadCopy.list(notFound)) not found") }
        return "Apps: " + parts.joined(separator: "; ")
    }

    // The footer.

    static let openCheckup = LaunchpadCopy.FinishSetup.openCheckup

    /// An address as one line shows it: it may break after its last slash,
    /// never inside the name after it.
    static func address(_ address: String) -> String {
        guard let slash = address.lastIndex(of: "/"), address.index(after: slash) < address.endIndex else { return address }
        let head = address[...slash]
        let name = address[address.index(after: slash)...].replacingOccurrences(of: "-", with: "\u{2011}")
        return "\(head)\u{200B}\(name)"
    }

    /// `text` with its spaces held together, so it never breaks a line.
    static func bound(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: glue)
    }
}

extension CountNoun {
    fileprivate static let app = CountNoun("app")
    fileprivate static let tool = CountNoun("tool")
    fileprivate static let entry = CountNoun("entry", plural: "entries")
    fileprivate static let thing = CountNoun("thing")
    fileprivate static let suggestion = CountNoun("suggestion")
}

import AgentToolingCore
import Foundation

/// Join your library (J01, V08) and You joined (J02).
extension LaunchpadCopy.Join {
    static let eyebrow = "Join"
    static let title = "Join your library"
    static let subtitle =
        "Paste the repository address from Settings › Sync on your other Mac. Git uses the sign-in it already has; Agent Tooling never asks for a password."

    // The apps strip.

    static let appsLabel = "This Mac’s apps"
    static let readsOnlyThese = "Joining reads only these"

    /// "Reads 9 places and runs 8 commands here".
    static func reads(places: Int, commands: Int) -> String {
        let read = count(places, "place", "places")
        let run = count(commands, "command", "commands")
        return "Reads \(read) and runs \(run) here"
    }

    /// Opens the full list of what the join reads.
    static let whatItReads = "What it reads…"
    /// Under a tile whose app was not found.
    static func notFound(_ app: String) -> String {
        "\(app) · Not found"
    }

    /// A tile, as VoiceOver reads it.
    static func tileLabel(_ app: String, found: Bool, chosen: Bool) -> String {
        let place = found ? "found" : "not found"
        let read = chosen ? "read when joining" : "not read"
        return "\(app), \(place), \(read)"
    }

    /// "Command-1 leaves it out."
    static func tileHint(_ shortcut: String, chosen: Bool) -> String {
        let does = chosen ? "leaves it out" : "reads it too"
        return "\(shortcut) \(does)."
    }

    /// The row of tiles, as one group.
    static func tilesLabel(chosen: [String]) -> String {
        chosen.isEmpty ? "Joining reads none of this Mac’s apps" : "Joining reads \(LaunchpadCopy.list(chosen))"
    }

    // The popover.

    static let readsList = "Reads"
    static let runsList = "Runs"
    static let signInList = "How your apps sign in"
    /// After the login shell in the sign-in list.
    static func shellVariablesOnly(_ count: Int) -> String {
        "(names of \(count) sign-in variables only)"
    }

    static let fetchesAfter = "Then Git fetches your library into Agent Tooling’s own folder."

    // Under the fields.

    /// Under the fields, before the checks: on `mac`, or on "this Mac" until
    /// its name has been read.
    static func consent(mac: String?) -> String {
        let mac = mac ?? "this Mac"
        return
            "Joining reads what these apps hold on \(mac), the same places a new library reads. Nothing is installed until you review it."
    }

    // Before joining: the preflight's four checks.

    static let beforeJoining = "Before joining"
    static let gitInstalled = "Git is installed"
    /// "github.com answered".
    static func answered(host: String?) -> String {
        host.map { "\($0) answered" } ?? "The repository answered"
    }

    static let holdsLibrary = "It holds a library"
    /// "It holds a library (13 tools)".
    static func holdsLibrary(tools: Int) -> String {
        let held = count(tools, "tool", "tools")
        return "It holds a library (\(held))"
    }

    static let buildCanRead = "This build can read it"
    static let notCheckedYet = "Not checked yet"

    // Where a check stopped: the row's words, and the banner's title.

    static let gitMissing = "Git is not installed"
    static let couldNotReach = "Couldn’t reach that repository"
    static let noLibrary = "No library to join there"
    static let cannotRead = "This build can’t read it"
    /// Any other reason a join did not go on.
    static let couldNotJoin = "Couldn’t join"

    // A step, as VoiceOver reads it.

    static func stepDone(_ step: String) -> String { "\(step), done" }
    static func stepRunning(_ step: String) -> String { "\(step), under way" }
    static func stepWaiting(_ step: String) -> String { "\(step), not started" }
    static func stepNotChecked(_ step: String) -> String { "\(step), not checked yet" }
    static func stepFailed(_ step: String) -> String { "\(step), failed" }

    // Joining: the join's five steps.

    static let joining = "Joining"
    static let reachingRepository = "Reaching the repository"
    static let readingLibrary = "Reading your library"
    /// "Reading your library (13 tools)".
    static func readingLibrary(tools: Int) -> String {
        let held = count(tools, "tool", "tools")
        return "Reading your library (\(held))"
    }

    static let checkingApps = "Checking this Mac’s apps"
    /// "Registering “Cedar”", or "Registering this Mac" until its name has
    /// been read.
    static func registering(_ name: String?) -> String {
        name.map { "Registering “\($0)”" } ?? "Registering this Mac"
    }

    static let sharing = "Sharing"
    static let notStarted = "Not started"

    // The footer.

    /// "Join as Cedar".
    static func joinAs(_ name: String) -> String {
        "Join as \(name)"
    }

    /// The primary before this Mac's name has been read.
    static let joinUnnamed = "Join"

    static let joiningBusy = "Joining…"
    static let tryAgain = "Try again"
    static let finishJoining = "Finish joining"

    // Finish joining: the join stopped after this Mac's store was made.

    static let stoppedTitle = "Joining stopped before it finished"
    static let stoppedMessage = "Finish joining completes it; nothing in your apps changes."
    static let nothingToFinishTitle = "There is nothing to finish"

    // You joined (J02).

    /// "You joined as Cedar".
    static func joinedAs(_ name: String) -> String {
        "You joined as \(name)"
    }

    /// "2 of your own skills came across."
    static func skillsCameAcross(_ count: Int) -> String {
        count == 0 ? "Your library came across." : "\(count) of your own skills came across."
    }

    static let rename = "Rename…"
    static let renameTitle = "This Mac’s name"
    static let renameConfirm = "Rename"
    static let cancel = "Cancel"

    /// Under the well, for each other Mac: "Juniper · published 6 min ago ·
    /// Codex 0.164.0 · Claude Code 2.1.304".
    static func otherMacLine(name: String, published: String?, apps: [(name: String, version: String)]) -> String {
        let when = published.map { "published \($0)" } ?? "not published yet"
        return ([name, when] + apps.map { "\($0.name) \($0.version)" }).joined(separator: " · ")
    }

    /// How long ago another Mac published, as the line under the well says it.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) hr ago" }
        return SnapshotTime.compact(date, now: now)
    }

    /// Between the two Macs in the well: "Same library · 13 tools".
    static func sameLibrary(tools: Int) -> String {
        let held = count(tools, "tool", "tools")
        return "Same library · \(held)"
    }

    /// Under another Mac's name: no model is published, so none is shown.
    static let otherMac = "other Mac"
    /// Under this Mac's name: "Mac mini · macOS 26 · this Mac".
    static func thisMac(family: String?, systemVersion: Int) -> String {
        ([family, "macOS \(systemVersion)", "this Mac"] as [String?]).compactMap(\.self).joined(separator: " · ")
    }

    /// The well, as VoiceOver reads it.
    static func macsLabel(other: String, this: String, tools: Int) -> String {
        let held = count(tools, "tool", "tools")
        return "\(other), other Mac, and \(this), this Mac: the same library of \(held)"
    }

    /// The arrivals card's heading: "Juniper shares 3 tools with every Mac".
    static func shares(_ mac: String, tools: Int) -> String {
        let shared = count(tools, "tool", "tools")
        return tools == 0 ? "Nothing from \(mac) to install here" : "\(mac) shares \(shared) with every Mac"
    }

    /// The heading while what arrived is still being worked out.
    static func whatIsShared(_ mac: String) -> String {
        "What \(mac) shares with every Mac"
    }

    static let policy = "Nothing from another Mac installs here until you press Install."
    /// While the first pass and the review of what arrived run.
    static func checkingShared(_ mac: String) -> String {
        "Checking what \(mac) shares…"
    }

    /// Under an arrival's name: "Into Codex and Claude Code".
    static func into(_ apps: [String]) -> String {
        "Into \(LaunchpadCopy.list(apps))"
    }

    /// "2 installs".
    static func installs(_ count: Int) -> String {
        LaunchpadCopy.Join.count(count, "install", "installs")
    }

    /// An arrival whose files are not in the library yet: left out, and why.
    static let noVerifiedCopy = "No verified copy in your library yet"

    /// Agent Tooling's own connection, bound to each Mac.
    static let ownConnection = "Agent Tooling’s own connection"
    /// "Set up on Juniper only".
    static func setUpOn(_ macs: [String]) -> String {
        "Set up on \(LaunchpadCopy.list(macs)) only"
    }

    static let setUpHereToo = "Set up on this Mac too"
    /// When no other Mac has it.
    static let setUpHere = "Set up on this Mac"
    static let connectHereToo = "Connect it here too"

    /// The footer's secondary, and its help tag.
    static let installLater = "Install later"
    static let installLaterHelp = "They stay on Home under From your other Macs."
    /// "Review 5 changes…".
    static func review(_ count: Int) -> String {
        let changes = LaunchpadCopy.Join.count(count, "change", "changes")
        return "Review \(changes)…"
    }

    /// "1 tool", "13 tools".
    static func count(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value) \(value == 1 ? one : many)"
    }

    enum Failures {
        /// The name could not be changed, for the registry's reason.
        static func notRenamed(_ reason: String) -> String {
            reason.hasSuffix("Nothing was changed.") ? reason : "\(reason) Nothing was changed."
        }

        /// Rename… while this Mac is sharing with the others.
        static let renameWhileSharing = "This Mac is sharing with your other Macs. Rename it again in a moment. Nothing was changed."

        /// What another Mac shares could not be worked out here, for the
        /// plan's reason when it gave one.
        static func notWorkedOut(_ mac: String, reason: String?) -> String {
            let closing = "Nothing was changed."
            let said = reason.map { reason in
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasSuffix(closing) else { return trimmed }
                return String(trimmed.dropLast(closing.count)).trimmingCharacters(in: .whitespaces)
            }
            guard let said, !said.isEmpty else {
                return "Agent Tooling could not work out what \(mac) shares here. Nothing was changed."
            }
            return "Agent Tooling could not work out what \(mac) shares here. \(said) Nothing was changed."
        }
    }
}

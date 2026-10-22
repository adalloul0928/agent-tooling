import AgentToolingCore

// Before you start (S00) and Let your apps ask Agent Tooling (S11): the
// fragments' words, and the NEW sentences of plan §6, each pinned by
// `LaunchpadHelperWordingTests`.

extension LaunchpadCopy.Helper {
    // MARK: Before you start

    static let moveTitle = "Put Agent Tooling in Applications"
    static let moveSubtitle = "Your apps and Raycast find Agent Tooling by where it lives."
    static let runningFrom = "Running from"
    static let movesTo = "Moves to"

    /// Row 1 for a copy on a mounted disk image: "The disk image “Agent
    /// Tooling”".
    static func diskImage(named volume: String) -> String {
        "The disk image “\(volume)”"
    }

    /// Row 1 for a copy macOS translocated.
    static let temporaryPlace = "A temporary place macOS chose"
    /// Row 1 for a copy in Downloads (NEW).
    static let downloadsFolder = "Your Downloads folder"
    /// Row 1 for a copy in any other folder (NEW).
    static let folderOutsideApplications = "A folder outside Applications"

    /// Row 2's caption when an older copy is in Applications.
    static let olderCopyThere = "An older Agent Tooling is there. It goes to the Trash."

    /// Row 2's caption when the copy in Applications is this version or a
    /// newer one (NEW).
    static func copyAlreadyThere(version: String?) -> String {
        version.map { "Agent Tooling \($0) is already there." } ?? "Agent Tooling is already there."
    }

    /// The caption under the facts, for a disk image.
    static let movesFromDiskImage = "Agent Tooling copies itself to Applications, opens from there and ejects the disk image."

    /// The disk image's own file, which the move leaves alone:
    /// "Agent-Tooling-0.1.0-arm64.dmg stays in Downloads."
    static func imageStays(_ file: String, in folder: String) -> String {
        "\(file) stays in \(folder)."
    }

    /// The caption for a copy in another folder, or a translocated one (NEW).
    static let movesFromFolder =
        "Agent Tooling copies itself to Applications and opens from there. The copy you opened stays where it is."

    /// The copy a move opened is still translocated (NEW, D42).
    static let stillTranslocated =
        "macOS is still running Agent Tooling from a temporary place. Quit, then open it from Applications."

    /// What Before you start's caption says when the move could not open the
    /// copy it made (NEW).
    static let openFromApplications =
        "Agent Tooling is in Applications now, but it could not be opened from there. Open it from Applications."

    static let moveAndReopen = "Move to Applications and reopen"
    static let replaceAndReopenEllipsis = "Replace and reopen…"
    static let replaceAndReopen = "Replace and reopen"
    /// The primary when the copy in Applications is the same or newer (NEW).
    static let openFromApplicationsTitle = "Open it from Applications"
    static let moving = "Moving…"
    static let quit = "Quit Agent Tooling"
    static let keepItHere = "Keep it here"
    static let keepItHereHelp = "Connecting your apps to Agent Tooling waits until it is in Applications."
    static let showInFinder = "Show in Finder"
    static let cancel = "Cancel"

    /// The confirm before an older copy goes to the Trash.
    static let replaceQuestion = "Replace the Agent Tooling in Applications?"
    static let replaceDetail = "The older copy goes to the Trash. Nothing else on this Mac changes."

    // MARK: Let your apps ask Agent Tooling

    static let askEyebrow = "Put in apps"
    static let askTitle = "Let your apps ask Agent Tooling"
    static let askSubtitle =
        "Your apps can look things up in your library and ask you for changes. They can only ask; every change still waits for you here."

    /// The explainer's two lists: "Can look up · 9", "Can only ask · 5".
    static func canLookUp(_ count: Int) -> String {
        "Can look up · \(count)"
    }

    static func canOnlyAsk(_ count: Int) -> String {
        "Can only ask · \(count)"
    }

    static let queuedRequest = "A queued request changes nothing. It waits on Home until you approve or decline it."
    static let addTo = "Add Agent Tooling to"

    // One app's row, when it has no command to show.

    static let notFound = "Not found on this Mac"
    /// Chosen, but its read was skipped (NEW).
    static let notChecked = "Not checked on this Mac yet"
    /// Found, but this Mac does not manage it (NEW).
    static let notManaged = "Not managed on this Mac"
    static let waitsForVersion = "Waits for a version"
    static let alreadyConnected = "Already connected"

    /// A registration at another path (NEW): "Connected to another copy at
    /// /Applications/…/agent-tooling-mcp".
    static func connectedToAnotherCopy(at path: String) -> String {
        path.isEmpty ? "Connected to another copy" : "Connected to another copy at \(path)"
    }

    /// Under a registration Agent Tooling cannot prove it made (NEW).
    static let notOurs = "Agent Tooling did not add this one, so it is left alone."

    /// The review's note under a replacement step (NEW): it removes the old
    /// registration before it adds this one, the note every connection's
    /// replacement carries (`LaunchpadCopy.Review.replaceNote`).
    static func replaceNote(app: String) -> String {
        LaunchpadCopy.Review.replaceNote(server: AgentToolingConnection.declaredName, app: app)
    }

    /// Why the rows are ticked as they are: "All three answered with a
    /// version, so all three start ticked." Nil when none did.
    static func answeredWithAVersion(_ apps: [String]) -> String? {
        switch apps.count {
        case 0: nil
        case 1: "\(apps[0]) answered with a version, so it starts ticked."
        case 2: "Both answered with a version, so both start ticked."
        case 3: "All three answered with a version, so all three start ticked."
        default: "All \(apps.count) answered with a version, so all \(apps.count) start ticked."
        }
    }

    /// "Your apps find Agent Tooling at <path>; if it moves, Checkup says the
    /// command was not found.", the path set in mono between the two halves.
    static let findsItAt = "Your apps find Agent Tooling at"
    static let ifItMoves = "; if it moves, Checkup says the command was not found."

    /// Kept outside Applications: the apps card waits for the move.
    static let moveFirst = "Move Agent Tooling to Applications first, so your apps can find it."
    static let moveToApplications = "Move to Applications…"
    /// A development build, which has no helper to hand out.
    static let noHelper = "This build of Agent Tooling has no helper."

    /// The primary: "Review 4 changes…", or "Review changes…" before the
    /// count is known or when there is none.
    static func review(changes: Int?) -> String {
        guard let changes, changes > 0 else { return "Review changes…" }
        return "Review \(CountNoun.change.phrase(changes))…"
    }

    /// Why Done says the step was passed over: no app is managed here (NEW).
    static let skippedNoApps = "No app is managed here, so Agent Tooling’s own connection was not set up."

    // What VoiceOver reads for a row and the lists.

    /// "Codex, not found on this Mac".
    static func rowLabel(_ app: String, _ state: String) -> String {
        "\(app), \(state.prefix(1).lowercased() + state.dropFirst())"
    }

    static let explainerLabel = "What your apps can look up, and what they can only ask for"

    enum Failures {
        /// Before you start: the move to Applications did not happen.
        static let notMoved = "Agent Tooling could not be copied to Applications. Nothing was changed."
        /// The copy in Applications is open, so it cannot be replaced (NEW).
        static let otherCopyOpen = "The Agent Tooling in Applications is open. Quit it, then try again. Nothing was changed."
    }
}

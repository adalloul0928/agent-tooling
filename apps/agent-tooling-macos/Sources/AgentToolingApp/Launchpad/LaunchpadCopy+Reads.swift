import AgentToolingCore

/// What Agent Tooling reads (S04) and the read itself (S05), with their
/// rerun variants: the consent, each app's list, how the apps sign in, the
/// tally, the commit line, the notices a slow read raises, and what VoiceOver
/// says as each app is read.
extension LaunchpadCopy.Reads {
    // S04, the consent.

    static let eyebrow = "Before anything is read"
    static let title = "Agent Tooling looks before it changes anything"

    /// The subtitle's first line, its counts from the manifest: "It reads 14
    /// places and runs 9 commands for the 3 apps you chose. Nothing leaves
    /// this Mac."
    static func lineOne(places: Int, commands: Int, apps: Int) -> String {
        let chose = apps == 1 ? "the app you chose" : "the \(CountNoun.app.phrase(apps)) you chose"
        return
            "It reads \(CountNoun.place.phrase(places)) and runs \(CountNoun.command.phrase(commands)) for \(chose). Nothing leaves this Mac."
    }

    static let lineTwo = "It writes one folder of its own, your library, and that comes last. Chat history is not read here."
    /// A rerun's second line: the library exists and only catches up.
    static let lineTwoRerun = "Your library is updated last, from what this reads. Chat history is not read here."

    /// This Mac, until its name is read.
    static let thisMac = "this Mac"
    /// The fork restated before anything is read. Hidden on a rerun.
    static func fork(mac: String) -> String {
        "This starts a new library on \(mac). If your library is already on another Mac, go back and choose Join."
    }

    /// The one choice on the screen, and its caption around the folder it
    /// names, which is set in mono.
    static let projectsTitle = "Also find projects from Claude Code’s history"
    static let projectsDetailLead = "Reads only the folder names in "
    static let projectsDetailTail = ", never the conversations in them."

    /// The column of an app that is not read.
    static let offNotRead = "Off · not read in this first read"
    /// The same once the library exists: a rerun's read, or one resumed
    /// after the first, is not the first read.
    static let offNotReadRerun = "Off · not read this time"
    static let goBackToTurnOn = "Go back to turn it on."

    /// The strip inside the well.
    static let signInLabel = "How your apps sign in"
    /// Its caption, around the shell command and the file it runs, which are
    /// set in mono: "Your login shell, zsh -l -i: runs ~/.zshrc and keeps only
    /// the names of 12 sign-in variables, never their values."
    static let shellLead = "Your login shell, "
    static let shellRuns = ": runs "
    static let shellStartupFile = "~/.zshrc"
    static func shellTail(variables: Int) -> String {
        " and keeps only the names of \(variables) sign-in variables, never their values."
    }

    /// A place another app's list already holds, after its path: "with
    /// Codex".
    static func linkedSuffix(_ apps: String) -> String {
        "with \(apps)"
    }

    // S05, the read.

    static let readingEyebrow = "Your apps"
    static let readingTitle = "Reading what each app holds"
    static let readingLineOne = "Nothing is installed or changed. Your library is created when this finishes."
    static let readingLineOneRerun = "Nothing is installed or changed. Your library is updated when this finishes."
    static let readingLineTwo = "Stop at any time; nothing is kept."

    /// Line A under a tile while its `--version` has not answered.
    static let checkingVersion = "Checking version…"
    static let versionUnknown = "Version unknown"
    /// An app skipped before its read finished: never "Not found".
    static let notCheckedYet = "Not checked yet"

    /// How long an app's read has taken: "2.4 s".
    static func elapsed(_ seconds: Double) -> String {
        "\((max(seconds, 0) * 10).rounded() / 10) s"
    }

    // The notices a slow read raises, one at a time, under the tally.

    static func takingAWhile(_ app: String) -> String {
        "\(app) is taking a while (up to a minute)."
    }

    static let skipThisApp = "Skip this app"
    static func didNotAnswerVersion(_ app: String) -> String {
        "\(app) did not answer --version. Installs into it wait until it does."
    }

    static func didNotAnswerInAMinute(_ app: String) -> String {
        "\(app) did not answer in a minute. Its files were read from disk only."
    }

    /// V2: the app's version is below the account reader's minimum. Under
    /// its tile, in place of its sign-in line.
    static func updateToReadAccount(_ app: String, account: String) -> String {
        "Update \(app) to read your \(account) account here"
    }

    /// The same, as the read's notice under the tally.
    static func updateToReadAccountNotice(_ app: String, account: String) -> String {
        "Update \(app) to read your \(account) account here."
    }

    // The tally and the commit line.

    /// While reading: "11 of 14 places read · 7 of 9 commands run".
    static func tallyReading(places: Int, of placeTotal: Int, commands: Int, of commandTotal: Int) -> String {
        "\(places) of \(CountNoun.place.phrase(placeTotal)) read · \(commands) of \(CountNoun.command.phrase(commandTotal)) run"
    }

    /// Once read: "14 places read · 9 commands run".
    static func tallyDone(places: Int, commands: Int) -> String {
        "\(CountNoun.place.phrase(places)) read · \(CountNoun.command.phrase(commands)) run"
    }

    static let tallySeparator = " · "
    /// The tally's last figure. A first read never changes an app, so it is
    /// a fact, not a count, and it never animates.
    static let zeroChanged = "0 changed in your apps"

    static let commitPending = "Then: create your library"
    static let commitPendingRerun = "Then: update your library"
    static let commitDone = "Your library is created"
    static let commitDoneRerun = "Your library is up to date"

    static let tryAgain = "Try again"

    /// Why the read and what it found are passed over: nothing was turned
    /// on, so there was nothing to read.
    static let nothingToRead = "No app was turned on, so nothing was read."

    // What VoiceOver says.

    /// One app's list: "Codex reads 4 places and runs 3 commands"; "Gemini
    /// CLI reads 4 places, and ~/.agents/skills with Codex, and runs 1
    /// command".
    static func manifestSummary(_ app: String, places: Int, linked: [String], commands: Int) -> String {
        let reads = "\(app) reads \(CountNoun.place.phrase(places))"
        let also = linked.map { ", and \($0)" }.joined()
        let comma = linked.isEmpty ? "" : ","
        let runs = commands == 0 ? "" : "\(comma) and runs \(CountNoun.command.phrase(commands))"
        return reads + also + runs
    }

    /// A place read for an earlier app: "~/.agents/skills, also read for
    /// Codex".
    static func linkedLabel(_ path: String, apps: String) -> String {
        "\(path), also read for \(apps)"
    }

    /// A place read that no list held.
    static func unlistedLabel(_ path: String) -> String {
        "\(path), not listed before"
    }

    /// Posted as each app's read lands: "Gemini CLI read: version 0.38.2, 1
    /// skill, 0 plugins, 1 connection."
    static func readAnnouncement(_ app: String, version: String?, holdings: [String]) -> String {
        let version = version.map { "version \($0)" } ?? "version unknown"
        return "\(app) read: " + ([version] + holdings).joined(separator: ", ") + "."
    }

    static func skippedAnnouncement(_ app: String) -> String {
        "\(app) skipped. Nothing of it is kept."
    }

    static let finishedAnnouncement = "Reading finished. Your library is created."
    static let finishedAnnouncementRerun = "Reading finished. Your library is up to date."
    static let stoppedAnnouncement = "Reading stopped. Nothing was kept."

    enum Failures {
        /// The read finished, but creating the library from it did not.
        static let notCreated = "Your library could not be created. Nothing was changed."
    }
}

extension CountNoun {
    fileprivate static let app = CountNoun("app")
    fileprivate static let place = CountNoun("place")
    fileprivate static let command = CountNoun("command")
}

import AgentToolingCore

/// Home's Finish setting up card (P01), its sidebar chip, the connection
/// check's confirmation and the Raycast and Terminal tips.
extension LaunchpadCopy.FinishSetup {
    // The card's header.

    static let title = "Finish setting up"
    static let finishedTitle = "Setup finished"
    static let hide = "Hide"

    /// "3 of 7 done".
    static func count(done: Int, of total: Int) -> String {
        "\(done) of \(total) done"
    }

    /// What VoiceOver calls the card: "Finish setting up, 3 of 7 done".
    static func cardLabel(_ title: String, done: Int, of total: Int) -> String {
        "\(title), \(count(done: done, of: total))"
    }

    // A row's state, spoken.

    static let notDone = "Not done"

    /// "Done, in setup".
    static func doneValue(_ place: String) -> String {
        "Done, \(place)"
    }

    // Where a row was done.

    static func place(_ place: FinishSetupPlace) -> String {
        switch place {
        case .setup: "in setup"
        case .home: "from Home"
        case .library: "from Library"
        case .discover: "from Discover"
        case .apps: "from Apps"
        case .checkup: "from Checkup"
        case .projects: "from Projects"
        case .settings: "from Settings"
        case .insights: "from Insights"
        case .activity: "from Activity"
        }
    }

    /// A done row's caption: what happened, then where. "Installed 4 changes
    /// · 9:52 AM · in setup", or "Done in setup" when there is nothing more
    /// to say.
    static func done(_ summary: String?, place: String) -> String {
        guard let summary, !summary.isEmpty else { return "Done \(place)" }
        return "\(summary) · \(place)"
    }

    // The row a first run left for later leads with. It is not counted.

    /// "Resume setup — next: Put your tools in your apps".
    static func resume(next: String) -> String {
        "Resume setup — next: \(next)"
    }

    static let resumeButton = "Resume"

    /// The step a resume opens at, by its screen's title. You joined is
    /// titled with the name this Mac joined as: "You joined as Cedar".
    static func next(_ step: LaunchpadStep, device: String? = nil) -> String {
        switch step {
        case .move: "Put Agent Tooling in Applications"
        case .welcome: "Welcome to Agent Tooling"
        case .apps: "Choose the apps this Mac manages"
        case .reads: "Agent Tooling looks before it changes anything"
        case .found: "Here is what this Mac has"
        case .library: "Start your library"
        case .place: "Put your tools in your apps"
        case .ask: "Let your apps ask Agent Tooling"
        case .assistant: "Let your assistant help"
        case .behave: "How Agent Tooling behaves"
        case .macs: "Use your library on your other Macs"
        case .done: "See what happened"
        case .join: "Join your library"
        case .arrivals: joinedAs(device)
        }
    }

    /// You joined's title: "You joined as Cedar", or "You joined as this
    /// Mac" before the name is known.
    static func joinedAs(_ device: String?) -> String {
        guard let device, !device.isEmpty else { return "You joined as this Mac" }
        return "You joined as \(device)"
    }

    // The row a copy outside Applications adds. It is not counted.

    static let moveTitle = "Move Agent Tooling to Applications"
    static let moveCaption = "Your apps keep its connection only from there"
    static let moveButton = "Move…"

    // The rows.

    static let makeSkillsYours = "Make your skills yours"
    static let putToolsInApps = "Put your tools in your apps"
    static let connectAgentTooling = "Connect Agent Tooling to your apps"
    static let connectOtherMacs = "Connect your other Macs"
    static let signInConnections = "Sign in to your connections"
    static let trackProjects = "Track your projects"
    /// The trial row before it knows its skill.
    static let trySkillTitle = "Try a skill in your apps"

    /// "Look at 4 things on Checkup".
    static func lookAtCheckup(_ count: Int) -> String {
        "Look at \(CountNoun.thing.phrase(count)) on Checkup"
    }

    /// "Try Release Notes in Codex".
    static func trySkill(_ skill: String, in app: String) -> String {
        "Try \(skill) in \(app)"
    }

    // Open rows' captions and buttons.

    /// "2 skills in your apps are not in your library yet".
    static func skillsNotYoursYet(_ count: Int) -> String {
        let are = count == 1 ? "is" : "are"
        return "\(CountNoun.skill.phrase(count)) in your apps \(are) not in your library yet"
    }

    static let openCheckup = "Open Checkup"

    /// "4 changes waiting".
    static func changesWaiting(_ count: Int) -> String {
        "\(CountNoun.change.phrase(count)) waiting"
    }

    static let nothingInstalledYet = "Nothing is installed yet"
    static let connectAgentToolingCaption = "So your apps can find what is in your library"
    static let otherMacsCaption = "Use this library on your other Macs too"
    static let connect = "Connect…"

    static let notCheckedYet = "Not checked yet"

    /// "Not checked yet · Sentry in Claude Code may need you to sign in", or
    /// "Not checked yet" when nothing is known to need one.
    static func notChecked(mayNeed who: String) -> String {
        who.isEmpty ? notCheckedYet : "\(notCheckedYet) · \(who) may need you to sign in"
    }

    /// "Sentry in Claude Code needs you to sign in".
    static func needSignIn(_ who: String, count: Int) -> String {
        let need = count == 1 ? "needs" : "need"
        return "\(who) \(need) you to sign in"
    }

    /// After a check, when a connection needs a sign-in Agent Tooling cannot
    /// run: "Checked · Gmail in Claude Code needs you to sign in from its
    /// app".
    static func signInInItsApp(_ who: String, count: Int) -> String {
        "Checked · \(signInFromTheirApps(who, count: count))"
    }

    /// "Gmail in Claude Code needs you to sign in from its app".
    static func signInFromTheirApps(_ who: String, count: Int) -> String {
        count == 1 ? "\(who) needs you to sign in from its app" : "\(who) need you to sign in from their apps"
    }

    /// After a check that found nothing to sign in to, until the row ticks.
    static let checkedNothingToSignIn = "Checked · no connection needs a sign-in"
    static let checkConnections = "Check connections…"
    static let signIn = "Sign in…"

    /// One app's connections: "GitHub and Sentry in Claude Code".
    static func connections(_ names: String, in app: String) -> String {
        "\(names) in \(app)"
    }

    /// The trial row's caption, before the command it ends with.
    static let tryCaption = "Checks apps first, then opens Terminal running"
    static let tryIt = "Try it"
    static let checkingApps = "Checking apps…"

    /// "4 folders Claude Code has worked in".
    static func foldersClaudeCodeWorkedIn(_ count: Int) -> String {
        "\(CountNoun.folder.phrase(count)) Claude Code has worked in"
    }

    /// Track your projects, with no folders read from Claude Code's history.
    static let addFolders = "Add the folders you work in"
    static let openProjects = "Open Projects"

    // What a done row says happened.

    /// "Connected to Codex and Claude Code".
    static func connected(to apps: String) -> String {
        "Connected to \(apps)"
    }

    /// "Synced just now".
    static func synced(_ when: String) -> String {
        "Synced \(when)"
    }

    /// "Sentry signed in".
    static func signedIn(_ names: String) -> String {
        "\(names) signed in"
    }

    static let noSignInNeeded = "No connection needs a sign-in"
    static let allLookedAt = "All looked at"

    /// "Tried Release Notes in Codex".
    static func tried(_ skill: String, in app: String) -> String {
        "Tried \(skill) in \(app)"
    }

    /// "1 project tracked".
    static func projectsTracked(_ count: Int) -> String {
        "\(CountNoun.project.phrase(count)) tracked"
    }

    // The card's foot.

    static let useFromRaycastOrTerminal = "Use it from Raycast or Terminal…"
    static let runSetupAgain = "Run setup again from Settings › General."

    // The sidebar chip, while the card is hidden.

    /// "Finish setting up · 4 left".
    static func chip(left: Int) -> String {
        "\(title) · \(left) left"
    }

    /// "Finish setting up, 4 left".
    static func chipLabel(left: Int) -> String {
        "\(title), \(left) left"
    }

    static let chipHint = "Shows the card on Home again"

    // The confirmation before a connection check, and its sign-in.

    static let checkTitle = "Check your connections?"
    static let checkRuns = "Runs, and can take up to a minute:"

    /// "If Sentry needs you, its sign-in comes next, with its command shown
    /// first:".
    static func signInComesNext(_ names: String) -> String {
        "If \(names) needs you, its sign-in comes next, with its command shown first:"
    }

    /// Names as a choice: "Sentry", "GitHub or Sentry", "A, B or C".
    static func either(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
        }
    }

    /// "If one needs you, its sign-in comes next…", when no connection is
    /// known to need one before the check.
    static let signInComesNextIfAny = "If a connection needs you, its sign-in comes next, with its command shown first."
    static let signInRuns = "Sign in ⌘↩ runs it and opens the page it prints; Agent Tooling never sees a token."
    static let signInRunsEach = "Sign in ⌘↩ runs each in turn and opens the page it prints; Agent Tooling never sees a token."
    static let signInTitle = "Sign in to your connections?"
    static let cancel = "Cancel"
    static let check = "Check"
    static let checking = "Checking…"
    static let signInButton = "Sign in"
    static let signingIn = "Signing in…"
    static let close = "Done"
    /// The confirmation's title once the check has run.
    static let checkedTitle = "Connections checked"
    /// After the check, with nothing to sign in to.
    static let nothingToSignIn = "No connection needs you to sign in."

    /// After the check, when what needs a sign-in is only its own app's to
    /// run: "Gmail in Claude Code needs you to sign in from its app. Apps ›
    /// Health shows how."
    static func signInFromApps(_ who: String, count: Int) -> String {
        "\(signInFromTheirApps(who, count: count)). Apps › Health shows how."
    }
    static let pressCommandReturn = "Press ⌘↩ to sign in"
    static let pressCommandReturnSpoken = "Press Command-Return to sign in."

    // The Raycast and Terminal tips.

    static let raycast = "Raycast"
    static let terminal = "Terminal"

    /// Raycast is here, its Agent Tooling extension is not.
    static func raycastWithoutExtension(_ commands: [String]) -> String {
        "Raycast is on this Mac; the Agent Tooling extension is not. \(itsCommands(commands)) It needs the signed release build."
    }

    /// Raycast and its Agent Tooling extension are both here.
    static func raycastWithExtension(_ commands: [String]) -> String {
        "Raycast and the Agent Tooling extension are on this Mac. \(itsCommands(commands))"
    }

    /// Raycast is not here.
    static func noRaycast(_ commands: [String]) -> String {
        let count = spelled(commands.count)
        let list = names(commands)
        return "Raycast is not on this Mac. Its Agent Tooling extension adds \(count) commands: \(list). It needs the signed release build."
    }

    /// "Its six commands: Search Agent Tooling, …".
    private static func itsCommands(_ commands: [String]) -> String {
        let count = spelled(commands.count)
        let list = names(commands)
        return "Its \(count) commands: \(list)."
    }

    /// Command names one after another, as Raycast lists them.
    private static func names(_ commands: [String]) -> String {
        commands.joined(separator: ", ")
    }

    /// What to type once the tool is on the path.
    static let terminalCommands = ["agent-tooling scan", "agent-tooling doctor", "agent-tooling search <words>"]

    /// A copy with no command-line tool inside it, such as a local build.
    static let noCommandLineTool = "The command-line tool comes inside Agent Tooling in Applications."

    /// A small number in words, as a sentence says it: "two apps", "six
    /// commands". Larger numbers stay digits.
    static func spelled(_ number: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return words.indices.contains(number) ? words[number] : "\(number)"
    }
}

extension CountNoun {
    fileprivate static let thing = CountNoun("thing")
    fileprivate static let folder = CountNoun("folder")
    fileprivate static let project = CountNoun("project")
}

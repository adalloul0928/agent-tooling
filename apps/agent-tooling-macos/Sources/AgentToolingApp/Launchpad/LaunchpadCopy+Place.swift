extension LaunchpadCopy.Place {
    // The header.

    static let eyebrow = "Put in apps"
    static let title = "Put your tools in your apps"
    static let subtitle = "Choose which apps get each tool. Nothing is installed until you review it."

    // Where: which Macs, or which project, what is placed here is for.

    static let whereLabel = "Where"
    static let everyMac = "Every Mac"
    static let thisMacOnly = "This Mac only"
    static let oneProject = "One project"
    /// Every Mac, on a Mac no other Mac has joined yet.
    static let everyMacLater = "Macs that join later get it too."
    /// Every Mac, once other Macs share the library.
    static let everyMacOthers = "Your other Macs get it too."
    static let thisMacOnlyNote = "Other Macs are left out."
    /// One project, naming the project it places into.
    static func forProject(_ name: String) -> String {
        "For \(name) only, on this Mac."
    }

    static let chooseProject = "Choose a project…"
    /// Why One project cannot be chosen yet: this Mac tracks no project.
    static let trackProjectFirst = "Track a project first, on Projects."

    // The grid's cells.

    static let willInstall = "Will install"
    static let add = "Add"
    static let hasIt = "Has it"
    static let leftAlone = "Left alone"

    /// An app that reads another app's folder, where the library's copy
    /// goes: "Through Codex’s folder".
    static func through(_ app: String) -> String {
        "Through \(app)’s folder"
    }

    /// Under Left alone, for an app that reads another app's folder, where
    /// that app's own copy stays: "Reads Codex’s copy".
    static func readsCopy(of app: String) -> String {
        "Reads \(app)’s copy"
    }

    /// An app that reads another app's folder, where nothing is going.
    static func readsFolder(of app: String) -> String {
        "Reads \(app)’s folder"
    }

    /// Under Left alone: the app holds a copy Agent Tooling did not put there.
    static func differentCopy(in app: String) -> String {
        "\(app) already has a different copy"
    }

    /// Under Left alone: the app holds Agent Tooling's copy, edited since.
    static func editedCopy(in app: String) -> String {
        "\(app)’s copy was edited since it was installed"
    }

    /// A plugin from another app's catalog: "Codex has its own catalog".
    static func ownCatalog(_ app: String) -> String {
        "\(app) has its own catalog"
    }

    /// "Gemini CLI takes no plugins".
    static func takesNoPlugins(_ app: String) -> String {
        "\(app) takes no plugins"
    }

    static let waitsForVersion = "Waits for a version"
    /// A plugin in One project: Agent Tooling installs plugins for every
    /// project only.
    static let pluginsForEveryProject = "Plugins go to every project"
    static let cannotTakeIt = "Cannot take this here"
    static let noVerifiedCopy = "No verified copy yet"
    static let notSetUpHere = "Not set up on this Mac"
    static let notOnThisMac = "Not on this Mac"

    // The rows.

    static let skill = "Skill"
    static let plugin = "Plugin"
    static let connection = "Connection"

    /// Under a row's name: "Skill · Personal library".
    static func rowSubtitle(kind: String, source: String) -> String {
        "\(kind) · \(source)"
    }

    /// Where something added from an app's catalog came from.
    static func catalog(of app: String) -> String {
        "\(app)’s catalog"
    }

    static let skillsSh = "skills.sh"

    // The captions under the grid.

    /// What the grid leaves to the apps that installed it.
    static func stayWithTheirApps(_ names: String, count: Int) -> String {
        count == 1 ? "\(names) stays as its app manages it." : "\(names) stay as their apps manage them."
    }

    /// What is in the library but not yet yours, so cannot be placed.
    static func placedOnceYours(_ names: String, count: Int) -> String {
        count == 1 ? "\(names) can be placed once you make it yours." : "\(names) can be placed once you make them yours."
    }

    /// Apps this Mac does not manage.
    static func off(_ apps: String, count: Int) -> String {
        count == 1 ? "\(apps) is off on this Mac, so it has no column." : "\(apps) are off on this Mac, so they have no columns."
    }

    /// Managed apps no read has checked yet (D7).
    static func notChecked(_ apps: String, count: Int) -> String {
        count == 1
            ? "\(apps) was not checked, so it has no column yet. Place things there after the next check."
            : "\(apps) were not checked, so they have no columns yet. Place things there after the next check."
    }

    /// Managed apps the read did not find.
    static func notFound(_ apps: String, count: Int) -> String {
        count == 1 ? "\(apps) is not on this Mac, so it has no column." : "\(apps) are not on this Mac, so they have no columns."
    }

    static let reviewedNext = "Changes so far are reviewed after the next step."

    /// On a Mac set to take only what names it, which the grid opens on This
    /// Mac only for.
    static let takesOnlyWhatNamesIt = "This Mac is set to take only what names it, so Every Mac leaves it out."

    /// The card when there is nothing to place, naming what stays with its
    /// apps when there is something.
    static func nothingToPlace(appManaged names: String?, count: Int) -> String {
        let first = "Nothing to place yet. Skills can be placed once they are yours"
        guard let names else { return first + "." }
        return count == 1 ? "\(first); \(names) stays as its app manages it." : "\(first); \(names) stay as their apps manage them."
    }

    // The footer.

    /// "2 changes so far": what the next step's review installs, Has it never
    /// among them.
    static func changesSoFar(_ count: Int) -> String {
        count == 0 ? "No changes so far" : "\(CountNoun.change.phrase(count)) so far"
    }

    // What VoiceOver reads.

    /// One cell: "Release Notes, Codex: will install".
    static func cell(_ item: String, in app: String, _ state: String) -> String {
        "\(item), \(app): \(state)"
    }

    static let spokenWillInstall = "will install"
    static let spokenAdd = "can be added"
    static let spokenHasIt = "has it"

    /// "Frontend Design, Codex: left alone. Codex already has a different
    /// copy."
    static func spokenLeftAlone(because reason: String) -> String {
        "left alone. \(reason)."
    }

    /// "through Codex’s folder".
    static func spokenThrough(_ app: String) -> String {
        "through \(app)’s folder"
    }

    /// "left alone. It reads Codex’s own copy in ~/.agents/skills."
    static func spokenReadsCopy(of app: String, in folder: String) -> String {
        "left alone. It reads \(app)’s own copy in \(folder)."
    }

    /// "reads Codex’s folder in ~/.agents/skills".
    static func spokenReadsFolder(of app: String, in folder: String) -> String {
        "reads \(app)’s folder in \(folder)"
    }

    static let spokenTurnOff = "Press Space to leave it out."
    static let spokenTurnOn = "Press Space to add it."

    /// Done's reason when the walk had no app to put anything in.
    static let skippedNoApps = "Nothing was put in apps, because this Mac manages no app."

    enum Failures {
        static let notChecked = "This Mac’s apps could not be checked. Nothing was changed."
        static let notSaved = "Where your tools go could not be saved. Nothing was changed."
    }
}

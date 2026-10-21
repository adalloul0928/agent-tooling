import AgentToolingCore

/// Your other Macs (S17): connecting a repository and publishing this Mac's
/// library there.
extension LaunchpadCopy.Macs {
    static let eyebrow = "Other Macs"
    static let title = "Use your library on your other Macs"
    static let subtitle =
        "Connect a private Git repository your other Macs can read. Agent Tooling publishes this Mac’s library there."

    // The form.

    static let addressLabel = "Repository address"
    static let branchLabel = "Branch"
    static let nameLabel = "This Mac’s name"
    /// The address field's placeholder: the HTTPS form, never the scp one.
    static let addressPlaceholder = "https://github.com/you/agent-tooling-workspace.git"
    static let defaultBranch = "main"
    /// Under a well-formed address.
    static let httpsAddress = "An HTTPS address"
    /// The button that puts the HTTPS form of an address in the field.
    static func use(_ suggestion: String) -> String {
        "Use \(suggestion)"
    }

    /// Beside the name field, when another Mac already uses the name typed.
    static func nameTaken(_ typed: String, savedAs: String) -> String {
        "Another Mac is called \(typed), so this Mac is saved as \(savedAs)."
    }

    // What travels, and what stays.

    static let travelsTitle = "What travels"
    static let travelsLibrary = "Your library and where each tool goes"
    static let travelsSkillFiles = "Your own skills’ files"
    static let travelsStatus =
        "Each Mac’s status: app versions, item counts, names of pending items, the sign-in method and plan, and a salted account fingerprint"
    static let staysTitle = "What stays on this Mac"
    static let staysChoices = "Which apps it manages and its update choices"
    static let staysProjects = "Project folders"
    static let staysKeys = "Passwords and keys: Git uses the sign-in it already has"
    static let warning = "A repository is not encrypted storage. Anyone with access to it can read what is published there."

    // The footer.

    static let notNow = "Not now"
    static let skipForNow = "Skip for now"
    static let connectAndShare = "Connect and share"
    /// The primary once the check stopped at something put right outside
    /// the app: the network, the sign-in, the Command Line Tools.
    static let tryAgain = "Try again"
    static let connecting = "Connecting…"
    static let publishing = "Publishing…"

    // The result card.

    /// The shipped result of a first publish.
    static let sharedFirstTime = "Shared this Mac’s setup for the first time."
    static let upToDate = "Up to date with your other Macs."
    static let combined = "Combined changes from another Mac and shared the result."
    static let tookIn = "Took in changes from another Mac."
    static let needsDecisions = "Connected. Some changes need your decision in Settings › Sync."
    static let anotherMacPublished = "Connected. Another Mac published while this one was working; the next pass finishes it."
    /// A rerun on a Mac that already shares its library.
    static let alreadyConnected = "This Mac already shares its library through this repository."
    /// A rerun on a Mac that shares its library through a folder another
    /// service keeps in step (Settings › Sync), not a repository.
    static let alreadySharesThroughFolder = "This Mac already shares its library through a folder."
    static let joinNext = "On your other Mac, open Agent Tooling and choose Join."
    static let copy = "Copy"

    /// What VoiceOver says once the library is shared.
    static func sharedAnnouncement(_ result: String) -> String {
        "\(result) \(joinNext)"
    }

    // Why it did not connect: the card's title, by where it stopped. The
    // message under it is the cause's own sentence.

    static let couldNotReach = "Couldn’t reach that repository"
    static let gitMissingTitle = "Git is not installed"
    static let notThisLibrary = "That repository can’t hold this library"
    static let cannotRead = "This build can’t read that library"
    static let couldNotPublish = "Couldn’t publish there"
    static let couldNotConnect = "Couldn’t connect that repository"

    enum Failures {
        /// Other Macs cannot be offered here, with the reason the sync session
        /// could not be prepared, when there is one.
        static func unavailable(_ reason: String?) -> String {
            guard let reason, !reason.isEmpty else { return "This Mac cannot connect a repository now. Nothing was changed." }
            return "This Mac cannot connect a repository now. \(reason) Nothing was changed."
        }
    }
}

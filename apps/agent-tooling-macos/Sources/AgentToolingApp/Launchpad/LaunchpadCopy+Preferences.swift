extension LaunchpadCopy.Preferences {
    /// Both screens' eyebrow.
    static let eyebrow = "Preferences"

    // MARK: Let your assistant help (S15)

    static let assistantTitle = "Let your assistant help"
    static let assistantSubtitle =
        "Your own signed-in assistant can read your setup and suggest what to do. It can read; it cannot change anything."
    /// Under the cards, until a review has run on this Mac.
    static let firstReview = "The first review starts when Home opens."
    /// What VoiceOver calls the three cards.
    static let runsLabel = "The assistant’s runs"

    // MARK: How Agent Tooling behaves (S16)

    static let behaveTitle = "How Agent Tooling behaves"
    static let behaveSubtitle = "These choices are for this Mac. Change them any time in Settings."

    static let appearance = "Appearance"
    static let appearanceDetail = "System follows macOS."
    static let menuBar = "Show Agent Tooling in the menu bar"
    /// The menu-bar item's menu, by the names its items carry there.
    static var menuBarDetail: String {
        "Open Agent Tooling, \(ActionTitles.checkAppsCommand(.menu)) and \(ActionTitles.reviewChangesCommand(.menu)) from the menu bar."
    }
    static let checkOnOpen = "Check my apps each time Agent Tooling opens"
    static let checkOnOpenDetail = "Read what each app holds on this Mac. Nothing is changed."
    static let updatesSection = "Updates"
    static let checkForUpdates = "Check for updates"
    static let checkForUpdatesDetail = "Looks for newer versions of your skills, plugins and connections."
    static let skills = "Skills"
    static let plugins = "Plugins"
    static let connections = "Connections"
    /// The two lines under the card.
    static let decidesArrivals = "This also decides what arrives from your other Macs."
    static let connectionsWait = "Updates to connections always wait for you."
    /// What VoiceOver calls the card of rows.
    static let behaveLabel = "This Mac’s preferences"
}

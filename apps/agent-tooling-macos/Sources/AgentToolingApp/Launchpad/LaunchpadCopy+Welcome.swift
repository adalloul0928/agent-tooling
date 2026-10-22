extension LaunchpadCopy.Welcome {
    /// The setup stage's window, as the Window menu and VoiceOver name it.
    static let windowTitle = "Set up Agent Tooling"

    // Welcome (S01): the fork, before anything is read.

    static let title = "Welcome to Agent Tooling"
    static let subtitle = "Is this your first Mac, or does another Mac already have your library?"

    /// The first row: start this Mac's own library.
    static let startTitle = "Start a library on this Mac"
    static let startDetail = "Reads this Mac’s apps. Nothing is installed."
    /// The second row: join the library another Mac shares.
    static let joinTitle = "Join your library from another Mac"
    static let joinDetail = "Paste the address from Settings › Sync on that Mac."

    /// The one fact the app cannot undo, under the rows.
    static let footnote = "A Mac that starts its own library cannot join another later."

    /// The line under it: this copy's version.
    static func version(_ number: String) -> String {
        "Agent Tooling \(number)"
    }

    /// The primary follows the row the keyboard is on.
    static let startPrimary = "Start here"
    static let joinPrimary = "Join"

    /// While a library opens: the main window, the menu-bar item, and the
    /// stage carrying on a first run.
    static let openingWorkspace = "Opening your workspace…"
    /// When it could not open: the main window's heading over the reason,
    /// and the menu-bar item's line over Try Again.
    static let couldNotOpenWorkspace = "Agent Tooling could not open your workspace"
}

extension LaunchpadCopy.Footer {
    // The footer's step names: the capsule's name, not the screen's title.

    static let stepBeforeYouStart = "Before you start"
    static let stepWelcome = "Welcome"
    static let stepYourApps = "Your apps"
    static let stepYourLibrary = "Your library"
    static let stepPutInApps = "Put in apps"
    static let stepPreferences = "Preferences"
    /// Join's third capsule, where Start here's says Preferences.
    static let stepThisMac = "This Mac"
    static let stepOtherMacs = "Other Macs"
    static let stepDone = "Done"
    static let stepJoin = "Join"
    static let stepArrivals = "Arrivals"

    // The footer's own controls.

    static let setUpLater = "Set up later"
    static let stop = "Stop"
    static let back = "Back"
    static let `continue` = "Continue"

    /// What VoiceOver calls the footer's group.
    static let groupLabel = "Setup actions"

    /// The capsules, spoken: "Step 2 of 5".
    static func stepOf(_ reached: Int, _ total: Int) -> String {
        "Step \(reached) of \(total)"
    }

    // FooterConfirm: what ⎋, ⌘W and the close button ask.

    static let keepGoing = "Keep going"
    /// Before the commit point: nothing is on disk yet.
    static let beforeCommit = "Nothing is written yet. Agent Tooling asks again when it next opens."
    static let quitSetup = "Quit setup"
    /// A join that stopped after this Mac's store was made (NEW, O6): the
    /// store is on disk, so nothing-is-written would not be true.
    static let unfinishedJoin = "Joining stopped before it finished. Agent Tooling offers Finish joining when it next opens."
    /// After it, on a first run or a resumed one: the cursor is kept.
    static let afterCommit = "Finish later? Your choices so far are saved, and Home shows where you left off."
    /// On a rerun or a revisit: nothing is written by leaving.
    static let rerunLeave = "Leave setup? What you saved stays saved. Run it again from Settings › General."
    static let goToHome = "Go to Home"

    // What is running while setup cannot stop: each is the sentence
    // FooterConfirm shows instead of its buttons.

    static let creatingLibrary = "Creating your library…"
    static let updatingLibrary = "Updating your library…"
    static let finishingJoin = "Finishing joining…"
    static let stoppingAfterStep = "Stopping after this step…"
    static let publishing = "Publishing…"

    // A plain ↩ on a screen where only ⌘↩ acts.

    static let commandReturnHint = "Press ⌘↩ to install"
    static let commandReturnSpoken = "Press Command-Return to install."
    static let commandReturnAccessibilityHint = "Command-Return installs."
    /// Your other Macs' Connect and share.
    static let commandReturnConnectHint = "Press ⌘↩ to connect"
    static let commandReturnConnectSpoken = "Press Command-Return to connect."
    static let commandReturnConnectAccessibilityHint = "Command-Return connects."
    /// Join's Join as and Finish joining.
    static let commandReturnJoinHint = "Press ⌘↩ to join"
    static let commandReturnJoinSpoken = "Press Command-Return to join."
    static let commandReturnJoinAccessibilityHint = "Command-Return joins."

    enum Failures {
        /// A choice the stage tried to record did not save, and was put back.
        static let notRecorded = "This Mac could not record that choice. Nothing was changed."
    }
}

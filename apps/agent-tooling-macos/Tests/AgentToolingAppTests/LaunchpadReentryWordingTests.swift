import Testing

@testable import AgentToolingApp

/// The words WP10a owns, pinned from plan §6: Settings › General's Setup card
/// and its Run setup again row, the line that says what every way back does
/// (the row's, and the help on Apps' button and the row's), and the palette
/// entry's line. Every other test reads them through `LaunchpadCopy.Reentry`,
/// so a change to the wording is made here and nowhere else. The command's
/// own name, Set up this Mac…, is pinned with the welcome's wording.
@Suite("Launchpad re-entry wording")
struct LaunchpadReentryWordingTests {
    @Test func everyWayBackSaysWhatItDoes() {
        let copy = LaunchpadCopy.Reentry.self
        #expect(copy.settingsCard == "Setup")
        #expect(copy.runSetupAgain == "Run setup again")
        #expect(copy.opensAtYourApps == "Opens setup at Your apps. Nothing changes until you review it.")
        #expect(copy.paletteSubtitle == "Choose your apps and walk through setup again")
    }
}

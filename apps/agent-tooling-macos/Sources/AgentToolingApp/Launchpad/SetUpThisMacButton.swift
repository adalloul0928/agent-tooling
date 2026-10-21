import SwiftUI

/// Set up this Mac…, as Apps and Settings › General offer it: the setup stage
/// again at Your apps, over the library this Mac already has, with no fork.
/// The palette and the app menu open the same stage, and so does
/// `agent-tooling://setup`. Opening it changes nothing: the stage writes only
/// what the person goes on to review there.
struct SetUpThisMacButton: View {
    @Environment(\.openSetup) private var openSetup

    var body: some View {
        Button(ActionTitles.setUpThisMacCommand(.palette), systemImage: Self.symbol) {
            openSetup(.rerun)
        }
        .help(LaunchpadCopy.Reentry.opensAtYourApps)
    }

    /// The symbol every way back draws: this button, the Settings row and
    /// the palette entry.
    nonisolated static let symbol = "wand.and.stars"
}

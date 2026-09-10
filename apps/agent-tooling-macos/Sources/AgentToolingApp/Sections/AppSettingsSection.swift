import SwiftUI

/// The Apps family's settings tab: the effective native settings each client
/// will actually use on this Mac, layer by layer.
struct AppSettingsSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        EffectiveSettingsView(session: workspace.settings)
    }
}

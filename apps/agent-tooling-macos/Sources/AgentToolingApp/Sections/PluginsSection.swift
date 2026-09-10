import SwiftUI

/// The Library's Plugins tab. Layout and interaction live in `PluginsView`,
/// restored to the original screen's visual; this file only keeps the
/// section's identity, per the port map.
struct PluginsSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        PluginsView(workspace: workspace)
    }
}

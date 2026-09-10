import SwiftUI

/// The Library's plugins tab. Until the plugin screen is restored it shows the
/// same library the other tabs do, unfiltered, rather than an empty pane that
/// would read as a workspace with no plugins in it.
struct PluginsSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        WorkspaceLibraryView(
            session: workspace.library, authoring: workspace.authoring, export: workspace.export,
            initialKind: .plugins
        )
    }
}

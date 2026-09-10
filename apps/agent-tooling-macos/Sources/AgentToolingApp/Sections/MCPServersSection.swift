import SwiftUI

/// The Library's connections tab. Until the server screen is restored it shows
/// the same library the other tabs do, unfiltered, rather than an empty pane
/// that would read as a workspace with no servers in it.
struct MCPServersSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        WorkspaceLibraryView(
            session: workspace.library, authoring: workspace.authoring, export: workspace.export)
    }
}

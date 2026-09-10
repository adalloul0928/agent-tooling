import SwiftUI

/// Discover, the reviewed catalogs.
///
/// The catalog session belongs to the workspace rather than to this screen, so
/// what Discover lists and what Home compares a plugin against are one answer
/// from one refresh. Which catalogs it can reach was decided when the workspace
/// was opened; a test opens one that answers from memory, and the screen never
/// reaches the network to be drawn.
struct DiscoverSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        MarketplaceView(workspace: workspace, session: workspace.marketplace)
            // Reading this Mac's own record and asking a catalog both happen
            // here rather than while the view is being built, so opening
            // Discover cannot make the window wait on a database or a socket.
            .task { await workspace.marketplace.refresh() }
    }
}

import AgentToolingCore
import SwiftUI

/// Discover, the reviewed catalogs.
///
/// The section's only job is to give the screen a session built from the
/// catalogs this build was handed. Which catalogs those are is an environment
/// value, so a render test can supply one that answers from memory and the
/// screen never reaches the network to be drawn.
struct DiscoverSection: View {
    let workspace: WorkspaceLaunch.Workspace
    @Environment(\.marketplaceProviders) private var catalogs

    var body: some View {
        // Split so the session can be `@State` built from an environment value:
        // a `View` cannot read the environment before its own initializer runs.
        DiscoverSectionBody(
            workspace: workspace,
            providers: catalogs(
                MarketplaceCatalogContext(homeRoot: workspace.homeRoot, store: workspace.store)))
    }
}

private struct DiscoverSectionBody: View {
    let workspace: WorkspaceLaunch.Workspace
    @State private var session: WorkspaceMarketplaceSession

    init(workspace: WorkspaceLaunch.Workspace, providers: [any MarketplaceProvider]) {
        self.workspace = workspace
        _session = State(
            initialValue: WorkspaceMarketplaceSession(
                providers: providers, service: workspace.service,
                library: workspace.library, store: workspace.store))
    }

    var body: some View {
        MarketplaceView(workspace: workspace, session: session)
            // Reading this Mac's own record and asking a catalog both happen
            // here rather than while the view is being built, so opening
            // Discover cannot make the window wait on a database or a socket.
            .task { await session.refresh() }
    }
}

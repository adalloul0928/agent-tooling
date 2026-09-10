import AgentToolingCore
import SwiftUI

/// Home, the screen that composes the others.
///
/// Home reports what Insights, Discover and the review queue already produced,
/// so it needs their sessions — and every one of those reaches outside the app:
/// a catalog is a network call, a kept report is a file, and the queue is this
/// Mac's own store. All three are resolved from the environment here, so the
/// screen itself names none of the real ones and a render test can draw Home
/// without a socket, a support folder or a client.
struct HomeSection: View {
    let workspace: WorkspaceLaunch.Workspace
    @Environment(\.marketplaceProviders) private var providers
    @Environment(\.insightsServices) private var insightsServices
    @Environment(\.pendingRequestQueue) private var queue

    var body: some View {
        // Split so the sessions can be `@State` built from environment values:
        // a `View` cannot read the environment before its own initializer runs.
        HomeSectionBody(
            workspace: workspace, providers: providers,
            insightsServices: insightsServices, queue: queue)
    }
}

private struct HomeSectionBody: View {
    let workspace: WorkspaceLaunch.Workspace
    @State private var catalog: WorkspaceMarketplaceSession
    @State private var insights: WorkspaceInsightsSession
    @State private var requests: WorkspaceRequestSession

    init(
        workspace: WorkspaceLaunch.Workspace,
        providers: [any MarketplaceProvider],
        insightsServices: (URL) -> any InsightsServicing,
        queue: any PendingRequestQueuing
    ) {
        self.workspace = workspace
        let container = workspace.store.databaseURL.deletingLastPathComponent()
        _catalog = State(
            initialValue: WorkspaceMarketplaceSession(
                providers: providers, service: workspace.service,
                library: workspace.library, store: workspace.store))
        // Reads the report this Mac already kept and nothing else. Opening Home
        // is not a scan: reading a transcript stays a decision made on Insights.
        _insights = State(
            initialValue: WorkspaceInsightsSession(
                library: workspace.library, store: workspace.store,
                homeRoot: workspace.homeRoot, services: insightsServices(container)))
        _requests = State(
            initialValue: WorkspaceRequestSession(
                store: workspace.store, library: workspace.library,
                device: workspace.device, queue: queue))
    }

    var body: some View {
        OverviewView(
            workspace: workspace, catalog: catalog, insights: insights, requests: requests
        )
        // Both reads happen after the window is up and neither waits for the
        // other, so opening Home cannot make it wait on a database or a socket.
        .task {
            async let queued: Void = requests.refresh()
            async let catalogs: Void = catalog.refresh()
            _ = await (queued, catalogs)
        }
    }
}

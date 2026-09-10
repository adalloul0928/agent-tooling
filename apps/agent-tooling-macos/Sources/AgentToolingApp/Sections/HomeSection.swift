import SwiftUI

/// Home, the screen that composes the others.
///
/// Home reports what Insights, Discover and the review queue already produced,
/// so it reads their sessions — the same three the workspace handed every other
/// screen. It builds none of them: a catalog is a network call, a kept report is
/// a file and the queue is this Mac's own store, and all three were settled when
/// the workspace was opened. So Home says what those screens say, rather than
/// going and asking again and reporting a second answer.
struct HomeSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        OverviewView(
            workspace: workspace, catalog: workspace.marketplace,
            insights: workspace.insights, requests: workspace.requests
        )
        // Both reads happen after the window is up and neither waits for the
        // other, so opening Home cannot make it wait on a database or a socket.
        // Reading the kept report is not one of them: that happened when the
        // workspace opened, and starting a scan stays a decision made on
        // Insights.
        .task {
            async let queued: Void = workspace.requests.refresh()
            async let catalogs: Void = workspace.marketplace.refresh()
            _ = await (queued, catalogs)
        }
    }
}

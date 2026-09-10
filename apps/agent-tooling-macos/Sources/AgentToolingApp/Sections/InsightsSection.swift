import SwiftUI

/// Insights: what this Mac's own recent work suggests.
///
/// The screen's session needs a scan and somewhere to keep its report, and both
/// of those touch this Mac. They are resolved from the environment here so the
/// pane itself never names the real ones, and a test can render this screen
/// without reading a transcript or writing a file.
struct InsightsSection: View {
    let workspace: WorkspaceLaunch.Workspace
    @Environment(\.insightsServices) private var services

    var body: some View {
        InsightsView(
            workspace: workspace,
            services: services(workspace.store.databaseURL.deletingLastPathComponent()))
    }
}

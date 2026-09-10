import SwiftUI

/// Insights: what this Mac's own recent work suggests.
///
/// The scan and the file its report is kept in were settled when the workspace
/// was opened, so this screen reads the same session Home reports from: a scan
/// run here is the scan Home shows, and neither screen keeps a report the other
/// has not got.
struct InsightsSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        InsightsView(workspace: workspace, session: workspace.insights)
    }
}

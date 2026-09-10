import SwiftUI

/// Restore points: the earlier versions of this workspace, and the way back to
/// one of them.
struct HistorySection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        WorkspaceHistoryView(session: workspace.history)
    }
}

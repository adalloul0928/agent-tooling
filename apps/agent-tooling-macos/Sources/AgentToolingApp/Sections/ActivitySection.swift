import SwiftUI

/// The journal, the receipts and the drift this Mac recorded. The restore points
/// beside it are already readable; this half waits on its own session.
struct ActivitySection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: AppSection.activity.navigationTitle, context: "What this Mac has already done") {}
            EmptyStateView(
                symbol: AppSection.activity.symbol,
                title: AppSection.activity.navigationTitle,
                message: "Activity is being restored.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

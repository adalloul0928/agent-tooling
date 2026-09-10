import SwiftUI

/// Insights. The scan behind it is real code with no caller yet; until it has a
/// session, this pane makes no claim about how anything is being used.
struct InsightsSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: AppSection.insights.navigationTitle, context: "What your own use suggests") {}
            Divider()
            EmptyStateView(
                symbol: AppSection.insights.symbol,
                title: AppSection.insights.navigationTitle,
                message: "Insights is being restored.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

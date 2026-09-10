import SwiftUI

/// Home. It composes what the other screens report, so it is restored last and
/// says so rather than showing a surface with nothing behind it.
struct HomeSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: AppSection.overview.navigationTitle, context: "What this Mac has, and what needs a look") {}
            Divider()
            EmptyStateView(
                symbol: AppSection.overview.symbol,
                title: AppSection.overview.navigationTitle,
                message: "Home is being restored.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

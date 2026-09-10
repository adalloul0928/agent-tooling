import SwiftUI

/// Discover, the reviewed catalogs. It needs a marketplace session before it can
/// answer anything, and says nothing until it has one.
struct DiscoverSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: AppSection.marketplace.navigationTitle, context: "Reviewed catalogs and sources") {}
            Divider()
            EmptyStateView(
                symbol: AppSection.marketplace.symbol,
                title: AppSection.marketplace.navigationTitle,
                message: "Discover is being restored.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

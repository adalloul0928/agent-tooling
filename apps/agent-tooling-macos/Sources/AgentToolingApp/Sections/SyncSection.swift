import SwiftUI

/// Sync between your own Macs: Git or an encrypted folder. This is transport,
/// not installation; nothing here reaches a client.
struct SyncSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        if let sync = workspace.sync {
            SyncSettingsView(session: sync)
        } else {
            VStack(spacing: 0) {
                PageToolbar(title: AppSection.sync.navigationTitle, context: "Unavailable on this Mac") {}
                EmptyStateView(
                    symbol: AppSection.sync.symbol,
                    title: "Sync unavailable",
                    message: "Sync could not be prepared on this Mac, so this workspace stays local to it.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

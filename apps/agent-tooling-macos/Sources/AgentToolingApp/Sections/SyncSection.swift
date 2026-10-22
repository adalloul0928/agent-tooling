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
                    message: syncUnavailableMessage)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Names the cause when the workspace kept one. Falls back to the plain
    /// sentence when no reason was captured.
    private var syncUnavailableMessage: String {
        if let reason = workspace.syncUnavailableReason {
            return "Sync unavailable — \(reason)"
        }
        return "Sync could not be prepared on this Mac, so this workspace stays local to it."
    }
}

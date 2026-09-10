import SwiftUI

/// Presets: the reusable shelves a person assigns in one go. A Mac whose linked
/// preset file could not be prepared still opens its library, so this pane says
/// what is unavailable instead of the window failing to open.
struct PresetsSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        if let presets = workspace.presets {
            WorkspacePresetsView(session: presets, library: workspace.library)
        } else {
            VStack(spacing: 0) {
                PageToolbar(title: AppSection.presets.navigationTitle, context: "Unavailable on this Mac") {}
                EmptyStateView(
                    symbol: AppSection.presets.symbol,
                    title: "Presets unavailable",
                    message: "This Mac's linked presets could not be opened, so following a preset is unavailable here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

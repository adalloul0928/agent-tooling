import SwiftUI

/// Presets: the reusable shelves a person assigns in one go. A Mac whose linked
/// preset file could not be prepared still opens its library, so this pane says
/// what is unavailable instead of the window failing to open.
struct PresetsSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        if let presets = workspace.presets {
            PresetsView(session: presets, library: workspace.library, export: workspace.export)
        } else {
            VStack(spacing: 0) {
                PageToolbar(title: AppSection.presets.navigationTitle, context: "Unavailable on this Mac") {}
                EmptyStateView(
                    symbol: AppSection.presets.symbol,
                    title: "Presets unavailable",
                    message: presetsUnavailableMessage)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Names the cause when the workspace kept one, so the pane says why rather
    /// than only that something went wrong. Falls back to the plain sentence
    /// when no reason was captured.
    private var presetsUnavailableMessage: String {
        if let reason = workspace.presetsUnavailableReason {
            return "Presets unavailable — \(reason)"
        }
        return "This Mac's linked presets could not be opened, so following a preset is unavailable here."
    }
}

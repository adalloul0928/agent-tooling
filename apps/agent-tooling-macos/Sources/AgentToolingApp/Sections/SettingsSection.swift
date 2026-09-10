import SwiftUI

/// Settings · General. Appearance is here because it survived the workspace
/// change intact; the two panes beside it name what is still missing rather than
/// leaving a person to wonder where runtimes and managed policy went.
struct SettingsSection: View {
    let workspace: WorkspaceLaunch.Workspace
    @AppStorage("appearance") private var appearance = "System"

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: AppSection.settings.navigationTitle, context: "This app, on this Mac") {}
            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceLayout.sectionSpacing) {
                    AppearanceSettingsView(appearance: $appearance)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    placeholder(
                        symbol: AppSection.mcpServers.symbol,
                        title: "Runtimes",
                        message: "What each MCP runtime reports on this Mac is being restored.")
                    placeholder(
                        symbol: "lock.doc",
                        title: "Managed policy",
                        message: "The policy file an organisation can place on this Mac is being restored.")
                }
                .padding(WorkspaceLayout.pageInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(symbol: String, title: String, message: String) -> some View {
        EmptyStateView(symbol: symbol, title: title, message: message)
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .standardPanel()
    }
}

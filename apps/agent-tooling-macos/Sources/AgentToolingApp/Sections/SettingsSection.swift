import SwiftUI

/// Settings · General. Appearance is here because it survived the workspace
/// change intact; MCP connection modes and managed policy sit beside it, both
/// read from `workspace.settings` and `workspace.device`. Backup and encrypted
/// sync moved to Settings · Sync.
struct SettingsSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        SettingsGeneralView(workspace: workspace)
    }
}

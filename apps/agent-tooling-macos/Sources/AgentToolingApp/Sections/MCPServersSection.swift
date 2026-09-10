import SwiftUI

/// The Library's connections tab: the MCP servers this workspace knows about,
/// their capability switches, the live test console and the runtimes this Mac
/// has. Everything that shells out is injected, so a preview or a test can hand
/// in a runtime that answers without running anything.
struct MCPServersSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        MCPServersView(workspace: workspace)
    }
}

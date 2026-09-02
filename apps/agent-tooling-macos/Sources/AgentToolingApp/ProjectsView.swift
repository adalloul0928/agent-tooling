import AgentToolingCore
import SwiftUI

/// Per-project tooling: the engine already supports project scope for skills
/// and MCP servers, but it has had nowhere to live. This placeholder reserves
/// the section so the sidebar and routing stay stable while the feature lands.
struct ProjectsView: View {
    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Projects", context: nil) { EmptyView() }
            EmptyStateView(
                symbol: "folder.badge.gearshape",
                title: "Projects are on the way",
                message: "See which folders carry their own skills, servers, and configuration."
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

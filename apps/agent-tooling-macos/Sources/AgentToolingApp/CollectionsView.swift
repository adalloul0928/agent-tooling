import AgentToolingCore
import SwiftUI

/// Reusable material a Configuration is built from. A Collection is a shelf;
/// a Configuration is a contract about what this Mac should have. This
/// placeholder reserves the section so the sidebar and routing stay stable
/// while the feature lands.
struct CollectionsView: View {
    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Collections", context: nil) { EmptyView() }
            EmptyStateView(
                symbol: "square.stack.3d.up",
                title: "Collections are on the way",
                message: "Group skills, plugins, and servers into reusable sets a configuration can include."
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

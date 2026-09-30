import AgentToolingCore
import SwiftUI

/// Checkup: the audit of this Mac's tooling and the assistant's reading of it.
struct CheckupSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        CheckupView(workspace: workspace, session: workspace.setup)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import AgentToolingCore
import SwiftUI

/// The Projects entry point the shell renders. Layout and interaction live in
/// `ProjectsView`, restored to the original screen's visual; this file only
/// keeps the section's identity, per the port map.
struct ProjectsSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        ProjectsView(workspace: workspace)
    }
}

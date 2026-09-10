import SwiftUI

/// Apps: what this Mac would change in each client, and the reviewed step that
/// changes it. Requested assignment is never rendered here as installation;
/// installing stays the separate decision this screen asks for.
struct ClientsSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        WorkspaceDeploymentView(session: workspace.deployment)
    }
}

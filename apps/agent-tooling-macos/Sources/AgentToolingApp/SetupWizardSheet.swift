import AgentToolingCore
import SwiftUI

/// The guided walk through everything the audit found. Filled in below.
struct SetupWizardSheet: View {
    let workspace: WorkspaceLaunch.Workspace
    @Bindable var session: WorkspaceSetupSession
    let onClose: () -> Void

    var body: some View {
        VStack {
            Text("Setup").font(.title2)
            Button("Close", action: onClose)
        }
        .frame(width: 400, height: 200)
    }
}

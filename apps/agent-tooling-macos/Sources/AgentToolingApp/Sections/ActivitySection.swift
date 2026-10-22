import SwiftUI

/// The journal, the receipts and the drift this Mac recorded, over its own
/// `WorkspaceActivitySession`.
///
/// `WorkspaceActivitySession` has no home on `WorkspaceLaunch.Workspace` —
/// Activity is one of the screens the versioned store never offered a session
/// for — so this section creates and holds one itself, the same way a Group B
/// screen owns the session it wires to a protocol-typed service.
struct ActivitySection: View {
    let workspace: WorkspaceLaunch.Workspace
    @Environment(\.installDriftReader) private var driftReader
    @State private var session: WorkspaceActivitySession

    init(workspace: WorkspaceLaunch.Workspace) {
        self.workspace = workspace
        _session = State(initialValue: WorkspaceActivitySession(store: workspace.store))
    }

    var body: some View {
        ActivityView(session: session)
            .task { await session.refresh(driftReader: driftReader) }
    }
}

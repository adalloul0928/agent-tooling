import SwiftUI

/// The Apps family's Health tab: what each managed client's last connection
/// check found, and the reviewed re-authentication a person can start.
///
/// The screen draws; the session decides. Landing here from the palette runs a
/// check once, and a check answered here is the check every other read of this
/// session sees.
struct HealthSection: View {
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        HealthView(session: workspace.health, device: workspace.device)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

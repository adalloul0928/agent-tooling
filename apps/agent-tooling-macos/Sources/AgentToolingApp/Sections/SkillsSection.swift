import SwiftUI

/// The Library's skills tab, and the only place onboarding is allowed to stand
/// in front of a screen.
///
/// Getting started is a thing you do to your library, so it belongs here rather
/// than over the window: every other section stays reachable while it is up, and
/// choosing tools or skipping puts it away for good.
struct SkillsSection: View {
    let workspace: WorkspaceLaunch.Workspace
    @AppStorage("onboarding.skipped.v2") private var onboardingSkipped = false

    var body: some View {
        if showsOnboarding {
            WorkspaceOnboardingView(session: workspace.library) { onboardingSkipped = true }
        } else {
            WorkspaceLibraryView(
                session: workspace.library, authoring: workspace.authoring, export: workspace.export)
        }
    }

    /// Only for a writable workspace that holds items and has no assignments at
    /// all. A read-only preview and an already-used workspace go straight in.
    private var showsOnboarding: Bool {
        guard !onboardingSkipped, workspace.library.access == .writable,
            let library = workspace.library.state?.library
        else { return false }
        return !library.rows.isEmpty && library.rows.allSatisfy { $0.requestedAssignments.isEmpty }
    }
}

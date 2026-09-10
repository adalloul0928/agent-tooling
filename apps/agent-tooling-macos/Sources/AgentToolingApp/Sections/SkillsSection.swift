import SwiftUI

/// The Library's skills tab, and the only place onboarding is allowed to stand
/// in front of a screen.
///
/// Getting started is a thing you do to your library, so it belongs here rather
/// than over the window: every other section stays reachable while it is up, and
/// choosing tools or skipping puts it away for good.
struct SkillsSection: View {
    let workspace: WorkspaceLaunch.Workspace
    @Environment(\.skillContentService) private var skillContentService
    @AppStorage("onboarding.skipped.v2") private var onboardingSkipped = false
    @State private var content: SkillContentSession?

    var body: some View {
        if showsOnboarding {
            OnboardingWizard(workspace: workspace) { onboardingSkipped = true }
        } else if let content {
            SkillsView(workspace: workspace, content: content)
        } else {
            // One session per workspace, made once. Building it in `body` would
            // hand the screen a new one on every layout pass and lose whatever
            // the last one had read.
            Color.clear.onAppear {
                content = SkillContentSession(
                    service: workspace.service, library: workspace.library,
                    cacheRoot: workspace.store.databaseURL.deletingLastPathComponent()
                        .appending(path: "cache", directoryHint: .isDirectory),
                    content: skillContentService)
            }
        }
    }

    /// Only for a writable workspace that holds items and has no assignments at
    /// all. A read-only preview and an already-used workspace go straight in.
    private var showsOnboarding: Bool {
        OnboardingPresentationPolicy.shouldPresent(
            skipped: onboardingSkipped, access: workspace.library.access,
            rows: workspace.library.state?.library.rows)
    }
}

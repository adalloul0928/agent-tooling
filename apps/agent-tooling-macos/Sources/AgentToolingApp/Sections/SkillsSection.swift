import SwiftUI

/// The Library's skills tab: the skills list, and under it the line saying
/// what the accounts add that the library does not hold.
///
/// Nothing stands in front of it. Setting a Mac up is the setup stage's work,
/// in a window of its own, so the library opens straight onto its rows on a
/// Mac that has assigned nothing yet, as on any other.
struct SkillsSection: View {
    let workspace: WorkspaceLaunch.Workspace
    @Environment(\.skillContentService) private var skillContentService
    @State private var content: SkillContentSession?

    var body: some View {
        if let content {
            VStack(spacing: 0) {
                SkillsView(workspace: workspace, content: content)
                AccountContentsStrip(session: workspace.accounts, kinds: [.skill])
            }
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
}

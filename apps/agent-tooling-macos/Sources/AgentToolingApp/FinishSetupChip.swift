import AgentToolingCore
import SwiftUI

/// The sidebar's reminder while Home's Finish setting up card is hidden:
/// "Finish setting up · 4 left", a 22 pt pill above the sync foot. Pressing
/// it shows the card again and opens Home.
struct FinishSetupChip: View {
    let left: Int
    let action: () -> Void

    var body: some View {
        let copy = LaunchpadCopy.FinishSetup.self
        Button(action: action) {
            Text(copy.chip(left: left))
                .font(AgentFont.captionMedium)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, Space.md)
                .frame(height: Size.pillHeight)
                .background(AgentTheme.fillSubtle, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copy.chipLabel(left: left))
        .accessibilityHint(copy.chipHint)
    }
}

/// The chip as the sidebar mounts it, over its sync foot: there only while
/// the card is hidden with rows left, and gone again once it shows.
struct FinishSetupSidebarChip: View {
    let workspace: WorkspaceLaunch.Workspace
    /// Opens Home, where the card shows again.
    let openHome: () -> Void
    @Environment(\.snapshotNow) private var snapshotNow

    var body: some View {
        if let left = FinishSetupChecklist.chipLeft(FinishSetupFacts.live(workspace: workspace), now: snapshotNow ?? .now) {
            FinishSetupChip(left: left) {
                workspace.setupProgress.setChecklistHidden(false)
                openHome()
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

import AgentToolingCore
import SwiftUI

/// The verdict half of a row: a small glyph next to two or three words. An item
/// that is up to date says nothing in a list, so a quiet screen means a quiet
/// inventory; the detail pane always states the verdict in full.
struct UpdateStateBadge: View {
    let availability: UpdateAvailability
    var showsWhenCurrent = false

    var body: some View {
        if showsWhenCurrent || !availability.isUpToDate {
            HStack(spacing: Space.xs) {
                StatusGlyph(state: availability.health, size: Size.glyphSmall)
                Text(availability.title)
                    .font(AgentFont.captionMedium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.md)
            .frame(height: Size.pillHeight)
            .background(Capsule().fill(AgentTheme.fillSubtle))
            .help(availability.detail)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(availability.title). \(availability.detail)")
        }
    }
}

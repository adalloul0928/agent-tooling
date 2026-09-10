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
            HStack(spacing: 5) {
                StatusGlyph(state: availability.health, size: 12)
                Text(availability.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 21)
            .background(Capsule().fill(Color.primary.opacity(0.055)))
            .help(availability.detail)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(availability.title). \(availability.detail)")
        }
    }
}

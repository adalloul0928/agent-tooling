import SwiftUI

/// Agent Tooling's mark where it names Agent Tooling in a row: 20 in the
/// apps header of Let your apps ask, 28 beside its own connection on You
/// joined. Knobs at rest, and in light a hairline of shadow, as macOS draws a
/// small icon on a white card.
struct AgentToolingAppMark: View {
    var size: CGFloat = Size.tile

    var body: some View {
        AgentToolingMark(size: size, elevated: false)
            .compositingGroup()
            .elevation(.smallMarkEdge)
    }
}

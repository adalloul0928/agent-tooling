import SwiftUI

extension StageLayout.Arrivals {
    /// From a Mac's tile to its name.
    static let tileGap: CGFloat = Space.sm
    /// From its name to the caption under it.
    static let captionGap: CGFloat = Space.xs
}

/// A Mac on You joined (J02): a 64 pt graphite symbol tile, the Mac's name
/// under it, and a caption saying which Mac it is ("other Mac", "Mac mini ·
/// macOS 26 · this Mac").
///
/// The graphite is the stage's deep one, so the white symbol keeps 4.5:1 in
/// dark. This Mac's tile lights once as it appears; another Mac's stands
/// still.
struct MacTile: View {
    let symbol: String
    let name: String
    let caption: String
    /// Whether the tile lights as it appears: this Mac's, which just joined.
    var lightsIn = false
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: Size.stageTile * Proportion.tileCorner, style: .continuous)
                    .fill(AgentTheme.graphiteDeep.gradient)
                Image(systemName: symbol)
                    .font(.system(size: Size.stageTile * Proportion.symbolTileSymbol, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: Size.stageTile, height: Size.stageTile)
            .opacity(isGhost ? Opacity.ghost : 1)
            .saturation(isGhost ? Saturation.ghost : 1)
            .padding(.bottom, StageLayout.Arrivals.tileGap)
            Text(name)
                .font(AgentFont.bodySemibold)
                .lineLimit(1)
            Text(caption)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, StageLayout.Arrivals.captionGap)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(caption)")
        .task {
            guard lightsIn, motion.resolved(reduceMotion: reduceMotion).animatesDetails, !lit else {
                lit = true
                return
            }
            withAnimation(AgentMotion.selection) { lit = true }
        }
    }

    /// Before it lights, this Mac's tile is a ghost, as a found app's is.
    private var isGhost: Bool { lightsIn && !lit && motion.resolved(reduceMotion: reduceMotion).animatesDetails }
}

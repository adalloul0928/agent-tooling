import AgentToolingCore
import SwiftUI

/// The poster Before you start and Welcome open on: no well, the stage ground
/// itself, with Agent Tooling's mark as the one lit object over the four
/// places its apps will stand in.
///
/// The places sit exactly where Your apps lights its tiles (x 136 / 332 /
/// 528 / 724, y 170), so the next screen lights them where they wait. They are
/// empty plates, never the not-found ring: nothing has been looked for yet.
/// VoiceOver reads the mark as "Agent Tooling" and the places as one image.
struct StagePoster: View {
    /// Slide the mark's knobs in, and fade the places in after them.
    var animates = false
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    var body: some View {
        let moving = animates && motion.resolved(reduceMotion: reduceMotion).animatesDetails
        ZStack(alignment: .top) {
            AgentToolingMark(size: Size.heroMark, animatesKnobs: animates)
                .offset(y: StageLayout.Poster.markTop)
            HStack(spacing: StageLayout.Well.columnGap) {
                ForEach(Array(ClientKind.allCases.enumerated()), id: \.element) { index, client in
                    StageAgentTile(client: client, state: .place)
                        .frame(width: StageLayout.Well.column)
                        .opacity(moving && !arrived ? 0 : 1)
                        .animation(
                            AgentMotion.selection.delay(
                                AgentMotion.knobDelays[0] + AgentMotion.revealStagger * Double(index)),
                            value: arrived)
                }
            }
            .padding(.top, StageLayout.Poster.placesTop)
            .padding(.horizontal, StageLayout.Well.columnInset)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LaunchpadCopy.Kit.placesLabel)
            .accessibilityAddTraits(.isImage)
        }
        .frame(maxWidth: .infinity)
        .frame(height: StageLayout.Poster.height, alignment: .top)
        .onAppear { arrived = true }
    }
}

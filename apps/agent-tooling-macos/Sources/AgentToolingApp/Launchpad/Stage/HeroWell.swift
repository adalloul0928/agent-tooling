import AgentToolingCore
import SwiftUI

/// Recessed container with four stable client columns. Height changes by setup
/// step while tile positions remain fixed. It stays unclipped for popovers.
struct HeroWell<Column: View>: View {
    let height: CGFloat
    var topInset: CGFloat = StageLayout.Well.tileTop
    /// What VoiceOver says for the row: "Apps: Codex, Claude Code and Gemini
    /// CLI found; Kiro CLI not found".
    var accessibilitySummary: String?
    let column: (ClientKind) -> Column

    init(
        height: CGFloat, topInset: CGFloat = StageLayout.Well.tileTop, accessibilitySummary: String? = nil,
        @ViewBuilder column: @escaping (ClientKind) -> Column
    ) {
        self.height = height
        self.topInset = topInset
        self.accessibilitySummary = accessibilitySummary
        self.column = column
    }

    var body: some View {
        HStack(alignment: .top, spacing: StageLayout.Well.columnGap) {
            ForEach(ClientKind.allCases) { client in
                column(client)
                    .frame(width: StageLayout.Well.column, alignment: .top)
            }
        }
        .padding(.top, topInset)
        .padding(.horizontal, StageLayout.Well.columnInset)
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: height, alignment: .top)
        .background { WellSurface() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary ?? "")
    }
}

/// The well's recessed surface: its floor, a shade under the top edge, a
/// hairline rim, and a lit lower lip under it.
struct WellSurface: View {
    var body: some View {
        let shape = RoundedRectangle.panel
        ZStack {
            shape.fill(AgentTheme.wellFloor)
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: AgentTheme.wellFloorShade, location: 0),
                        .init(color: .clear, location: StageLayout.Well.floorShadeStop),
                    ],
                    startPoint: .top, endPoint: .bottom))
            InnerTopShade(
                shape: shape, color: AgentTheme.wellTopShade, radius: StageLayout.Well.topShadeRadius,
                y: StageLayout.Well.topShadeY)
            shape.strokeBorder(HairlineStyle(), lineWidth: Hairline.width)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AgentTheme.wellLip)
                .frame(height: Hairline.width)
                .padding(.horizontal, Radius.xl)
                .offset(y: Hairline.width)
        }
        .accessibilityHidden(true)
    }
}

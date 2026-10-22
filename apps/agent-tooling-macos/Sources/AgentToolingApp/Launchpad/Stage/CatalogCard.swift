import SwiftUI

extension StageLayout.Catalog {
    /// A card's inset above and below its words; `Space.lg` either side.
    static let verticalInset: CGFloat = 10
    /// The room a card's name keeps clear of the badge at its corner.
    static let badgeClearance: CGFloat = Space.xl
}

/// Selectable starter listing with a native kind icon, source, and description.
/// A failed addition shows a warning; the full reason appears below the shelf.
/// Its icon represents kind, never verification.
struct CatalogCard: View {
    enum Art: Equatable {
        /// The listing's bundled artwork, by its catalog identity.
        case package(String)
        /// A skill's tile.
        case skill
    }

    let art: Art
    let name: String
    let summary: String
    let source: String
    let isPicked: Bool
    /// Whether it can be picked: not when the library holds it already, or
    /// it needs something this Mac does not have.
    var isEnabled = true
    /// Whether the last Add left it out: its last line says so.
    var isRefused = false
    /// The card as VoiceOver reads its checkbox.
    let accessibilityLabel: String
    let toggle: () -> Void
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.md) {
                    artwork
                    Text(name)
                        .font(AgentFont.bodySemibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.trailing, StageLayout.Catalog.badgeClearance)
                Text(summary)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, Space.sm)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    if isRefused {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AgentTheme.warning)
                    }
                    Text(source)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .font(AgentFont.micro)
            }
            .padding(.vertical, StageLayout.Catalog.verticalInset)
            .padding(.horizontal, Space.lg)
            .frame(width: StageLayout.Catalog.card.width, height: StageLayout.Catalog.card.height, alignment: .topLeading)
            .contentShape(shape)
            .softHighlight(isPicked, in: shape)
            .background { shape.fill(AgentTheme.controlBackground).elevation(.cardRest) }
            .overlay {
                if !isPicked {
                    shape.strokeBorder(HairlineStyle(), lineWidth: colorScheme == .dark ? Hairline.fine : Hairline.width)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isPicked {
                    CheckBadge(tint: AgentTheme.selection, size: Size.glyphLarge, ring: .clear, bounces: true)
                        .padding(Space.sm)
                        .transition(.opacity)
                }
            }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isEnabled)
        .animation(motion.resolved(reduceMotion: reduceMotion) == .full ? AgentMotion.selection : nil, value: isPicked)
        .accessibilityRepresentation {
            Toggle(accessibilityLabel, isOn: Binding(get: { isPicked }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .disabled(!isEnabled)
        }
    }

    @ViewBuilder private var artwork: some View {
        switch art {
        case .package(let packageID): ToolIdentityIcon(packageID: packageID, fallback: .plugin, size: Size.tile)
        case .skill: KindTile(kind: .skill, size: Size.tile)
        }
    }
}

import AgentToolingCore
import SwiftUI

/// Decorative client tile. Missing apps use an empty socket; unchecked apps use
/// an empty plate. Selection uses an accent ring and status uses a green check,
/// never both. The containing screen supplies controls and accessible labels.
struct StageAgentTile: View {
    enum State: Equatable, Sendable {
        /// Nothing looked for yet: an empty plate.
        case place
        /// Found and managed: lit, the accent ring and check.
        case managed
        /// Read: lit, a green check, no ring.
        case read
        /// Being read: lit, a spinner in the badge.
        case reading
        /// Found, not managed: lit at reduced presence, no ring, no badge.
        case ghost
        /// Not found: a socket holding the empty ring.
        case absent
        /// Not found, but turned on: the socket with the ring and check.
        case absentManaged
    }

    let client: ClientKind
    let state: State
    var compact = false
    /// Whether the badge bounces in as the tile lights.
    var badgeBounces = false

    private var side: CGFloat { compact ? Size.stageTileCompact : Size.stageTile }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: compact ? Radius.lg : Radius.xl, style: .continuous)
    }

    private var isLit: Bool { [.managed, .read, .reading, .ghost].contains(state) }
    private var isAbsent: Bool { state == .absent || state == .absentManaged }
    private var hasManagedRing: Bool { state == .managed || state == .absentManaged }

    var body: some View {
        ZStack {
            surface
            if isLit {
                ClientBrandIcon(client: client, size: compact ? Size.tile : Size.tileLarge)
            } else if isAbsent {
                if compact {
                    AbsentMark(size: Size.tile)
                } else {
                    AbsentMark(size: Size.tile, lineWidth: Hairline.ring, inset: 0)
                }
            }
        }
        .frame(width: side, height: side)
        .overlay {
            if hasManagedRing {
                shape.strokeBorder(AgentTheme.selection.opacity(Opacity.selectedStroke), lineWidth: Hairline.ring)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            badge
                .offset(x: Size.badgeOverhang + StageLayout.Well.badgeRing, y: Size.badgeOverhang + StageLayout.Well.badgeRing)
        }
        .compositingGroup()
        .opacity(state == .ghost ? Opacity.ghost : 1)
        .saturation(state == .ghost ? Saturation.ghost : 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var surface: some View {
        switch state {
        case .place:
            ZStack {
                shape.fill(AgentTheme.fillSubtle)
                shape.strokeBorder(HairlineStyle(base: AgentTheme.hairlineStroke), lineWidth: Hairline.width)
            }
        case .absent, .absentManaged:
            if compact {
                shape.strokeBorder(HairlineStyle(), lineWidth: Hairline.width)
            } else {
                StageSocket(shape: shape)
            }
        case .managed, .read, .reading, .ghost:
            StagePlate(shape: shape, casts: !compact)
        }
    }

    @ViewBuilder private var badge: some View {
        let size = compact ? Size.glyphSmall : Size.glyphLarge
        switch state {
        case .managed, .absentManaged:
            CheckBadge(tint: AgentTheme.selection, size: size, bounces: badgeBounces)
        case .read:
            CheckBadge(tint: AgentTheme.ok, size: size, bounces: badgeBounces)
        case .reading:
            ProgressView()
                .controlSize(.mini)
                .frame(width: size, height: size)
                .padding(StageLayout.Well.badgeRing)
                .background(AgentTheme.plateOnCard, in: Circle())
                .accessibilityHidden(true)
        case .place, .ghost, .absent:
            EmptyView()
        }
    }
}

/// A lit tile's plate: one step above a card, a lit top edge and, in dark, a
/// sheen fading down it, with a contact shadow and (in the well) a cast one.
struct StagePlate<S: InsettableShape>: View {
    let shape: S
    var casts = true

    var body: some View {
        ZStack {
            shape.fill(AgentTheme.plateOnCard)
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: AgentTheme.tileSheen, location: 0),
                        .init(color: .clear, location: StageLayout.Well.sheenStop),
                    ],
                    startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(HairlineStyle(), lineWidth: Hairline.width)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AgentTheme.tileTopEdge)
                .frame(height: Hairline.width)
                .padding(.horizontal, Radius.lg)
                .padding(.top, Hairline.width)
        }
        .compositingGroup()
        .elevation(.tileContact)
        .elevation(.tileCast, isOn: casts)
    }
}

/// The opposite of a lit plate: a socket in the well's floor where an app
/// that was not found would stand. Its top inner edge is in shade, its lower
/// one catches the light.
struct StageSocket<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        ZStack {
            InnerTopShade(
                shape: shape, color: AgentTheme.socketShade, radius: StageLayout.Well.socketShadeRadius,
                y: StageLayout.Well.socketShadeY)
            shape.strokeBorder(HairlineStyle(), lineWidth: Hairline.width)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AgentTheme.socketLip)
                .frame(height: Hairline.width)
                .padding(.horizontal, Radius.lg)
                .padding(.bottom, Hairline.width)
        }
    }
}

/// A shade cast into a recessed shape from its top edge, as an inset shadow
/// falls: everything outside the shape, dropped by `y` and blurred, seen only
/// through the shape. It lies deepest under the top edge, softens down the
/// sides, and never reaches the bottom.
struct InnerTopShade<S: InsettableShape>: View {
    let shape: S
    let color: Color
    let radius: CGFloat
    let y: CGFloat

    var body: some View {
        OutsideOf(shape: shape, margin: Space.xxxl)
            .fill(color, style: FillStyle(eoFill: true))
            .offset(y: y)
            .blur(radius: radius)
            .mask(shape)
            .allowsHitTesting(false)
    }
}

/// The band around a shape, `margin` wide, with the shape cut out of it.
private struct OutsideOf<S: Shape>: Shape {
    let shape: S
    let margin: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -margin, dy: -margin))
        path.addPath(shape.path(in: rect))
        return path
    }
}

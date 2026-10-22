import SwiftUI

// MARK: - Regions that scroll

extension View {
    /// A region of the stage that keeps its own height while it fits the
    /// room it is given, and scrolls inside that room once it does not, so a
    /// long list never pushes past the slot or grows the 860 × 640 window
    /// (brief §7). Give the region `layoutPriority(1)` beside a spacer, so
    /// it takes the room it needs before the spacer does.
    func scrollsWhenFull() -> some View {
        ViewThatFits(in: .vertical) {
            self
            ScrollView { self }
                .scrollBounceBehavior(.basedOnSize)
        }
    }
}

// MARK: - Motion on the stage

/// How the setup stage moves.
///
/// `full` is the stage as designed: tiles light in turn, badges bounce, the
/// knobs slide, checks draw on. `reduced` is Reduce Motion's: no slide,
/// stagger, scale, bounce or draw-on, content crossfades at `AgentMotion.quick`
/// and counts show their final values. `still` draws every view in its final
/// state with no motion at all, so a render test or a gallery capture, which
/// settles for a fraction of a second, sees what a person sees once the motion
/// has ended rather than a frame from the middle of it.
enum StageMotion: Sendable, Equatable {
    case full
    case reduced
    case still

    /// The motion in force once the system's Reduce Motion is applied.
    func resolved(reduceMotion: Bool) -> StageMotion {
        self == .full && reduceMotion ? .reduced : self
    }

    /// Whether the detail motions run: staggers, bounces, slides and
    /// draw-ons.
    var animatesDetails: Bool { self == .full }

    /// The animation a change of content takes: `selection` in full,
    /// `quick`'s crossfade under Reduce Motion, none in a still.
    var contentChange: Animation? {
        switch self {
        case .full: AgentMotion.selection
        case .reduced: AgentMotion.quick
        case .still: nil
        }
    }
}

extension EnvironmentValues {
    /// The setup stage's motion. The stage sets it from its environment; a
    /// render test or the gallery sets `.still`.
    @Entry var stageMotion: StageMotion = .full
}

// MARK: - Chips

/// One short capsule beside a name: how many copies an app has, which Mac a
/// review is for, whether something leaves this Mac. Neutral on the
/// quaternary ground; `warning` puts its words in the warning colour (copies
/// that differ); `outline` draws only its edge, for a chip beside a title.
struct Chip: View {
    enum Style: Sendable {
        case neutral
        case warning
        case outline
    }

    let text: String
    var style: Style = .neutral

    var body: some View {
        Text(text)
            .font(AgentFont.microMedium)
            .lineLimit(1)
            .padding(.horizontal, Space.sm)
            .frame(height: Size.chipHeight)
            .foregroundStyle(style == .warning ? AgentTheme.warning : Color.secondary)
            .background {
                if style != .outline { Capsule().fill(.quaternary) }
            }
            .overlay {
                if style == .outline { Capsule().strokeBorder(HairlineStyle(), lineWidth: Hairline.width) }
            }
            .fixedSize()
    }
}

// MARK: - Note lines

/// A caption with a small glyph before it: the one fact under Welcome's
/// choices, the fork restated before the read, the line under a form. It
/// carries meaning, so it is secondary, never tertiary.
struct NoteLine: View {
    let symbol: String
    let text: String
    var alignment: HorizontalAlignment = .center

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: Size.glyphSmall))
                .accessibilityHidden(true)
            Text(text).wrapsLines()
        }
        .font(AgentFont.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Check badges

/// A check on a small disc of the plate's colour, at a tile's or a card's
/// corner: the accent when it means chosen or managed, the ok green when it
/// means read. It arrives with a bounce, one beat after what it badges,
/// except under Reduce Motion or in a still.
struct CheckBadge: View {
    let tint: Color
    var size: CGFloat = Size.glyphLarge
    /// The ring's colour: the plate the badge sits on, so it reads cut out of
    /// the corner.
    var ring: Color = AgentTheme.plateOnCard
    /// Whether it bounces in when it appears.
    var bounces = false
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, tint)
            .font(.system(size: size, weight: .medium))
            .frame(width: size, height: size)
            .padding(Space.xxs)
            .background(ring, in: Circle())
            .symbolEffect(.bounce, value: landed)
            .task {
                guard bounces, motion.resolved(reduceMotion: reduceMotion).animatesDetails else { return }
                try? await Task.sleep(for: .seconds(AgentMotion.badgeDelay))
                landed = true
            }
            .accessibilityHidden(true)
    }
}

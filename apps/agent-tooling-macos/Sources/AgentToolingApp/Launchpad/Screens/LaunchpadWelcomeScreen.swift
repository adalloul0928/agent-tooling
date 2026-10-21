import AgentToolingCore
import SwiftUI

/// Chooses Start here or Join before configuration reads. Arrow keys select a path;
/// Return activates it. Decorative arrival motion is disabled for reduced motion
/// and deterministic captures.
struct LaunchpadWelcomeScreen: LaunchpadScreen {
    let flow: LaunchpadFlow
    private let choice: LaunchpadWelcomeChoice
    @FocusState private var focused: Bool

    init(flow: LaunchpadFlow) {
        self.flow = flow
        choice = Self.choice(flow)
    }

    private typealias Copy = LaunchpadCopy.Welcome

    var body: some View {
        VStack(spacing: 0) {
            StagePoster(animates: true)
            hello
                .padding(.top, StageLayout.Poster.titleGap)
                .modifier(WelcomeArrival(order: 0))
            VStack(spacing: StageLayout.Choice.gap) {
                ForEach(Array(Self.rows.enumerated()), id: \.element.path) { index, row in
                    WelcomeChoiceRow(row: row, isFocused: choice.focused == row.path) {
                        flow.choosePath(row.path)
                    }
                    .modifier(WelcomeArrival(order: index + 1))
                }
            }
            .frame(width: StageLayout.Choice.width)
            .padding(.top, StageLayout.Choice.top)
            NoteLine(symbol: "info.circle", text: Copy.footnote)
                .padding(.top, StageLayout.Choice.noteGap)
                .modifier(WelcomeArrival(order: Self.rows.count + 1))
            if let version = Self.version(of: flow.environment.bundleURL) {
                Text(Copy.version(version))
                    .font(AgentFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.top, StageLayout.Choice.versionGap)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .defaultFocus($focused, true)
        .onAppear { focused = true }
        .onChange(of: flow.isConfirmingLeave) { _, confirming in
            // Back from FooterConfirm: the keyboard returns to the rows.
            if !confirming { focused = true }
        }
        .onKeyPress(.upArrow) {
            choice.focus(.startHere)
            return .handled
        }
        .onKeyPress(.downArrow) {
            choice.focus(.join)
            return .handled
        }
        .accessibilityElement(children: .contain)
    }

    private var hello: some View {
        VStack(spacing: 0) {
            Text(Copy.title)
                .font(AgentFont.hero)
                .lineLimit(1)
                .frame(height: StageLayout.Header.heroTitleLine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
            Text(Copy.subtitle)
                .font(AgentFont.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .wrapsLines()
                .frame(maxWidth: Size.proseMaxWidth)
                .padding(.top, StageLayout.Choice.subtitleGap)
        }
    }

    /// The footer: "Set up later ⎋", no Back (the copy that drew Before you
    /// start has quit), and the primary the keyboard's row names.
    static func footer(_ flow: LaunchpadFlow) -> StageFooterSpec {
        let choice = choice(flow)
        return StageFooterSpec(
            later: .setUpLater, showsBack: false,
            primary: .init(title: choice.focused == .join ? Copy.joinPrimary : Copy.startPrimary) {
                flow.choosePath(choice.focused)
            })
    }

    /// The row the keyboard is on, kept by the flow so it holds across
    /// redraws, FooterConfirm, and a Back from Join.
    static func choice(_ flow: LaunchpadFlow) -> LaunchpadWelcomeChoice {
        flow.model(for: .welcome) { LaunchpadWelcomeChoice() }
    }

    /// The two rows, in order.
    static let rows = [
        WelcomeChoiceRow.Row(path: .startHere, symbol: "laptopcomputer", title: Copy.startTitle, detail: Copy.startDetail),
        WelcomeChoiceRow.Row(
            path: .join, symbol: "arrow.triangle.2.circlepath", title: Copy.joinTitle, detail: Copy.joinDetail),
    ]

    /// The version this copy says it is, from its bundle, or nil when the
    /// bundle names none (a development build).
    static func version(of bundleURL: URL) -> String? {
        guard let version = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            !version.isEmpty
        else { return nil }
        return version
    }
}

/// Which of Welcome's two rows the keyboard is on. The primary follows it.
@MainActor @Observable
final class LaunchpadWelcomeChoice {
    private(set) var focused: LaunchpadPath = .startHere

    /// Puts the keyboard on Start here's row or Join's.
    func focus(_ path: LaunchpadPath) {
        guard path != .rerun else { return }
        focused = path
    }
}

/// One of Welcome's rows: a deep graphite tile, the choice, what it does, and
/// a chevron, on a card. The row the keyboard is on carries the soft
/// highlight; a click takes it.
///
/// VoiceOver reads the two rows as a choice of two: each as its choice, with
/// what choosing it does as the hint, and the row the keyboard is on as the
/// selected one.
struct WelcomeChoiceRow: View {
    struct Row: Sendable {
        let path: LaunchpadPath
        let symbol: String
        let title: String
        let detail: String

        /// What VoiceOver reads for the row: its choice.
        var accessibilityLabel: String { title }
        /// What choosing it does.
        var accessibilityHint: String { detail }
    }

    let row: Row
    let isFocused: Bool
    let take: () -> Void

    /// A button, and the selected one of the two while the keyboard is on it.
    static func traits(isFocused: Bool) -> AccessibilityTraits {
        isFocused ? [.isButton, .isSelected] : .isButton
    }

    var body: some View {
        let shape = RoundedRectangle.card
        Button(action: take) {
            HStack(spacing: StageLayout.Choice.innerGap) {
                WelcomeChoiceTile(symbol: row.symbol)
                VStack(alignment: .leading, spacing: StageLayout.Choice.textGap) {
                    Text(row.title)
                        .font(AgentFont.bodySemibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(row.detail)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: StageLayout.Choice.chevron))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.leading, StageLayout.Choice.leadingInset)
            .padding(.trailing, StageLayout.Choice.trailingInset)
            .frame(maxWidth: .infinity)
            .frame(height: StageLayout.Choice.height)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .softHighlight(isFocused, in: shape)
        .background { shape.fill(AgentTheme.controlBackground).elevation(.cardRest) }
        .overlay {
            if !isFocused { shape.strokeBorder(HairlineStyle(), lineWidth: Hairline.width) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(row.accessibilityHint)
        .accessibilityAddTraits(Self.traits(isFocused: isFocused))
    }
}

/// A row's symbol tile: the symbol tile's shape, on the deep graphite that
/// keeps 4.5:1 behind its white symbol in dark.
private struct WelcomeChoiceTile: View {
    let symbol: String

    var body: some View {
        let side = StageLayout.Choice.tile
        ZStack {
            RoundedRectangle(cornerRadius: max(Radius.sm, side * Proportion.tileCorner), style: .continuous)
                .fill(AgentTheme.graphiteDeep.gradient)
            Image(systemName: symbol)
                .font(.system(size: side * Proportion.symbolTileSymbol, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// Welcome's content arriving: the title first, after the first knob, then
/// each row and the note one beat apart, fading in from a little smaller.
/// Only when the stage moves fully; otherwise it is simply there.
private struct WelcomeArrival: ViewModifier {
    /// The title is 0, the rows 1 and 2, the note 3.
    let order: Int
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    func body(content: Content) -> some View {
        let moving = motion.resolved(reduceMotion: reduceMotion).animatesDetails
        let shown = arrived || !moving
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : AgentMotion.appearScale)
            .onAppear {
                guard moving, !arrived else { return }
                let delay = AgentMotion.heroDelay + AgentMotion.revealStagger * Double(order)
                withAnimation(AgentMotion.selection.delay(delay)) { arrived = true }
            }
    }
}

extension StageLayout.Choice {
    /// From the welcome's subtitle to the rows.
    static let top: CGFloat = Space.xxxl
    /// From the title to the subtitle.
    static let subtitleGap: CGFloat = Space.md
    /// Between a row's tile, its words and its chevron.
    static let innerGap: CGFloat = Space.lg
    /// Between a row's choice and what it does.
    static let textGap: CGFloat = Space.xxs
    /// A row's insets: more before the tile than after the chevron.
    static let leadingInset: CGFloat = Space.xl
    static let trailingInset: CGFloat = Space.lg
    static let chevron: CGFloat = Size.glyphSmall
    /// From the rows to the note, and from the note to the version.
    static let noteGap: CGFloat = Space.xl
    static let versionGap: CGFloat = Space.md
}

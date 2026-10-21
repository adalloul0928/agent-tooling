import AgentToolingCore
import SwiftUI

extension StageLayout.Done {
    /// From a tile to its name, and from the name to its version: the
    /// bookend row sits centred in its 136 pt card.
    static let nameGap: CGFloat = Space.md
    static let lineGap: CGFloat = Space.xxs
    /// From the well to the title, from the title to its line, and from that
    /// line to the two columns.
    static let titleGap: CGFloat = Space.xl
    static let subtitleGap: CGFloat = Space.sm
    static let columnsGap: CGFloat = Space.lg
    /// Between the lines of What happened, and from a glyph to its words.
    static let lineSpacing: CGFloat = Space.sm
    static let glyphGap: CGFloat = Space.md
    /// Between the cards and blocks of Left for later.
    static let laterSpacing: CGFloat = Space.md
    /// From a column's label to what is under it.
    static let labelGap: CGFloat = Space.xxs
    /// The space above Runs on its own, past the column's own spacing.
    static let runsGap: CGFloat = Space.xs
    static let runSpacing: CGFloat = Space.xs
    /// Between the key strip's three keys.
    static let keySpacing: CGFloat = Space.xxxl
    /// How finely a balanced paragraph's width is searched for: each step
    /// halves what is left, so ten get within a point of a 796 column.
    static let balanceSteps = 10
}

extension View {
    /// Wraps text into lines of even length, as the mockups set a centred
    /// subtitle and what runs on its own (CSS `text-wrap: balance`): the
    /// narrowest width that keeps the lines the full width needs. Like
    /// `wrapsLines()`, it frees the height only once it has a real width.
    func balancesLines() -> some View {
        BalancedLinesLayout { self }
    }
}

/// The layout behind `balancesLines()`.
struct BalancedLinesLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        guard let width = proposal.width, width > 0 else { return view.sizeThatFits(proposal) }
        return view.sizeThatFits(ProposedViewSize(width: Self.balancedWidth(of: view, within: width), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let width = Self.balancedWidth(of: view, within: bounds.width)
        view.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: ProposedViewSize(width: width, height: nil))
    }

    /// The narrowest width at which `view` is no taller than at `width`.
    private static func balancedWidth(of view: LayoutSubview, within width: CGFloat) -> CGFloat {
        let height = view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        var narrow: CGFloat = 0
        var wide = width
        for _ in 0..<StageLayout.Done.balanceSteps {
            let middle = (narrow + wide) / 2
            if view.sizeThatFits(ProposedViewSize(width: middle, height: nil)).height > height {
                narrow = middle
            } else {
                wide = middle
            }
        }
        return min(width, wide.rounded(.up))
    }
}

/// One app's column in Done's bookend row: the tile, already lit with its
/// read check (or the empty socket), its name and its version.
struct DoneTileColumn: View {
    let tile: LaunchpadDoneSummary.Tile

    var body: some View {
        VStack(spacing: 0) {
            StageAgentTile(client: tile.client, state: tile.state)
            Text(tile.client.rawValue)
                .font(AgentFont.bodySemibold)
                .foregroundStyle(tile.isFound ? Color.primary : Color.secondary)
                .lineLimit(1)
                .padding(.top, StageLayout.Done.nameGap)
            Text(tile.line)
                .font(AgentFont.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: StageLayout.Well.columnText)
                .padding(.top, StageLayout.Done.lineGap)
        }
        .accessibilityHidden(true)
    }
}

/// A status glyph at Done's size, with no frame of its own around it, so a
/// line's words start where the mockups start them.
struct DoneGlyph: View {
    let symbol: String
    let tint: Color

    init(_ state: HealthState) {
        switch state {
        case .healthy: (symbol, tint) = ("checkmark.circle.fill", AgentTheme.ok)
        case .attention: (symbol, tint) = ("exclamationmark.triangle.fill", AgentTheme.warning)
        case .pending: (symbol, tint) = ("clock", .secondary)
        case .unavailable: (symbol, tint) = ("xmark.circle.fill", AgentTheme.failure)
        }
    }

    /// The info glyph a caption-only line leads with.
    static var info: DoneGlyph { DoneGlyph(symbol: "info.circle", tint: .secondary) }

    private init(symbol: String, tint: Color) {
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: Size.glyph, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: Size.glyph, height: Size.glyph)
            .padding(.top, Space.nudge)
            .accessibilityHidden(true)
    }
}

/// One line of What happened: a check that draws on in its turn, the line
/// in label colour, and a caption under it. An info line is a caption with
/// the info glyph.
struct DoneOutcomeRow: View {
    let line: LaunchpadDoneSummary.Line
    /// Where the line is in the list: its check draws on that many beats
    /// after the first.
    let index: Int
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    private var animates: Bool { motion.resolved(reduceMotion: reduceMotion).animatesDetails }

    var body: some View {
        HStack(alignment: .top, spacing: StageLayout.Done.glyphGap) {
            glyph
            VStack(alignment: .leading, spacing: StageLayout.Done.lineGap) {
                Text(styled(line.text))
                    .font(line.kind == .info ? AgentFont.caption : AgentFont.body)
                    .foregroundStyle(line.kind == .info ? Color.secondary : Color.primary)
                    .wrapsLines()
                if let detail = line.detail {
                    Text(detail)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .task {
            guard animates, line.kind != .info, !drawn else { return }
            try? await Task.sleep(for: .seconds(AgentMotion.revealStagger * Double(index)))
            withAnimation(AgentMotion.selection) { drawn = true }
        }
    }

    @ViewBuilder private var glyph: some View {
        switch line.kind {
        case .info:
            DoneGlyph.info
        case .done, .partial:
            ZStack {
                if drawn || !animates {
                    DoneGlyph(line.kind == .done ? .healthy : .attention)
                        .transition(.symbolEffect(.drawOn))
                }
            }
            .frame(width: Size.glyph, height: Size.glyph + Space.nudge, alignment: .top)
        }
    }

    /// The line with its path or command in the monospaced face, at the
    /// size a caption's code takes.
    private func styled(_ text: String) -> AttributedString {
        var styled = AttributedString(text)
        if let code = line.code, let range = styled.range(of: code) {
            styled[range].font = line.kind == .info ? AgentFont.monoMicro : AgentFont.mono
        }
        return styled
    }
}

/// A column's label with its qualifier beside it: "Left for later · 2 Home
/// adds 2 suggestions", "Runs on its own only while Agent Tooling is open".
struct DoneColumnLabel: View {
    let label: String
    var qualifier: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Eyebrow(label)
                .accessibilityAddTraits(.isHeader)
            if let qualifier {
                Text(qualifier)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One card of Left for later: its glyph, a title in medium weight, and a
/// caption under it.
struct DoneLaterCard: View {
    let later: LaunchpadDoneSummary.Later

    var body: some View {
        HStack(alignment: .top, spacing: StageLayout.Done.glyphGap) {
            DoneGlyph(later.state)
            VStack(alignment: .leading, spacing: StageLayout.Done.lineGap) {
                Text(later.title)
                    .font(AgentFont.bodyMedium)
                    .wrapsLines()
                if let detail = later.detail {
                    Text(detail)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Space.md)
        .padding(.horizontal, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stageCard()
        .accessibilityElement(children: .combine)
    }
}

/// What runs on its own, one part to a line: the part's lead in label
/// colour, what runs in secondary.
struct DoneRunsBlock: View {
    let runs: [LaunchpadDoneSummary.Run]

    var body: some View {
        VStack(alignment: .leading, spacing: StageLayout.Done.runSpacing) {
            if runs.isEmpty {
                Text(LaunchpadCopy.Done.nothingRuns)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .wrapsLines()
            }
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                Text(styled(run))
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .balancesLines()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(LaunchpadCopy.Done.run(run.lead, run.text))
            }
        }
    }

    private func styled(_ run: LaunchpadDoneSummary.Run) -> AttributedString {
        var lead = AttributedString(run.lead)
        lead.font = AgentFont.captionMedium
        lead.foregroundColor = Color.primary
        return lead + AttributedString(" " + run.text)
    }
}

/// The main window's keys, taught on the way out: ⌘K, ⇧⌘R and ⇧⌘D. The
/// stage never binds them; each is a picture of the key beside what it
/// does there.
struct DoneKeyStrip: View {
    var body: some View {
        let copy = LaunchpadCopy.Done.self
        HStack(spacing: StageLayout.Done.keySpacing) {
            key(KeyboardShortcut("k", modifiers: .command), copy.keySearch)
            key(KeyboardShortcut("r", modifiers: [.shift, .command]), copy.keyReview)
            key(KeyboardShortcut("d", modifiers: [.shift, .command]), copy.keyCheckApps)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func key(_ shortcut: KeyboardShortcut, _ action: String) -> some View {
        HStack(spacing: Space.sm) {
            KeyCombo(shortcut: shortcut)
            Text(action)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LaunchpadCopy.Done.key(action, spoken: KeyCombo.spoken(shortcut)))
    }
}

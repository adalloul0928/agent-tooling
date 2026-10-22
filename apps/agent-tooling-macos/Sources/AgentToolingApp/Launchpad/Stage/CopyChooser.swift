import SwiftUI

extension StageLayout.CopyChooser {
    /// The radio at a cell's leading edge, and the dot a chosen one holds.
    static let radio: CGFloat = Size.glyph
    static let radioDot: CGFloat = 6
    /// Between the radio and its two lines.
    static let radioGap: CGFloat = Space.sm
    /// Between two cells, across and down.
    static let cellGap: CGFloat = Space.lg
    /// Cells side by side in the group; a third copy starts a second row.
    static let columns = 2

    /// How much taller than its two copies' one row the chooser is with
    /// `count` copies: a row of cells and the gap above it for each row past
    /// the first.
    static func extraHeight(forCopies count: Int) -> CGFloat {
        let rows = (max(count, 1) + columns - 1) / columns
        return CGFloat(rows - 1) * (cell.height + cellGap)
    }
}

/// The copy chooser's radio at rest, as the kit draws a radio: a filled
/// control with a ring, a hair of shadow under it. White on a light card; a
/// lighter disc on a dark one, where the card's own colour would lose it.
extension AgentTheme {
    static let stageRadioFill = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 1, darkAlpha: 0.12)
    static let stageRadioRing = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.10)
    static let stageRadioShadow = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0.25)
}

extension Elevation {
    /// Under a radio at rest (`0 .5px 1px`).
    static let stageRadioEdge = Elevation(color: AgentTheme.stageRadioShadow, radius: 0.5, y: 0.5)
}

/// Accessible radio group for choosing among differing skill copies. Cells wrap
/// two per row; the caller reserves extra height. Clicking or arrow keys select
/// a copy and let the caller select its parent skill.
struct CopyChooser: View {
    /// One copy.
    struct Option: Identifiable, Equatable {
        /// The copy's folder.
        let id: String
        /// "Claude Code’s copy".
        let title: String
        /// "3 files · changed Oct 2", once the copy is measured.
        let detail: String?
        /// The cell as VoiceOver reads it.
        let accessibilityLabel: String
    }

    /// The group's name: "Copy of Frontend Design to bring in".
    let label: String
    let options: [Option]
    let selection: String?
    var isEnabled = true
    let choose: (String) -> Void
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Layout = StageLayout.CopyChooser

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(Layout.cell.width), spacing: Layout.cellGap, alignment: .leading),
                count: Layout.columns),
            alignment: .leading, spacing: Layout.cellGap
        ) {
            ForEach(options) { option in cell(option) }
        }
        .frame(width: Layout.group, alignment: .leading)
        .onKeyPress(.leftArrow) { step(by: -1) }
        .onKeyPress(.rightArrow) { step(by: 1) }
        .accessibilityRepresentation {
            Picker(label, selection: Binding(get: { selection ?? "" }, set: { choose($0) })) {
                ForEach(options) { option in Text(option.accessibilityLabel).tag(option.id) }
            }
            .pickerStyle(.radioGroup)
            .disabled(!isEnabled)
        }
    }

    private func cell(_ option: Option) -> some View {
        let isOn = option.id == selection
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        return Button {
            choose(option.id)
        } label: {
            HStack(spacing: Layout.radioGap) {
                RadioMark(isOn: isOn)
                VStack(alignment: .leading, spacing: 0) {
                    Text(option.title)
                        .font(AgentFont.captionMedium)
                        .foregroundStyle(.primary)
                    if let detail = option.detail {
                        Text(detail)
                            .font(AgentFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Layout.cellPadding)
            .frame(width: Layout.cell.width, height: Layout.cell.height)
            .contentShape(shape)
            .softHighlight(isOn, in: shape)
            .overlay {
                if !isOn { shape.strokeBorder(HairlineStyle(), lineWidth: Hairline.width) }
            }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isEnabled)
        .animation(motion.resolved(reduceMotion: reduceMotion) == .full ? AgentMotion.selection : nil, value: isOn)
    }

    /// ←→: the copy before or after the chosen one.
    private func step(by offset: Int) -> KeyPress.Result {
        guard isEnabled, !options.isEmpty else { return .ignored }
        let current = options.firstIndex { $0.id == selection } ?? 0
        let next = min(max(current + offset, 0), options.count - 1)
        guard next != current || selection == nil else { return .handled }
        choose(options[next].id)
        return .handled
    }
}

/// A radio drawn as the kit draws one: at rest a filled disc with a ring and
/// a hair of shadow; chosen, the accent with a white dot in it.
private struct RadioMark: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(AgentTheme.selection)
                Circle()
                    .fill(AgentTheme.onSelection)
                    .frame(width: StageLayout.CopyChooser.radioDot, height: StageLayout.CopyChooser.radioDot)
            } else {
                Circle()
                    .fill(AgentTheme.stageRadioFill)
                    .elevation(.stageRadioEdge)
                Circle().strokeBorder(HairlineStyle(base: AgentTheme.stageRadioRing), lineWidth: Hairline.width)
            }
        }
        .frame(width: StageLayout.CopyChooser.radio, height: StageLayout.CopyChooser.radio)
        .accessibilityHidden(true)
    }
}

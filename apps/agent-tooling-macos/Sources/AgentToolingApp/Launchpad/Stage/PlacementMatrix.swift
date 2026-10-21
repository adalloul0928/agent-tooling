import AgentToolingCore
import SwiftUI

extension StageLayout.Matrix {
    /// Where a cell starts in its column, and where its glyph or first word
    /// starts in the cell: together the column head's 22, so each column
    /// reads down one edge.
    static let cellInset: CGFloat = Space.lg
    static let cellLeading: CGFloat = headInset - cellInset
    /// How many app columns take their full width. More share what the item
    /// column leaves, and their reasons wrap.
    static let fullColumns = 3

    /// One app column's width when there are `count`.
    static func appColumnWidth(count: Int) -> CGFloat {
        guard count > fullColumns else { return appColumn }
        return (StageLayout.Grid.contentWidth - itemColumn) / CGFloat(count)
    }

    /// The cursor's ring: `Hairline.focus` wide, a hairline outside the cell,
    /// as a focus ring sits.
    @MainActor static let cursorOutset: CGFloat = Hairline.width + Hairline.focus
}

/// Accessible placement grid: items are rows and managed apps are columns.
/// Arrow keys move focus; Space toggles only installable cells. Other cells
/// explain existing content, shared folders, or refusal. VoiceOver exposes press
/// actions only where the selection can change.
struct PlacementMatrix: View {
    let model: LaunchpadPlacement
    @FocusState private var isFocused: Bool
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var columnWidth: CGFloat { StageLayout.Matrix.appColumnWidth(count: model.apps.count) }
    /// Every row and the hairline between each two: the most the rows take
    /// before they scroll.
    private var rowsHeight: CGFloat {
        let rows = CGFloat(model.items.count)
        return StageLayout.Matrix.row * rows + Hairline.width * max(rows - 1, 0)
    }
    private var cellWidth: CGFloat { min(StageLayout.Matrix.cell.width, columnWidth - StageLayout.Matrix.cellInset * 2) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .hairlineBottom()
            ScrollViewReader { rows in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Hairline(indent: Hairline.afterLeading(Size.tile)) }
                            row(item)
                                .id(item.id)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.automatic)
                // The cursor's row stays in view as the keyboard moves it.
                .onChange(of: model.cursor?.item) { _, item in
                    guard let item else { return }
                    withAnimation(motion.resolved(reduceMotion: reduceMotion).contentChange) { rows.scrollTo(item) }
                }
            }
            .frame(maxHeight: rowsHeight)
            .layoutPriority(1)
        }
        .frame(width: StageLayout.Grid.contentWidth, alignment: .leading)
        .stageCard()
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .defaultFocus($isFocused, true)
        .onKeyPress(.space) {
            guard let cursor = model.cursor else { return .ignored }
            toggle(cursor)
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            switch press.key {
            case .upArrow: model.moveCursor(.up)
            case .downArrow: model.moveCursor(.down)
            case .leftArrow: model.moveCursor(.left)
            default: model.moveCursor(.right)
            }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LaunchpadCopy.Place.title)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: StageLayout.Matrix.itemColumn)
                .accessibilityHidden(true)
            ForEach(model.apps) { app in
                HStack(spacing: Space.sm) {
                    ClientBrandIcon(client: app, size: Size.brandMark)
                    Text(app.rawValue)
                        .font(AgentFont.captionMedium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, StageLayout.Matrix.headInset)
                .frame(width: columnWidth, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(app.rawValue)
                .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
        }
        .frame(height: StageLayout.Matrix.header)
    }

    private func row(_ item: LaunchpadPlacement.Item) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: Space.lg) {
                tile(item)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(item.name)
                        .font(AgentFont.bodyMedium)
                        .lineLimit(1)
                        .frame(height: StageLayout.Header.subtitleLine, alignment: .leading)
                    Text(item.subtitle)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: StageLayout.Well.captionLine, alignment: .leading)
                }
            }
            .padding(.horizontal, Space.xl)
            .frame(width: StageLayout.Matrix.itemColumn, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityValue(item.subtitle)
            .accessibilityAddTraits(.isHeader)
            ForEach(model.apps) { app in
                cell(LaunchpadPlacement.Key(item: item.artifactID, app: app))
                    .frame(width: columnWidth, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .frame(height: StageLayout.Matrix.row)
        // VoiceOver reads the grid row by row: the item, then its cells.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
    }

    @ViewBuilder private func tile(_ item: LaunchpadPlacement.Item) -> some View {
        if let artwork = item.artworkID {
            ToolIdentityIcon(packageID: artwork, fallback: ToolingKind(item.kind), size: Size.tile)
        } else {
            KindTile(kind: ToolingKind(item.kind), size: Size.tile)
        }
    }

    private func cell(_ key: LaunchpadPlacement.Key) -> some View {
        MatrixCell(
            cell: model.cells[key], isCursor: model.cursor == key, width: cellWidth,
            columnWidth: columnWidth - StageLayout.Matrix.cellInset
        )
        .padding(.leading, StageLayout.Matrix.cellInset)
        .contentShape(Rectangle())
        .onTapGesture {
            isFocused = true
            toggle(key)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel(for: key))
        .accessibilityHint(model.accessibilityHint(for: key) ?? "")
        .accessibilityAddTraits(model.isToggleable(key) ? [.isToggle] : [.isStaticText])
        .accessibilityAddTraits(model.cells[key] == .willInstall ? [.isSelected] : [])
        .pressAction(when: model.isToggleable(key)) { toggle(key) }
    }

    /// Space or a click: the cell changes fill and ring at selection, and
    /// the footer's count with it.
    private func toggle(_ key: LaunchpadPlacement.Key) {
        withAnimation(motion.resolved(reduceMotion: reduceMotion).contentChange) {
            model.toggle(key)
        }
    }
}

/// One cell of the placement grid, as the fragment draws each state.
struct MatrixCell: View {
    let cell: LaunchpadPlacement.Cell?
    var isCursor = false
    var width: CGFloat = StageLayout.Matrix.cell.width
    /// The column's width past the cell's inset, which a two-line cell takes.
    var columnWidth: CGFloat = StageLayout.Matrix.appColumn - StageLayout.Matrix.cellInset

    var body: some View {
        content
            .overlay {
                if isCursor {
                    RoundedRectangle(cornerRadius: Radius.md + StageLayout.Matrix.cursorOutset, style: .continuous)
                        .strokeBorder(AgentTheme.selection, lineWidth: Hairline.focus)
                        .padding(-StageLayout.Matrix.cursorOutset)
                }
            }
    }

    @ViewBuilder private var content: some View {
        let copy = LaunchpadCopy.Place.self
        switch cell {
        case .willInstall:
            line(symbol: "checkmark", tint: AgentTheme.selection, text: copy.willInstall, font: AgentFont.captionMedium)
                .foregroundStyle(.primary)
                .boxed(width: width)
                .softHighlight(true, in: RoundedRectangle.control)
        case .add:
            line(symbol: "plus", tint: nil, text: copy.add, font: AgentFont.caption)
                .foregroundStyle(.primary)
                .boxed(width: width)
                .overlay { RoundedRectangle.control.strokeBorder(HairlineStyle(), lineWidth: Hairline.width) }
        case .hasIt:
            line(symbol: "checkmark.circle.fill", tint: AgentTheme.ok, text: copy.hasIt, font: AgentFont.caption)
                .foregroundStyle(.primary)
                .boxed(width: width)
        case .through(let app):
            line(symbol: "link", tint: nil, text: copy.through(app.rawValue), font: AgentFont.caption)
                .foregroundStyle(.secondary)
                .boxed(width: width)
        case .leftAlone(let reason):
            twoLines(reason)
        case .readsCopy(let app):
            twoLines(copy.readsCopy(of: app.rawValue))
        case .readsFolder(let app):
            reason(copy.readsFolder(of: app.rawValue))
        case .unavailable(let text):
            reason(text)
        case nil:
            Color.clear.boxed(width: width)
        }
    }

    /// A glyph and its words, on one line at full width; in a column
    /// narrowed to fit a fourth app the words take a second.
    private func line(symbol: String, tint: Color?, text: String, font: Font) -> some View {
        HStack(spacing: Space.sm) {
            glyph(symbol, tint: tint)
            Text(text)
                .font(font)
                .lineLimit(2)
        }
    }

    private func glyph(_ symbol: String, tint: Color?) -> some View {
        Image(systemName: symbol)
            .font(.system(size: Size.glyphSmall, weight: .medium))
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .frame(width: Size.glyphSmall, height: Size.glyphSmall)
            .accessibilityHidden(true)
    }

    /// Left alone over its reason: the column's width, two caption lines
    /// under the first.
    private func twoLines(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            glyph("minus.circle.fill", tint: nil)
                .padding(.top, Space.nudge)
            VStack(alignment: .leading, spacing: 0) {
                Text(LaunchpadCopy.Place.leftAlone)
                    .font(AgentFont.captionMedium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(reason)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .wrapsLines()
            }
        }
        .padding(.leading, StageLayout.Matrix.cellLeading)
        .padding(.vertical, Space.xs)
        .frame(width: columnWidth, alignment: .topLeading)
        .frame(minHeight: StageLayout.Matrix.cell.height)
    }

    /// A reason alone, where nothing can go.
    private func reason(_ text: String) -> some View {
        Text(text)
            .font(AgentFont.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.leading, StageLayout.Matrix.cellLeading)
            .frame(width: columnWidth, alignment: .leading)
            .frame(minHeight: StageLayout.Matrix.cell.height)
    }
}

extension View {
    /// A cell's box: the cell's width and the control height, its glyph or
    /// first word on the column's edge.
    fileprivate func boxed(width: CGFloat) -> some View {
        padding(.leading, StageLayout.Matrix.cellLeading)
            .padding(.trailing, Space.md)
            .frame(width: width, height: StageLayout.Matrix.cell.height, alignment: .leading)
    }

    /// VoiceOver's press, only on a cell Space turns on or off: a cell that
    /// is only read offers nothing to do.
    @ViewBuilder
    fileprivate func pressAction(when isEnabled: Bool, _ action: @escaping () -> Void) -> some View {
        if isEnabled {
            accessibilityAction(.default, action)
        } else {
            self
        }
    }
}

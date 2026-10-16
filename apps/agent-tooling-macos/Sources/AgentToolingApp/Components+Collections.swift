import SwiftUI

// MARK: - Collection lists

// Every collection in the app — Skills, Plugins, Connections, Projects,
// Activity, History — is a run of rows on one standing card, separated by one
// hairline, with the accent fill for selection. Native `List` and `Table`
// draw their own separators in colours that have nothing to do with that
// card (the black lines on the Activity screen), so a collection built on a
// `List` switches the system chrome off here and draws the shared chrome
// instead. `Table` cannot be quieted the same way; the two screens that used
// it now lay their columns out by hand inside a `List`, which keeps native
// multiple selection and keyboard navigation.

extension View {
    /// The chrome of a native `List` used as a collection: the system's own
    /// separators and backgrounds are switched off so rows can draw the same
    /// hairline every hand-built list draws, and the list sits on the shared
    /// collection surface.
    func collectionListChrome() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Size.rowHeight)
    }

    /// A row inside a `collectionListChrome()` list: the standard inset and a
    /// hairline underneath, hidden while the row is selected so the accent
    /// fill has a clean edge.
    func collectionRowChrome(selected: Bool) -> some View {
        collectionRowChrome(selected: selected, leading: Space.xl, trailing: Space.xl)
    }

    /// A row of a collection laid out as a table under a
    /// `CollectionColumnHeader` (Plugins, Connections): the same chrome, with
    /// the row's content at exactly the standard inset. The header stands
    /// outside the list, and the list pads each row's content by
    /// `ListCellMargin` on its own, so a table row gives that margin back and
    /// its columns stand under the header's titles.
    func collectionTableRowChrome(selected: Bool) -> some View {
        collectionRowChrome(
            selected: selected, leading: Space.xl - ListCellMargin.leading,
            trailing: Space.xl - ListCellMargin.trailing)
    }

    private func collectionRowChrome(selected: Bool, leading: CGFloat, trailing: CGFloat) -> some View {
        // The system separator is a row trait, so it is switched off here, on
        // the row, where it has effect; on the list it is ignored.
        listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing))
            .frame(minHeight: Size.rowHeight)
            .listRowBackground(
                ZStack(alignment: .bottom) {
                    SelectionRowBackground(selected: selected)
                    if !selected { Hairline().padding(.horizontal, Space.xl) }
                }
            )
    }

    /// Text and glyphs on a selected row turn white so they stay legible on
    /// the accent fill; `secondary` is the detail line, `primary` the name.
    func collectionRowForeground(selected: Bool, secondary: Bool = false) -> some View {
        foregroundStyle(
            selected
                ? (secondary ? AgentTheme.onSelection.opacity(Opacity.secondaryOnSelection) : AgentTheme.onSelection)
                : (secondary ? Color.secondary : Color.primary))
    }
}

/// The title over a run of rows inside a collection list: "Today", "Pinned".
/// It is a row of the list, not a native section header, which would draw its
/// own rule and ground; it carries the chrome a header row needs.
struct CollectionSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(AgentFont.heading)
            .foregroundStyle(.primary)
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.lg)
            .padding(.bottom, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textCase(nil)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .selectionDisabled()
    }
}

/// The column titles over a collection laid out as a table. Each title is
/// framed by the caller to its column's width, so the header and the rows
/// read from one set of widths.
struct CollectionColumnHeader<Columns: View>: View {
    @ViewBuilder let columns: Columns

    var body: some View {
        HStack(spacing: Space.lg) {
            columns
        }
        .font(AgentFont.captionMedium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.xl)
        .frame(height: Size.compactRowHeight)
        .background(AgentTheme.fillSubtle)
        .hairlineBottom()
    }
}

// MARK: - Collection tables

/// How a collection laid out as a table by hand divides its width: the
/// Skills, Plugins and Connections tables. `Table` draws its own row
/// separators in a colour the card cannot control, so these tables are rows of
/// plain frames, and the header and every row read their widths from one value
/// of this.
///
/// One rule serves all three. A table shows its wide layout from its own
/// `expandedFrom` width up, and its narrow layout below it. In the wide layout
/// the name column takes its share of the width, up to a ceiling; in the
/// narrow one it takes what the columns beside it leave, down to a floor. The
/// other columns are fixed widths from `CollectionColumn`, or take a share of
/// their own through `share(_:upTo:)`.
struct CollectionColumns {
    /// One table's numbers, all from `CollectionColumn`.
    struct Layout {
        /// The width the wide layout starts at.
        let expandedFrom: CGFloat
        /// The wide layout's name column: this share of the width, up to
        /// `nameMax`.
        let nameShare: CGFloat
        let nameMax: CGFloat
        /// The narrow layout's name column: the width less `narrowReserve`,
        /// everything else a narrow row holds (its other columns and every
        /// gap between its items, so a row adds no gap the reserve leaves
        /// out), down to `nameMin`.
        let nameMin: CGFloat
        let narrowReserve: CGFloat
    }

    /// The table's inner width: the card's, less the rows' own insets.
    let width: CGFloat
    /// Whether the table shows its wide layout.
    let expanded: Bool
    /// The name column's width.
    let name: CGFloat

    init(width: CGFloat, layout: Layout) {
        self.width = width
        expanded = width >= layout.expandedFrom
        name =
            expanded
            ? min(layout.nameMax, width * layout.nameShare)
            : max(layout.nameMin, width - layout.narrowReserve)
    }

    /// A column that takes `fraction` of the table's width, up to `ceiling`.
    func share(_ fraction: CGFloat, upTo ceiling: CGFloat) -> CGFloat {
        min(ceiling, width * fraction)
    }
}

extension CollectionColumns.Layout {
    /// The Connections table. Its narrow layout keeps the App column, and the
    /// one gap before it, beside the name; the row and its header put nothing
    /// else between them.
    static let connections = Self(
        expandedFrom: CollectionColumn.Connections.expandedFrom,
        nameShare: CollectionColumn.Connections.nameShare,
        nameMax: CollectionColumn.Connections.nameMax,
        nameMin: CollectionColumn.Connections.nameMin,
        narrowReserve: CollectionColumn.clientMarks + Space.lg)

    /// The Plugins table. Its narrow layout keeps the Managed by column, and
    /// the one gap before it, beside the name; the row and its header put
    /// nothing else between them.
    static let plugins = Self(
        expandedFrom: CollectionColumn.Plugins.expandedFrom,
        nameShare: CollectionColumn.Plugins.nameShare,
        nameMax: CollectionColumn.nameMax,
        nameMin: CollectionColumn.Plugins.nameMin,
        narrowReserve: CollectionColumn.clientMarks + Space.lg)

    /// The Skills table. Its narrow layout keeps the Found in marks, the
    /// compact Managed column and, while several are being chosen, the
    /// checkbox slot and its gap. With no description on the list the wide
    /// name takes that column's room back.
    static func skills(selecting: Bool, describing: Bool) -> Self {
        Self(
            expandedFrom: CollectionColumn.Skills.expandedFrom,
            nameShare: describing ? CollectionColumn.Skills.nameShare : CollectionColumn.Skills.nameShareUndescribed,
            nameMax: describing ? CollectionColumn.nameMax : CollectionColumn.Skills.nameMaxUndescribed,
            nameMin: CollectionColumn.Skills.nameMin,
            narrowReserve: CollectionColumn.Skills.compactReserve + CollectionColumn.Skills.verdictCompact
                + (selecting ? Size.glyphSlot + Space.lg : 0))
    }
}

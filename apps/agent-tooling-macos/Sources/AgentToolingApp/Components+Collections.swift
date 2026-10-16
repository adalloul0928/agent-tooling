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
        // The system separator is a row trait, so it is switched off here, on
        // the row, where it has effect; on the list it is ignored.
        listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: Space.xl, bottom: 0, trailing: Space.xl))
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
                ? (secondary ? AgentTheme.onSelection.opacity(0.78) : AgentTheme.onSelection)
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

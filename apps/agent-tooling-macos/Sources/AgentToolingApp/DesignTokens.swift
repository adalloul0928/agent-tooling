import SwiftUI

// The design tokens. Every view picks from these scales and only these; a raw
// number in a view is a bug, the way a raw hex colour would be. The scales are
// deliberately short so two screens drawing the same kind of thing can only
// land on the same value.
//
// Fonts are fixed-size on purpose. The screens are dense, with fixed row
// heights and column widths, and the explicit sizes are what the shared
// components (`PageToolbar`, `InventorySearchField`) already used; the text
// styles drifted away from them by two and three points. One scale now.

// MARK: - Type

/// The type scale. Four sizes carry almost everything: `pageTitle` for the
/// screen, `title` for the thing a detail pane is about, `body` for rows and
/// prose, `caption` for the clause under a row. `micro` is for stamps and
/// badges only; `mono` for paths, commands, and identifiers.
enum AgentFont {
    // Sizes in points. These are the macOS norms: 13 for body text, 11 for
    // secondary, 15 for a heading, 20 for a page title.
    static let microSize: CGFloat = 10
    static let captionSize: CGFloat = 11
    static let bodySize: CGFloat = 13
    static let titleSize: CGFloat = 15
    static let titleLargeSize: CGFloat = 17
    static let pageTitleSize: CGFloat = 20
    static let statSize: CGFloat = 22
    static let statLargeSize: CGFloat = 30

    /// The screen's name in the page toolbar; the name of the thing a detail
    /// pane or sheet is about.
    static let pageTitle = Font.system(size: pageTitleSize, weight: .semibold)
    /// A heading over a group of cards, or a big-step wizard title.
    static let titleLarge = Font.system(size: titleLargeSize, weight: .semibold)
    /// The title line of a detail header or a prominent card.
    static let title = Font.system(size: titleSize, weight: .semibold)
    /// The same size, regular weight: a lead sentence under a title.
    static let titleRegular = Font.system(size: titleSize, weight: .regular)
    /// Card titles and section labels above a list of rows.
    static let heading = Font.system(size: bodySize, weight: .semibold)

    /// Prose, labeled values, body copy.
    static let body = Font.system(size: bodySize, weight: .regular)
    /// The name on a row.
    static let bodyMedium = Font.system(size: bodySize, weight: .medium)
    /// A row name that must out-rank its neighbours (a client name in a wizard).
    static let bodySemibold = Font.system(size: bodySize, weight: .semibold)

    /// The clause under a row name; secondary text everywhere.
    static let caption = Font.system(size: captionSize, weight: .regular)
    static let captionMedium = Font.system(size: captionSize, weight: .medium)
    static let captionSemibold = Font.system(size: captionSize, weight: .semibold)

    /// Timestamps, counts in a pill, "+2 more". Never for a sentence.
    static let micro = Font.system(size: microSize, weight: .regular)
    static let microMedium = Font.system(size: microSize, weight: .medium)
    static let microSemibold = Font.system(size: microSize, weight: .semibold)
    /// A letter or two inside a tiny badge.
    static let microBold = Font.system(size: microSize, weight: .bold)

    /// Paths, commands, identifiers. Caption-sized so it never shouts.
    static let mono = Font.system(size: captionSize, design: .monospaced)
    /// Code the person is reading or editing, at body size.
    static let monoBody = Font.system(size: bodySize, design: .monospaced)

    /// One number that is the point of a card.
    static let stat = Font.system(size: statSize, weight: .semibold).monospacedDigit()
    /// The same, for the single headline number on a dashboard.
    static let statLarge = Font.system(size: statLargeSize, weight: .bold).monospacedDigit()
}

// MARK: - Space

/// The spacing scale: a 4-point grid with one half-step at 2 and one at 6.
/// Padding, stack spacing, and insets all come from here.
enum Space {
    /// 2 — a title and the detail line beneath it.
    static let xxs: CGFloat = 2
    /// 4 — a glyph and its label.
    static let xs: CGFloat = 4
    /// 6 — pills in a row; a tight inline group.
    static let sm: CGFloat = 6
    /// 8 — controls in a bar; items in a stack.
    static let md: CGFloat = 8
    /// 12 — the default stack gap; the inset of a banner or compact row.
    static let lg: CGFloat = 12
    /// 16 — the inset of a row or a card body; the gap between cards.
    static let xl: CGFloat = 16
    /// 20 — the inset of a sheet or an inspector detail.
    static let xxl: CGFloat = 20
    /// 24 — the page inset; the gap between page sections.
    static let xxxl: CGFloat = 24
    /// 32 — breathing room around an empty state or a hero.
    static let huge: CGFloat = 32
}

// MARK: - Radius

/// Corner radii. Cards and anything card-sized use `lg`; controls and row
/// selection use `md`; small tiles use `sm`; sheets and the palette use `xl`.
enum Radius {
    /// 6 — chips, tiles under 24 points.
    static let sm: CGFloat = 6
    /// 8 — row selection, fields, inner controls.
    static let md: CGFloat = 8
    /// 12 — cards, panels, banners, search.
    static let lg: CGFloat = 12
    /// 16 — the command palette, hero cards.
    static let xl: CGFloat = 16
}

// MARK: - Size

/// Fixed dimensions: row and header heights, glyph and tile sizes, control
/// heights. A row on any screen is `rowHeight` tall; a status glyph beside a
/// row title is `glyph` wide.
enum Size {
    /// The standard row: a title with a detail line.
    static let rowHeight: CGFloat = 44
    /// A row with a third line, or a search field with its own chrome.
    static let rowHeightTall: CGFloat = 56
    /// A one-line row, or a row inside a compact card.
    static let compactRowHeight: CGFloat = 36
    /// The header strip over a pane or panel.
    static let headerHeight: CGFloat = 44
    /// The page toolbar's title strip.
    static let toolbarHeight: CGFloat = 58
    /// The header or footer bar of a sheet.
    static let sheetBarHeight: CGFloat = 72
    /// A text field or search field.
    static let controlHeight: CGFloat = 36
    /// A filter pill or a tag.
    static let pillHeight: CGFloat = 22
    /// A membership chip on a row.
    static let chipHeight: CGFloat = 18

    /// A status glyph next to a row title or badge text.
    static let glyph: CGFloat = 14
    /// A status glyph in a detail header or banner.
    static let glyphLarge: CGFloat = 16
    /// A small glyph inside a pill or a toolbar stamp.
    static let glyphSmall: CGFloat = 12
    /// The fixed-width slot a leading glyph sits in, so labels align.
    static let glyphSlot: CGFloat = 20
    /// A status dot.
    static let dot: CGFloat = 8

    /// The identity tile on a collection row.
    static let tile: CGFloat = 28
    /// The tile in a dense table row.
    static let tileSmall: CGFloat = 20
    /// The tile in a detail header.
    static let tileLarge: CGFloat = 40

    /// A client brand mark on a row.
    static let brandMark: CGFloat = 15
    /// A client disc on a row.
    static let disc: CGFloat = 30
    /// A client disc in a header or hero.
    static let discLarge: CGFloat = 34

    /// The hit target of a bare icon button (close, info).
    static let iconButton: CGFloat = 28
    /// The label column of a key/value row.
    static let labelColumn: CGFloat = 132
    /// A standalone symbol beside a sheet or wizard heading.
    static let symbol: CGFloat = 18
    /// The hero symbol in an empty state or a done screen.
    static let heroSymbol: CGFloat = 28
    /// The one large symbol on an introductory screen.
    static let heroSymbolLarge: CGFloat = 40
}

/// Sheets come in four sizes. A sheet picks the smallest it fits in; its
/// content scrolls rather than the sheet growing to fit.
enum SheetSize {
    /// A side pane shown in a popover.
    static let popover = CGSize(width: 340, height: 500)
    /// A short choice: a chooser, a single confirmation.
    static let small = CGSize(width: 520, height: 400)
    /// A form or a short review.
    static let medium = CGSize(width: 640, height: 520)
    /// A wizard step or a review with a list.
    static let large = CGSize(width: 720, height: 600)
    /// A review with a split pane.
    static let xlarge = CGSize(width: 860, height: 680)
    /// A full editor.
    static let editor = CGSize(width: 980, height: 720)
}

extension View {
    /// Pins a sheet to one of the four sizes.
    func sheetSize(_ size: CGSize) -> some View {
        frame(width: size.width, height: size.height)
    }
}

// MARK: - Fills and shadows

extension AgentTheme {
    /// The fill behind a quiet chip or tag.
    static let fillSubtle = Color.primary.opacity(0.05)
    /// The fill under the pointer.
    static let fillHover = Color.primary.opacity(0.06)
    /// A pressed or emphasised quiet fill.
    static let fillStrong = Color.primary.opacity(0.08)

    /// The shadow under a bar or card that floats over content.
    static let shadow = Color.black.opacity(0.12)
    /// The shadow under the command palette.
    static let shadowStrong = Color.black.opacity(0.30)
    /// The dimming scrim behind the palette.
    static let scrim = Color.black.opacity(0.22)

    /// The stroke around a card or control.
    static let hairlineStroke = separator.opacity(0.35)
}

// MARK: - Hairline

/// The one divider. Rows inside a card are separated by this and nothing
/// else; a bare `Divider()` belongs only in a menu, where the system draws it.
struct Hairline: View {
    /// Where the line starts. Zero spans the row; `afterLeading(_:)` starts it
    /// at the text column, so a row's leading tile stays joined to the row
    /// above instead of being boxed in.
    var indent: CGFloat = 0

    var body: some View {
        Divider().opacity(Hairline.opacity).padding(.leading, indent)
    }

    /// The text column of a row with the standard inset, a leading element
    /// `width` wide and the standard gap after it.
    static func afterLeading(_ width: CGFloat, gap: CGFloat = Space.lg) -> CGFloat {
        Space.xl + width + gap
    }

    /// The hairline's presence against the material it sits on.
    static let opacity: Double = 0.45
    /// The stroke width of a drawn border.
    static let width: CGFloat = 0.5
    /// The stroke of a selection ring around a card or disc.
    static let ring: CGFloat = 1.5
}

extension View {
    /// A hairline along the bottom edge: a row in a list that draws its own
    /// separators, a header strip.
    func hairlineBottom(_ shown: Bool = true) -> some View {
        overlay(alignment: .bottom) {
            if shown { Hairline() }
        }
    }

    /// A hairline along the trailing edge: a pane beside another pane.
    func hairlineTrailing() -> some View {
        overlay(alignment: .trailing) {
            Rectangle().fill(AgentTheme.separator.opacity(Hairline.opacity)).frame(width: Hairline.width)
        }
    }
}

// MARK: - Shapes

extension RoundedRectangle {
    /// The card shape.
    static var card: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.lg, style: .continuous) }
    /// The control shape: a field, a selection highlight.
    static var control: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.md, style: .continuous) }
    /// The palette and hero shape.
    static var panel: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.xl, style: .continuous) }
}

// MARK: - Buttons

extension View {
    /// The one primary action on a surface. Prominent, in the app's blue.
    func primaryActionStyle() -> some View {
        buttonStyle(.borderedProminent).tint(AgentTheme.selection)
    }

    /// A secondary action beside a primary one, or any action in a card.
    func secondaryActionStyle() -> some View {
        buttonStyle(.bordered)
    }

    /// An action that reads as a phrase in running text: Show file, Dismiss,
    /// See all. Never for the action a surface exists for.
    func inlineActionStyle() -> some View {
        buttonStyle(.borderless)
    }
}

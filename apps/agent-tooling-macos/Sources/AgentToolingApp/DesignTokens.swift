import SwiftUI

// The design tokens. Every view picks from these scales and only these; a raw
// number in a view is a bug, the way a raw hex colour would be. The scales are
// deliberately short so two screens drawing the same kind of thing can only
// land on the same value.
//
// What a token covers: anything a view is drawn with. Sizes and frames,
// padding and spacing, radii, strokes, opacity and saturation, shadows and
// offsets, kerning, the ratios a tile scales by, split proportions, column
// widths and the width a table changes layout at, and animation durations and
// scales.
//
// What stays a literal, because it is not a design value:
// - indices and offsets into a collection (`parts[0]`, `index + 1`);
// - counts and limits: how many to show (`prefix(3)`, `lineLimit(2)`), a
//   character or byte cap, a threshold or rank in logic, the 2 in "both
//   sides" (`Space.xl * 2`);
// - time that paces behaviour rather than motion: a debounce, a clipboard
//   timeout, a clock's tick;
// - data: picker tags, a setting's default;
// - 0 and 1 where they mean none and all: opacity 1 and 0, spacing, padding
//   and insets of 0, a scale of 1, grayscale 0 and 1, an angle of zero.
// Everything else comes from here. A value two screens share for the same
// job is one token; a value that only happens to be equal gets its own.
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

    /// The tracking an all-caps label takes, so its capitals don't crowd.
    static let capsKerning: CGFloat = 0.7
}

// MARK: - Space

/// The spacing scale: a 4-point grid with one half-step at 2 and one at 6, and
/// a one-point nudge. Padding, stack spacing, and insets all come from here.
enum Space {
    /// 1 — a nudge: a leading glyph lowered to sit level with the first line
    /// of the text beside it, or the vertical padding of a tag that must not
    /// make its row taller.
    static let nudge: CGFloat = 1
    /// 2 — a title and the detail line beneath it; the room a status glyph's
    /// frame adds to its symbol, and so to the indent of the line under it.
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
    /// The fixed-width slot a leading glyph sits in, or the number of a step
    /// in a wizard's step list, so the labels after it align.
    static let glyphSlot: CGFloat = 20
    /// A status dot.
    static let dot: CGFloat = 8

    /// The identity tile on a collection row.
    static let tile: CGFloat = 28
    /// The tile in a dense table row.
    static let tileSmall: CGFloat = 20
    /// The tile in a detail header.
    static let tileLarge: CGFloat = 40

    /// A menu picker at the trailing edge of a settings row, wide enough for
    /// its longest title so the column of pickers lines up.
    static let pickerWidth: CGFloat = 200
    /// A short text field (a branch name, a port).
    static let fieldNarrow: CGFloat = 160
    /// A medium field or menu picker: wider than a port, narrower than a URL.
    static let fieldMedium: CGFloat = 360
    /// A wide text field, a search box, or a compact confirmation popover; also
    /// the least width each Home dashboard column keeps before the two stack.
    static let fieldWide: CGFloat = 420
    /// A field or menu picker in a form or a detail pane (a preset's name, the
    /// project to follow, the item to share), the search box in the Projects
    /// filter bar, and a popover of text or a short list.
    static let fieldStandard: CGFloat = 320
    /// A short field or menu picker in a sheet's form: a skill's display name,
    /// the app to install into.
    static let fieldShort: CGFloat = 280
    /// A menu picker for one of a tool's arguments.
    static let fieldChoice: CGFloat = 240
    /// A text field that caps itself mid-width: a URL or path in an editing
    /// sheet, wider than a search box but kept off the sheet's edges.
    static let fieldCapped: CGFloat = 300
    /// A field holding a short upstream reference (a ref or tag).
    static let fieldRef: CGFloat = 220
    /// A field holding an upstream URL beside that ref.
    static let fieldLink: CGFloat = 340
    /// The least width a header search field keeps before it stops shrinking.
    static let searchFieldMin: CGFloat = 180
    /// The width that search field prefers.
    static let searchFieldIdeal: CGFloat = 300
    /// The width a search field in a sheet's header prefers (adding tools to a
    /// project), narrower than a page's.
    static let searchFieldSheetIdeal: CGFloat = 240
    /// The Skills search field in its wide filter bar, where it shares the row
    /// with the ownership picker.
    static let searchFieldCompact: CGFloat = 220
    /// A segmented picker for a scan option, wide enough for three choices.
    static let segmentedPickerMax: CGFloat = 330
    /// The longest a filter menu's label runs before it truncates (the Skills
    /// marketplace filter).
    static let filterMenuLabelMax: CGFloat = 220
    /// The longest an active filter token's label runs before it truncates.
    static let filterTokenLabelMax: CGFloat = 190
    /// The label column of a scan option row: its title and the line under it.
    static let optionLabelColumn: CGFloat = 180
    /// The managed-clients popover shown from the Apps toolbar.
    static let managedClientsPopover: CGFloat = 380
    /// A popover that explains one detail (the info button in a skill's
    /// details).
    static let infoPopover: CGFloat = 290
    /// A path's popover: the least width it keeps, and the most it takes
    /// before a long path wraps.
    static let pathPopoverMin: CGFloat = 220
    static let pathPopoverMax: CGFloat = 440
    /// A popover listing what a plugin includes is its chrome (title, caption
    /// and insets) and one row per item, up to `popoverListMaxHeight`, where
    /// the list starts to scroll.
    static let popoverListChrome: CGFloat = 90
    static let popoverListRow: CGFloat = 26
    static let popoverListMaxHeight: CGFloat = 320
    /// The least height an empty or loading state keeps so its symbol and text
    /// sit clear of the edges.
    static let emptyStateMinHeight: CGFloat = 200
    /// The height a full-page empty-state card fills (or, in a sheet with
    /// nothing else to show, keeps at least), so its symbol and text sit with
    /// room above and below rather than hugging the top.
    static let emptyStatePaneHeight: CGFloat = 220
    /// An empty state standing in for one panel's rows (an Insights panel) or
    /// for the Apps tile row.
    static let emptyStatePanelHeight: CGFloat = 180
    /// An empty state heading a stack of cards (app settings), short enough
    /// that the cards under it stay in view.
    static let emptyStateStackMinHeight: CGFloat = 160
    /// The least height a progress placeholder keeps in a sheet section while
    /// the content it stands for is worked out.
    static let progressPlaceholderMinHeight: CGFloat = 120
    /// The height a bounded scroll area inside a sheet or popover keeps before
    /// its own content scrolls, instead of growing the surface to fit.
    static let sheetScrollCap: CGFloat = 200
    /// A multi-line field of fixed height in a form (a skill's purpose).
    static let editorFieldHeight: CGFloat = 120
    /// The skill creator's message field: the least height it keeps, and the
    /// most it grows to before its text scrolls.
    static let composerMinHeight: CGFloat = 72
    static let composerMaxHeight: CGFloat = 140
    /// A workload's log output: the least height it keeps, and the most it
    /// grows to before it scrolls.
    static let logMinHeight: CGFloat = 110
    static let logMaxHeight: CGFloat = 240
    /// The form on the first-launch screen.
    static let firstLaunchFormWidth: CGFloat = 520
    /// The longest a centred or footer sentence runs before it wraps, so prose
    /// keeps a readable measure in a wide sheet.
    static let proseMaxWidth: CGFloat = 520
    /// The longest the ToolHive inspector's content runs; wider sheets centre
    /// it.
    static let inspectorContentMax: CGFloat = 620

    /// The least width the list column of a screen's main list/detail split
    /// keeps. Every equivalent split (Presets, Projects, Activity, MCP servers,
    /// Marketplace, Plugins, Skills) uses this one value so the columns line up
    /// screen to screen.
    static let listPaneMin: CGFloat = 320
    /// The least width the detail column of that same split keeps.
    static let detailPaneMin: CGFloat = 400
    /// The width a split prefers when the window has room: a near-even split.
    static let paneIdealWide: CGFloat = 600
    /// The least width the History tab's version list keeps. A narrower rail
    /// than the shared list column because it holds only stamps, not rows of
    /// detail.
    static let versionListMin: CGFloat = 260
    /// The width that version list prefers when the window has room.
    static let versionListIdeal: CGFloat = 300
    /// The least width the History tab's detail column keeps, narrower than the
    /// shared detail minimum because its content is a single version's note.
    static let versionDetailMin: CGFloat = 380
    /// The skill creator's chat column: its own split, not the shared list/detail
    /// one, so it keeps its own widths.
    static let creatorChatMin: CGFloat = 380
    static let creatorChatIdeal: CGFloat = 430
    static let creatorChatMax: CGFloat = 520
    /// The skill creator's draft-review column.
    static let creatorDraftMin: CGFloat = 440
    /// The list of generated files inside that column: the least it keeps,
    /// the width it prefers, and the most it takes.
    static let creatorFileListMin: CGFloat = 200
    static let creatorFileListIdeal: CGFloat = 230
    static let creatorFileListMax: CGFloat = 300
    /// The least width the preview of the chosen file keeps beside that list.
    static let creatorPreviewMin: CGFloat = 240
    /// The source editor's two panes side by side: the stored copy, and the
    /// edited one, which keeps more room because it is the one being typed in.
    static let storedSourcePaneMin: CGFloat = 360
    static let editedSourcePaneMin: CGFloat = 420
    /// The step list down the skill editor's leading edge.
    static let stepListWidth: CGFloat = 205
    /// The sidebar column: the least it keeps, the width it opens at, and the
    /// most it widens to.
    static let sidebarMin: CGFloat = 210
    static let sidebarIdeal: CGFloat = 230
    static let sidebarMax: CGFloat = 300

    /// A skill row in the narrow layout, which stacks its caption lines under
    /// the name: the name alone, with one caption line, with two.
    static let stackedRowHeight: CGFloat = 40
    static let stackedRowHeightOneCaption: CGFloat = 48
    static let stackedRowHeightTwoCaptions: CGFloat = 64
    /// The room a list leaves under its last row while the selection bar
    /// floats over it, so the bar covers no row.
    static let selectionBarClearance: CGFloat = 72

    /// A client brand mark on a row.
    static let brandMark: CGFloat = 15
    /// A client disc on a row.
    static let disc: CGFloat = 30
    /// A client disc in a header or hero.
    static let discLarge: CGFloat = 34
    /// How far a status dot hangs past the corner of the app tile it badges.
    static let badgeOverhang: CGFloat = 3

    /// A package or plugin's identity icon beside a page-title name: a detail
    /// header, or a Discover card at full size.
    static let identityIconLarge: CGFloat = 44
    /// That icon on a compact Discover card, beside an open details pane.
    static let identityIconCompact: CGFloat = 36
    /// A Discover card in the gallery grid: the least and the most width a
    /// column of cards takes.
    static let packageCardMinWidth: CGFloat = 360
    static let packageCardMaxWidth: CGFloat = 560
    /// The least height a Discover card keeps, so a row of cards lines up; and
    /// the same for the compact card beside an open details pane.
    static let packageCardMinHeight: CGFloat = 138
    static let packageCardMinHeightCompact: CGFloat = 116
    /// The room a Discover card keeps for a two-line summary even when the
    /// summary is shorter, so the tags under it line up from card to card.
    static let cardSummaryMinHeight: CGFloat = 38

    /// The hit target of a bare icon button (close, info).
    static let iconButton: CGFloat = 28
    /// The least width of a small action at a row's trailing edge (Show, or
    /// the Shown label that takes its place), so the two line up.
    static let rowActionMinWidth: CGFloat = 52
    /// The frame of an invisible view that only anchors a system picker (the
    /// share sheet): one point, so it takes no room.
    static let anchorPoint: CGFloat = 1
    /// The label column of a key/value row.
    static let labelColumn: CGFloat = 132
    /// The trailing "Found in" column on a skill table row and its header, wide
    /// enough for the client marks it holds.
    static let foundInColumn: CGFloat = 72
    /// A narrower, trailing-aligned label column for a sheet's detail rows,
    /// where the value column wants more room than `labelColumn` leaves.
    static let compactLabelColumn: CGFloat = 118
    /// The trailing-aligned column a step number sits in, so a list of steps
    /// keeps its numbers aligned down one edge.
    static let indexBadge: CGFloat = 24
    /// A standalone symbol beside a sheet or wizard heading.
    static let symbol: CGFloat = 18
    /// The hero symbol in an empty state or a done screen.
    static let heroSymbol: CGFloat = 28
    /// The one large symbol on an introductory screen.
    static let heroSymbolLarge: CGFloat = 40
}

/// Sheets come in a few fixed sizes. A sheet picks the smallest it fits in; its
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
    /// The skill creator: a chat column beside a draft-review pane, wider than
    /// the shared editor so both panes keep room.
    static let creator = CGSize(width: 1_000, height: 720)

    // The few that resize, from a minimum up, opening at their ideal size.

    /// The setup wizard.
    static let setupWizardMinimum = CGSize(width: 780, height: 560)
    static let setupWizardIdeal = CGSize(width: 860, height: 640)
    /// The ToolHive workload inspector.
    static let inspectorMinimum = CGSize(width: 640, height: 480)
    static let inspectorIdeal = CGSize(width: 720, height: 560)
    /// The least room the onboarding wizard needs. It fills the Skills screen
    /// rather than a sheet, so it has a minimum and no ideal.
    static let onboardingMinimum = CGSize(width: 720, height: 480)
}

/// The main window's sizes.
enum WindowSize {
    /// The least the main window shrinks to; every screen is laid out to fit
    /// it.
    static let minimum = CGSize(width: 1_180, height: 760)
    /// The size the main window opens at the first time.
    static let standard = CGSize(width: 1_440, height: 900)
    /// The width of the system Settings window's one form.
    static let settingsWidth: CGFloat = 360
}

extension View {
    /// Pins a sheet to one of the fixed sizes.
    func sheetSize(_ size: CGSize) -> some View {
        frame(width: size.width, height: size.height)
    }

    /// Lets a sheet resize from `minimum` up, opening at `ideal`.
    func sheetSize(minimum: CGSize, ideal: CGSize) -> some View {
        frame(minWidth: minimum.width, idealWidth: ideal.width, minHeight: minimum.height, idealHeight: ideal.height)
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
    /// The line between two rows. Drawn from `primary` so it reads as a
    /// faint lift in dark mode and a faint shadow in light, whatever material
    /// it crosses; the system separator darkens on a vibrant card.
    static let hairline = Color.primary.opacity(0.1)
}

/// A shadow under something that floats over content: the theme's shadow
/// colour with the blur and drop that go with it.
struct Elevation {
    let color: Color
    let radius: CGFloat
    let y: CGFloat

    /// A bar floating over a list (the selection bar).
    static let floatingBar = Elevation(color: AgentTheme.shadow, radius: 8, y: 3)
    /// The command palette over the dimmed window.
    static let palette = Elevation(color: AgentTheme.shadowStrong, radius: 28, y: 12)
}

extension View {
    /// Casts one of the shadows above.
    func elevation(_ elevation: Elevation) -> some View {
        shadow(color: elevation.color, radius: elevation.radius, y: elevation.y)
    }
}

// MARK: - Opacity

/// How strongly something is drawn. Pass these to `opacity(_:)` on a colour or
/// a view. Each names the job it does, so two screens doing the same job land
/// on the same strength. There are four families: a *wash* is a tint laid
/// under content drawn in the same tint; a *stroke* edges a wash; a *ground*
/// is a neutral surface at part strength; a *fade* is content drawn at less
/// than full strength.
enum Opacity {
    // Washes.

    /// 0.07 — a notice inset in a sheet's body (the plan review's notes): the
    /// faintest wash, so a column of them stays calm.
    static let noticeWash: Double = 0.07
    /// 0.10 — an attention banner, or a warning card.
    static let bannerWash: Double = 0.10
    /// 0.12 — a tag that names something: a category, an active filter, a
    /// property a tool declares; a state capsule in a sheet header; the ground
    /// of a symbol tile drawn in the accent.
    static let tagWash: Double = 0.12
    /// 0.14 — a badge that grades or states something: a health state, a
    /// tool's safety, a grade, a severity.
    static let badgeWash: Double = 0.14
    /// 0.14 — the accent under a row picked in a list that does not take the
    /// solid selection fill (a Discover source).
    static let selectedWash: Double = 0.14
    /// 0.18 — your own message in a conversation.
    static let messageWash: Double = 0.18

    // Strokes.

    /// 0.28 — the edge of a notice inset.
    static let noticeStroke: Double = 0.28
    /// 0.32 — the edge of an attention banner or warning card.
    static let bannerStroke: Double = 0.32
    /// 0.65 — the accent ring around the card that is open.
    static let selectedStroke: Double = 0.65

    // Grounds.

    /// 0.28 — the well of a multi-line text editor, on `.quaternary`.
    static let editorWell: Double = 0.28
    /// 0.35 — `controlBackground` under a header strip or a side column, a
    /// shade off the surface beside it.
    static let paneShade: Double = 0.35
    /// 0.6 — `controlBackground` (or `contentBackground` in a sheet) under an
    /// inset notice row or a group of options.
    static let insetGround: Double = 0.6

    // Fades.

    /// 0.18 — the steps of a step indicator not reached yet.
    static let track: Double = 0.18
    /// 0.3 — a control that cannot be used (a disabled checkbox).
    static let disabled: Double = 0.3
    /// 0.35 — the low beat of a live indicator's pulse.
    static let pulseLow: Double = 0.35
    /// 0.45 — a ghost tile: found on this Mac, not managed here.
    static let ghost: Double = 0.45
    /// 0.5 — the tile of a row with nothing in it yet (a project with no
    /// tools).
    static let inactive: Double = 0.5
    /// 0.55 — an option that cannot be chosen.
    static let unavailable: Double = 0.55
    /// 0.7 — a glyph or line a step quieter than its neighbours: the info
    /// severity, the tile of a project found but not yet tracked.
    static let quiet: Double = 0.7
    /// 0.75 — a supporting label beside the text it belongs to: the count in
    /// a selected pill, a palette row's context label.
    static let supporting: Double = 0.75
    /// 0.78 — secondary text on the accent fill of a selected row, and the
    /// empty ring of an app that does not have the item there, applied to
    /// `AgentTheme.onSelection`.
    static let secondaryOnSelection: Double = 0.78
    /// 0.85 — a label on a selected row that ranks between its title and its
    /// secondary text: a copies badge, the Managed column.
    static let labelOnSelection: Double = 0.85
}

/// How much colour a dimmed tile keeps.
enum Saturation {
    /// 0.35 — a ghost tile, with `Opacity.ghost`.
    static let ghost: Double = 0.35
}

// MARK: - Proportions

/// Ratios a view scales by: a tile or disc keeps its shape at every size, and
/// a split divides its ideal width. Multiply the size or width by these.
enum Proportion {
    /// 0.28 — a kind or symbol tile's corner radius (never under `Radius.sm`).
    static let tileCorner: CGFloat = 0.28
    /// 0.5 — the symbol inside a kind tile, and an identity icon's fallback
    /// symbol.
    static let tileSymbol: CGFloat = 0.5
    /// 0.46 — the symbol inside a symbol tile.
    static let symbolTileSymbol: CGFloat = 0.46
    /// 0.23 — an identity icon's corner radius: the app-icon curve.
    static let iconCorner: CGFloat = 0.23
    /// 0.53 — the brand mark inside a client disc.
    static let discMark: CGFloat = 0.53
    /// 0.32 — how far each disc in a placement stack tucks under the one
    /// before it.
    static let discOverlap: CGFloat = 0.32

    /// 0.55 and 0.45 — the list's and the detail's shares of a list/detail
    /// split's ideal width.
    static let listShare: CGFloat = 0.55
    static let detailShare: CGFloat = 0.45
    /// 0.5 — an even split (the Skills browser).
    static let evenShare: CGFloat = 0.5
}

// MARK: - Collection columns

/// The columns of the three collection tables laid out by hand (Skills,
/// Plugins, Connections). Each table shows its wide layout from its own
/// `expandedFrom` width up, and its narrow layout below it. A name column takes
/// its share of the table's width up to a ceiling in the wide layout, and what
/// the other columns leave, down to a floor, in the narrow one; the other
/// columns are fixed. Widths the tables share live at the top.
enum CollectionColumn {
    /// Four client brand marks and the gaps between them: the App and Managed
    /// by columns.
    static let clientMarks: CGFloat = Size.brandMark * 4 + Space.sm * 3 + Space.sm
    /// A source label.
    static let source: CGFloat = 150
    /// A count or a single status glyph: a plugin's skills, a connection's
    /// status.
    static let narrow: CGFloat = 50
    /// The ceiling of a name column with a description column beside it
    /// (Plugins, Skills).
    static let nameMax: CGFloat = 300

    /// The Connections table. Its wide layout adds Managed by, Plugin, Source,
    /// Asked for, Tools and Status.
    enum Connections {
        static let expandedFrom: CGFloat = 1_050
        static let nameMin: CGFloat = 150
        static let nameMax: CGFloat = 240
        static let nameShare: CGFloat = 0.22
        /// Managed by.
        static let ownership: CGFloat = 165
        /// Plugin.
        static let plugin: CGFloat = 170
        /// Asked for.
        static let requested: CGFloat = 75
        /// Tools.
        static let tools: CGFloat = 100
    }

    /// The Plugins table. Its wide layout adds Description, Source, Skills and
    /// Updates.
    enum Plugins {
        static let expandedFrom: CGFloat = 820
        static let nameMin: CGFloat = 160
        static let nameShare: CGFloat = 0.28
        /// Updates.
        static let updates: CGFloat = 130
    }

    /// The Skills table. Its wide layout adds the description, Plugin and
    /// Marketplace columns.
    enum Skills {
        static let expandedFrom: CGFloat = 940
        /// The narrow layout's name column takes what is left after
        /// `compactReserve` (the Found in marks, the row's insets and its
        /// gaps), the Managed column and any checkbox, down to `nameMin`.
        static let nameMin: CGFloat = 140
        static let compactReserve: CGFloat = 144
        static let nameShare: CGFloat = 0.24
        /// The name column when no skill on the list has a description, so the
        /// name takes that column's room back.
        static let nameMaxUndescribed: CGFloat = 520
        static let nameShareUndescribed: CGFloat = 0.42
        /// The Managed column, in the wide and in the narrow layout.
        static let verdict: CGFloat = 104
        static let verdictCompact: CGFloat = 96
        /// Plugin and Marketplace: a share of the width, up to a ceiling.
        static let pluginMax: CGFloat = 200
        static let pluginShare: CGFloat = 0.17
        static let marketplaceMax: CGFloat = 180
        static let marketplaceShare: CGFloat = 0.15
    }
}

/// What a native `List` puts between its edge and each row's content on its
/// own, past the insets the row asks for: it lays its one column out 17 points
/// narrower than the list, 8 in from the leading edge and 9 from the trailing.
/// The system picks these, not this app. A row that has to line up with
/// something outside its list, such as the column titles over a table, gives
/// them back (`collectionTableRowChrome(selected:)`); `CollectionTableRowTests`
/// fails if a macOS release moves them.
enum ListCellMargin {
    static let leading: CGFloat = 8
    static let trailing: CGFloat = 9
}

// MARK: - Hairline

/// The one divider. Rows inside a card are separated by this and nothing
/// else; a bare `Divider()` belongs only in a menu, where the system draws it.
struct Hairline: View {
    /// Where the line starts. Zero spans the row; `afterLeading(_:)` starts it
    /// at the text column, so a row's leading tile stays joined to the row
    /// above instead of being boxed in.
    var indent: CGFloat = 0
    /// Horizontal between rows; vertical between the cells of one row.
    var axis: Axis = .horizontal

    init(indent: CGFloat = 0, axis: Axis = .horizontal) {
        self.indent = indent
        self.axis = axis
    }

    init(_ axis: Axis) {
        self.init(indent: 0, axis: axis)
    }

    var body: some View {
        // Not a `Divider`: on a material its system colour blends darker than
        // the surface, which is the opposite of what a separator should do.
        switch axis {
        case .horizontal:
            Rectangle()
                .fill(AgentTheme.hairline)
                .frame(height: Hairline.width)
                .padding(.leading, indent)
        case .vertical:
            Rectangle()
                .fill(AgentTheme.hairline)
                .frame(width: Hairline.width)
        }
    }

    /// The text column of a row with the standard inset, a leading element
    /// `width` wide and the standard gap after it.
    static func afterLeading(_ width: CGFloat, gap: CGFloat = Space.lg) -> CGFloat {
        Space.xl + width + gap
    }

    /// The stroke width of a drawn border and of the line itself.
    static let width: CGFloat = 1
    /// The stroke of a selection ring around a card or disc.
    static let ring: CGFloat = 1.5
    /// The resting border of a Discover card: half the hairline, so a grid of
    /// cards on material stays quiet until one is opened.
    static let fine: CGFloat = 0.5
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
            Rectangle().fill(AgentTheme.hairline).frame(width: Hairline.width)
        }
    }
}

// MARK: - Absent marks

/// What a row of client marks shows for an app that does not have the item: a
/// small empty ring in the slot the app's brand mark would fill. A filled mark
/// beside an empty ring is a difference of shape, so it reads without colour,
/// and the ring is drawn in `AgentTheme.absentMark`, which keeps at least 3:1
/// against a card in both appearances. On a selected row the ground is the
/// accent fill, where that grey all but vanishes, so the ring takes the row's
/// secondary foreground instead (`AgentTheme.onSelection` at
/// `Opacity.secondaryOnSelection`), which keeps 3:1 on the fill. The ring sits
/// inside the slot rather than filling it, so it reads as an empty place and
/// not as the unchecked selection checkbox. Use it in place of the brand mark
/// rather than dimming the mark, and keep the row's accessibility label naming
/// the apps that have the item.
struct AbsentMark: View {
    var size: CGFloat = Size.brandMark
    /// Whether the row it sits on is selected, and so drawn on the accent fill.
    var selected = false

    var body: some View {
        Circle()
            .strokeBorder(
                selected ? AgentTheme.onSelection.opacity(Opacity.secondaryOnSelection) : AgentTheme.absentMark,
                lineWidth: Hairline.width
            )
            .padding(Space.xxs)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Wrapping text

extension View {
    /// Lets a line of text grow downward as it wraps instead of truncating.
    ///
    /// This is what `fixedSize(horizontal: false, vertical: true)` is for, and
    /// it must be used instead of it. When a view appears after the window has
    /// laid out — a banner arriving with a result — AppKit re-measures the
    /// window's content at a zero-width proposal to learn its minimum size. A
    /// vertically fixed text answers that probe by wrapping every word onto
    /// its own line, several hundred points tall, and that becomes the
    /// window's minimum: the whole split view grows past the window and is
    /// centred in it, so everything shifts up out of frame. This layout only
    /// frees the height once it has a real width to wrap in.
    func wrapsLines() -> some View {
        WrappingTextLayout { self }
    }
}

struct WrappingTextLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        if let width = proposal.width, width > 0 {
            return view.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
        // The minimum (zero) and ideal (nil) probes: answer as plain text
        // would, one line, rather than as a column of single words.
        return view.sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil))
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

extension Angle {
    /// A disclosure chevron turned from pointing at its title to pointing down
    /// at the content it opened.
    static let disclosureOpen = Angle.degrees(90)
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

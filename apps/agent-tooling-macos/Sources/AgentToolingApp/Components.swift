import AgentToolingCore
import AppKit
import SwiftUI

// MARK: - Identity

/// The object vocabulary. A tile says what a thing is; the three brand marks
/// say where it runs; a status glyph beside a label says how it is doing.
enum ToolingKind {
    case skill, plugin, mcpServer, profile, collection, library, activity, source, connection, account, settings

    /// The one mapping from a library record's kind to how it is drawn.
    /// Presets draw as collections everywhere, matching their own screen.
    init(_ kind: ArtifactKind) {
        self =
            switch kind {
            case .skill: .skill
            case .mcpServer: .mcpServer
            case .package, .nativePlugin: .plugin
            case .preset: .collection
            case .logicalProject: .library
            }
    }

    var color: Color {
        switch self {
        case .skill: AgentTheme.skill
        case .plugin: AgentTheme.plugin
        case .mcpServer: AgentTheme.mcpServer
        case .profile: AgentTheme.profile
        case .collection: AgentTheme.collection
        case .library, .activity, .source, .connection, .account, .settings: AgentTheme.graphite
        }
    }

    var symbol: String {
        switch self {
        case .skill: "doc.text"
        case .plugin: "puzzlepiece.extension"
        case .mcpServer: "server.rack"
        case .profile: "slider.horizontal.3"
        // A stack, never a slider: a collection must not read as a
        // configuration at a glance, since the two sit in the same sidebar
        // group and confusing them is the documented failure mode.
        case .collection: "square.stack.3d.up"
        case .library: "books.vertical"
        case .activity: "clock.arrow.circlepath"
        case .source: "shippingbox"
        case .connection: "link"
        case .account: "person.crop.circle"
        case .settings: "gearshape"
        }
    }
}

extension AgentTheme {
    static let collection = graphite
}

struct KindTile: View {
    let kind: ToolingKind
    var size: CGFloat = Size.tile
    /// Discovered on this Mac but not managed by Agent Tooling: the same tile
    /// at reduced presence, so long lists of vendor items stay quiet.
    var ghost = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(Radius.sm, size * Proportion.tileCorner), style: .continuous)
                .fill(kind.color.gradient)
            Image(systemName: kind.symbol)
                .font(.system(size: size * Proportion.tileSymbol, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .opacity(ghost ? Opacity.ghost : 1)
        .saturation(ghost ? Saturation.ghost : 1)
        .accessibilityHidden(true)
    }
}

/// A neutral graphite tile for objects outside the four identity kinds.
struct SymbolTile: View {
    let symbol: String
    var size: CGFloat = Size.discLarge

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(Radius.sm, size * Proportion.tileCorner), style: .continuous)
                .fill(AgentTheme.graphite.gradient)
            Image(systemName: symbol)
                .font(.system(size: size * Proportion.symbolTileSymbol, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Clients

/// A slot for every client, always in the same order: its brand mark where it
/// has the item, an empty ring (`AbsentMark`) where it does not.
struct ClientMarks: View {
    let present: Set<ClientKind>
    var size: CGFloat = Size.brandMark
    /// Whether the row is selected, so the empty rings stand off the accent
    /// fill rather than the card.
    var selected = false
    /// The shell publishes the clients this Mac actually offers, so a row never
    /// has to know how that set was decided. With nothing published the marks
    /// fall back to every known client, which is what a single row rendered on
    /// its own in a preview or a test should show.
    @Environment(\.availableClients) private var order

    var body: some View {
        HStack(spacing: Space.sm) {
            ForEach(order) { client in
                if present.contains(client) {
                    ClientBrandIcon(client: client, size: size).help(client.rawValue)
                } else {
                    AbsentMark(size: size, selected: selected).help("Not in \(client.rawValue)")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            present.isEmpty
                ? "Not installed in any client"
                : "Installed in \(order.filter(present.contains).map(\.rawValue).joined(separator: ", "))")
    }
}

/// The apps this library has placed something in, as overlapping discs: one
/// glance says "yours, and in these". Order follows the shell's client order
/// so the same apps stack the same way on every row.
struct PlacementStack: View {
    let placed: Set<ClientKind>
    var size: CGFloat = Size.tileSmall
    @Environment(\.availableClients) private var order

    private var ordered: [ClientKind] { order.filter(placed.contains) }

    var body: some View {
        HStack(spacing: -(size * Proportion.discOverlap)) {
            ForEach(ordered) { client in
                ClientDisc(client: client, size: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ordered.isEmpty
                ? "Not placed anywhere"
                : "Yours. Placed by this app in \(ordered.map(\.rawValue).joined(separator: ", "))")
    }
}

struct ClientDisc: View {
    let client: ClientKind
    var size: CGFloat = Size.discLarge
    var bordered = true

    var body: some View {
        ZStack {
            if bordered {
                Circle().fill(AgentTheme.controlBackground)
                Circle().strokeBorder(AgentTheme.hairlineStroke, lineWidth: Hairline.width)
            }
            ClientBrandIcon(client: client, size: size * Proportion.discMark)
        }
        .frame(width: size, height: size)
    }
}

/// Accent selection for `List` rows, matching `rowSelection` on custom rows.
struct SelectionRowBackground: View {
    let selected: Bool

    var body: some View {
        if selected {
            RoundedRectangle.control
                .fill(AgentTheme.selection)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xxs)
        } else {
            Color.clear
        }
    }
}

// MARK: - Status

struct StatusGlyph: View {
    let state: HealthState
    var size: CGFloat = Size.glyph
    /// Selected rows draw the glyph in white so it stays legible on the accent fill.
    var tint: Color?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(tint ?? color)
            // A hairline indented past a glyph (Home's rows) adds the same
            // `Space.xxs` to the glyph's size, so the two stay in step.
            .frame(width: size + Space.xxs, height: size + Space.xxs)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .healthy: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .pending: "clock"
        case .unavailable: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .healthy: AgentTheme.ok
        case .attention: AgentTheme.warning
        case .pending: .secondary
        case .unavailable: AgentTheme.failure
        }
    }
}

struct StatusBadge: View {
    let state: HealthState
    let text: String
    var tint: Color?

    var body: some View {
        HStack(spacing: Space.xs) {
            StatusGlyph(state: state, size: Size.glyphSmall, tint: tint)
            Text(text)
                .lineLimit(1)
        }
        .font(AgentFont.captionMedium)
        .foregroundStyle(tint ?? Color.secondary)
        .accessibilityElement(children: .combine)
    }
}

struct AttentionBanner<Action: View>: View {
    let title: String
    let message: String
    @ViewBuilder let action: Action
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, message: String, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        HStack(spacing: Space.lg) {
            StatusGlyph(state: .attention, size: Size.glyphLarge)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(AgentFont.bodySemibold)
                Text(message).font(AgentFont.caption).foregroundStyle(.secondary).wrapsLines()
            }
            Spacer(minLength: Space.lg)
            action
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
        .background(AgentTheme.warning.opacity(Opacity.bannerWash), in: RoundedRectangle.card)
        // Banners come and go with state; arriving with a transition keeps the
        // content below from teleporting by a banner's height. Under Reduce
        // Motion it only fades.
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        .overlay {
            RoundedRectangle.card
                .strokeBorder(AgentTheme.warning.opacity(Opacity.bannerStroke), lineWidth: Hairline.width)
        }
    }
}

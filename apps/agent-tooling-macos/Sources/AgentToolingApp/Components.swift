import AgentToolingCore
import AppKit
import SwiftUI

// MARK: - Identity

/// The object vocabulary. A tile says what a thing is; the three brand marks
/// say where it runs; a status glyph beside a label says how it is doing.
enum ToolingKind {
    case skill, plugin, mcpServer, profile, collection, library, activity, source, connection, account, settings

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

extension ToolingKind {
    init(_ kind: ToolingItemKind) {
        switch kind {
        case .skill: self = .skill
        case .plugin: self = .plugin
        case .mcpServer: self = .mcpServer
        }
    }
}

extension AgentTheme {
    static let collection = graphite
}

struct KindTile: View {
    let kind: ToolingKind
    var size: CGFloat = 28
    /// Discovered on this Mac but not managed by Agent Tooling: the same tile
    /// at reduced presence, so long lists of vendor items stay quiet.
    var ghost = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(6, size * 0.28), style: .continuous)
                .fill(kind.color.gradient)
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .opacity(ghost ? 0.45 : 1)
        .saturation(ghost ? 0.35 : 1)
        .accessibilityHidden(true)
    }
}

/// A neutral graphite tile for objects outside the four identity kinds.
struct SymbolTile: View {
    let symbol: String
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(6, size * 0.28), style: .continuous)
                .fill(AgentTheme.graphite.gradient)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Clients

/// All three marks, always in the same order; absent clients are dimmed.
struct ClientMarks: View {
    let present: Set<ClientKind>
    var size: CGFloat = 15
    /// The shell publishes the clients this Mac actually offers, so a row never
    /// has to know how that set was decided. With nothing published the marks
    /// fall back to every known client, which is what a single row rendered on
    /// its own in a preview or a test should show.
    @Environment(\.availableClients) private var order

    var body: some View {
        HStack(spacing: 7) {
            ForEach(order) { client in
                ClientBrandIcon(client: client, size: size)
                    .opacity(present.contains(client) ? 1 : 0.22)
                    .grayscale(present.contains(client) ? 0 : 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            present.isEmpty
                ? "Not installed in any client"
                : "Installed in \(order.filter(present.contains).map(\.rawValue).joined(separator: ", "))")
    }
}

struct ClientDisc: View {
    let client: ClientKind
    var size: CGFloat = 34
    var bordered = true

    var body: some View {
        ZStack {
            if bordered {
                Circle().fill(AgentTheme.controlBackground)
                Circle().strokeBorder(AgentTheme.separator.opacity(0.5), lineWidth: 0.5)
            }
            ClientBrandIcon(client: client, size: size * 0.53)
        }
        .frame(width: size, height: size)
    }
}

/// Accent selection for `List` rows, matching `rowSelection` on custom rows.
struct SelectionRowBackground: View {
    let selected: Bool

    var body: some View {
        if selected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AgentTheme.selection)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
        } else {
            Color.clear
        }
    }
}

// MARK: - Status

struct StatusGlyph: View {
    let state: HealthState
    var size: CGFloat = 14
    /// Selected rows draw the glyph in white so it stays legible on the accent fill.
    var tint: Color?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(tint ?? color)
            .frame(width: size + 2, height: size + 2)
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
        HStack(spacing: 5) {
            StatusGlyph(state: state, size: 13, tint: tint)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint ?? Color.secondary)
        .accessibilityElement(children: .combine)
    }
}

struct AttentionBanner<Action: View>: View {
    let title: String
    let message: String
    @ViewBuilder let action: Action

    init(title: String, message: String, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusGlyph(state: .attention, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AgentTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Banners come and go with state; arriving with a transition keeps the
        // content below from teleporting by a banner's height.
        .transition(.move(edge: .top).combined(with: .opacity))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AgentTheme.warning.opacity(0.32), lineWidth: 0.5)
        }
    }
}


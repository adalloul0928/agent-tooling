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
        Image(systemName: kind.symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.64, weight: .regular))
            .foregroundStyle(kind.color)
            .frame(width: size, height: size)
            .opacity(ghost ? 0.7 : 1)
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
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(AgentTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AgentTheme.warning.opacity(0.32), lineWidth: 0.5)
        }
    }
}

// MARK: - Toolbar and cards

/// The heading every screen shares: what you are looking at, one line of
/// context, and the actions for it.
struct PageToolbar<Actions: View>: View {
    let title: String
    let context: String?
    @ViewBuilder let actions: Actions

    init(title: String, context: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.context = context
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                    if let context {
                        Text(context)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        actions
                    }
                }
                .tint(nil as Color?)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
            .padding(.horizontal, WorkspaceLayout.pageInset)
            .padding(.vertical, 10)
            .frame(minHeight: 58)

        }
    }
}

extension EnvironmentValues {
}

/// One search field treatment across the library. Native text editing and
/// accessibility are retained, including an explicit clear action.
struct InventorySearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Clear \(placeholder.lowercased())")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(AgentTheme.controlBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AgentTheme.separator.opacity(0.4), lineWidth: 0.5))
    }
}

struct WorkspaceSegmentedPicker<Value: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Value
    @ViewBuilder let content: Content

    init(_ title: String, selection: Binding<Value>, @ViewBuilder content: () -> Content) {
        self.title = title
        _selection = selection
        self.content = content()
    }

    var body: some View {
        Picker(title, selection: $selection) { content }
            .pickerStyle(.segmented)
            .labelsHidden()
            .font(.system(size: 13))
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
            .tint(nil as Color?)
            .accessibilityLabel(title)
    }
}

extension View {
    /// Filter and sorting menus share the system's neutral pop-up treatment.
    func inventoryMenuStyle() -> some View {
        menuStyle(.borderedButton)
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
            .tint(nil as Color?)
            .foregroundStyle(.primary)
    }
}

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

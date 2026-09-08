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
    /// Collections get their own hue in the identity palette. Configurations
    /// are indigo; a green-teal keeps the shelf visually separate from the
    /// contract it feeds.
    static let collection = Color(
        nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? 0x3FC79A : 0x139E77)
        })
}

struct KindTile: View {
    let kind: ToolingKind
    var size: CGFloat = 28
    /// Discovered on this Mac but not managed by Agent Tooling: the same tile
    /// at reduced presence, so long lists of vendor items stay quiet.
    var ghost = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(kind.color.gradient)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .opacity(ghost ? 0.5 : 1)
        .accessibilityHidden(true)
    }

    private var radius: CGFloat { max(6, size * 0.28) }
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
    @Environment(AppModel.self) private var model
    private var order: [ClientKind] { model.availableClients }

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
                .fill(AgentTheme.blue)
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
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if let context {
                    Text(context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                actions
            }
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }
}

struct SlidingSegmentedControl<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let title: String

        var id: Value { value }
    }

    @Binding var selection: Value
    let items: [Item]
    let accessibilityLabel: String
    var segmentWidth: CGFloat? = 112

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace
    @ScaledMetric(relativeTo: .callout) private var segmentHeight: CGFloat = 28
    @ScaledMetric(relativeTo: .callout) private var segmentScale: CGFloat = 1

    var body: some View {
        let minimumWidth = segmentWidth.map { $0 * segmentScale }

        HStack(spacing: 2) {
            ForEach(items) { item in
                let isSelected = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                        .frame(minWidth: minimumWidth, minHeight: segmentHeight)
                        .frame(maxWidth: segmentWidth == nil ? .infinity : nil)
                        .fixedSize(horizontal: segmentWidth != nil, vertical: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(AgentTheme.blue)
                            .matchedGeometryEffect(id: "sliding-segment-selection", in: selectionNamespace)
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                    }
                }
                .accessibilityLabel(item.title)
                .accessibilityValue(isSelected ? "Selected" : "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.075))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AgentTheme.separator.opacity(0.45), lineWidth: 0.5)
        }
        .animation(reduceMotion ? nil : AgentMotion.selection, value: selection)
        .onMoveCommand { direction in
            switch direction {
            case .left: moveSelection(by: -1)
            case .right: moveSelection(by: 1)
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func moveSelection(by offset: Int) {
        guard let index = items.firstIndex(where: { $0.value == selection }), !items.isEmpty else { return }
        selection = items[(index + offset + items.count) % items.count].value
    }
}

struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            trailing
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Divider().opacity(0.3) }
    }
}

/// Title above, card below. Cards are only ever a list of rows.
struct TitledCard<Trailing: View, Content: View>: View {
    private let title: String
    private let count: String?
    private let trailing: Trailing
    private let content: Content

    init(_ title: String, count: String? = nil, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.count = count
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(title).font(.subheadline.weight(.semibold))
                if let count {
                    Text(count).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                trailing
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 2)
            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .standardPanel()
        }
    }
}

extension TitledCard where Trailing == EmptyView {
    init(_ title: String, count: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, count: count, trailing: { EmptyView() }, content: content)
    }
}

/// The row grammar: a leading tile or glyph, a name, one clause, a verdict.
struct InfoRow<Leading: View, Trailing: View>: View {
    let title: String
    let detail: String?
    let leading: Leading
    let trailing: Trailing

    init(_ title: String, detail: String? = nil, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 11) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

extension InfoRow where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil, @ViewBuilder leading: () -> Leading) {
        self.init(title, detail: detail, leading: leading, trailing: { EmptyView() })
    }
}

struct TagCloud: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Color.primary.opacity(0.055), in: Capsule())
            }
        }
    }
}

// MARK: - Collections and tags

/// Membership pills for an inventory row, so a person can see which shelves an
/// item sits on without opening every collection.
///
/// Overlap is normal: one skill can belong to three collections, and the row
/// says so rather than pretending there is a single owner.
struct CollectionPills: View {
    let names: [String]
    var selected = false
    var limit = 2

    var body: some View {
        if !names.isEmpty {
            HStack(spacing: 5) {
                ForEach(names.prefix(limit), id: \.self) { name in
                    Label(name, systemImage: ToolingKind.collection.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.medium))
                        .imageScale(.small)
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.white : AgentTheme.collection)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(
                            Capsule().fill(selected ? Color.white.opacity(0.22) : AgentTheme.collection.opacity(0.13))
                        )
                }
                if names.count > limit {
                    Text("+\(names.count - limit)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("In collections \(names.formatted(.list(type: .and)))")
        }
    }
}

/// Tag pills. Deliberately quieter than a collection pill, because a tag
/// filters and a collection applies; the row must not suggest otherwise.
struct TagPills: View {
    let tags: [String]
    var selected = false
    var limit = 3

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 5) {
                ForEach(tags.prefix(limit), id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(
                            Capsule().fill(selected ? Color.white.opacity(0.16) : Color.primary.opacity(0.06))
                        )
                }
                if tags.count > limit {
                    Text("+\(tags.count - limit)")
                        .font(.caption2)
                        .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tagged \(tags.formatted(.list(type: .and)))")
        }
    }
}

/// One filter pill. Kept separate so the Untagged pill is the same object as
/// every other pill rather than a special case bolted on the end.
struct FilterPill: View {
    let title: String
    var count: Int?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                if let count {
                    Text(count, format: .number)
                        .foregroundStyle(isOn ? Color.white.opacity(0.75) : Color.secondary)
                        .monospacedDigit()
                }
            }
            .font(.caption.weight(isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(
                Capsule().fill(isOn ? AgentTheme.blue : Color.primary.opacity(0.06))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// Tags filter; they never change what is installed. `Untagged` always
/// appears, so the unsorted pile stays one click away instead of being the
/// one thing a tag list cannot express.
struct TagFilterBar: View {
    let tags: [String]
    var untaggedCount: Int?
    @Binding var selection: Set<String>
    @Binding var untaggedOnly: Bool

    var body: some View {
        FlowLayout(spacing: 6) {
            FilterPill(title: "Untagged", count: untaggedCount, isOn: untaggedOnly) {
                untaggedOnly.toggle()
                if untaggedOnly { selection.removeAll() }
            }
            ForEach(tags, id: \.self) { tag in
                FilterPill(title: tag, isOn: selection.contains(tag)) {
                    if selection.contains(tag) { selection.remove(tag) } else { selection.insert(tag) }
                    if !selection.isEmpty { untaggedOnly = false }
                }
            }
            if !selection.isEmpty || untaggedOnly {
                Button("Clear") {
                    selection.removeAll()
                    untaggedOnly = false
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(AgentTheme.blue)
                .padding(.horizontal, 6)
                .frame(height: 22)
            }
        }
        .accessibilityLabel("Filter by tag")
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var isActionEnabled = true
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isActionEnabled)
            }
        }
        // Panes lay their content out from the top edge, so an empty state has
        // to claim the remaining space itself to sit in the middle of the pane.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Bulk selection

/// The mark that says a row is picked. It sits inside the row rather than in a
/// gutter, so turning selection on does not reflow the list.
struct SelectionCheckbox: View {
    let selected: Bool
    var enabled = true

    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 15))
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    private var tint: Color {
        if selected { return .white }
        return enabled ? Color.secondary : Color.secondary.opacity(0.3)
    }
}

/// The bar a collection floats over its list while rows are picked: how many,
/// the one action they were picked for, and the way back out. It never replaces
/// the page toolbar, so the page's own actions stay where they were.
struct SelectionActionBar: View {
    let count: Int
    let actionTitle: String
    var isActionEnabled = true
    let action: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Text("\(count) selected")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Clear", action: clear)
                .buttonStyle(.bordered)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(!isActionEnabled)
                .lineLimit(1)
        }
        .buttonBorderShape(.capsule)
        .padding(.horizontal, 13)
        .frame(height: 48)
        .standardPanel()
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(count) selected")
    }
}

/// Key on the left at a fixed width, value on the left of its own column.
struct LabeledValueRow<Trailing: View>: View {
    let label: String
    @ViewBuilder let trailing: Trailing

    init(_ label: String, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)
            trailing
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Commands stay behind a disclosure: explicit when opened, never the
/// dominant visual.
struct CommandDisclosure: View {
    let title: String
    let command: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            HStack {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 10)
        } label: {
            Text(title)
                .font(.callout)
        }
        .padding(13)
        .standardPanel()
    }
}

struct ClientStatusRows: View {
    let clients: [ClientState]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(clients.enumerated()), id: \.offset) { index, client in
                HStack(spacing: 11) {
                    ClientDisc(client: client.client, size: 30)
                    Text(client.client.rawValue)
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 20)
                    StatusBadge(state: client.state, text: client.detailWithRevision)
                }
                .padding(.horizontal, 13)
                .frame(minHeight: 46)
                if index < clients.count - 1 { Divider().opacity(0.45) }
            }
        }
    }
}

struct SectionCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Installation map

struct ToolingMatrixRow: Identifiable {
    let id: AppSection
    let title: String
    let symbol: String
    let libraryCount: Int
    let installedCounts: [ClientKind: Int]
    var kind: ToolingKind?
}

/// One honest comparison between the managed inventory and the local state
/// each client reported during the last check.
struct ToolingMatrixView: View {
    let rows: [ToolingMatrixRow]
    let clients: [ClientKind]
    var onSelect: ((AppSection) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Installation map")

            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("Tool")
                        .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                    columnHeader("Library", symbol: "books.vertical")
                    ForEach(clients) { client in
                        clientHeader(client)
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(minHeight: 38)

                Divider().opacity(0.35)

                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    GridRow {
                        Button {
                            onSelect?(row.id)
                        } label: {
                            HStack(spacing: 9) {
                                if let kind = row.kind {
                                    KindTile(kind: kind, size: 22)
                                } else {
                                    Image(systemName: row.symbol).foregroundStyle(.secondary)
                                }
                                Text(row.title)
                                    .font(.callout.weight(.medium))
                            }
                            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(onSelect == nil)
                        .accessibilityHint(onSelect == nil ? "" : "Opens \(row.title)")

                        countCell(row.libraryCount)
                        ForEach(clients) { client in
                            countCell(row.installedCounts[client, default: 0])
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)

                    if index < rows.count - 1 { Divider().opacity(0.28) }
                }
            }

            Divider().opacity(0.35)
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        }
        .standardPanel()
    }

    private func countCell(_ count: Int) -> some View {
        Text(count, format: .number)
            .font(.callout.monospacedDigit())
            .foregroundStyle(count == 0 ? .tertiary : .primary)
            .frame(minWidth: 92, maxWidth: .infinity, alignment: .center)
    }

    private func columnHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .frame(minWidth: 92, maxWidth: .infinity, alignment: .center)
    }

    private func clientHeader(_ client: ClientKind) -> some View {
        HStack(spacing: 6) {
            ClientBrandIcon(client: client, size: 14)
            Text(shortName(client))
        }
        .frame(minWidth: 92, maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(client.rawValue)
    }

    private func shortName(_ client: ClientKind) -> String {
        switch client {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }

    private var footerText: String {
        if clients.count == 1, let client = clients.first {
            return
                "Library shows items associated with \(client.rawValue). The app column shows local installations found during the last check."
        }
        return "Library shows known items. App columns show local installations found during the last check."
    }
}

// MARK: - Locations

/// Paths never sit in a row. A short name identifies the place; the ⓘ opens a
/// popover with the full location and a Reveal in Finder link.
struct LocationText: View {
    let path: String
    var label: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(label ?? LocationText.shortName(for: path))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            PathInfoButton(path: path)
        }
    }

    static func shortName(for path: String) -> String {
        if let components = URLComponents(string: path),
            let scheme = components.scheme,
            let host = components.host,
            !scheme.isEmpty,
            !host.isEmpty
        {
            let suffix = components.path.split(separator: "/").suffix(1).first.map(String.init)
            return suffix.map { "\(host) / \($0)" } ?? host
        }
        let components = URL(fileURLWithPath: path).standardized.pathComponents.filter { $0 != "/" }
        guard components.count > 2 else { return components.joined(separator: " / ") }
        return components.suffix(2).joined(separator: " / ")
    }
}

struct PathInfoButton: View {
    let path: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(path)
        .accessibilityLabel("Show location")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isWebURL ? "Address" : "Location")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if canReveal {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .padding(12)
            .frame(minWidth: 220, maxWidth: 440, alignment: .leading)
        }
    }

    private var isWebURL: Bool {
        guard let components = URLComponents(string: path), let scheme = components.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && components.host?.isEmpty == false
    }

    private var canReveal: Bool {
        !isWebURL && FileManager.default.fileExists(atPath: path)
    }
}

/// Kept for the plan review and settings, where the exact path is the point.
struct CompactPathText: View {
    let path: String
    var lineLimit = 1

    var body: some View {
        Text(displayPath)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
            .truncationMode(.middle)
            .help(path)
            .accessibilityLabel(path)
    }

    private var displayPath: String {
        if let components = URLComponents(string: path),
            let scheme = components.scheme,
            let host = components.host,
            !scheme.isEmpty,
            !host.isEmpty
        {
            let suffix = components.path.split(separator: "/").suffix(1).first.map(String.init)
            return suffix.map { "\(host)/…/\($0)" } ?? host
        }

        let components = URL(fileURLWithPath: path).standardized.pathComponents
        guard components.count > 3 else { return path }
        return "…/" + components.suffix(2).joined(separator: "/")
    }
}

private extension ClientState {
    var detailWithRevision: String {
        guard let revision else { return detail }
        return "\(detail) · \(revision)"
    }
}

/// Native table cells can be recycled while their enclosing view is changing.
/// Keep their content independent of required observable environment objects.
struct TableClientMarks: View {
    let clients: [ClientKind]
    let present: Set<ClientKind>

    var body: some View {
        HStack(spacing: 7) {
            ForEach(clients) { client in
                ClientBrandIcon(client: client, size: 15)
                    .opacity(present.contains(client) ? 1 : 0.22)
                    .grayscale(present.contains(client) ? 0 : 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clients.filter(present.contains).map(\.rawValue).joined(separator: ", "))
    }
}

import AgentToolingCore
import AppKit
import SwiftUI

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
            HStack(spacing: Space.xs) {
                ForEach(names.prefix(limit), id: \.self) { name in
                    Label(name, systemImage: ToolingKind.collection.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(AgentFont.microMedium)
                        .imageScale(.small)
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.white : AgentTheme.collection)
                        .padding(.horizontal, Space.sm)
                        .frame(height: Size.chipHeight)
                        .background(
                            Capsule().fill(selected ? Color.white.opacity(0.22) : AgentTheme.collection.opacity(0.13))
                        )
                }
                if names.count > limit {
                    Text("+\(names.count - limit)")
                        .font(AgentFont.microMedium)
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
            HStack(spacing: Space.xs) {
                ForEach(tags.prefix(limit), id: \.self) { tag in
                    Text(tag)
                        .font(AgentFont.micro)
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        .padding(.horizontal, Space.sm)
                        .frame(height: Size.chipHeight)
                        .background(
                            Capsule().fill(selected ? Color.white.opacity(0.16) : AgentTheme.fillSubtle)
                        )
                }
                if tags.count > limit {
                    Text("+\(tags.count - limit)")
                        .font(AgentFont.micro)
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
            HStack(spacing: Space.xs) {
                Text(title).lineLimit(1)
                if let count {
                    Text(count, format: .number)
                        .foregroundStyle(isOn ? Color.white.opacity(0.75) : Color.secondary)
                        .monospacedDigit()
                }
            }
            .font(isOn ? AgentFont.captionSemibold : AgentFont.caption)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, Space.lg)
            .frame(height: Size.pillHeight)
            .background(
                Capsule().fill(isOn ? AgentTheme.selection : AgentTheme.fillSubtle)
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
        FlowLayout(spacing: Space.sm) {
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
                .font(AgentFont.caption)
                .foregroundStyle(AgentTheme.selection)
                .padding(.horizontal, Space.sm)
                .frame(height: Size.pillHeight)
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
                    .primaryActionStyle()
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
            .font(.system(size: Size.brandMark))
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
        HStack(spacing: Space.md) {
            Text("\(count) selected")
                .font(AgentFont.bodyMedium)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: Space.md)
            Button("Clear", action: clear)
                .secondaryActionStyle()
            Button(actionTitle, action: action)
                .primaryActionStyle()
                .disabled(!isActionEnabled)
                .lineLimit(1)
        }
        .buttonBorderShape(.capsule)
        .padding(.horizontal, Space.xl)
        .frame(height: Size.headerHeight)
        .standardPanel()
        .shadow(color: AgentTheme.shadow, radius: 8, y: 3)
        .padding(Space.lg)
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
        HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: Size.labelColumn, alignment: .leading)
            trailing
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(AgentFont.body)
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
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
                    .font(AgentFont.mono)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .secondaryActionStyle()
                .controlSize(.small)
            }
            .padding(.top, Space.lg)
        } label: {
            Text(title)
                .font(AgentFont.body)
        }
        .padding(Space.xl)
        .standardPanel()
    }
}

struct ClientStatusRows: View {
    let clients: [ClientState]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(clients.enumerated()), id: \.offset) { index, client in
                HStack(spacing: Space.lg) {
                    ClientDisc(client: client.client, size: Size.disc)
                    Text(client.client.rawValue)
                        .font(AgentFont.bodyMedium)
                    Spacer(minLength: Space.xxl)
                    StatusBadge(state: client.state, text: client.detailWithRevision)
                }
                .padding(.horizontal, Space.xl)
                .frame(minHeight: Size.rowHeight)
                if index < clients.count - 1 { Hairline() }
            }
        }
    }
}

struct SectionCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AgentFont.captionMedium)
            .foregroundStyle(.secondary)
    }
}


private extension ClientState {
    var detailWithRevision: String {
        guard let revision else { return detail }
        return "\(detail) · \(revision)"
    }
}

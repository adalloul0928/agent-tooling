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
                    .tint(AgentTheme.selection)
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
                .tint(AgentTheme.selection)
                .disabled(!isActionEnabled)
                .lineLimit(1)
        }
        .buttonBorderShape(.capsule)
        .padding(.horizontal, 14)
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
                .padding(.horizontal, 14)
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


private extension ClientState {
    var detailWithRevision: String {
        guard let revision else { return detail }
        return "\(detail) · \(revision)"
    }
}

import AgentToolingCore
import AppKit
import SwiftUI

// MARK: - Tag filtering

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
                        .foregroundStyle(isOn ? AgentTheme.onSelection.opacity(0.75) : Color.secondary)
                        .monospacedDigit()
                }
            }
            .font(isOn ? AgentFont.captionSemibold : AgentFont.caption)
            .foregroundStyle(isOn ? AgentTheme.onSelection : Color.primary)
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
        if selected { return AgentTheme.onSelection }
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

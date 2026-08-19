import AgentToolingCore
import AppKit
import SwiftUI

struct StatusDot: View {
    let state: HealthState
    var size: CGFloat = 8

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: max(size + 2, 10), weight: .medium))
            .foregroundStyle(state == .unavailable ? Color.red : Color.secondary)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .healthy: "checkmark"
        case .attention: "exclamationmark"
        case .pending: "clock"
        case .unavailable: "xmark"
        }
    }
}

struct StatusBadge: View {
    let state: HealthState
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(state == .unavailable ? Color.red : Color.secondary)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch state {
        case .healthy: "checkmark"
        case .attention: "exclamationmark"
        case .pending: "clock"
        case .unavailable: "xmark"
        }
    }
}

struct SymbolTile: View {
    let symbol: String
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
    }
}

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
        HStack(spacing: 12) {
            Text(title)
                .font(.system(.title3, design: .default, weight: .semibold))

            if let context {
                Text(context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                actions
            }
        }
        .padding(.horizontal, 23)
        .frame(height: 54)
        .overlay(alignment: .bottom) { Divider().opacity(0.32) }
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
                .font(.system(.subheadline, design: .default, weight: .semibold))
            Spacer()
            trailing
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 17)
        .frame(height: 49)
        .overlay(alignment: .bottom) { Divider().opacity(0.12) }
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
    }
}

struct LabeledValueRow<Trailing: View>: View {
    let label: String
    @ViewBuilder let trailing: Trailing

    init(_ label: String, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 24)
            trailing
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

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
                LabeledValueRow(client.client.rawValue) {
                    StatusBadge(state: client.state, text: client.detailWithRevision)
                }
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

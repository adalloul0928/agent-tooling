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
                HStack(spacing: 11) {
                    ClientBrandIcon(client: client.client, size: 18)
                        .frame(width: 22)
                    Text(client.client.rawValue)
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 20)
                    StatusBadge(state: client.state, text: client.detailWithRevision)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
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

struct ToolingMatrixRow: Identifiable {
    let id: AppSection
    let title: String
    let symbol: String
    let libraryCount: Int
    let installedCounts: [ClientKind: Int]
}

/// The product's signature view: one honest comparison between the managed
/// inventory and the local state each client reported during the last check.
struct ToolingMatrixView: View {
    let rows: [ToolingMatrixRow]
    var onSelect: ((AppSection) -> Void)?
    private let clients: [ClientKind] = [.claude, .codex, .gemini]

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
                            Label(row.title, systemImage: row.symbol)
                                .font(.callout.weight(.medium))
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
            Text("Library shows known items. App columns show local installations found during the last check.")
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
}

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

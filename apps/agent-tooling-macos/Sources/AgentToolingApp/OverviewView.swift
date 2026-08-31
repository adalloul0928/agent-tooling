import AgentToolingCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    let navigate: (AppSection) -> Void
    @State private var selectedReceipt: ActivityReceipt?

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Overview") {
                Button {
                    Task { await model.runDoctor() }
                } label: {
                    Label(model.isRunningDoctor ? "Checking…" : "Check setup", systemImage: "stethoscope")
                }
                .buttonStyle(.bordered)
                .disabled(model.isInteractionLocked)

                Button {
                    Task { await model.runSync() }
                } label: {
                    Label(model.isSyncing ? "Preparing…" : "Review sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInteractionLocked)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pageHeading

                    ToolingMatrixView(rows: matrixRows, onSelect: navigate)

                    HStack(alignment: .top, spacing: 14) {
                        attentionPanel
                        activityPanel
                    }
                }
                .frame(maxWidth: 1_100)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(item: $selectedReceipt) { receipt in
            ReceiptDetailSheet(receipt: receipt)
        }
    }

    private var pageHeading: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("This Mac")
                    .font(.title2.weight(.semibold))
                Text("Manage the tools available to Claude Code, Codex, and Gemini CLI.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(lastScanText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var matrixRows: [ToolingMatrixRow] {
        [
            ToolingMatrixRow(
                id: .skills,
                title: "Skills",
                symbol: "doc.text",
                libraryCount: model.skills.count,
                installedCounts: installedCounts(for: model.skills.map(\.clients))
            ),
            ToolingMatrixRow(
                id: .mcpServers,
                title: "MCP servers",
                symbol: "network",
                libraryCount: model.mcpServers.count,
                installedCounts: installedCounts(for: model.mcpServers.map(\.clients))
            ),
            ToolingMatrixRow(
                id: .plugins,
                title: "Plugins",
                symbol: "puzzlepiece.extension",
                libraryCount: model.plugins.count,
                installedCounts: installedCounts(for: model.plugins.map(\.clients))
            ),
        ]
    }

    private func installedCounts(for clientLists: [[ClientState]]) -> [ClientKind: Int] {
        Dictionary(
            uniqueKeysWithValues: ClientKind.allCases.map { client in
                (
                    client,
                    clientLists.filter { states in
                        states.contains { $0.client == client && $0.reportsLocalPresence }
                    }.count
                )
            })
    }

    private var attentionPanel: some View {
        VStack(spacing: 0) {
            PanelHeader("Needs attention") {
                if !attentionItems.isEmpty {
                    Button("Review") { navigate(.syncCenter) }
                        .buttonStyle(.plain)
                        .foregroundStyle(AgentTheme.blue)
                }
            }

            if attentionItems.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No local issues found")
                            .font(.callout.weight(.medium))
                        Text("Account sign-in and fresh-session checks remain manual.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
            } else {
                VStack(spacing: 0) {
                    ForEach(attentionItems) { item in
                        AttentionRow(item: item)
                        if item.id != attentionItems.last?.id { Divider().opacity(0.35) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .standardPanel()
    }

    private var activityPanel: some View {
        VStack(spacing: 0) {
            PanelHeader("Recent activity") {
                Button("View all") { navigate(.activity) }
                    .buttonStyle(.plain)
                    .foregroundStyle(AgentTheme.blue)
            }

            if model.activities.isEmpty {
                Text("Checks and reviewed changes will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentActivities) { receipt in
                        Button {
                            selectedReceipt = receipt
                        } label: {
                            ActivityCompactRow(receipt: receipt)
                        }
                        .buttonStyle(.plain)
                        if receipt.id != recentActivities.last?.id { Divider().opacity(0.35) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .standardPanel()
    }

    private var lastScanText: String {
        guard let date = model.targetObservations.map(\.lastScannedAt).max() else {
            return "Not checked yet"
        }
        return "Checked \(date.formatted(.relative(presentation: .named)))"
    }

    private var recentActivities: [ActivityReceipt] {
        var seenTitles = Set<String>()
        return Array(model.activities.filter { seenTitles.insert($0.displayTitle).inserted }.prefix(3))
    }

    private var attentionItems: [OverviewAttention] {
        let targets = model.targetObservations
            .filter { !$0.isCommandAvailable }
            .map {
                OverviewAttention(
                    id: $0.id,
                    title: $0.installed ? "\($0.surface.displayName) command is unavailable" : "\($0.surface.displayName) was not found",
                    detail: $0.notes.first ?? "The expected local path was checked.",
                    state: .attention
                )
            }
        let configurationChecks = (model.activeProfile?.checks ?? [])
            .filter { $0.state == .attention || $0.state == .unavailable }
            .map { OverviewAttention(id: "profile-\($0.id)", title: $0.name, detail: $0.detail, state: $0.state) }
        let servers = model.mcpServers
            .filter { $0.aggregateState == .attention || $0.aggregateState == .unavailable }
            .map { OverviewAttention(id: "mcp-\($0.id)", title: $0.name, detail: $0.summary, state: $0.aggregateState) }
        return Array((targets + configurationChecks + servers).prefix(4))
    }

}

private struct OverviewAttention: Identifiable {
    let id: String
    let title: String
    let detail: String
    let state: HealthState
}

private struct AttentionRow: View {
    let item: OverviewAttention

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.state == .unavailable ? "xmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(item.state == .unavailable ? Color.red : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 54)
    }
}

struct ActivityCompactRow: View {
    let receipt: ActivityReceipt

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: receipt.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(receipt.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(receipt.date, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

struct ReceiptDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let receipt: ActivityReceipt?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(receipt?.displayTitle ?? "Receipt")
                            .font(.title2.weight(.semibold))
                        Text(receipt?.date.formatted() ?? "")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let receipt {
                        GroupBox("Result") {
                            VStack(spacing: 0) {
                                LabeledValueRow("Status") {
                                    StatusBadge(state: receipt.state, text: receipt.state.rawValue.capitalized)
                                }
                                Divider()
                                LabeledValueRow("Detail") {
                                    Text(receipt.detail)
                                        .textSelection(.enabled)
                                }
                                if let command = receipt.command {
                                    Divider()
                                    LabeledValueRow("Command") {
                                        Text(command)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .frame(height: 58)
        }
        .frame(width: 580)
        .frame(minHeight: 360, idealHeight: 440, maxHeight: 620)
        .background(AgentTheme.contentBackground)
    }
}

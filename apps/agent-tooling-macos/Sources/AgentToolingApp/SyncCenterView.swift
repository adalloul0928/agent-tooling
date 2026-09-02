import AgentToolingCore
import SwiftUI

struct SyncCenterView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Sync", context: toolbarContext) {
                Button {
                    Task { await model.runDoctor() }
                } label: {
                    Label(model.isRunningDoctor ? "Checking…" : "Check Clients", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.isInteractionLocked)

                Button {
                    Task { await model.runSync() }
                } label: {
                    Label(model.isSyncing ? "Preparing…" : "Review Changes", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInteractionLocked)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Compare local state first. Review the exact plan before Agent Tooling changes a client.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)

                    ToolingMatrixView(rows: matrixRows)

                    HStack(alignment: .top, spacing: 16) {
                        clientsCard.frame(maxWidth: .infinity)
                        receiptsCard.frame(maxWidth: .infinity)
                    }
                }
                .padding(EdgeInsets(top: 4, leading: 22, bottom: 22, trailing: 22))
                .frame(maxWidth: 1_060)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var toolbarContext: String {
        model.attentionCount == 0
            ? "Clients match the desired configuration"
            : "\(model.attentionCount) \(model.attentionCount == 1 ? "item needs" : "items need") attention"
    }

    private var clientsCard: some View {
        TitledCard("Clients", count: "read-only check") {
            if model.targetObservations.isEmpty {
                EmptyStateView(
                    symbol: "arrow.clockwise",
                    title: "Clients have not been checked",
                    message: "Check clients to inspect known configuration paths and command-line tools."
                )
                .frame(height: 210)
            } else {
                ForEach(sortedTargets) { target in
                    InfoRow(target.surface.displayName, detail: target.version ?? "Command-line tool not found") {
                        if let client = target.surface.client {
                            ClientDisc(client: client, size: 28)
                        } else {
                            SymbolTile(symbol: "app", size: 28)
                        }
                    } trailing: {
                        StatusBadge(
                            state: target.isCommandAvailable ? .healthy : .attention,
                            text: target.isCommandAvailable ? "Available" : (target.installed ? "Configuration only" : "Not found")
                        )
                    }
                    if target.id != sortedTargets.last?.id { Divider().opacity(0.35) }
                }
            }
        }
    }

    private var receiptsCard: some View {
        TitledCard(
            "Recent changes",
            count: model.operationReceipts.count > 4
                ? "showing 4 of \(model.operationReceipts.count)" : "\(model.operationReceipts.count) saved"
        ) {
            if model.operationReceipts.isEmpty {
                Text("No files have been changed. Review changes creates a plan before anything is written.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(recentReceipts) { receipt in
                    InfoRow(receipt.title, detail: receipt.verificationSummary) {
                        StatusGlyph(state: receipt.state, size: 16)
                    } trailing: {
                        Text(receipt.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if receipt.id != recentReceipts.last?.id { Divider().opacity(0.35) }
                }
            }
        }
    }

    private var sortedTargets: [TargetObservation] {
        model.targetObservations.sorted { $0.surface.displayName.localizedStandardCompare($1.surface.displayName) == .orderedAscending }
    }

    private var matrixRows: [ToolingMatrixRow] {
        [
            ToolingMatrixRow(
                id: .skills, title: "Skills", symbol: "doc.text", libraryCount: model.skills.count,
                installedCounts: installedCounts(for: model.skills.map(\.clients)), kind: .skill
            ),
            ToolingMatrixRow(
                id: .mcpServers, title: "MCP servers", symbol: "server.rack", libraryCount: model.mcpServers.count,
                installedCounts: installedCounts(for: model.mcpServers.map(\.clients)), kind: .mcpServer
            ),
            ToolingMatrixRow(
                id: .plugins, title: "Plugins", symbol: "puzzlepiece.extension", libraryCount: model.plugins.count,
                installedCounts: installedCounts(for: model.plugins.map(\.clients)), kind: .plugin
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

    private var recentReceipts: [OperationReceipt] {
        Array(
            model.operationReceipts.sorted {
                if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.createdAt > $1.createdAt
            }.prefix(4))
    }
}

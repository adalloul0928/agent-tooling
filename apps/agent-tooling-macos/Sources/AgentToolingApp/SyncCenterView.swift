import AgentToolingCore
import SwiftUI

struct SyncCenterView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(title: "Sync") {
                Button {
                    Task { await model.runDoctor() }
                } label: {
                    Label(model.isRunningDoctor ? "Checking…" : "Check apps", systemImage: "stethoscope")
                }
                .buttonStyle(.bordered)
                .disabled(model.isInteractionLocked)

                Button {
                    Task { await model.runSync() }
                } label: {
                    Label(model.isSyncing ? "Preparing…" : "Review changes", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInteractionLocked)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keep apps aligned")
                            .font(.title2.weight(.semibold))
                        Text("Compare local state first. Review the exact plan before Agent Tooling changes a client.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    ToolingMatrixView(rows: matrixRows)

                    HStack(alignment: .top, spacing: 14) {
                        targetPanel.frame(maxWidth: .infinity)
                        receiptsPanel.frame(maxWidth: .infinity)
                    }
                }
                .padding(24)
                .frame(maxWidth: 1_020)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var targetPanel: some View {
        VStack(spacing: 0) {
            PanelHeader("Apps") {
                Text("Read-only check")
            }

            if model.targetObservations.isEmpty {
                EmptyStateView(
                    symbol: "stethoscope",
                    title: "Apps have not been checked",
                    message: "Check apps to inspect known configuration paths and command-line tools."
                )
                .frame(height: 210)
            } else {
                VStack(spacing: 0) {
                    ForEach(sortedTargets) { target in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(target.surface.displayName)
                                    .font(.callout.weight(.medium))
                                Text(target.version ?? "Command-line tool not found")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusBadge(
                                state: target.isCommandAvailable ? .healthy : .attention,
                                text: target.isCommandAvailable ? "Available" : (target.installed ? "Configuration only" : "Not found")
                            )
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 54)
                        if target.id != sortedTargets.last?.id { Divider().opacity(0.35) }
                    }
                }
            }
        }
        .standardPanel()
    }

    private var receiptsPanel: some View {
        VStack(spacing: 0) {
            PanelHeader("Recent changes") {
                Text(
                    model.operationReceipts.count > 4
                        ? "Showing 4 of \(model.operationReceipts.count)" : "\(model.operationReceipts.count) saved")
            }

            if model.operationReceipts.isEmpty {
                Text("No files have been changed. Review changes creates a plan before anything is written.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentReceipts) { receipt in
                        HStack(spacing: 10) {
                            StatusDot(state: receipt.state)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(receipt.title).font(.callout.weight(.medium))
                                Text(receipt.verificationSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(receipt.createdAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 52)
                        if receipt.id != recentReceipts.last?.id { Divider().opacity(0.35) }
                    }
                }
            }
        }
        .standardPanel()
    }

    private var sortedTargets: [TargetObservation] {
        model.targetObservations.sorted { $0.surface.displayName.localizedStandardCompare($1.surface.displayName) == .orderedAscending }
    }

    private var matrixRows: [ToolingMatrixRow] {
        [
            ToolingMatrixRow(
                id: .skills, title: "Skills", symbol: "doc.text", libraryCount: model.skills.count,
                installedCounts: installedCounts(for: model.skills.map(\.clients))
            ),
            ToolingMatrixRow(
                id: .mcpServers, title: "MCP servers", symbol: "network", libraryCount: model.mcpServers.count,
                installedCounts: installedCounts(for: model.mcpServers.map(\.clients))
            ),
            ToolingMatrixRow(
                id: .plugins, title: "Plugins", symbol: "puzzlepiece.extension", libraryCount: model.plugins.count,
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

    private var recentReceipts: [OperationReceipt] {
        Array(
            model.operationReceipts.sorted {
                if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.createdAt > $1.createdAt
            }.prefix(4))
    }
}

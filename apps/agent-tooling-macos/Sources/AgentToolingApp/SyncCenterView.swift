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
                        Text("Installation status")
                            .font(.title2.weight(.semibold))
                        Text("Compare the managed library with each app before changing any files.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    operationPanel

                    HStack(alignment: .top, spacing: 14) {
                        targetPanel.frame(maxWidth: .infinity)
                        verificationPanel.frame(maxWidth: .infinity)
                    }

                    receiptsPanel
                }
                .padding(24)
                .frame(maxWidth: 1_020)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var operationPanel: some View {
        VStack(spacing: 0) {
            PanelHeader("Sync steps")
            ForEach(Array(model.syncStages.enumerated()), id: \.element.id) { index, stage in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.title)
                            .font(.callout.weight(.medium))
                        Text(stage.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    SyncStageLabel(state: stage.state)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 50)

                if index < model.syncStages.count - 1 { Divider().opacity(0.35) }
            }
        }
        .standardPanel()
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

    private var verificationPanel: some View {
        VStack(spacing: 0) {
            PanelHeader("How app checks work")
            VerificationLine(title: "Available", detail: "The command-line tool responded on this Mac.")
            Divider().opacity(0.35)
            VerificationLine(title: "Configuration only", detail: "Known configuration files exist, but the command was not found.")
            Divider().opacity(0.35)
            VerificationLine(title: "Not found", detail: "Neither the command nor a known local configuration was found.")
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

    private var recentReceipts: [OperationReceipt] {
        Array(
            model.operationReceipts.sorted {
                if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.createdAt > $1.createdAt
            }.prefix(4))
    }
}

private struct SyncStageLabel: View {
    let state: SyncStageState

    var body: some View {
        Group {
            if state == .running {
                ProgressView().controlSize(.small)
            } else {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(state == .attention ? Color.red : Color.secondary)
            }
        }
        .frame(minWidth: 62, alignment: .trailing)
    }

    private var label: String {
        switch state {
        case .waiting: "Waiting"
        case .running: "Working"
        case .complete: "Complete"
        case .attention: "Review"
        }
    }
}

private struct VerificationLine: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
    }
}

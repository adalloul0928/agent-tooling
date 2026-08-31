import AgentToolingCore
import SwiftUI

struct PlanReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let plan: OperationPlan
    @State private var isSubmitting = false
    @State private var executionTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.title).font(.title2.weight(.semibold))
                    Text(plan.summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                    executionLabel,
                    systemImage: planHasAutomaticSteps ? "exclamationmark.shield" : "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("Applies to") {
                        Text(([plan.scope.displayName] + plan.targetSurfaces.map(\.displayName)).joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)

                    Text("Planned steps")
                        .font(.headline)
                    VStack(spacing: 0) {
                        ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                            PlanStepRow(number: index + 1, step: step)
                            if index < plan.steps.count - 1 { Divider().opacity(0.25) }
                        }
                    }
                    .standardPanel()

                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.secondary)
                        Text(
                            "Commands use a fixed allowlist. File changes are limited to the managed library, supported client paths, and a reviewed complete backup; replaced files are saved as rollback artifacts."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .standardPanel()
                }
                .padding(24)
            }

            Divider()
            HStack {
                Button(
                    isSubmitting || model.isExecutingPlan ? "Stop" : "Cancel",
                    role: isSubmitting || model.isExecutingPlan ? .destructive : .cancel
                ) {
                    if isSubmitting || model.isExecutingPlan {
                        executionTask?.cancel()
                    } else {
                        model.discardPendingPlan()
                        dismiss()
                    }
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    guard !isSubmitting else { return }
                    isSubmitting = true
                    executionTask = Task { @MainActor in
                        await model.executePendingPlan()
                        isSubmitting = false
                        executionTask = nil
                        dismiss()
                    }
                } label: {
                    if isSubmitting || model.isExecutingPlan {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Running plan")
                    } else {
                        Text(
                            planHasAutomaticSteps
                                ? "Run \(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s")"
                                : "Record guidance")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(plan.steps.isEmpty || isSubmitting || model.isExecutingPlan)
            }
            .padding(.horizontal, 24)
            .frame(height: 78)
        }
        .frame(width: 840, height: 670)
        .background(AgentTheme.contentBackground)
        .interactiveDismissDisabled(isSubmitting || model.isExecutingPlan)
        .onDisappear {
            if isSubmitting { executionTask?.cancel() }
        }
    }

    private var planHasAutomaticSteps: Bool {
        plan.steps.contains { step in
            !step.requiresUserAction && step.kind != .manual && step.kind != .openURL
        }
    }

    private var executionLabel: String {
        if planHasAutomaticSteps {
            return plan.requiresConfirmation ? "Review required" : "Ready to run"
        }
        return "Guided operation"
    }

}

private struct PlanStepRow: View {
    let number: Int
    let step: OperationStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(step.title).font(.callout.weight(.semibold))
                    if step.requiresUserAction {
                        Text("Manual")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(step.detail).font(.caption).foregroundStyle(.secondary)
                if let command = step.renderedCommand {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                }
                if let source = step.sourcePath, let destination = step.destinationPath {
                    HStack(spacing: 6) {
                        CompactPathText(path: source)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        CompactPathText(path: destination)
                    }
                } else if let destination = step.destinationPath {
                    CompactPathText(path: destination)
                }
                if let fingerprint = step.sourceFingerprint {
                    Text("Reviewed source: \(fingerprint.prefix(12))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(15)
    }
}

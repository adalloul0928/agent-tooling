import AgentToolingCore
import SwiftUI

struct PlanReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let plan: OperationPlan
    @State private var isSubmitting = false
    @State private var executionTask: Task<Void, Never>?
    /// Computed before approval, never during execution. A person cannot
    /// consent to a removal they were only told about afterwards, and the
    /// execution boundary receives the digest of this exact reviewed plan.
    @State private var reviewState: ReviewState = .loading

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

                    if let headline = safetyReview?.headline {
                        AttentionBanner(
                            title: "Before you approve",
                            message: headline
                        )
                    }

                    switch reviewState {
                    case .loading:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking destinations and package contents…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .standardPanel()
                    case .failed(let message):
                        AttentionBanner(title: "This plan cannot be reviewed", message: message)
                    case .ready:
                        EmptyView()
                    }

                    Text("Planned steps")
                        .font(.headline)
                    VStack(spacing: 0) {
                        ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                            PlanStepRow(
                                number: index + 1,
                                step: step,
                                review: safetyReview?.review(forStep: step.id)
                            )
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
                    guard !isSubmitting, let reviewedPlan, safetyReview?.hasBlockedSteps == false else { return }
                    isSubmitting = true
                    executionTask = Task { @MainActor in
                        let completed = await model.executePendingPlan(reviewedPlan)
                        isSubmitting = false
                        executionTask = nil
                        if completed { dismiss() }
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
                .disabled(
                    plan.steps.isEmpty || isSubmitting || model.isExecutingPlan
                        || reviewedPlan == nil || safetyReview?.hasBlockedSteps != false
                )
            }
            .padding(.horizontal, 24)
            .frame(height: 78)
        }
        .frame(width: 840, height: 670)
        .background(AgentTheme.contentBackground)
        .interactiveDismissDisabled(isSubmitting || model.isExecutingPlan)
        .task(id: plan.id) {
            reviewState = .loading
            do {
                let reviewedPlan = try OperationPlanApproval.review(plan)
                let safetyReview = await model.safetyReviewAsync(for: plan)
                guard !Task.isCancelled else { return }
                guard safetyReview.planID == plan.id else {
                    reviewState = .failed("The safety review did not match this plan. Close the sheet and prepare it again.")
                    return
                }
                reviewState = .ready(safetyReview, reviewedPlan)
            } catch {
                reviewState = .failed(error.localizedDescription)
            }
        }
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
        switch reviewState {
        case .loading: return "Checking safety"
        case .failed: return "Review unavailable"
        case .ready(let review, _):
            if review.hasBlockedSteps { return "Blocked" }
        }
        if planHasAutomaticSteps {
            return plan.requiresConfirmation ? "Review required" : "Ready to run"
        }
        return "Guided operation"
    }

    private var safetyReview: OperationPlanSafetyReview? {
        guard case .ready(let safetyReview, _) = reviewState else { return nil }
        return safetyReview
    }

    private var reviewedPlan: ReviewedOperationPlan? {
        guard case .ready(_, let reviewedPlan) = reviewState else { return nil }
        return reviewedPlan
    }

    private enum ReviewState {
        case loading
        case ready(OperationPlanSafetyReview, ReviewedOperationPlan)
        case failed(String)
    }

}

private struct PlanStepRow: View {
    let number: Int
    let step: OperationStep
    var review: OperationStepSafetyReview?

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
                    if review?.isBlocked == true {
                        StatusBadge(state: .attention, text: "Blocked", tint: AgentTheme.failure)
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
                if let review {
                    if let blockReason = review.blockReason {
                        PlanFindingPanel(
                            symbol: "hand.raised",
                            tint: AgentTheme.failure,
                            title: "This step will not run",
                            message: blockReason
                        )
                    }
                    if let replacement = review.replacement, let headline = replacement.removalHeadline {
                        PlanRemovalPanel(headline: headline, diff: replacement)
                    }
                    if let contentRisk = review.contentRisk, !contentRisk.isClean {
                        PlanContentRiskPanel(report: contentRisk)
                    }
                }
            }
        }
        .padding(15)
    }
}

/// A neutral, bordered note under a step. Colour is a small glyph only, so a
/// finding informs the decision without shouting at the operator.
private struct PlanFindingPanel<Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var message: String?
    @ViewBuilder var content: Content

    init(
        symbol: String,
        tint: Color,
        title: String,
        message: String? = nil,
        @ViewBuilder content: () -> Content = { EmptyView() }
    ) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.message = message
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
        }
        .padding(.top, 2)
    }
}

/// Names every file the update would delete, before approval.
private struct PlanRemovalPanel: View {
    let headline: String
    let diff: DirectoryReplacementDiff

    var body: some View {
        PlanFindingPanel(symbol: "trash", tint: AgentTheme.warning, title: headline) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(diff.removedPaths.prefix(Self.listLimit), id: \.self) { path in
                    Text(path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if diff.removedPaths.count > Self.listLimit {
                    Text("and \(diff.removedPaths.count - Self.listLimit) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if diff.isTruncated {
                    Text("The folders were too large to compare completely, so this list may be incomplete.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static let listLimit = 12
}

/// Content-scan findings, shown in the same sheet as the approve button so the
/// operator decides with the finding in front of them. Nothing is dropped or
/// filtered on their behalf.
private struct PlanContentRiskPanel: View {
    let report: ContentRiskReport

    var body: some View {
        PlanFindingPanel(
            symbol: "doc.text.magnifyingglass",
            tint: report.maliciousCount > 0 ? AgentTheme.failure : AgentTheme.warning,
            title: report.headline
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(report.findings.prefix(Self.listLimit)) { finding in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Image(systemName: finding.category.symbolName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(finding.severity.displayName) · \(finding.headline)")
                                .font(.caption.weight(.medium))
                        }
                        Text(finding.location)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(finding.evidence)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Text(finding.guidance)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if report.findings.count > Self.listLimit {
                    Text("and \(report.findings.count - Self.listLimit) more findings")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                ForEach(report.coverageNotes.prefix(Self.listLimit), id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static let listLimit = 8
}

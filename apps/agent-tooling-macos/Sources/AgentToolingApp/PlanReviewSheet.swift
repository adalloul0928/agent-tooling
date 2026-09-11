import AgentToolingCore
import SwiftUI

/// What installing would do to this Mac, shown before anything is written.
///
/// The plan on screen is the plan that runs: `deployment.apply()` applies this
/// exact `WorkspaceDeploymentPlan`, so nothing here is a rehearsal of a
/// different list. Each step names the tool, the app it lands in, and — for a
/// step that runs a command rather than copying a folder — the command itself.
///
/// A saved assignment is never reported as installed. What has only been asked
/// for appears under "not being installed" with the reason, and only a step
/// that succeeds turns into a result.
struct PlanReviewSheet: View {
    let workspace: WorkspaceLaunch.Workspace
    let plan: WorkspaceDeploymentPlan
    @Environment(\.dismiss) private var dismiss
    @State private var isSubmitting = false
    @State private var executionTask: Task<Void, Never>?
    /// Computed before approval, never during execution. A person cannot
    /// consent to content they were only shown afterwards.
    @State private var reviewState: ReviewState = .loading

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Label(executionLabel, systemImage: planRunsCommands ? "exclamationmark.shield" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("Applies to") {
                        Text(appliesTo)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)

                    if let headline = review?.headline {
                        AttentionBanner(title: "Before you approve", message: headline)
                    }

                    if let message = workspace.deployment.errorMessage {
                        AttentionBanner(title: "Nothing was installed", message: message)
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

                    if plan.items.isEmpty {
                        EmptyStateView(
                            symbol: "checkmark.circle",
                            title: "Nothing to install",
                            message: "Your apps already match what you asked for."
                        )
                        .frame(height: 200)
                    } else {
                        Text("Planned steps")
                            .font(.headline)
                        VStack(spacing: 0) {
                            ForEach(Array(plan.items.enumerated()), id: \.offset) { index, item in
                                PlanStepRow(
                                    number: index + 1,
                                    item: item,
                                    linkedPath: linkedPath(for: item),
                                    command: review?.command(for: item),
                                    nothingRuns: review?.reasonNothingRuns(for: item),
                                    contentRisk: review?.contentRisk(for: item))
                                if index < plan.items.count - 1 { Divider().opacity(0.25) }
                            }
                        }
                        .standardPanel()
                    }

                    if !plan.exclusions.isEmpty { excluded }
                    if !workspace.deployment.linkedDestinations.isEmpty { linkedDestinations }

                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.secondary)
                        Text(
                            "Commands use a fixed allowlist. File changes are limited to the managed library, supported client paths, and the folders you pointed a destination at; replaced files are saved as rollback artifacts."
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
                    isRunning ? "Stop" : "Cancel",
                    role: isRunning ? .destructive : .cancel
                ) {
                    if isRunning {
                        executionTask?.cancel()
                    } else {
                        dismiss()
                    }
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    guard !isSubmitting, canInstall else { return }
                    isSubmitting = true
                    executionTask = Task { @MainActor in
                        await workspace.deployment.apply()
                        isSubmitting = false
                        executionTask = nil
                        if workspace.deployment.errorMessage == nil { dismiss() }
                    }
                } label: {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Installing")
                    } else {
                        Text(installLabel)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canInstall)
            }
            .padding(.horizontal, 24)
            .frame(height: 78)
        }
        .frame(width: 840, height: 670)
        .background(AgentTheme.contentBackground)
        .interactiveDismissDisabled(isRunning)
        .task(id: planIdentity) {
            reviewState = .loading
            guard let contentStore = workspace.contentStore else {
                reviewState = .failed(
                    "This workspace has no verified content store, so nothing here can be read before it is written."
                )
                return
            }
            guard let snapshot = workspace.library.state?.snapshot else {
                reviewState = .failed(
                    "The library has not been read yet. Close this and check your apps again.")
                return
            }
            let plan = self.plan
            let homeRoot = workspace.homeRoot
            let reviewed = await DeploymentPlanReviewer.review(
                plan: plan, snapshot: snapshot, contentStore: contentStore, homeRoot: homeRoot)
            guard !Task.isCancelled else { return }
            reviewState = .ready(reviewed)
        }
        .onDisappear {
            if isSubmitting { executionTask?.cancel() }
        }
    }

    // MARK: - Sections

    private var excluded: some View {
        DisclosureGroup("\(plan.exclusions.count) not being installed") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Asking for a tool and installing it are two different things. These were asked for and are not being installed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(plan.exclusions.enumerated()), id: \.offset) { _, exclusion in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(exclusionTitle(exclusion.reason)).font(.callout).fontWeight(.medium)
                        Text(exclusion.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .standardPanel()
    }

    /// Where these go on this Mac, when that is not the app's own folder. The
    /// exact folder is the point here, so it is shown rather than hidden.
    private var linkedDestinations: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where these go on this Mac").font(.headline)
            Text(
                "Agent Tooling writes only into the folder you named, and only if nothing is already there under that tool's name. Anything already in it is left exactly as it is."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            ForEach(workspace.deployment.linkedDestinations) { destination in
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(
                        "\(destination.surface.displayName) · \(destination.projectName ?? destination.scope.displayName)"
                    )
                    .font(.callout.weight(.medium))
                    Spacer(minLength: 12)
                    LocationText(path: destination.path)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .standardPanel()
    }

    // MARK: - Derived

    private var isRunning: Bool { isSubmitting || workspace.deployment.isBusy }

    private var canInstall: Bool {
        guard case .ready(let reviewed) = reviewState else { return false }
        return workspace.deployment.canApply && !isRunning && runnableCount > 0
            && !reviewed.hasBlockedItems
    }

    /// Steps that will do something when Install is pressed. Until the review
    /// has looked, every listed step is taken at its word.
    private var runnableCount: Int {
        plan.items.count - (review?.stepsWithoutCommand ?? 0)
    }

    private var installLabel: String {
        runnableCount == 0 && !plan.items.isEmpty
            ? "Nothing can run yet"
            : "Install \(runnableCount) change\(runnableCount == 1 ? "" : "s")"
    }

    private var review: DeploymentPlanReview? {
        guard case .ready(let reviewed) = reviewState else { return nil }
        return reviewed
    }

    private var title: String {
        plan.items.isEmpty ? "Nothing to install" : installLabel
    }

    private var summary: String {
        "Each app is handled on its own, and nothing else in its folder is touched."
    }

    private var appliesTo: String {
        let scopes = Set(plan.items.map(\.scope)).map(\.displayName).sorted()
        let surfaces = Set(plan.items.map(\.surface)).map(\.displayName).sorted()
        let parts = scopes + surfaces
        return parts.isEmpty ? "Nothing on this Mac" : parts.joined(separator: " · ")
    }

    private var planRunsCommands: Bool {
        plan.items.contains { item in
            switch item.action {
            case .installNativePackage, .configureManagedConnection: true
            case .installContent, .updateContent, .removeContent: false
            }
        }
    }

    private var executionLabel: String {
        switch reviewState {
        case .loading: return "Checking safety"
        case .failed: return "Review unavailable"
        case .ready(let reviewed):
            if reviewed.hasBlockedItems { return "Blocked" }
        }
        return planRunsCommands ? "Review required" : "Ready to run"
    }

    /// Identifies this exact plan, so re-preparing re-reviews rather than
    /// leaving an older answer beside a newer list.
    private var planIdentity: String {
        plan.items
            .map {
                "\($0.artifactID.rawValue.uuidString)|\($0.physicalDestinationID.rawValue.uuidString)|\($0.surface.rawValue)"
            }
            .joined(separator: ",")
    }

    private func linkedPath(for item: WorkspaceDeploymentItem) -> String? {
        workspace.deployment.linkedDestinations.first {
            $0.surface == item.surface && $0.scope == item.scope
        }?.path
    }

    private func exclusionTitle(_ reason: WorkspaceDeploymentExclusionReason) -> String {
        switch reason {
        case .missingContent: "No verified copy in your library"
        case .trackedOwnership: "Recorded only"
        case .packageMember: "Comes with its package"
        case .missingNativeRoute: "No install route on this Mac"
        case .unsupportedByAdapter: "This app version cannot do it"
        case .needsAssignmentReview: "Needs review first"
        case .alreadyPresent: "Already there"
        }
    }

    private enum ReviewState {
        case loading
        case ready(DeploymentPlanReview)
        case failed(String)
    }
}

// MARK: - Steps

private struct PlanStepRow: View {
    let number: Int
    let item: WorkspaceDeploymentItem
    var linkedPath: String?
    var command: String?
    /// Why pressing Install does nothing for this step, when it does nothing.
    var nothingRuns: String?
    var contentRisk: ContentRiskReport?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.displayName).font(.callout.weight(.semibold))
                    if contentRisk?.isComplete == false {
                        StatusBadge(state: .attention, text: "Blocked", tint: AgentTheme.failure)
                    }
                    if nothingRuns != nil {
                        StatusBadge(state: .attention, text: "Will not run", tint: AgentTheme.warning)
                    }
                }
                Text("\(clause) · \(item.surface.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let nothingRuns {
                    Text(nothingRuns)
                        .font(.caption)
                        .foregroundStyle(AgentTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let command {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                }
                if let linkedPath {
                    CompactPathText(path: linkedPath)
                }
                if let contentRisk, !contentRisk.isClean {
                    PlanContentRiskPanel(report: contentRisk)
                }
            }
        }
        .padding(15)
    }

    private var symbol: String {
        switch item.action {
        case .installContent: "arrow.down.circle"
        case .updateContent: "arrow.triangle.2.circlepath"
        case .installNativePackage: "puzzlepiece.extension"
        case .configureManagedConnection: "cable.connector"
        case .removeContent: "trash"
        }
    }

    private var clause: String {
        let place = item.scope == .project ? "in this project" : "for your account"
        switch item.action {
        case .installContent: return "Add \(place)"
        case .updateContent(let from, _):
            return from == nil
                ? "Replace what is there now, \(place)" : "Update to your approved version, \(place)"
        case .installNativePackage: return "Ask its app to install it, \(place)"
        case .configureManagedConnection: return "Set up this connection \(place)"
        case .removeContent:
            return "Remove the copy this app installed, \(place). Anything you changed is left alone."
        }
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

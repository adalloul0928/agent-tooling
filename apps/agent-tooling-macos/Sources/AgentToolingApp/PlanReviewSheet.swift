import AgentToolingCore
import SwiftUI

/// Reviews and applies the exact supplied plan through `ScopedPlanReview`.
/// Unowned replacements remain visible but cannot run; already-present items
/// are omitted. Only a fresh ⌘Return installs. Assignment intent is never shown
/// as an installation result until execution succeeds.
struct PlanReviewSheet: View {
    let workspace: WorkspaceLaunch.Workspace
    @State private var review: ScopedPlanReview
    @Environment(\.dismiss) private var dismiss
    /// The "not being installed" list starts open when there is nothing else to
    /// show, so the reasons are in front of the person rather than hidden behind
    /// a closed disclosure while the sheet reads "nothing to install".
    @State private var exclusionsExpanded = false
    /// A plain ↩ reached the sheet, where only ⌘↩ installs.
    @State private var commandReturnHint = false
    @State private var commandReturnFlash = 0

    init(workspace: WorkspaceLaunch.Workspace, plan: WorkspaceDeploymentPlan) {
        self.init(workspace: workspace, review: ScopedPlanReview(workspace: workspace, reviewing: plan, includingRemovals: true))
    }

    /// The sheet over a review someone already holds, read or not: it reads
    /// it only if nobody has.
    init(workspace: WorkspaceLaunch.Workspace, review: ScopedPlanReview) {
        self.workspace = workspace
        _review = State(initialValue: review)
    }

    var body: some View {
        ReviewSheetLayout(size: SheetSize.xlarge) {
            HStack(alignment: .top, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(review.title).font(AgentFont.titleLarge)
                    Text(summary).font(AgentFont.body).foregroundStyle(.secondary)
                }
                Spacer()
                Label(executionLabel, systemImage: planRunsCommands ? "exclamationmark.shield" : "info.circle")
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Space.xxxl)
        } content: {
            VStack(alignment: .leading, spacing: Space.xl) {
                LabeledContent("Applies to") {
                    Text(appliesTo)
                        .foregroundStyle(.secondary)
                }
                .font(AgentFont.caption)

                // Facts, never a verdict: one neutral line, as on the stage's
                // panel. A finding is drawn under its own step.
                if let line = review.beforeYouApprove {
                    ReviewSafetyRow(text: line, overhang: 0)
                }

                switch review.phase {
                case .preparing:
                    HStack(spacing: Space.md) {
                        ProgressView().controlSize(.small)
                        Text(LaunchpadCopy.Review.checking)
                            .font(AgentFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .standardPanel()
                case .failed(let message):
                    AttentionBanner(title: "This plan cannot be reviewed", message: message)
                case .notRun(let message):
                    AttentionBanner(title: PlanReviewLabels.nothingDoneTitle(hasRemoval: review.hasRemoval), message: message)
                case .stale:
                    AttentionBanner(
                        title: PlanReviewLabels.nothingDoneTitle(hasRemoval: review.hasRemoval),
                        message: LaunchpadCopy.Review.changedWhileOpen)
                case .ready, .running, .finished:
                    EmptyView()
                }

                if review.listedCount == 0, review.phase != .preparing {
                    if review.exclusions.isEmpty {
                        EmptyStateView(
                            symbol: "checkmark.circle",
                            title: "Nothing to install",
                            message: "Your apps already match what you asked for."
                        )
                        .frame(height: Size.emptyStateMinHeight)
                    } else {
                        // Things were asked for, and none can be installed
                        // right now. Say so plainly and show the reasons,
                        // rather than implying everything already matches.
                        EmptyStateView(
                            symbol: "exclamationmark.triangle",
                            title: "Nothing can be installed right now",
                            message:
                                "\(CountNoun("requested item").phrase(review.exclusions.count)) "
                                + "\(review.exclusions.count == 1 ? "is" : "are") "
                                + "not being installed. The reasons are listed below."
                        )
                        .frame(height: Size.emptyStateMinHeight)
                    }
                } else if !review.groups.isEmpty {
                    Text("Planned steps")
                        .font(AgentFont.heading)
                    VStack(alignment: .leading, spacing: Space.lg) {
                        ForEach(review.groups) { group in
                            VStack(alignment: .leading, spacing: Space.xs) {
                                ReviewAppHeader(client: group.client, summary: group.summary)
                                ForEach(group.steps) { step in
                                    ReviewStepRow(step: step, accessibilityText: review.accessibilityLabel(for: step))
                                }
                            }
                        }
                    }
                    .padding(Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .standardPanel()
                }

                if !review.exclusions.isEmpty { excluded }
                if !workspace.deployment.linkedDestinations.isEmpty { linkedDestinations }

                HStack(spacing: Space.md) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text(LaunchpadCopy.Review.safety)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
                .padding(Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
                .standardPanel()
            }
            .padding(Space.xxxl)
        } footer: {
            footer
        }
        .background(AgentTheme.contentBackground)
        .interactiveDismissDisabled(review.isBusy)
        // ⌘↩ installs only while the plan waits on it; once there is a
        // result, ↩ is the footer's again.
        .commandReturnAction(
            isActive: LaunchpadReviewPanel.awaitsCommandReturn(review), isReady: review.canInstall, perform: install,
            onPlainReturn: {
                commandReturnHint = true
                commandReturnFlash &+= 1
            }
        )
        .task {
            guard !review.hasBegunReading else { return }
            await review.prepare()
            // With nothing installable, open the reasons by default so they
            // are read rather than hidden behind a closed disclosure.
            exclusionsExpanded = review.listedCount == 0 && !review.exclusions.isEmpty
        }
        .onDisappear {
            // Closed mid-install: it stops after the step it is on.
            if review.isBusy { review.stop() }
        }
    }

    // MARK: - Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: Space.md) {
            if case .finished(let outcome) = review.phase {
                Text(outcome.summary)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .primaryActionStyle()
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(review.isBusy ? "Stop" : "Cancel", role: review.isBusy ? .destructive : .cancel) {
                    if review.isBusy {
                        review.stop()
                    } else {
                        dismiss()
                    }
                }
                .secondaryActionStyle()
                .keyboardShortcut(.cancelAction)
                Spacer()
                if commandReturnHint, review.phase == .ready {
                    Text(LaunchpadCopy.Footer.commandReturnHint)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                }
                if review.phase == .stale {
                    Button(LaunchpadCopy.Review.reviewAgain) { Task { await review.reviewAgain() } }
                        .secondaryActionStyle()
                }
                Button(action: install) {
                    if review.isBusy {
                        HStack(spacing: Space.sm) {
                            ProgressView().controlSize(.small)
                            Text(review.progressLine ?? PlanReviewLabels.runningLabel(hasRemoval: review.hasRemoval))
                        }
                        .accessibilityLabel(PlanReviewLabels.runningLabel(hasRemoval: review.hasRemoval))
                    } else {
                        HStack(spacing: Space.sm) {
                            Text(review.title)
                            KeyCombo(shortcut: StageShortcut.commandReturn)
                                .modifier(KeycapFlash(trigger: commandReturnFlash))
                        }
                        .environment(\.keycapOnAccent, true)
                    }
                }
                .primaryActionStyle()
                .disabled(!review.canInstall)
                .accessibilityHint(LaunchpadCopy.Footer.commandReturnAccessibilityHint)
            }
        }
    }

    /// ⌘↩ or a click on Install: exactly what the sheet lists runs. The
    /// review is running before this returns, so a ⎋ handled next is Stop,
    /// not a Cancel that closes the sheet as the install begins. A complete
    /// install closes the sheet; a failure, or a Stop, stays in front of the
    /// person.
    private func install() {
        commandReturnHint = false
        let review = review
        guard let installing = review.begin() else { return }
        Task {
            await installing.value
            if case .finished(let outcome) = review.phase, outcome.isComplete { dismiss() }
        }
    }

    // MARK: - Sections

    private var excluded: some View {
        DisclosureGroup(
            isExpanded: $exclusionsExpanded
        ) {
            VStack(alignment: .leading, spacing: Space.lg) {
                Text(
                    "Asking for a tool and installing it are two different things. These were asked for and are not being installed."
                )
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .wrapsLines()
                ForEach(Array(review.exclusions.enumerated()), id: \.offset) { _, exclusion in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(exclusionTitle(exclusion.reason)).font(AgentFont.bodyMedium)
                        Text(exclusion.detail).font(AgentFont.caption).foregroundStyle(.secondary)
                            .wrapsLines()
                    }
                }
            }
            .padding(.top, Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("\(review.exclusions.count) not being installed")
        }
        .padding(Space.xl)
        .standardPanel()
    }

    /// Where these go on this Mac, when that is not the app's own folder. The
    /// exact folder is the point here, so it is shown rather than hidden.
    private var linkedDestinations: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Where these go on this Mac").font(AgentFont.heading)
            Text(
                "Agent Tooling writes only into the folder you named, and only if nothing is already there under that tool's name. Anything already in it is left exactly as it is."
            )
            .font(AgentFont.caption)
            .foregroundStyle(.secondary)
            .wrapsLines()
            ForEach(workspace.deployment.linkedDestinations) { destination in
                HStack(spacing: Space.lg) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(
                        "\(destination.surface.client?.rawValue ?? destination.surface.displayName) · \(destination.projectName ?? destination.scope.displayName)"
                    )
                    .font(AgentFont.bodyMedium)
                    Spacer(minLength: Space.lg)
                    LocationText(path: destination.path)
                }
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .standardPanel()
    }

    // MARK: - Derived

    private var summary: String {
        "Each app is handled on its own, and nothing else in its folder is touched."
    }

    /// Where the steps land: the scopes the plan's steps are in, then the
    /// apps, as a person names them.
    private var appliesTo: String {
        let apps = review.groups.map(\.client.rawValue)
        return apps.isEmpty ? "Nothing on this Mac" : (review.scopes.map(\.displayName) + apps).joined(separator: " · ")
    }

    private var planRunsCommands: Bool {
        review.groups.contains { $0.steps.contains { $0.isChange && $0.action.runsAppsOwnTool } }
    }

    private var executionLabel: String {
        switch review.phase {
        case .preparing: return "Checking safety"
        case .failed: return "Review unavailable"
        case .ready, .stale, .running, .finished, .notRun:
            if review.isBlocked { return "Blocked" }
        }
        return planRunsCommands ? "Review required" : "Ready to run"
    }

    private func exclusionTitle(_ reason: WorkspaceDeploymentExclusionReason) -> String {
        switch reason {
        case .missingContent: "No verified copy in your library"
        case .trackedOwnership: "Recorded only"
        case .packageMember: "Comes with its plugin"
        case .missingNativeRoute: "No install route on this Mac"
        case .unsupportedByAdapter: "This app version cannot do it"
        case .unknownClientVersion: "App version unknown"
        case .noDestination: "No destination on this Mac"
        case .needsAssignmentReview: "Needs review first"
        case .alreadyPresent: "Already there"
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
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: symbol)
                .font(AgentFont.caption)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(AgentFont.captionSemibold)
                if let message {
                    Text(message)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
                content
            }
            Spacer(minLength: 0)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(Opacity.noticeWash), in: RoundedRectangle.control)
        .overlay {
            RoundedRectangle.control
                .strokeBorder(tint.opacity(Opacity.noticeStroke), lineWidth: Hairline.width)
        }
        .padding(.top, Space.xxs)
    }
}

/// Content-scan findings, shown in the same review as the approve button so
/// the operator decides with the finding in front of them (the shared sheet
/// and the stage's panel). Nothing is dropped or filtered on their behalf.
struct PlanContentRiskPanel: View {
    let report: ContentRiskReport

    var body: some View {
        PlanFindingPanel(
            symbol: "doc.text.magnifyingglass",
            tint: report.maliciousCount > 0 ? AgentTheme.failure : AgentTheme.warning,
            title: report.headline
        ) {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(report.findings.prefix(Self.listLimit)) { finding in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        HStack(spacing: Space.sm) {
                            Image(systemName: finding.category.symbolName)
                                .font(AgentFont.micro)
                                .foregroundStyle(.secondary)
                            Text("\(finding.severity.displayName) · \(finding.headline)")
                                .font(AgentFont.captionMedium)
                        }
                        Text(finding.location)
                            .font(AgentFont.mono)
                            .foregroundStyle(.tertiary)
                        Text(finding.evidence)
                            .font(AgentFont.mono)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Text(finding.guidance)
                            .font(AgentFont.micro)
                            .foregroundStyle(.secondary)
                            .wrapsLines()
                    }
                }
                if report.findings.count > Self.listLimit {
                    Text("and \(report.findings.count - Self.listLimit) more findings")
                        .font(AgentFont.micro)
                        .foregroundStyle(.tertiary)
                }
                ForEach(report.coverageNotes.prefix(Self.listLimit), id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(AgentFont.micro)
                        .foregroundStyle(.secondary)
                        .wrapsLines()
                }
            }
        }
    }

    private static let listLimit = 8
}

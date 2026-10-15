import AgentToolingCore
import SwiftUI

/// Reviews one untrusted integration request before the app turns it into
/// managed desired state or an immutable operation plan. This sheet never
/// executes the requested change.
struct PendingRequestReviewSheet: View {
    /// Optional so this sheet can be laid out on its own. Only the skill-draft
    /// route reads it, and only when somebody presses that button.
    @Environment(AppNavigationState.self) private var navigation: AppNavigationState?

    let request: PendingAgentRequest
    /// What the last attempt to approve this request said, when it said no.
    /// Shown here rather than as an alert, so the reason sits beside the fields
    /// it is about.
    var refusal: String?
    var isBusy = false
    let onDefer: () -> Void
    let onReject: () -> Void
    let onContinue: () -> Void

    var body: some View {
        ReviewSheetLayout(size: SheetSize.xlarge) {
            HStack(alignment: .top, spacing: Space.xl) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(AgentFont.titleLarge)
                    .foregroundStyle(AgentTheme.selection)
                    .frame(width: Size.tileLarge, height: Size.tileLarge)
                    .background(AgentTheme.selection.opacity(0.12), in: RoundedRectangle.control)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(request.kind.displayName)
                        .font(AgentFont.titleLarge)
                    Text(request.title)
                        .font(AgentFont.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Pending review")
                    .font(AgentFont.captionMedium)
                    .foregroundStyle(AgentTheme.warning)
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.xs)
                    .background(AgentTheme.warning.opacity(0.11), in: Capsule())
            }
            .padding(Space.xxxl)
        } content: {
            VStack(alignment: .leading, spacing: Space.xl) {
                AttentionBanner(
                    title: "A local client asked for this",
                    message:
                        "Client identity and request text are self-reported. Continuing only asks Agent Tooling to build its own reviewable draft or plan; it does not approve or run the change."
                )

                if isSkillDraft {
                    AttentionBanner(
                        title: "This asks for a skill that does not exist yet",
                        message:
                            "Opening the creator runs Codex in an isolated draft folder. Your library is unchanged until you have read the generated files and saved them, and this request stays in the queue until you do."
                    )
                }

                if let refusal {
                    AttentionBanner(title: "Nothing was approved", message: refusal)
                }

                VStack(alignment: .leading, spacing: Space.lg) {
                    detailRow("Request", value: request.summary)
                    detailRow("Apps", value: request.targets.map(\.rawValue).joined(separator: ", "))
                    detailRow("Scope", value: request.scope.displayName)
                    if let componentID = request.componentID {
                        detailRow("Component", value: componentID, monospaced: true)
                    }
                    if let reason = request.reason, !reason.isEmpty {
                        detailRow("Reason", value: reason)
                    }
                    detailRow(
                        "Requested by", value: request.requestedByLabels.joined(separator: ", "))
                    if request.repeatCount > 1 {
                        detailRow(
                            "Repeated",
                            value:
                                "\(request.repeatCount) matching requests · last \(request.lastRequestedAt.formatted(.relative(presentation: .named)))"
                        )
                    }
                }
                .padding(Space.xl)
                .standardPanel()

                if hasSensitiveDetails {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        Label("Local review details", systemImage: "lock.macwindow")
                            .font(AgentFont.heading)
                        Text(
                            "These fields are shown only in the app and are not returned by the integration server."
                        )
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        if let kind = request.reviewDetails.componentKind {
                            detailRow("Type", value: kind)
                        }
                        if let transport = request.reviewDetails.transport {
                            detailRow("Transport", value: transport)
                        }
                        if let endpoint = request.reviewDetails.endpoint {
                            detailRow("Endpoint or command", value: endpoint, monospaced: true)
                        }
                        if let projectRoot = request.reviewDetails.projectRoot {
                            detailRow("Project", value: projectRoot, monospaced: true)
                        }
                        if let source = request.reviewDetails.source {
                            detailRow("Catalog source", value: source)
                        }
                        if let instruction = request.reviewDetails.instruction {
                            detailRow("Instruction", value: instruction)
                        }
                    }
                    .padding(Space.xl)
                    .standardPanel()
                }
            }
            .padding(Space.xxxl)
        } footer: {
            HStack(spacing: Space.lg) {
                Button("Not Now", action: onDefer)
                    .secondaryActionStyle()
                    .keyboardShortcut(.cancelAction)
                    .help("Keep the request in the queue and close this review")
                Button("Reject Request", role: .destructive, action: onReject)
                    .secondaryActionStyle()
                    .disabled(isBusy)
                    .help("Remove this request without changing any client")
                Spacer()
                if isSkillDraft {
                    // A skill nobody has written yet cannot be assigned, so
                    // this request has no approval to give. It opens the
                    // creator instead, and stays in the queue until a draft
                    // made from it is accepted.
                    Button("Create with Codex…", action: openCreator)
                        .primaryActionStyle()
                        .keyboardShortcut(.defaultAction)
                        .disabled(isBusy)
                        .help("Opens the Codex creator on this request; nothing is created until you accept the draft")
                } else {
                    Button("Continue to App Review", action: onContinue)
                        .primaryActionStyle()
                        .keyboardShortcut(.defaultAction)
                        .disabled(isBusy)
                        .help("Build an app-owned draft or plan; no change runs yet")
                }
            }
        }
        .background(AgentTheme.contentBackground)
        .interactiveDismissDisabled(isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review \(request.kind.displayName) request")
    }

    /// A request to write a skill that does not exist yet. Approving one would
    /// have nothing to assign, so it is routed to the creator rather than to
    /// the assignment path every other request kind takes.
    private var isSkillDraft: Bool { request.kind == .createSkill }

    /// Closes this review first, then asks the window for the creator on the
    /// next turn, so the queued route is handed back exactly once before the
    /// new one is made.
    private func openCreator() {
        guard let navigation else { return }
        let id = request.id
        // A route that opened this review is handed back before the new one is
        // made, so asking for the creator cannot reopen the review behind it.
        navigation.consumePendingRequest(id)
        onDefer()
        Task { @MainActor in navigation.openSkillCreationRequest(id) }
    }

    private var hasSensitiveDetails: Bool {
        let details = request.reviewDetails
        return details.projectRoot != nil || details.endpoint != nil || details.transport != nil
            || details.source != nil || details.instruction != nil || details.componentKind != nil
    }

    @ViewBuilder
    private func detailRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xxl) {
            Text(label)
                .font(AgentFont.captionMedium)
                .foregroundStyle(.secondary)
                .frame(width: Size.compactLabelColumn, alignment: .trailing)
            if monospaced {
                Text(value)
                    .font(AgentFont.monoBody)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(value)
                    .font(AgentFont.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

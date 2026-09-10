import AgentToolingCore
import SwiftUI

/// Reviews one untrusted integration request before the app turns it into
/// managed desired state or an immutable operation plan. This sheet never
/// executes the requested change.
struct PendingRequestReviewSheet: View {
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
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.title2)
                    .foregroundStyle(AgentTheme.blue)
                    .frame(width: 38, height: 38)
                    .background(AgentTheme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.kind.displayName)
                        .font(.title2.weight(.semibold))
                    Text(request.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Pending review")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AgentTheme.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AgentTheme.warning.opacity(0.11), in: Capsule())
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AttentionBanner(
                        title: "A local client asked for this",
                        message:
                            "Client identity and request text are self-reported. Continuing only asks Agent Tooling to build its own reviewable draft or plan; it does not approve or run the change."
                    )

                    if let refusal {
                        AttentionBanner(title: "Nothing was approved", message: refusal)
                    }

                    VStack(alignment: .leading, spacing: 12) {
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
                    .padding(16)
                    .standardPanel()

                    if hasSensitiveDetails {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Local review details", systemImage: "lock.macwindow")
                                .font(.headline)
                            Text(
                                "These fields are shown only in the app and are not returned by the integration server."
                            )
                            .font(.caption)
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
                        .padding(16)
                        .standardPanel()
                    }
                }
                .padding(24)
            }

            Divider()
            HStack(spacing: 10) {
                Button("Not Now", action: onDefer)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .help("Keep the request in the queue and close this review")
                Button("Reject Request", role: .destructive, action: onReject)
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                    .help("Remove this request without changing any client")
                Spacer()
                Button("Continue to App Review", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
                    .help("Build an app-owned draft or plan; no change runs yet")
            }
            .padding(.horizontal, 24)
            .frame(height: 76)
        }
        .frame(width: 760, height: 650)
        .background(AgentTheme.contentBackground)
        .interactiveDismissDisabled(isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review \(request.kind.displayName) request")
    }

    private var hasSensitiveDetails: Bool {
        let details = request.reviewDetails
        return details.projectRoot != nil || details.endpoint != nil || details.transport != nil
            || details.source != nil || details.instruction != nil || details.componentKind != nil
    }

    @ViewBuilder
    private func detailRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .trailing)
            if monospaced {
                Text(value)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(value)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

import AgentToolingCore
import SwiftUI

/// Apps: what this Mac would change in each client, and the reviewed step that
/// changes it. Requested assignment is never rendered here as installation;
/// installing stays the separate decision this screen asks for.
///
/// The screen itself draws; this file only decides what is on top of it. Two
/// things can be: one untrusted request somebody is reading, and one prepared
/// plan somebody is approving. Neither opens itself.
struct ClientsSection: View {
    let workspace: WorkspaceLaunch.Workspace

    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.pendingRequestQueue) private var queue
    @State private var requests: WorkspaceRequestSession?
    @State private var reviewedRequest: PendingAgentRequest?
    @State private var refusal: String?
    @State private var isReviewingPlan = false
    @State private var isPreparing = false
    /// The request whose sheet is on screen, so closing it hands the queued
    /// route back exactly once.
    @State private var presentedRequestID: UUID?

    var body: some View {
        Group {
            if let requests {
                SyncCenterView(
                    workspace: workspace,
                    requests: requests,
                    client: scopedClient,
                    onShowAllClients: { navigation.showAllClients() },
                    onReviewChanges: { isPreparing = true },
                    onReviewRequest: { present($0) })
            } else {
                ProgressView("Opening your apps…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if requests == nil {
                requests = WorkspaceRequestSession(
                    store: workspace.store, library: workspace.library,
                    device: workspace.device, queue: queue)
            }
        }
        // Preparing reads; it writes nothing. The sheet opens on what it found,
        // and approving it is still a separate decision inside the sheet.
        .task(id: isPreparing) {
            guard isPreparing else { return }
            await workspace.deployment.prepare()
            isPreparing = false
            if workspace.deployment.plan != nil { isReviewingPlan = true }
        }
        .onAppear(perform: applyRequestedRoute)
        .onChange(of: navigation.revision) { _, _ in applyRequestedRoute() }
        .sheet(item: $reviewedRequest, onDismiss: finishRequestPresentation) { request in
            PendingRequestReviewSheet(
                request: request,
                refusal: refusal,
                isBusy: requests?.isBusy == true,
                onDefer: { reviewedRequest = nil },
                onReject: {
                    Task {
                        guard let requests, await requests.reject(request) else {
                            refusal = requests?.errorMessage
                            return
                        }
                        reviewedRequest = nil
                    }
                },
                onContinue: {
                    Task {
                        guard let requests else { return }
                        switch await requests.accept(request) {
                        case .assignmentSaved:
                            reviewedRequest = nil
                            // What was asked for is now recorded. Installing it
                            // is the next, separate decision, so the plan for it
                            // is prepared and shown rather than run.
                            isPreparing = true
                        case .refused(let reason):
                            refusal = reason
                        }
                    }
                })
        }
        .sheet(isPresented: $isReviewingPlan) {
            if let plan = workspace.deployment.plan {
                PlanReviewSheet(workspace: workspace, plan: plan)
            } else {
                // The plan went away while the sheet was open, which is what a
                // failed check looks like. Say so rather than showing a blank
                // sheet somebody would read as an empty plan.
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: "There is nothing to review",
                    message: workspace.deployment.errorMessage
                        ?? "This Mac's apps could not be checked. Nothing was changed.",
                    actionTitle: "Close",
                    action: { isReviewingPlan = false }
                )
                .frame(width: 480, height: 320)
                .background(AgentTheme.contentBackground)
            }
        }
    }

    /// The client this visit is scoped to, and only while this Mac still manages
    /// it. A scope on an app nobody manages would hide everything.
    private var scopedClient: ClientKind? {
        navigation.selectedClient.flatMap { workspace.device.isEnabled($0) ? $0 : nil }
    }

    /// A route that names one request opens it, once. Opening is not approving.
    private func applyRequestedRoute() {
        guard reviewedRequest == nil, let id = navigation.requestedPendingRequestID else { return }
        Task {
            guard let requests else { return }
            guard let request = await requests.request(id: id) else {
                navigation.consumePendingRequest(id)
                return
            }
            present(request)
        }
    }

    private func present(_ request: PendingAgentRequest) {
        refusal = nil
        presentedRequestID = request.id
        reviewedRequest = request
    }

    private func finishRequestPresentation() {
        if let id = presentedRequestID { navigation.consumePendingRequest(id) }
        presentedRequestID = nil
        refusal = nil
    }
}

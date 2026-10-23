import AgentToolingCore
import Observation
import SwiftUI

/// Apps: what this Mac would change in each client, and the reviewed step that
/// changes it. Requested assignment is never rendered here as installation;
/// installing stays the separate decision this screen asks for.
///
/// The review queue is the workspace's, not this screen's, so a request Home
/// counted is the request decided here and deciding it changes both.
///
/// The screen itself draws; this file only decides what is on top of it. Two
/// things can be: one untrusted request somebody is reading, and one prepared
/// plan somebody is approving. Neither opens itself.
struct ClientsSection: View {
    let workspace: WorkspaceLaunch.Workspace

    @Environment(AppNavigationState.self) private var navigation
    @State private var presentation = ClientReviewPresentation()

    var body: some View {
        @Bindable var presentation = presentation
        SyncCenterView(
            workspace: workspace,
            requests: workspace.requests,
            client: scopedClient,
            onShowAllClients: { navigation.showAllClients() },
            onReviewChanges: { presentation.isPreparing = true },
            onReviewRequest: { present($0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Preparing reads; it writes nothing. The sheet opens on what it found,
        // and approving it is still a separate decision inside the sheet.
        .task(id: presentation.isPreparing) {
            guard presentation.isPreparing else { return }
            await workspace.deployment.prepare()
            // The route that asked for this is answered now, plan or not. It
            // stayed asked until here so a task restarted mid-way (SwiftUI does
            // that at launch) found it waiting and joined the same preparation.
            navigation.consumeScreenRequest(.reviewChanges)
            presentation.prepared(hasPlan: workspace.deployment.plan != nil)
        }
        .onAppear(perform: applyRequestedRoute)
        .onChange(of: navigation.revision) { _, _ in applyRequestedRoute() }
        .onChange(of: navigation.requestedPendingRequestID) { _, _ in applyRequestedRoute() }
        .onChange(of: presentation.isPreparing) { _, preparing in
            if !preparing { applyRequestedRoute() }
        }
        .onChange(of: workspace.requests.isBusy) { _, busy in
            if !busy { applyRequestedRoute() }
        }
        // An install changed what the apps hold, so the next thing every screen
        // says about "found" should come from a fresh check, not the last one.
        .onChange(of: workspace.deployment.results.count) { _, _ in
            Task { await workspace.device.refresh() }
        }
        .sheet(item: $presentation.reviewedRequest, onDismiss: finishRequestPresentation) { request in
            PendingRequestReviewSheet(
                request: request,
                refusal: presentation.refusal,
                isBusy: workspace.requests.isBusy,
                draftingClient: presentation.draftingClient,
                onDefer: { presentation.reviewedRequest = nil },
                onReject: {
                    Task {
                        guard await workspace.requests.reject(request) else {
                            presentation.refusal = workspace.requests.errorMessage
                            return
                        }
                        presentation.reviewedRequest = nil
                    }
                },
                onContinue: {
                    Task {
                        switch await workspace.requests.accept(request) {
                        case .assignmentSaved:
                            // What was asked for is now recorded. Installing it
                            // is the next, separate decision, so the plan for it
                            // is prepared and shown rather than run.
                            presentation.acceptedRequest()
                        case .refused(let reason):
                            presentation.refusal = reason
                        }
                    }
                })
        }
        .sheet(isPresented: $presentation.isReviewingPlan, onDismiss: finishPlanPresentation) {
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
                    action: { presentation.isReviewingPlan = false }
                )
                .sheetSize(SheetSize.small)
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
        // Arriving here from "Install now" elsewhere: prepare the plan and open
        // it, exactly as pressing Review Changes on this screen does.
        if navigation.requestedScreenRequest == .reviewChanges {
            presentation.isPreparing = true
        }
        guard !workspace.requests.isBusy,
            let id = navigation.requestedPendingRequestID,
            presentation.beginRequestLoad(id)
        else { return }
        Task {
            let request = await workspace.requests.request(id: id)
            let client: ClientKind? = if let request { await workspace.requests.draftingClient(for: request) } else { nil }
            presentation.finishRequestLoad(id)
            guard navigation.requestedPendingRequestID == id else {
                applyRequestedRoute()
                return
            }
            guard let request else {
                navigation.consumePendingRequest(id)
                applyRequestedRoute()
                return
            }
            presentation.present(request, draftingClient: client)
        }
    }

    private func present(_ request: PendingAgentRequest) {
        guard presentation.beginRequestLoad(request.id) else { return }
        Task {
            let client = await workspace.requests.draftingClient(for: request)
            presentation.finishRequestLoad(request.id)
            presentation.present(request, draftingClient: client)
        }
    }

    private func finishRequestPresentation() {
        if let id = presentation.finishRequestPresentation() { navigation.consumePendingRequest(id) }
        applyRequestedRoute()
    }

    private func finishPlanPresentation() {
        presentation.finishPlanPresentation()
        applyRequestedRoute()
    }
}

/// A request, its closing animation, and its resulting plan occupy one review
/// slot. A second queued request waits until all three have finished.
@MainActor @Observable
final class ClientReviewPresentation {
    var reviewedRequest: PendingAgentRequest?
    var refusal: String?
    private(set) var draftingClient: ClientKind?
    var isReviewingPlan = false
    var isPreparing = false
    private(set) var presentedRequestID: UUID?
    private(set) var loadingRequestID: UUID?
    private var planIsPresented = false

    func beginRequestLoad(_ id: UUID) -> Bool {
        guard canPresentRequest else { return false }
        loadingRequestID = id
        return true
    }

    func finishRequestLoad(_ id: UUID) {
        if loadingRequestID == id { loadingRequestID = nil }
    }

    func present(_ request: PendingAgentRequest, draftingClient: ClientKind? = nil) {
        guard canPresentRequest else { return }
        refusal = nil
        presentedRequestID = request.id
        self.draftingClient = draftingClient
        reviewedRequest = request
    }

    func acceptedRequest() {
        isPreparing = true
        reviewedRequest = nil
    }

    func prepared(hasPlan: Bool) {
        planIsPresented = hasPlan
        isReviewingPlan = hasPlan && presentedRequestID == nil
        isPreparing = false
    }

    func finishRequestPresentation() -> UUID? {
        let id = presentedRequestID
        presentedRequestID = nil
        draftingClient = nil
        refusal = nil
        if planIsPresented { isReviewingPlan = true }
        return id
    }

    func finishPlanPresentation() {
        isReviewingPlan = false
        planIsPresented = false
    }

    private var canPresentRequest: Bool {
        reviewedRequest == nil && presentedRequestID == nil && loadingRequestID == nil
            && !isPreparing && !isReviewingPlan && !planIsPresented
    }
}

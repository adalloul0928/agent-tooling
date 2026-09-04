import AgentToolingCore
import SwiftUI

struct AppShellView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @State private var selection: AppSection
    @State private var paletteVisible = false
    @State private var screenRequest: ScreenRequest?
    @State private var pendingRequestReview: PendingAgentRequest?
    @State private var pendingRequestContinuation: PendingRequestContinuation?
    @State private var presentedPendingRequestID: UUID?
    @State private var requestPresentationActive = false

    init(initialSelection: AppSection = .overview) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        ZStack {
            // The window's own material, and nothing painted over it behind the
            // sidebar: like the Dock, the sidebar is a blurred view of whatever
            // is actually behind the window.
            if reduceTransparency {
                AgentTheme.contentBackground.ignoresSafeArea()
            } else {
                DesktopGlassBackground().ignoresSafeArea()
            }

            HStack(spacing: 0) {
                SidebarView(
                    selection: $selection,
                    isCollapsed: $sidebarCollapsed,
                    openPalette: { paletteVisible = true }
                )

                // Swap heavy screens immediately. Navigation feedback lives in
                // the sidebar selection pill, so changing sections never keeps
                // two list/detail hierarchies alive for a crossfade.
                destination
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .paperPane()
            }
            // The title bar is hidden, so its safe area would otherwise inset
            // the content pane at the top and nowhere else. The sidebar keeps
            // its own inset for the traffic lights.
            .ignoresSafeArea(edges: .top)
            .sheet(isPresented: $paletteVisible) {
                CommandPaletteView(
                    onActivate: { outcome in
                        paletteVisible = false
                        DispatchQueue.main.async { activate(outcome) }
                    },
                    onClose: { paletteVisible = false }
                )
                .environment(model)
            }
        }
        .foregroundStyle(.primary)
        .tint(AgentTheme.blue)
        .buttonBorderShape(.capsule)
        .animation(reduceMotion ? nil : AgentMotion.selection, value: sidebarCollapsed)
        .groupBoxStyle(ControlGroupBoxStyle())
        .task {
            await model.bootstrap()
        }
        .onAppear { applyExternalNavigation() }
        .onChange(of: navigation.revision) { _, _ in applyExternalNavigation() }
        .onChange(of: selection) { _, section in
            if let request = screenRequest, request.section != section {
                screenRequest = nil
            }
        }
        .sheet(item: $pendingRequestReview, onDismiss: finishPendingRequestPresentation) { request in
            PendingRequestReviewSheet(
                request: request,
                onDefer: { pendingRequestReview = nil },
                onReject: {
                    guard
                        model.rejectPendingRequest(
                            id: request.id,
                            expectedFingerprint: request.fingerprint
                        )
                    else { return }
                    pendingRequestReview = nil
                },
                onContinue: {
                    guard
                        let continuation = model.acceptPendingRequest(
                            id: request.id,
                            expectedFingerprint: request.fingerprint
                        )
                    else { return }
                    pendingRequestContinuation = continuation
                    pendingRequestReview = nil
                }
            )
        }
        .sheet(item: pendingPlanBinding) { plan in
            PlanReviewSheet(plan: plan)
                .environment(model)
        }
        .alert("Agent Tooling", isPresented: errorPresented) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.lastError ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch selection {
        case .overview: OverviewView(navigate: { selection = $0 })
        case .marketplace: MarketplaceView(request: $screenRequest)
        case .skills: SkillsView(navigate: { selection = $0 })
        case .insights: InsightsView()
        case .mcpServers: MCPServersView(request: $screenRequest)
        case .plugins: PluginsView(navigate: { selection = $0 }, request: $screenRequest)
        case .collections: CollectionsView()
        case .profiles: ProfilesView(request: $screenRequest)
        case .syncCenter:
            SyncCenterView(
                client: navigation.selectedClient,
                onShowAllClients: { navigation.showAllClients() }
            )
        case .activity: ActivityView(request: $screenRequest)
        case .projects: ProjectsView()
        case .accounts: AccountsView(request: $screenRequest)
        case .settings: SettingsView()
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.dismissError() } }
        )
    }

    private var pendingPlanBinding: Binding<OperationPlan?> {
        Binding(
            get: { requestPresentationActive ? nil : model.pendingPlan },
            set: { if $0 == nil { model.discardPendingPlan() } }
        )
    }

    private func applyExternalNavigation() {
        if let requestedSection = navigation.requestedSection {
            selection = requestedSection
            navigation.consumeRequestedSection(requestedSection)
        }
        guard !requestPresentationActive, let requestID = navigation.requestedPendingRequestID else { return }
        guard let request = model.pendingRequest(id: requestID) else {
            navigation.consumePendingRequest(requestID)
            return
        }
        presentedPendingRequestID = requestID
        requestPresentationActive = true
        pendingRequestReview = request
    }

    private func finishPendingRequestPresentation() {
        if let requestID = presentedPendingRequestID {
            navigation.consumePendingRequest(requestID)
        }
        presentedPendingRequestID = nil
        requestPresentationActive = false

        let continuation = pendingRequestContinuation
        pendingRequestContinuation = nil
        if case .skillCreation(let requestID) = continuation {
            navigation.openSkillCreationRequest(requestID)
        }
        DispatchQueue.main.async { applyExternalNavigation() }
    }

    /// A palette result runs the screen's own action. Anything that touches a
    /// client still arrives as a plan in the review sheet.
    private func activate(_ outcome: CommandPaletteOutcome) {
        switch outcome {
        case .navigate(let section):
            if section == .syncCenter {
                navigation.showAllClients()
            } else {
                selection = section
            }
        case .openClient(let client):
            navigation.openClient(client)
        case .screenRequest(let request):
            selection = request.section
            screenRequest = request
        case .openSkill(let id):
            navigation.open(.skill(id))
        case .openMarketplacePackage(let id):
            navigation.openMarketplacePackage(id)
        case .runDoctor:
            Task { await model.runDoctor() }
        case .runSync:
            Task { await model.runSync() }
        case .refreshMarketplace:
            Task { await model.refreshMarketplace() }
        }
    }
}

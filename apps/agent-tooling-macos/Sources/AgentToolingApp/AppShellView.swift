import AgentToolingCore
import SwiftUI

struct AppShellView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("onboarding.completed.v1") private var onboardingCompleted = false
    @AppStorage("onboarding.presented.v1") private var onboardingPresented = false
    @State private var showingOnboarding = false
    @State private var selection: AppSection
    @State private var paletteVisible = false
    @State private var screenRequest: ScreenRequest?
    @State private var pendingRequestReview: PendingAgentRequest?
    @State private var pendingRequestContinuation: PendingRequestContinuation?
    @State private var presentedPendingRequestID: UUID?
    @State private var requestPresentationActive = false
    @State private var workspaceMigration: WorkspaceMigrationSetupSession?
    let onWorkspaceAuthorityChanged: () -> Void

    init(initialSelection: AppSection = .overview, onWorkspaceAuthorityChanged: @escaping () -> Void = {}) {
        _selection = State(initialValue: initialSelection)
        self.onWorkspaceAuthorityChanged = onWorkspaceAuthorityChanged
    }

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(
                selection: $selection,
                isCollapsed: $sidebarCollapsed,
                openPalette: { paletteVisible = true }
            )
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            destination
                .environment(\.startOnboarding, presentOnboarding)
                .environment(\.reviewWorkspaceMigration, presentWorkspaceMigration)
                .environment(\.workspaceSelection, selection)
                .environment(
                    \.workspaceNavigate,
                    { section in
                        if section == .syncCenter { navigation.showAllClients() }
                        selection = section
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AgentTheme.contentBackground, ignoresSafeAreaEdges: [.top, .bottom, .trailing])
        }
        .navigationSplitViewStyle(.balanced)
        .background(WindowBackdropMaterial().ignoresSafeArea())
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
        .foregroundStyle(.primary)
        .animation(reduceMotion ? nil : AgentMotion.selection, value: sidebarCollapsed)
        .groupBoxStyle(ControlGroupBoxStyle())
        .task {
            let hasExistingSetup = !model.skills.isEmpty || !model.plugins.isEmpty || !model.mcpServers.isEmpty
            await model.bootstrap()
            if OnboardingPresentationPolicy.shouldPresent(
                completed: onboardingCompleted, presented: onboardingPresented,
                hasExistingSetup: hasExistingSetup,
                anotherPresentationActive: paletteVisible || requestPresentationActive || model.isInteractionLocked
                    || navigation.requestedSection != nil || navigation.requestedPendingRequestID != nil
            ) {
                presentOnboarding()
            }
        }
        .sheet(isPresented: $showingOnboarding, onDismiss: applyExternalNavigation) {
            OnboardingWizard(onNavigate: { section in
                if section == .syncCenter { navigation.showAllClients() }
                selection = section
            })
            .environment(model)
        }
        .sheet(item: $workspaceMigration) { session in
            WorkspaceMigrationSetupView(session: session, onCancel: {
                let returnedToLegacy = model.endWorkspaceMigrationReview()
                workspaceMigration = nil
                if !returnedToLegacy { onWorkspaceAuthorityChanged() }
            }, onAuthorityChanged: {
                workspaceMigration = nil
                // Keep the retired model gated until the root opens the saved
                // authority through its normal, validated startup path.
                onWorkspaceAuthorityChanged()
            })
        }
        .onAppear { applyExternalNavigation() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Client settings may have changed outside the app. Refresh their
            // cached status off the main thread when returning to this window.
            Task { await model.refreshSkillAvailability() }
        }
        .onChange(of: model.enabledClients) { _, _ in
            if let client = navigation.selectedClient, !model.isClientEnabled(client) { navigation.showAllClients() }
        }
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
        case .overview:
            OverviewView(
                navigate: { selection = $0 },
                onOpenPlugin: { id in
                    selection = .plugins
                    screenRequest = .selectPlugin(id)
                }
            )
        case .marketplace: MarketplaceView(request: $screenRequest)
        case .skills: SkillsView(navigate: { selection = $0 })
        case .insights: InsightsView()
        case .mcpServers: MCPServersView(request: $screenRequest)
        case .plugins: PluginsView(navigate: { selection = $0 }, request: $screenRequest)
        case .collections: CollectionsView()
        case .profiles: ProfilesView(request: $screenRequest)
        case .syncCenter:
            SyncCenterView(
                client: navigation.selectedClient.flatMap { model.isClientEnabled($0) ? $0 : nil },
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

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarCollapsed ? .detailOnly : .all },
            set: { sidebarCollapsed = $0 == .detailOnly }
        )
    }

    private var pendingPlanBinding: Binding<OperationPlan?> {
        Binding(
            get: { requestPresentationActive || showingOnboarding ? nil : model.pendingPlan },
            set: { if $0 == nil && !showingOnboarding { model.discardPendingPlan() } }
        )
    }

    private func presentOnboarding() {
        guard !model.isInteractionLocked, !requestPresentationActive else { return }
        onboardingPresented = true
        showingOnboarding = true
    }

    private func presentWorkspaceMigration() {
        guard !showingOnboarding, !paletteVisible, !requestPresentationActive,
              workspaceMigration == nil, let location = model.beginWorkspaceMigrationReview() else { return }
        workspaceMigration = WorkspaceMigrationSetupSession(location: location)
    }

    private func applyExternalNavigation() {
        guard !showingOnboarding, workspaceMigration == nil else { return }
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

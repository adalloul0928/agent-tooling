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

                destination
                    .id(selection)
                    .transition(reduceMotion ? .identity : .opacity)
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: selection)
        .animation(reduceMotion ? nil : .snappy(duration: 0.20), value: sidebarCollapsed)
        .groupBoxStyle(ControlGroupBoxStyle())
        .task {
            await model.bootstrap()
        }
        .onAppear { applyExternalNavigation() }
        .onChange(of: navigation.revision) { _, _ in applyExternalNavigation() }
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
        case .marketplace: MarketplaceView()
        case .skills: SkillsView(navigate: { selection = $0 })
        case .insights: InsightsView()
        case .mcpServers: MCPServersView(request: $screenRequest)
        case .plugins: PluginsView(navigate: { selection = $0 }, request: $screenRequest)
        case .collections: CollectionsView()
        case .profiles: ProfilesView()
        case .syncCenter: SyncCenterView()
        case .activity: ActivityView()
        case .projects: ProjectsView()
        case .accounts: AccountsView()
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
            get: { model.pendingPlan },
            set: { if $0 == nil { model.discardPendingPlan() } }
        )
    }

    private func applyExternalNavigation() {
        if let requestedSection = navigation.requestedSection {
            selection = requestedSection
        }
    }

    /// A palette result runs the screen's own action. Anything that touches a
    /// client still arrives as a plan in the review sheet.
    private func activate(_ outcome: CommandPaletteOutcome) {
        switch outcome {
        case .navigate(let section):
            selection = section
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

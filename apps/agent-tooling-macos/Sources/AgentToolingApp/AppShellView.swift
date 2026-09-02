import AgentToolingCore
import SwiftUI

struct AppShellView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @State private var selection: AppSection

    init(initialSelection: AppSection = .overview) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        ZStack {
            if reduceTransparency {
                AgentTheme.contentBackground.ignoresSafeArea()
            } else {
                DesktopGlassBackground().ignoresSafeArea()
                AmbientBackdrop().opacity(0.92)
            }

            HStack(spacing: 0) {
                SidebarView(selection: $selection, isCollapsed: $sidebarCollapsed)

                destination
                    .id(selection)
                    .transition(reduceMotion ? .identity : .opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .paperPane()
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
        case .mcpServers: MCPServersView()
        case .plugins: PluginsView(navigate: { selection = $0 })
        case .profiles: ProfilesView()
        case .syncCenter: SyncCenterView()
        case .activity: ActivityView()
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
}

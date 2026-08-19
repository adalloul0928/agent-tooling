import AgentToolingCore
import SwiftUI

struct AppShellView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @State private var selection: AppSection

    init(initialSelection: AppSection = .overview) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        ZStack {
            DesktopGlassBackground()
                .opacity(AgentTheme.desktopGlassOpacity)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarView(selection: $selection, isCollapsed: $sidebarCollapsed)

                Rectangle()
                    .fill(AgentTheme.separator.opacity(0.48))
                    .frame(width: 0.5)

                destination
                    .id(selection)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AgentTheme.contentBackground.opacity(0.88))
            }
        }
        .foregroundStyle(.primary)
        .tint(AgentTheme.blue)
        .animation(.easeInOut(duration: 0.16), value: selection)
        .animation(.snappy(duration: 0.22), value: sidebarCollapsed)
        .groupBoxStyle(ControlGroupBoxStyle())
        .task {
            await model.bootstrap()
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
        case .marketplace: MarketplaceView()
        case .skills: SkillsView()
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
}

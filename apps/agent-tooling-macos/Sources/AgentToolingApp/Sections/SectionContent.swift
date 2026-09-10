import SwiftUI

/// The one place a section identity becomes a screen.
///
/// Every case names a view that owns its whole pane, so restoring a screen is a
/// change to one file and never to the shell. Nothing is threaded through here
/// but the workspace: a screen that has to reach another screen asks
/// `AppNavigationState`, which the shell puts in the environment.
struct SectionContent: View {
    let section: AppSection
    let workspace: WorkspaceLaunch.Workspace

    var body: some View {
        switch section {
        case .overview: HomeSection(workspace: workspace)
        case .skills: SkillsSection(workspace: workspace)
        case .plugins: PluginsSection(workspace: workspace)
        case .mcpServers: MCPServersSection(workspace: workspace)
        case .presets: PresetsSection(workspace: workspace)
        case .marketplace: DiscoverSection(workspace: workspace)
        case .projects: ProjectsSection(workspace: workspace)
        case .syncCenter: ClientsSection(workspace: workspace)
        case .appSettings: AppSettingsSection(workspace: workspace)
        case .insights: InsightsSection(workspace: workspace)
        case .activity: ActivitySection(workspace: workspace)
        case .history: HistorySection(workspace: workspace)
        case .settings: SettingsSection(workspace: workspace)
        case .sync: SyncSection(workspace: workspace)
        }
    }
}

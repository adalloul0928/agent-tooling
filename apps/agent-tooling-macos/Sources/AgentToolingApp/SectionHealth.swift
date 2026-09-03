import AgentToolingCore
import Foundation

/// One verdict per navigable screen, from state the app has already checked.
/// A healthy app is meant to look quiet, so a section that has nothing to
/// report returns nil and its sidebar row stays undecorated.
extension AppModel {
    func sectionHealth(for section: AppSection) -> HealthState? {
        switch section {
        case .skills: skillsHealth
        case .plugins: pluginsHealth
        case .mcpServers: mcpHealth
        case .profiles: configurationsHealth
        case .accounts: accountsHealth
        case .projects: projectsHealth
        case .overview, .marketplace, .insights, .collections, .syncCenter, .activity, .settings: nil
        }
    }

    /// Only what discovery has actually inspected. Before a scan there is no
    /// verdict to give, and a project carrying no local configuration reports
    /// nothing rather than a reassuring tick it has not earned.
    private var projectsHealth: HealthState? {
        let inspected = projects.compactMap(\.configurationHealth)
        if inspected.contains(.attention) { return .attention }
        if inspected.contains(.pending) { return .pending }
        return nil
    }

    /// The plugin verdicts this app is prepared to stand behind, in list order.
    func pluginUpdateAvailability() -> [(plugin: Plugin, availability: UpdateAvailability)] {
        plugins.map { plugin in
            (plugin, UpdateAvailabilityEvaluator.evaluate(plugin: plugin, sources: sources, packages: marketplacePackages))
        }
    }

    private var skillsHealth: HealthState? {
        let owned = skills.filter(\.owned)
        if owned.contains(where: { $0.clients.contains { $0.state == .attention } }) { return .attention }
        return nil
    }

    /// Update news is the calm pending state; a client that reported a problem
    /// is the only thing here that warrants a warning.
    private var pluginsHealth: HealthState? {
        if plugins.contains(where: { $0.clients.contains { $0.state == .attention } }) { return .attention }
        if pluginUpdateAvailability().contains(where: { $0.availability.hasUpdate }) { return .pending }
        return nil
    }

    private var mcpHealth: HealthState? {
        if mcpServers.contains(where: { $0.aggregateState == .attention }) { return .attention }
        if mcpServers.contains(where: { $0.aggregateState == .unavailable }) { return .unavailable }
        if mcpServers.contains(where: { $0.aggregateState == .pending }) { return .pending }
        return nil
    }

    private var configurationsHealth: HealthState? {
        let checks = activeProfile?.checks ?? []
        if checks.contains(where: { $0.state == .attention }) { return .attention }
        if checks.contains(where: { $0.state == .unavailable }) { return .unavailable }
        return nil
    }

    private var accountsHealth: HealthState? {
        accountSurfaces.contains { $0.status != .verified } ? .pending : nil
    }
}

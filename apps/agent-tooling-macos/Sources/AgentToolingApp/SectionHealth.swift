import AgentToolingCore
import Foundation

/// One verdict per navigable screen, from state the app has already checked.
/// A healthy app is meant to look quiet, so a section that has nothing to
/// report carries no verdict at all and its sidebar row stays undecorated.
/// Nothing here ever answers `.healthy`: a tick the sidebar did not earn reads
/// exactly like one it did.
///
/// This is a value, not a query. It reads an inventory the caller already
/// gathered and touches neither the filesystem nor the network, so drawing the
/// sidebar can never be the thing that starts a scan.
struct SectionHealth: Equatable, Sendable {
    private let verdicts: [AppSection: HealthState]

    init(verdicts: [AppSection: HealthState] = [:]) {
        self.verdicts = verdicts
    }

    /// The verdict for one screen, or nil when it has nothing to report.
    subscript(section: AppSection) -> HealthState? {
        verdicts[section]
    }

    var isQuiet: Bool { verdicts.isEmpty }
}

extension SectionHealth {
    /// Derives the library verdicts from an inventory the caller already holds.
    ///
    /// Update news needs both a source list and a catalog. Given neither, the
    /// plugins verdict says nothing rather than implying everything is current;
    /// `UpdateAvailability` reports its own uncertainty on the row itself.
    init(
        inventory: VersionedInventoryProjection.Inventory,
        projects: [DiscoveredProject] = [],
        sources: [ToolingSource] = [],
        packages: [MarketplacePackage] = []
    ) {
        var verdicts: [AppSection: HealthState] = [:]
        verdicts[.skills] = Self.skillsHealth(inventory.skills)
        verdicts[.plugins] = Self.pluginsHealth(inventory.plugins, sources: sources, packages: packages)
        verdicts[.mcpServers] = Self.mcpHealth(inventory.mcpServers)
        verdicts[.projects] = Self.projectsHealth(projects)
        self.init(verdicts: verdicts)
    }

    /// Only what discovery has actually inspected. Before a scan there is no
    /// verdict to give, and a project carrying no local configuration reports
    /// nothing rather than a reassuring tick it has not earned.
    static func projectsHealth(_ projects: [DiscoveredProject]) -> HealthState? {
        let inspected = projects.compactMap(\.configurationHealth)
        if inspected.contains(.attention) { return .attention }
        if inspected.contains(.pending) { return .pending }
        return nil
    }

    static func skillsHealth(_ skills: [Skill]) -> HealthState? {
        let owned = skills.filter(\.owned)
        if owned.contains(where: { $0.clients.contains { $0.state == .attention } }) { return .attention }
        return nil
    }

    /// Update news is the calm pending state; a client that reported a problem
    /// is the only thing here that warrants a warning.
    static func pluginsHealth(
        _ plugins: [Plugin],
        sources: [ToolingSource],
        packages: [MarketplacePackage]
    ) -> HealthState? {
        if plugins.contains(where: { $0.clients.contains { $0.state == .attention } }) { return .attention }
        let verdicts = pluginUpdateAvailability(plugins: plugins, sources: sources, packages: packages)
        if verdicts.contains(where: { $0.availability.hasUpdate }) { return .pending }
        return nil
    }

    static func mcpHealth(_ servers: [MCPServer]) -> HealthState? {
        if servers.contains(where: { $0.aggregateState == .attention }) { return .attention }
        if servers.contains(where: { $0.aggregateState == .unavailable }) { return .unavailable }
        if servers.contains(where: { $0.aggregateState == .pending }) { return .pending }
        return nil
    }

    /// The plugin verdicts this app is prepared to stand behind, in list order.
    static func pluginUpdateAvailability(
        plugins: [Plugin],
        sources: [ToolingSource],
        packages: [MarketplacePackage]
    ) -> [(plugin: Plugin, availability: UpdateAvailability)] {
        plugins.map { plugin in
            (plugin, UpdateAvailabilityEvaluator.evaluate(plugin: plugin, sources: sources, packages: packages))
        }
    }
}

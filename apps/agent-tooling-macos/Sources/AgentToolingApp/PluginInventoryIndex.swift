import AgentToolingCore
import Foundation

/// Catalog comparisons belong to inventory changes, not table cell rendering.
/// Passing this snapshot to the browser also keeps search and selection from
/// rebuilding every package's supported-client projection.
struct PluginInventoryIndex {
    let plugins: [Plugin]
    let availability: [String: UpdateAvailability]

    init(plugins: [Plugin], connectors: [DiscoveredConnectorRow], sources: [ToolingSource], packages: [MarketplacePackage]) {
        let connectorsByPlugin = Dictionary(connectors.map { ($0.pluginID, $0) }, uniquingKeysWith: { first, _ in first })
        self.plugins = plugins.map { original in
            var plugin = original
            if let connector = connectorsByPlugin[plugin.id] {
                plugin.name = connector.name
                plugin.summary = connector.summary
            }
            plugin.name = ConnectionSource.pluginName(plugin.name, identifier: plugin.id)
            plugin.summary = plugin.summary.replacingOccurrences(of: plugin.id, with: plugin.name)
            return plugin
        }
        self.availability = Dictionary(
            self.plugins.map { ($0.id, UpdateAvailabilityEvaluator.evaluate(plugin: $0, sources: sources, packages: packages)) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

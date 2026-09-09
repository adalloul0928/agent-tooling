import AgentToolingCore
import Foundation

struct ConnectorInventoryRequest: Equatable, Sendable {
    let workspacePath: String
    let plugins: [Plugin]
    let scannedAt: Date?
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
}

/// Plugins and Connections share the same scan. Actor isolation keeps native
/// manifest reads off the UI executor and coalesces repeated navigation into
/// one cached result. A fresh setup scan invalidates even unchanged plugin IDs.
actor ConnectorInventoryCache {
    static let shared = ConnectorInventoryCache()
    private var cachedRequest: ConnectorInventoryRequest?
    private var cachedRecords: [DiscoveredConnectorRow] = []

    func records(for request: ConnectorInventoryRequest) -> [DiscoveredConnectorRow] {
        if request == cachedRequest { return cachedRecords }
        let records = ConnectorInventory.records(plugins: request.plugins, home: request.home)
        cachedRequest = request
        cachedRecords = records
        return records
    }
}

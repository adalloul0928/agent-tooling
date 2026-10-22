import AgentToolingCore
import Foundation

extension PublishedDeviceStatus {
    /// This Mac's summary of itself for the other Macs: what the last scan
    /// found per app, and what the current plan still has to do here. Read from
    /// sessions that already hold the facts; nothing is scanned to build it.
    @MainActor
    static func current(
        device: WorkspaceDeviceSession, library: WorkspaceLibrarySession, deployment: WorkspaceDeploymentSession,
        accounts: WorkspaceAccountsSession? = nil
    ) -> PublishedDeviceStatus? {
        guard let state = library.state else { return nil }
        let registry = state.snapshot.document.deviceRegistry
        let name = registry.first { $0.id == library.deviceID }?.name ?? Host.current().localizedName ?? "This Mac"
        // Agent Tooling's own connection, where this Mac set it up, is how an
        // app reaches this library, not one of its holdings. One somebody
        // made by hand under that name is theirs, and counts.
        let ownConnectionApps = AgentToolingConnection.apps(on: library.deviceID, in: state.snapshot.document)
        let apps = device.managedClients.compactMap { client -> AppSummary? in
            guard let surface = client.userSurface else { return nil }
            let observation = device.observations.first { $0.surface == surface }
            return AppSummary(
                surface: surface,
                installed: observation?.installed ?? false,
                version: observation?.version,
                skillCount: observation?.discoveredSkills.count ?? 0,
                pluginCount: observation?.discoveredPlugins.count ?? 0,
                mcpServerCount: observation?.discoveredMCPServers.count {
                    !(ownConnectionApps.contains(client) && $0 == AgentToolingConnection.declaredName)
                } ?? 0)
        }
        // What will run here: a step left alone is not pending (D6), so other
        // Macs never read it as waiting, and nor is one taking something out.
        let pending = deployment.pendingItems.filter { !$0.isRemoval }.map(\.displayName)
        return PublishedDeviceStatus(
            deviceID: library.deviceID, name: name, lastScan: device.lastCheckedAt,
            apps: apps, pending: Array(Set(pending)).sorted(),
            revisionID: state.snapshot.document.revision.id,
            // How each client signs in and whether it follows the shared
            // choices, never an address or a list of what an account holds.
            accounts: accounts?.publishedSummaries())
    }
}

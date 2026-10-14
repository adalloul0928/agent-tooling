import AgentToolingCore
import Foundation

extension PublishedDeviceStatus {
    /// This Mac's summary of itself for the other Macs: what the last scan
    /// found per app, and what the current plan still has to do here. Read from
    /// sessions that already hold the facts; nothing is scanned to build it.
    @MainActor
    static func current(
        device: WorkspaceDeviceSession, library: WorkspaceLibrarySession, deployment: WorkspaceDeploymentSession
    ) -> PublishedDeviceStatus? {
        guard let state = library.state else { return nil }
        let registry = state.snapshot.document.deviceRegistry
        let name = registry.first { $0.id == library.deviceID }?.name ?? Host.current().localizedName ?? "This Mac"
        let apps = device.managedClients.compactMap { client -> AppSummary? in
            guard let surface = client.userSurface else { return nil }
            let observation = device.observations.first { $0.surface == surface }
            return AppSummary(
                surface: surface,
                installed: observation?.installed ?? false,
                version: observation?.version,
                skillCount: observation?.discoveredSkills.count ?? 0,
                pluginCount: observation?.discoveredPlugins.count ?? 0,
                mcpServerCount: observation?.discoveredMCPServers.count ?? 0)
        }
        let pending = (deployment.plan?.items ?? [])
            .filter { if case .removeContent = $0.action { return false }; return true }
            .map(\.displayName)
        return PublishedDeviceStatus(
            deviceID: library.deviceID, name: name, lastScan: device.lastCheckedAt,
            apps: apps, pending: Array(Set(pending)).sorted(),
            revisionID: state.snapshot.document.revision.id)
    }
}

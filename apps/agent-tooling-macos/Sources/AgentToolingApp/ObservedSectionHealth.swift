import AgentToolingCore
import Foundation

extension SectionHealth {
    /// Derives sidebar health from device observations and library assignments.
    /// An unreachable managed app affects its assigned tools. Unchecked clients
    /// remain undecorated; assignment intent alone never establishes health.
    @MainActor
    static func observed(
        library: WorkspaceLibraryReadModel?,
        device: WorkspaceDeviceSession
    ) -> SectionHealth {
        guard let library else { return SectionHealth() }
        let inventory = VersionedInventoryProjection.inventory(library)
        var verdicts: [AppSection: HealthState] = [:]
        verdicts[.skills] = skillsHealth(inventory.skills)
        verdicts[.plugins] = pluginsHealth(inventory.plugins, sources: [], packages: [])
        verdicts[.mcpServers] = mcpHealth(inventory.mcpServers)

        let unreachable = Set(
            device.managedClients.filter {
                device.verdict(for: $0).state == .attention
            })
        guard !unreachable.isEmpty else { return SectionHealth(verdicts: verdicts) }
        for row in library.rows where stopped(row, by: unreachable) {
            switch row.kind {
            case .skill: verdicts[.skills] = .attention
            case .mcpServer: verdicts[.mcpServers] = .attention
            case .nativePlugin, .package: verdicts[.plugins] = .attention
            case .preset, .logicalProject: continue
            }
        }
        // Plugins and connections are tabs under the library, so the row a
        // person can actually see carries the worst of the three.
        if verdicts[.plugins] == .attention || verdicts[.mcpServers] == .attention {
            verdicts[.skills] = .attention
        }
        return SectionHealth(verdicts: verdicts)
    }

    /// Whether this row is waiting on an app that is not there. A tool asked for
    /// inside a plugin counts too: the ask is just as stuck.
    private static func stopped(
        _ row: WorkspaceLibraryReadModelRow,
        by unreachable: Set<ClientKind>
    ) -> Bool {
        func blocked(_ assignments: [WorkspaceLibraryRequestedAssignment]) -> Bool {
            assignments.contains { assignment in
                guard let client = assignment.destination.surface.client else { return false }
                return unreachable.contains(client)
            }
        }
        return blocked(row.requestedAssignments) || row.includedChildren.contains { blocked($0.requestedAssignments) }
    }
}

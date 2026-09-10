import AgentToolingCore
import Foundation

extension SectionHealth {
    /// The sidebar's verdicts, given what this Mac has actually checked.
    ///
    /// The library on its own cannot reach one. A requested assignment records
    /// where somebody asked for a tool, not what an app holds, so every client
    /// state the projection produces is `pending` and the library rules run and
    /// answer nothing. The last read-only check of this Mac can answer: it knows
    /// which apps it found and which it did not.
    ///
    /// One fact is worth a glyph. An app this Mac manages that the check could
    /// not reach stops every tool this workspace asked that app for, and the
    /// library is where those asks live, so the library row is where it is said.
    /// The apps row already carries its own count and is left alone.
    ///
    /// Nothing checked means nothing claimed. Before the first check, and for an
    /// app that has never been looked at, the row stays undecorated rather than
    /// being marked suspect — or reassured — on no evidence.
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
            device.availableClients.filter {
                device.isEnabled($0) && device.verdict(for: $0).state == .attention
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

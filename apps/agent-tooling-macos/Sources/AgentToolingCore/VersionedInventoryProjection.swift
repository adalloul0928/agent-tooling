import Foundation

/// The versioned workspace's own items, in the shape the read-only integration
/// surface already speaks.
///
/// This exists so that once a person moves their library to the versioned
/// store, the read-only surfaces answer from the library they actually have.
/// Before it, those surfaces kept answering from the retained legacy database
/// and an agent would be told about items that had moved and never told about
/// the ones that arrived — which is worse than an error, because it looks like
/// an answer.
///
/// One rule shapes every field here: a versioned workspace records what a
/// person *asked for*, and the legacy inventory recorded what a scan *found*.
/// Those are not the same claim, so nothing in this projection reports a
/// requested destination as an installed one. Every projected client state is
/// `pending` and `isInstalled: false`, whatever the request says.
public enum VersionedInventoryProjection {
    public struct Inventory: Sendable, Equatable {
        public var skills: [Skill]
        public var mcpServers: [MCPServer]
        public var plugins: [Plugin]
    }

    /// Projects one versioned workspace. `library` is the same read model the
    /// app's own Library view is built from, so the two cannot disagree about
    /// what exists or who owns it.
    public static func inventory(_ library: WorkspaceLibraryReadModel) -> Inventory {
        var skills: [Skill] = []
        var servers: [MCPServer] = []
        var plugins: [Plugin] = []
        for row in library.rows {
            switch row.kind {
            case .skill:
                skills.append(skill(row))
            case .mcpServer:
                servers.append(server(row))
            case .nativePlugin, .package:
                plugins.append(plugin(row))
                // A package's members are things a person can search for by
                // name, so they are listed rather than hidden inside it.
                for child in row.includedChildren where child.kind == .skill {
                    skills.append(skill(child, parentLabel: row.displayName))
                }
                for child in row.includedChildren where child.kind == .mcpServer {
                    servers.append(server(child, parentLabel: row.displayName))
                }
            case .preset, .logicalProject:
                continue
            }
        }
        return .init(skills: skills, mcpServers: servers, plugins: plugins)
    }

    // MARK: - Records

    private static func skill(_ row: WorkspaceLibraryReadModelRow) -> Skill {
        .init(
            id: row.artifactID.rawValue.uuidString.lowercased(), name: row.displayName,
            displayName: row.displayName, summary: row.observedDescription ?? "",
            bundle: row.sourceLabel ?? "", scope: scope(row.requestedAssignments),
            owned: owns(row.ownership), triggers: [], negativeTrigger: "", files: [],
            clients: states(row.requestedAssignments), validationCount: 0)
    }

    private static func skill(_ item: WorkspaceLibraryIncludedItem, parentLabel: String) -> Skill {
        .init(
            id: item.artifactID.rawValue.uuidString.lowercased(), name: item.displayName,
            displayName: item.displayName, summary: item.observedDescription ?? "",
            bundle: parentLabel, scope: scope(item.requestedAssignments),
            owned: owns(item.ownership), triggers: [], negativeTrigger: "", files: [],
            clients: states(item.requestedAssignments), validationCount: 0)
    }

    private static func server(_ row: WorkspaceLibraryReadModelRow) -> MCPServer {
        // A connection's endpoint lives in this Mac's own client files, not in
        // the portable workspace, so there is nothing here to report as one.
        // An empty string is the honest answer; a placeholder would read as a
        // real address.
        .init(
            id: row.artifactID.rawValue.uuidString.lowercased(), name: row.displayName,
            summary: row.observedDescription ?? "", endpoint: "", transport: .stdio,
            authentication: "", scope: scope(row.requestedAssignments),
            clients: states(row.requestedAssignments),
            definitionOrigin: owns(row.ownership) ? .managed : .observed)
    }

    private static func server(_ item: WorkspaceLibraryIncludedItem, parentLabel: String) -> MCPServer {
        .init(
            id: item.artifactID.rawValue.uuidString.lowercased(), name: item.displayName,
            summary: item.observedDescription ?? "", endpoint: "", transport: .stdio,
            authentication: "", scope: scope(item.requestedAssignments),
            clients: states(item.requestedAssignments),
            definitionOrigin: owns(item.ownership) ? .managed : .observed)
    }

    private static func plugin(_ row: WorkspaceLibraryReadModelRow) -> Plugin {
        .init(
            id: row.artifactID.rawValue.uuidString.lowercased(), name: row.displayName,
            summary: row.observedDescription ?? "",
            source: row.sourceLabel ?? row.nativeRoutes.first?.externalPluginID ?? "",
            scope: scope(row.requestedAssignments),
            // The workspace pins content by digest, not by a version string a
            // person would recognise, so no revision is claimed.
            revision: "",
            skills: row.includedChildren.filter { $0.kind == .skill }.map(\.displayName),
            profiles: [], clients: states(row.requestedAssignments),
            // Requested, not measured. Only the Install step knows what is
            // actually on this Mac, and it is not consulted here.
            installed: false)
    }

    // MARK: - Shared reading

    private static func owns(_ ownership: WorkspaceLibraryOwnership) -> Bool {
        switch ownership {
        case .centralPersonal, .centralUpstream: true
        case .nativeOwned, .attachedAuthoring, .trackedOnly: false
        }
    }

    private static func scope(_ assignments: [WorkspaceLibraryRequestedAssignment]) -> String {
        assignments.contains { $0.destination.scope == .user } ? "user" : "project"
    }

    /// One entry per client a destination was requested for, never more.
    private static func states(_ assignments: [WorkspaceLibraryRequestedAssignment]) -> [ClientState] {
        var byClient: [ClientKind: Int] = [:]
        for assignment in assignments where assignment.desiredPresence {
            guard let client = assignment.destination.surface.client else { continue }
            byClient[client, default: 0] += 1
        }
        return byClient.keys.sorted { $0.rawValue < $1.rawValue }.map { client in
            let count = byClient[client] ?? 0
            return ClientState(
                client: client, state: .pending,
                detail: count == 1
                    ? "Asked for in one place. Not checked against this Mac."
                    : "Asked for in \(count) places. Not checked against this Mac.",
                isInstalled: false)
        }
    }
}

import AgentToolingCore
import SwiftUI

// MARK: - Row model

/// Where one app gets a server by one name, as the last check found it.
struct MCPDefinitionSources: Equatable, Identifiable {
    let client: ClientKind
    /// "Claude Code configuration", or a plugin's `plugin@marketplace` id.
    let sources: [String]

    var id: ClientKind { client }

    /// Every source in observations for the server this app knows by `name`.
    static func found(named name: String?, in observations: [TargetObservation]) -> [Self] {
        guard let name, !name.isEmpty else { return [] }
        return
            observations
            .compactMap { observation -> Self? in
                guard let client = observation.surface.client, let metadata = observation.mcpMetadata[name] else { return nil }
                return Self(client: client, sources: metadata.allSources)
            }
            .sorted { $0.client.rawValue < $1.client.rawValue }
    }

    /// A source in words: a plugin by its name, a configuration as it is.
    static func label(_ source: String) -> String {
        let identity = SkillOrganization.SourceIdentity(source)
        guard let plugin = identity.pluginTitle else { return source }
        return [plugin, identity.marketplaceTitle].compactMap { $0 }.joined(separator: " · ")
    }
}

/// One connection the workspace knows about.
///
/// `nativeRoutes` is what an app's own package list said; `requestedAssignments`
/// is what somebody asked for. They are separate fields here because they are
/// separate claims, and the screen must never spend one as the other.
struct MCPConnectionEntry: Identifiable, Equatable {
    let artifactID: ArtifactID
    let displayName: String
    let ownershipLabel: String
    /// False for items an app or a publisher owns; the tile goes quiet for them.
    let isManaged: Bool
    let parentPluginLabel: String?
    let sourceLabel: String?
    let observedDescription: String?
    let requestedAssignments: [WorkspaceLibraryRequestedAssignment]
    let nativeRoutes: [WorkspaceLibraryNativeRoute]
    let isAssignable: Bool
    let assignmentExplanation: String?
    /// The same item in the shape the live-test console and the capability
    /// switches speak, from `VersionedInventoryProjection`.
    let server: MCPServer
    /// Every place each app was last found to get a server by this name: its
    /// own configuration, and each plugin that brings one. More than one in an
    /// app means more than one definition of it there.
    var definedBy: [MCPDefinitionSources] = []

    var id: String { server.id }

    /// Apps whose own package list carries this server. Presence, not intent.
    var routedClients: Set<ClientKind> { Set(nativeRoutes.map(\.client)) }

    /// Apps this server is either in or asked for, for filtering only.
    var involvedClients: Set<ClientKind> {
        routedClients.union(requestedAssignments.compactMap(\.destination.surface.client))
    }

    var needsADecision: Bool {
        routedClients.isEmpty && requestedAssignments.isEmpty
    }

    /// The row's one clause: where it came from, and what carries it.
    var clause: String {
        [ownershipLabel, parentPluginLabel.map { "In \($0)" }, sourceLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var verdict: (state: HealthState, text: String) {
        if !routedClients.isEmpty {
            let names = routedClients.map(\.rawValue).sorted().joined(separator: ", ")
            return (.healthy, "In \(names)")
        }
        if !requestedAssignments.isEmpty {
            let count = requestedAssignments.count
            return (.pending, count == 1 ? "Asked for in one place" : "Asked for in \(count) places")
        }
        return (.pending, "Not asked for anywhere")
    }
}

extension WorkspaceLibraryOwnership {
    /// True when Agent Tooling holds this item's content, which is what decides
    /// whether the row's tile is drawn at full presence.
    var isManagedHere: Bool {
        switch self {
        case .centralPersonal, .centralUpstream, .attachedAuthoring: true
        case .nativeOwned, .trackedOnly: false
        }
    }

    /// What a row's clause calls this authority. Restored from the dead-view
    /// sweep: `WorkspaceLibraryView.swift` had no caller left and was deleted,
    /// but Skills, Plugins, Projects and the command palette catalog all still
    /// read this label, so it stays module-wide rather than going down with
    /// the screen it was declared beside.
    var libraryLabel: String {
        switch self {
        case .centralPersonal: "Personal library"
        case .centralUpstream: "From a repository"
        case .nativeOwned: "Managed by its app"
        case .attachedAuthoring: "Linked authoring folder"
        case .trackedOnly: "Unmanaged"
        }
    }
}

extension WorkspaceLibraryReadModelRow {
    /// Same provenance as `WorkspaceLibraryOwnership.libraryLabel`, one row
    /// exception and all: a personal MCP server this workspace itself keeps
    /// configured is a connection, not a library entry, so its row says so.
    var ownershipLabel: String {
        kind == .mcpServer && ownership == .centralPersonal
            ? "Managed connection" : ownership.libraryLabel
    }
}

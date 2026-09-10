import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Draws one pane in both appearances, checks neither is a blank frame, and —
/// only when `MCP_LAYOUT_CAPTURE` names a folder — writes the PNGs there.
///
/// The panes behind a selection cannot be reached by launching the app with a
/// section argument, so this is how somebody looks at them. Two things are
/// supplied that the shell would otherwise supply: the detail column's own
/// background, without which light text lands on an unpainted bitmap, and an
/// explicit colour scheme, because a bare hosting view has no window to take
/// one from. A pane legible in only one of them fails here rather than in front
/// of somebody.
@MainActor
func captureMCPPane(
    _ view: some View, named name: String, _ location: SourceLocation = #_sourceLocation
) throws {
    for scheme in [ColorScheme.light, .dark] {
        let suffix = scheme == .dark ? "dark" : "light"
        let bitmap = try rasterize(
            view
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AgentTheme.contentBackground)
                .environment(\.colorScheme, scheme),
            location)
        #expect(
            distinctColours(in: bitmap) > 4, "the \(suffix) screen drew a blank frame",
            sourceLocation: location)
        guard let directory = ProcessInfo.processInfo.environment["MCP_LAYOUT_CAPTURE"],
            let png = bitmap.representation(using: .png, properties: [:])
        else { continue }
        try png.write(to: URL(fileURLWithPath: directory).appending(path: "mcp-\(name)-\(suffix).png"))
    }
}

/// This Mac's MCP runtimes, scripted.
///
/// The real inspector launches `thv`. A test that used it would take its answer
/// from whatever happens to be installed on the machine running it, and would
/// start a process to find out — so the connections screen and every sheet
/// under it are given this instead.
struct StubMCPRuntimeInspector: MCPRuntimeInspecting {
    var reading = MCPRuntimeReading(
        statuses: [
            MCPRuntimeStatus(
                id: "direct", displayName: "Direct client configuration", isAvailable: true,
                capabilities: [.directConfiguration],
                detail: "Uses each client's native MCP configuration without a separate runtime."),
            MCPRuntimeStatus(
                id: "toolhive", displayName: "ToolHive", isAvailable: true, version: "0.4.1",
                capabilities: [.health, .logs],
                detail: "Read-only workload status and log inspection available."),
        ],
        workloads: [
            MCPRuntimeServer(
                name: "fixture", package: "registry.example/fixture", status: "running",
                url: "http://127.0.0.1:8080/mcp", transport: "streamable-http", group: "preview")
        ])
    var status: ToolHiveInspectionResult<ToolHiveWorkloadStatus> = .available(
        ToolHiveWorkloadStatus(
            name: "fixture", status: "running", health: "healthy", package: "registry.example/fixture",
            url: "http://127.0.0.1:8080/mcp", port: 8_080, transport: "streamable-http",
            proxyMode: "enabled", group: "preview", uptime: "1m"),
        diagnostic: nil)
    var logs = ToolHiveLogSnapshot(
        workloadName: "fixture", isProxyLog: false, output: "listening on 127.0.0.1:8080",
        isTruncated: false)

    func inspect() async throws -> MCPRuntimeReading { reading }
    func workloadStatus(_ name: String) async throws -> ToolHiveInspectionResult<ToolHiveWorkloadStatus> { status }
    func workloadLogs(_ name: String, proxy: Bool) async throws -> ToolHiveLogSnapshot { logs }
}

/// An inspector that has nothing to report, for the sheet's own empty state.
struct EmptyMCPRuntimeInspector: MCPRuntimeInspecting {
    func inspect() async throws -> MCPRuntimeReading {
        MCPRuntimeReading(
            statuses: [
                MCPRuntimeStatus(
                    id: "direct", displayName: "Direct client configuration", isAvailable: true,
                    capabilities: [.directConfiguration],
                    detail: "Uses each client's native MCP configuration without a separate runtime."),
                MCPRuntimeStatus(
                    id: "toolhive", displayName: "ToolHive", isAvailable: false, capabilities: [],
                    detail: "ToolHive is not installed."),
            ],
            workloads: [])
    }

    func workloadStatus(_ name: String) async throws -> ToolHiveInspectionResult<ToolHiveWorkloadStatus> {
        .unavailable(diagnostic: "ToolHive is not installed.")
    }

    func workloadLogs(_ name: String, proxy: Bool) async throws -> ToolHiveLogSnapshot {
        ToolHiveLogSnapshot(workloadName: name, isProxyLog: proxy, output: "", isTruncated: false)
    }
}

extension ShellRenderFixture {
    /// The connections screen inside the shell, with a scripted runtime so no
    /// test can reach `thv`.
    @MainActor func connectionsScreen() -> some View {
        renderShell(.mcpServers, fixture: self)
            .environment(\.mcpRuntimeInspector, StubMCPRuntimeInspector())
    }

    /// Every MCP server the fixture workspace holds, in the shape the screen
    /// builds its rows from.
    @MainActor var connectionEntries: [MCPConnectionEntry] {
        guard let library = workspace.library.state?.library else { return [] }
        let projected = Dictionary(
            VersionedInventoryProjection.inventory(library).mcpServers.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return library.rows.compactMap { row in
            guard row.kind == .mcpServer,
                let server = projected[row.artifactID.rawValue.uuidString.lowercased()]
            else { return nil }
            return MCPConnectionEntry(
                artifactID: row.artifactID, displayName: row.displayName,
                ownershipLabel: row.ownershipLabel, isManaged: row.ownership.isManagedHere,
                parentPluginLabel: row.parentPluginLabel, sourceLabel: row.sourceLabel,
                observedDescription: row.observedDescription,
                requestedAssignments: row.requestedAssignments, nativeRoutes: row.nativeRoutes,
                isAssignable: row.isAssignable, assignmentExplanation: row.assignmentExplanation,
                server: server)
        }
    }
}

/// One connection row, scripted, for the shapes the fixture workspace does not
/// happen to hold: a server an app owns, and one nobody has asked for anywhere.
@MainActor
enum MCPConnectionFixture {
    static func entry(
        name: String = "Fixture Server",
        ownershipLabel: String = "Personal library",
        isManaged: Bool = true,
        parentPluginLabel: String? = nil,
        sourceLabel: String? = nil,
        routes: [WorkspaceLibraryNativeRoute] = [],
        requested: [WorkspaceLibraryRequestedAssignment] = [],
        isAssignable: Bool = true,
        explanation: String? = nil
    ) -> MCPConnectionEntry {
        let artifactID = ArtifactID()
        return MCPConnectionEntry(
            artifactID: artifactID, displayName: name, ownershipLabel: ownershipLabel,
            isManaged: isManaged, parentPluginLabel: parentPluginLabel, sourceLabel: sourceLabel,
            observedDescription: "Discovered in a local agent configuration.",
            requestedAssignments: requested, nativeRoutes: routes, isAssignable: isAssignable,
            assignmentExplanation: explanation,
            server: MCPServer(
                id: artifactID.rawValue.uuidString.lowercased(), name: name,
                summary: "Discovered in a local agent configuration.", endpoint: "",
                transport: .stdio, authentication: "", scope: "user",
                clients: requested.compactMap(\.destination.surface.client).map {
                    ClientState(
                        client: $0, state: .pending,
                        detail: "Asked for in one place. Not checked against this Mac.", isInstalled: false)
                },
                definitionOrigin: .observed))
    }

    /// A saved request, in the shape the read model reports one.
    static func request(_ surface: TargetSurface, scope: ToolingScope = .user)
        -> WorkspaceLibraryRequestedAssignment
    {
        WorkspaceLibraryRequestedAssignment(
            id: WorkspaceObjectID(), destination: PortableDestination(surface: surface, scope: scope),
            reason: .manual, desiredPresence: true, desiredEnabled: true, deviceScope: .thisDevice)
    }
}

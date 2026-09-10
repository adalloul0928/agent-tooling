import AgentToolingCore
import Foundation
import Observation
import SwiftUI

/// What this Mac's MCP connection modes report. Direct client configuration
/// always exists and needs no probe; ToolHive is an optional, separate host,
/// and checking it never moves a server into it.
///
/// A protocol rather than a direct call so a render test can hand in canned
/// statuses and never launch a real process.
protocol MCPRuntimeObserving: Sendable {
    /// Direct configuration first, then ToolHive, mirroring the order every
    /// screen has always listed them in.
    func statuses() async -> [MCPRuntimeStatus]
    /// ToolHive's own workloads, read only. Called with the status this same
    /// refresh already found, so a caller never has to probe twice.
    func servers(after toolHiveStatus: MCPRuntimeStatus) async throws -> [MCPRuntimeServer]
}

enum WorkspaceRuntimesError: Error, Sendable {
    case commandFailed
    case invalidResponse
}

/// The real check: the same read-only `thv` inspection ToolHive's own docs
/// describe, over a bounded, non-interactive process.
struct LiveMCPRuntimeObserver: MCPRuntimeObserving {
    static let direct = MCPRuntimeStatus(
        id: "direct",
        displayName: "Direct client configuration",
        isAvailable: true,
        capabilities: [.directConfiguration],
        detail: "Uses each client's native MCP configuration without a separate runtime.")

    private let runner: any CommandRunning

    init(runner: any CommandRunning = ProcessCommandRunner(timeout: .seconds(15))) {
        self.runner = runner
    }

    func statuses() async -> [MCPRuntimeStatus] {
        [Self.direct, await toolHiveStatus()]
    }

    func servers(after toolHiveStatus: MCPRuntimeStatus) async throws -> [MCPRuntimeServer] {
        try Task.checkCancellation()
        guard toolHiveStatus.isAvailable, toolHiveStatus.capabilities.contains(.health) else { return [] }
        let result = try await runner.run(
            executable: "thv", arguments: ["list", "--all", "--format", "json"], currentDirectory: nil)
        try Task.checkCancellation()
        guard result.status == 0 else { throw WorkspaceRuntimesError.commandFailed }
        guard let data = result.standardOutput.data(using: .utf8), data.count <= 1_048_576 else {
            throw WorkspaceRuntimesError.invalidResponse
        }
        let workloads: [ToolHiveWorkloadEntry]
        do {
            workloads = try AgentToolingCoding.decoder().decode([ToolHiveWorkloadEntry].self, from: data)
        } catch {
            throw WorkspaceRuntimesError.invalidResponse
        }
        return workloads.map {
            MCPRuntimeServer(
                name: String($0.name.prefix(256)), package: String($0.package.prefix(1_024)),
                status: String($0.status.prefix(128)), url: $0.url.map { String($0.prefix(2_048)) },
                transport: $0.transport.map { String($0.prefix(128)) },
                group: $0.group.map { String($0.prefix(256)) }, isRemote: $0.remote ?? false)
        }.sorted { $0.name < $1.name }
    }

    private func toolHiveStatus() async -> MCPRuntimeStatus {
        do {
            switch try await ToolHiveRuntimeInspection(runner: runner).version() {
            case .available(let version, let diagnostic):
                return MCPRuntimeStatus(
                    id: "toolhive", displayName: "ToolHive", isAvailable: true, version: version.version,
                    capabilities: [.health, .logs],
                    detail: diagnostic ?? "Read-only workload status and log inspection available.")
            case .unavailable(let diagnostic):
                return unavailable(detail: diagnostic)
            case .unsupportedResponse(let diagnostic), .commandFailed(let diagnostic):
                return MCPRuntimeStatus(
                    id: "toolhive", displayName: "ToolHive", isAvailable: true, capabilities: [],
                    detail: diagnostic.isEmpty ? "ToolHive could not be inspected." : diagnostic)
            }
        } catch {
            return unavailable(detail: "ToolHive is not installed.")
        }
    }

    private func unavailable(detail: String) -> MCPRuntimeStatus {
        MCPRuntimeStatus(
            id: "toolhive", displayName: "ToolHive", isAvailable: false, capabilities: [],
            detail: detail.isEmpty ? "ToolHive is not installed." : detail)
    }
}

private struct ToolHiveWorkloadEntry: Decodable {
    var name: String
    var package: String
    var url: String?
    var transport: String?
    var status: String
    var group: String?
    var remote: Bool?

    private enum CodingKeys: String, CodingKey {
        case name, package, url, status, group, remote
        case transport = "transport_type"
    }
}

/// This Mac's MCP connection modes: servers stay configured directly in each
/// client by default, and ToolHive is an optional separate host for isolated
/// workloads. Agent Tooling never moves a server into it automatically.
@MainActor @Observable
final class WorkspaceRuntimesSession {
    private(set) var statuses: [MCPRuntimeStatus] = []
    private(set) var servers: [MCPRuntimeServer] = []
    private(set) var isRefreshingMCPRuntimes = false
    private(set) var mcpRuntimeError: String?

    private let observer: any MCPRuntimeObserving

    init(observer: any MCPRuntimeObserving) {
        self.observer = observer
    }

    var toolHive: MCPRuntimeStatus? { statuses.first { $0.id == "toolhive" } }

    func refresh() async {
        guard !isRefreshingMCPRuntimes else { return }
        isRefreshingMCPRuntimes = true
        defer { isRefreshingMCPRuntimes = false }
        let statuses = await observer.statuses()
        self.statuses = statuses
        guard let toolHive = statuses.first(where: { $0.id == "toolhive" }) else {
            servers = []
            return
        }
        do {
            servers = try await observer.servers(after: toolHive)
            mcpRuntimeError = nil
        } catch is CancellationError {
        } catch {
            servers = []
            mcpRuntimeError = "The last ToolHive refresh did not complete, so the workload list is not authoritative."
        }
    }
}

extension EnvironmentValues {
    @Entry var mcpRuntimeObserver: any MCPRuntimeObserving = LiveMCPRuntimeObserver()
}

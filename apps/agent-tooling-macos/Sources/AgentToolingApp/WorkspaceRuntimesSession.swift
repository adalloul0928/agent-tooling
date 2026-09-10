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

/// The real check: `AgentToolingCore`'s own runtime providers, which are the
/// same read-only `thv` inspection ToolHive's own docs describe, over a
/// bounded, non-interactive process.
///
/// Nothing about either runtime is decided here. Asking two different parts of
/// this app about the same Mac and being told two different things would be a
/// bug nobody could see, so both answers come from the one place that knows how
/// to ask.
struct LiveMCPRuntimeObserver: MCPRuntimeObserving {
    /// What `DirectMCPRuntimeProvider` reports, spelled out so a test can name
    /// the value without awaiting a provider it is not testing.
    static let direct = MCPRuntimeStatus(
        id: "direct",
        displayName: "Direct client configuration",
        isAvailable: true,
        capabilities: [.directConfiguration],
        detail: "Uses each client's native MCP configuration without a separate runtime.")

    private let toolHive: ToolHiveMCPRuntimeProvider

    init(runner: any CommandRunning = ProcessCommandRunner(timeout: .seconds(15))) {
        toolHive = ToolHiveMCPRuntimeProvider(runner: runner)
    }

    func statuses() async -> [MCPRuntimeStatus] {
        [await DirectMCPRuntimeProvider().status(), await toolHive.status()]
    }

    func servers(after toolHiveStatus: MCPRuntimeStatus) async throws -> [MCPRuntimeServer] {
        do {
            return try await toolHive.servers(after: toolHiveStatus)
        } catch let error as MCPRuntimeError {
            switch error {
            case .commandFailed: throw WorkspaceRuntimesError.commandFailed
            case .invalidResponse: throw WorkspaceRuntimesError.invalidResponse
            }
        }
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

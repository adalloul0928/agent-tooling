import AgentToolingCore
import Foundation
import Observation
import SwiftUI

/// Reading the MCP runtimes on this Mac, and changing none of them.
///
/// A protocol rather than a call so a render test can hand in an inspector that
/// returns canned answers and never launches `thv`, never touches the network,
/// and never depends on what happens to be installed on the machine running it.
protocol MCPRuntimeInspecting: Sendable {
    /// Which runtimes this Mac has, and the workloads the managed one reports.
    func inspect() async throws -> MCPRuntimeReading
    /// One workload's own status, read again on demand.
    func workloadStatus(_ name: String) async throws -> ToolHiveInspectionResult<ToolHiveWorkloadStatus>
    /// The latest output from one workload or its proxy.
    func workloadLogs(_ name: String, proxy: Bool) async throws -> ToolHiveLogSnapshot
}

/// What one runtime check saw: a status per runtime, and the workloads the
/// managed runtime listed. Empty workloads is a normal answer, not a failure.
struct MCPRuntimeReading: Sendable, Equatable {
    var statuses: [MCPRuntimeStatus] = []
    var workloads: [MCPRuntimeServer] = []
}

/// The real check.
///
/// Direct client configuration is always available: it is what every client
/// does without a separate runtime, so it is stated rather than probed. Only
/// ToolHive is asked, through the same read-only inspection the rest of the app
/// uses, and only when somebody opens the runtimes sheet.
struct LiveMCPRuntimeInspector: MCPRuntimeInspecting {
    /// The `thv list` payload is small; anything larger is a different program
    /// answering and is refused rather than parsed.
    static let maximumWorkloadListBytes = 1_048_576
    private let runner: any CommandRunning

    init(runner: any CommandRunning = ProcessCommandRunner(timeout: .seconds(15))) {
        self.runner = runner
    }

    func inspect() async throws -> MCPRuntimeReading {
        let direct = MCPRuntimeStatus(
            id: "direct", displayName: "Direct client configuration", isAvailable: true,
            capabilities: [.directConfiguration],
            detail: "Uses each client's native MCP configuration without a separate runtime.")
        let toolHive = await toolHiveStatus()
        var reading = MCPRuntimeReading(statuses: [direct, toolHive])
        guard toolHive.isAvailable, toolHive.capabilities.contains(.health) else { return reading }
        reading.workloads = try await workloads()
        return reading
    }

    func workloadStatus(_ name: String) async throws -> ToolHiveInspectionResult<ToolHiveWorkloadStatus> {
        try await ToolHiveRuntimeInspection(runner: runner).status(workloadName: name)
    }

    func workloadLogs(_ name: String, proxy: Bool) async throws -> ToolHiveLogSnapshot {
        try await ToolHiveRuntimeInspection(runner: runner).logs(workloadName: name, proxy: proxy)
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
                return MCPRuntimeStatus(
                    id: "toolhive", displayName: "ToolHive", isAvailable: false, capabilities: [],
                    detail: bounded(diagnostic).isEmpty ? "ToolHive is not installed." : bounded(diagnostic))
            case .unsupportedResponse(let diagnostic), .commandFailed(let diagnostic):
                return MCPRuntimeStatus(
                    id: "toolhive", displayName: "ToolHive", isAvailable: true, capabilities: [],
                    detail: bounded(diagnostic).isEmpty ? "ToolHive could not be inspected." : bounded(diagnostic))
            }
        } catch {
            return MCPRuntimeStatus(
                id: "toolhive", displayName: "ToolHive", isAvailable: false, capabilities: [],
                detail: bounded(error.localizedDescription))
        }
    }

    private func workloads() async throws -> [MCPRuntimeServer] {
        try Task.checkCancellation()
        let result = try await runner.run(
            executable: "thv", arguments: ["list", "--all", "--format", "json"], currentDirectory: nil)
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw MCPRuntimeReadingError.listFailed(bounded(result.standardError))
        }
        guard let data = result.standardOutput.data(using: .utf8),
            data.count <= Self.maximumWorkloadListBytes,
            let decoded = try? AgentToolingCoding.decoder().decode([ListedWorkload].self, from: data)
        else { throw MCPRuntimeReadingError.unsupportedList }
        return decoded.map {
            MCPRuntimeServer(
                name: bounded($0.name, limit: 256), package: bounded($0.package),
                status: bounded($0.status, limit: 128), url: $0.url.map { bounded($0, limit: 2_048) },
                transport: $0.transport.map { bounded($0, limit: 128) },
                group: $0.group.map { bounded($0, limit: 256) }, isRemote: $0.remote ?? false)
        }.sorted { $0.name < $1.name }
    }

    private func bounded(_ value: String, limit: Int = 1_024) -> String { String(value.prefix(limit)) }

    /// The subset of `thv list` this screen shows. Anything else in the payload
    /// is ignored rather than surfaced.
    private struct ListedWorkload: Decodable {
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
}

enum MCPRuntimeReadingError: LocalizedError, Sendable, Equatable {
    case listFailed(String)
    case unsupportedList

    var errorDescription: String? {
        switch self {
        case .listFailed(let detail): "ToolHive could not list its workloads. \(detail)"
        case .unsupportedList: "ToolHive answered with a workload list this build cannot read."
        }
    }
}

/// What the last runtime check found.
///
/// Nothing here runs on its own: the check happens when somebody opens the
/// runtimes sheet and presses for it, and the work leaves this actor so the
/// screen that asked keeps drawing.
@MainActor @Observable
final class MCPRuntimeSession {
    private(set) var statuses: [MCPRuntimeStatus] = []
    private(set) var workloads: [MCPRuntimeServer] = []
    private(set) var lastCheckedAt: Date?
    private(set) var isBusy = false
    private(set) var errorMessage: String?

    private let inspector: any MCPRuntimeInspecting

    init(inspector: any MCPRuntimeInspecting) {
        self.inspector = inspector
    }

    /// Reads this Mac's runtimes. Reads only.
    ///
    /// A second call while one is running is dropped rather than started beside
    /// it, and a failed check leaves the last successful one on screen: it is
    /// still the truest thing known about this Mac.
    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            let reading = try await inspector.inspect()
            statuses = reading.statuses
            workloads = reading.workloads
            lastCheckedAt = .now
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension EnvironmentValues {
    /// How the connections screen reads this Mac's MCP runtimes. Replaced by a
    /// stub in tests so no test can start `thv`.
    @Entry var mcpRuntimeInspector: any MCPRuntimeInspecting = LiveMCPRuntimeInspector()
}

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
/// ToolHive is asked, and only when somebody opens the runtimes sheet.
///
/// Neither probe is written here. Both are `AgentToolingCore`'s own runtime
/// providers — the same version check and the same `thv list` reading the rest
/// of the app uses — so this screen cannot come to a different conclusion about
/// this Mac than any other caller of the same command.
struct LiveMCPRuntimeInspector: MCPRuntimeInspecting {
    private let runner: any CommandRunning
    private let toolHive: ToolHiveMCPRuntimeProvider

    init(runner: any CommandRunning = ProcessCommandRunner(timeout: .seconds(15))) {
        self.runner = runner
        toolHive = ToolHiveMCPRuntimeProvider(runner: runner)
    }

    func inspect() async throws -> MCPRuntimeReading {
        let direct = await DirectMCPRuntimeProvider().status()
        let toolHiveStatus = await toolHive.status()
        var reading = MCPRuntimeReading(statuses: [direct, toolHiveStatus])
        guard toolHiveStatus.isAvailable, toolHiveStatus.capabilities.contains(.health) else { return reading }
        do {
            // The status this refresh already found is handed back, so listing
            // the workloads does not probe ToolHive's version a second time.
            reading.workloads = try await toolHive.servers(after: toolHiveStatus)
        } catch let error as MCPRuntimeError {
            throw MCPRuntimeReadingError(error)
        }
        return reading
    }

    func workloadStatus(_ name: String) async throws -> ToolHiveInspectionResult<ToolHiveWorkloadStatus> {
        try await ToolHiveRuntimeInspection(runner: runner).status(workloadName: name)
    }

    func workloadLogs(_ name: String, proxy: Bool) async throws -> ToolHiveLogSnapshot {
        try await ToolHiveRuntimeInspection(runner: runner).logs(workloadName: name, proxy: proxy)
    }
}

enum MCPRuntimeReadingError: LocalizedError, Sendable, Equatable {
    case listFailed(String)
    case unsupportedList

    /// The runtime provider's refusal, in this screen's own words. The reason
    /// is the provider's; only the sentence around it belongs to the sheet.
    init(_ error: MCPRuntimeError) {
        switch error {
        case .commandFailed(let detail): self = .listFailed(detail)
        case .invalidResponse: self = .unsupportedList
        }
    }

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

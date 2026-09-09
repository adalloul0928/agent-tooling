import Foundation

public enum ToolHiveLifecycleAction: String, Hashable, Sendable, CaseIterable {
    case start, stop, restart

    var command: String { rawValue }

    /// Statuses ToolHive reports that satisfy this action. A status outside the
    /// set is not treated as success, whatever the command's exit code was.
    var satisfyingStatuses: Set<String> {
        switch self {
        case .start, .restart: ["running"]
        case .stop: ["stopped", "exited"]
        }
    }

    /// Restart always acts, even from a satisfying state.
    var isIdempotentFromSatisfyingState: Bool { self != .restart }
}

/// A reviewed action against one exact workload, bound to the state that was
/// observed when it was prepared.
public struct ToolHiveLifecyclePlan: Hashable, Sendable {
    public let workloadName: String
    public let action: ToolHiveLifecycleAction
    public let observed: ToolHiveWorkloadStatus
    /// Other workloads this device knows about, checked before and after so an
    /// action that reaches beyond its target is visible rather than assumed away.
    public let otherWorkloadNames: [String]

    public init(
        workloadName: String,
        action: ToolHiveLifecycleAction,
        observed: ToolHiveWorkloadStatus,
        otherWorkloadNames: [String] = []
    ) {
        self.workloadName = workloadName
        self.action = action
        self.observed = observed
        self.otherWorkloadNames = otherWorkloadNames
    }
}

public enum ToolHiveLifecycleOutcome: Hashable, Sendable {
    /// The workload already reports a state this action would produce.
    case alreadySatisfied(ToolHiveWorkloadStatus)
    /// The postcondition was verified after the command ran.
    case applied(before: ToolHiveWorkloadStatus, after: ToolHiveWorkloadStatus)
    /// The command exited successfully but the workload does not report the
    /// expected state. This is never retried automatically.
    case ambiguous(diagnostic: String, after: ToolHiveWorkloadStatus?)
    /// The workload changed between preparing and applying, so the reviewed
    /// plan no longer describes what would happen.
    case stalePlan(current: ToolHiveWorkloadStatus?)
    /// Another workload's state changed while this action ran.
    case affectedOtherWorkload(name: String)
    case commandFailed(diagnostic: String)
    case unavailable(diagnostic: String)
    case unsupported(diagnostic: String)
}

/// Reviewed start, stop and restart for a locally installed ToolHive.
///
/// Every action names one exact workload, is bound to the state observed when it
/// was prepared, and is confirmed by re-reading that workload afterwards. A
/// command that exits cleanly without producing the expected state is reported
/// as ambiguous and never retried, because a second attempt at an unclear
/// mutation is its own risk.
///
/// Replacement, upgrade and deletion are deliberately absent. The inspected
/// workload API exposes no conditional-mutation contract, so this app cannot
/// promise that its view of a workload is still current when it writes; those
/// actions stay in ToolHive's own tools until such a contract exists.
public struct ToolHiveLifecycleService: Sendable {
    private let inspection: ToolHiveRuntimeInspection
    private let runner: any CommandRunning

    public init(
        runner: any CommandRunning = ProcessCommandRunner(timeout: .seconds(60)),
        inspection: ToolHiveRuntimeInspection? = nil
    ) {
        self.runner = runner
        self.inspection = inspection ?? ToolHiveRuntimeInspection(runner: runner)
    }

    /// Reads the workload's current state and describes what this action would
    /// do. Nothing is changed here.
    public enum PlanResult: Hashable, Sendable {
        case prepared(ToolHiveLifecyclePlan)
        /// Why no plan could be prepared, in the same terms an outcome uses.
        case blocked(ToolHiveLifecycleOutcome)
    }

    public func plan(
        workloadName: String,
        action: ToolHiveLifecycleAction,
        otherWorkloadNames: [String] = []
    ) async throws -> PlanResult {
        switch try await inspection.status(workloadName: workloadName) {
        case .available(let status, _):
            return .prepared(.init(workloadName: workloadName, action: action, observed: status,
                                   otherWorkloadNames: otherWorkloadNames))
        case .unavailable(let diagnostic):
            return .blocked(.unavailable(diagnostic: diagnostic))
        case .unsupportedResponse(let diagnostic):
            return .blocked(.unsupported(diagnostic: diagnostic))
        case .commandFailed(let diagnostic):
            return .blocked(.commandFailed(diagnostic: diagnostic))
        }
    }

    public func apply(_ plan: ToolHiveLifecyclePlan) async throws -> ToolHiveLifecycleOutcome {
        try Task.checkCancellation()
        // The reviewed plan must still describe reality before anything runs.
        guard case .available(let current, _) = try await inspection.status(workloadName: plan.workloadName) else {
            return .stalePlan(current: nil)
        }
        guard current == plan.observed else { return .stalePlan(current: current) }
        if plan.action.isIdempotentFromSatisfyingState,
           plan.action.satisfyingStatuses.contains(current.status.lowercased()) {
            return .alreadySatisfied(current)
        }

        var othersBefore: [String: ToolHiveWorkloadStatus] = [:]
        for name in plan.otherWorkloadNames where name != plan.workloadName {
            if case .available(let status, _) = try await inspection.status(workloadName: name) {
                othersBefore[name] = status
            }
        }

        let output: CommandOutput
        do {
            output = try await runner.run(
                executable: "thv",
                arguments: [plan.action.command, plan.workloadName],
                currentDirectory: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unavailable(diagnostic: Self.diagnostic(error.localizedDescription))
        }
        try Task.checkCancellation()
        guard output.status == 0 else {
            return output.status == 127
                ? .unavailable(diagnostic: Self.diagnostic(output.standardError))
                : .commandFailed(diagnostic: Self.diagnostic(output.standardError))
        }

        // A clean exit is not the postcondition. Read the workload again.
        guard case .available(let after, _) = try await inspection.status(workloadName: plan.workloadName) else {
            return .ambiguous(diagnostic: "ToolHive did not report this workload after the change.", after: nil)
        }
        guard plan.action.satisfyingStatuses.contains(after.status.lowercased()) else {
            return .ambiguous(
                diagnostic: "ToolHive reports this workload as \(after.status) after the change.",
                after: after)
        }
        for (name, before) in othersBefore.sorted(by: { $0.key < $1.key }) {
            guard case .available(let now, _) = try await inspection.status(workloadName: name) else { continue }
            // Uptime moves on its own; the reported state must not.
            if now.status != before.status || now.port != before.port || now.url != before.url {
                return .affectedOtherWorkload(name: name)
            }
        }
        return .applied(before: plan.observed, after: after)
    }

    private static func diagnostic(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ToolHive reported no details." }
        return String(trimmed.prefix(500))
    }
}

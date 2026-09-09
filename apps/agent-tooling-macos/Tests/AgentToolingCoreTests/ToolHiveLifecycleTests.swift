import Foundation
import Testing

@testable import AgentToolingCore

/// A scripted `thv`. Every command is recorded so a test can prove that no
/// unrequested mutation was issued.
private actor ScriptedToolHive: CommandRunning {
    private var responses: [(match: String, output: CommandOutput)]
    private(set) var calls: [[String]] = []

    init(_ responses: [(String, CommandOutput)]) {
        self.responses = responses.map { (match: $0.0, output: $0.1) }
    }

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        calls.append(arguments)
        let key = arguments.joined(separator: " ")
        guard let index = responses.firstIndex(where: { key.hasPrefix($0.match) }) else {
            throw ScriptError.unexpected(key)
        }
        return responses.remove(at: index).output
    }

    func recorded() -> [[String]] { calls }
}

private enum ScriptError: Error { case unexpected(String) }

@Suite("ToolHive lifecycle")
struct ToolHiveLifecycleTests {
    @Test func aVerifiedStartReportsTheStateBeforeAndAfter() async throws {
        let runner = ScriptedToolHive([
            ("status browser", Self.list(status: "stopped")),
            ("status browser", Self.list(status: "stopped")),
            ("start browser", Self.ok()),
            ("status browser", Self.list(status: "running")),
        ])
        let service = ToolHiveLifecycleService(runner: runner)

        guard case .prepared(let plan) = try await service.plan(workloadName: "browser", action: .start) else {
            Issue.record("A reachable workload must produce a plan.")
            return
        }
        let outcome = try await service.apply(plan)

        guard case .applied(let before, let after) = outcome else {
            Issue.record("Expected a verified change, got \(outcome).")
            return
        }
        #expect(before.status == "stopped" && after.status == "running")
        #expect(await runner.recorded().contains(["start", "browser"]))
    }

    @Test func acleanExitWithoutTheExpectedStateIsAmbiguousAndNotRetried() async throws {
        let runner = ScriptedToolHive([
            ("status browser", Self.list(status: "stopped")),
            ("status browser", Self.list(status: "stopped")),
            ("start browser", Self.ok()),
            ("status browser", Self.list(status: "starting")),
        ])
        let service = ToolHiveLifecycleService(runner: runner)
        guard case .prepared(let plan) = try await service.plan(workloadName: "browser", action: .start) else {
            Issue.record("Expected a plan."); return
        }

        let outcome = try await service.apply(plan)

        guard case .ambiguous(let diagnostic, let after) = outcome else {
            Issue.record("Expected an ambiguous outcome, got \(outcome).")
            return
        }
        #expect(diagnostic.contains("starting"))
        #expect(after?.status == "starting")
        // Exactly one mutation was attempted; an unclear result is not retried.
        #expect(await runner.recorded().filter { $0.first == "start" }.count == 1)
    }

    @Test func aWorkloadThatChangedSinceReviewIsNotActedOn() async throws {
        let runner = ScriptedToolHive([
            ("status browser", Self.list(status: "stopped")),
            ("status browser", Self.list(status: "running")),
        ])
        let service = ToolHiveLifecycleService(runner: runner)
        guard case .prepared(let plan) = try await service.plan(workloadName: "browser", action: .start) else {
            Issue.record("Expected a plan."); return
        }

        let outcome = try await service.apply(plan)

        guard case .stalePlan(let current) = outcome else {
            Issue.record("Expected a stale plan, got \(outcome).")
            return
        }
        #expect(current?.status == "running")
        #expect(await runner.recorded().allSatisfy { $0.first != "start" })
    }

    @Test func anAlreadySatisfiedStateIsReportedWithoutRunningACommand() async throws {
        let runner = ScriptedToolHive([
            ("status browser", Self.list(status: "running")),
            ("status browser", Self.list(status: "running")),
        ])
        let service = ToolHiveLifecycleService(runner: runner)
        guard case .prepared(let plan) = try await service.plan(workloadName: "browser", action: .start) else {
            Issue.record("Expected a plan."); return
        }

        let outcome = try await service.apply(plan)

        guard case .alreadySatisfied = outcome else {
            Issue.record("Expected an already-satisfied outcome, got \(outcome).")
            return
        }
        #expect(await runner.recorded().allSatisfy { $0.first == "status" })
    }

    @Test func restartActsEvenFromARunningState() async throws {
        let runner = ScriptedToolHive([
            ("status browser", Self.list(status: "running")),
            ("status browser", Self.list(status: "running")),
            ("restart browser", Self.ok()),
            ("status browser", Self.list(status: "running")),
        ])
        let service = ToolHiveLifecycleService(runner: runner)
        guard case .prepared(let plan) = try await service.plan(workloadName: "browser", action: .restart) else {
            Issue.record("Expected a plan."); return
        }

        let outcome = try await service.apply(plan)

        guard case .applied = outcome else {
            Issue.record("Expected a verified restart, got \(outcome).")
            return
        }
        #expect(await runner.recorded().contains(["restart", "browser"]))
    }

    @Test func anUnrelatedWorkloadChangingIsReportedRatherThanIgnored() async throws {
        let runner = ScriptedToolHive([
            ("status browser", Self.list(status: "stopped")),
            ("status browser", Self.list(status: "stopped")),
            ("status other", Self.list(name: "other", status: "running")),
            ("start browser", Self.ok()),
            ("status browser", Self.list(status: "running")),
            ("status other", Self.list(name: "other", status: "stopped")),
        ])
        let service = ToolHiveLifecycleService(runner: runner)
        guard case .prepared(let plan) = try await service.plan(
            workloadName: "browser", action: .start, otherWorkloadNames: ["other"]) else {
            Issue.record("Expected a plan."); return
        }

        let outcome = try await service.apply(plan)

        #expect(outcome == .affectedOtherWorkload(name: "other"))
    }

    @Test func anAbsentToolHiveIsReportedWithoutAPlan() async throws {
        let runner = ScriptedToolHive([
            ("status browser", CommandOutput(status: 127, standardOutput: "", standardError: "not found")),
        ])
        let service = ToolHiveLifecycleService(runner: runner)

        guard case .blocked(let outcome) = try await service.plan(workloadName: "browser", action: .stop) else {
            Issue.record("Expected no plan without ToolHive.")
            return
        }
        guard case .unavailable = outcome else {
            Issue.record("Expected an unavailable outcome, got \(outcome).")
            return
        }
        #expect(await runner.recorded().allSatisfy { $0.first != "stop" })
    }

    private static func ok() -> CommandOutput {
        .init(status: 0, standardOutput: "", standardError: "")
    }

    private static func list(name: String = "browser", status: String) -> CommandOutput {
        let payload = """
        {"name":"\(name)","status":"\(status)","package":"ghcr.io/example/\(name)",\
        "url":"http://127.0.0.1:4711","port":4711,"transport":"stdio"}
        """
        return .init(status: 0, standardOutput: payload, standardError: "")
    }
}

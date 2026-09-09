import Foundation
import Testing

@testable import AgentToolingCore

private actor ToolHiveInspectionRunner: CommandRunning {
    private var results: [CommandOutput]
    private var calls: [(String, [String])] = []

    init(results: [CommandOutput]) {
        self.results = results
    }

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        calls.append((executable, arguments))
        guard !results.isEmpty else { throw InspectionRunnerError.unexpectedCommand }
        return results.removeFirst()
    }

    func recordedCalls() -> [(String, [String])] { calls }
}

private enum InspectionRunnerError: Error { case unexpectedCommand }

private actor InspectionGate {
    private var opened = false
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForRelease() async {
        if opened { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func open() {
        opened = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor GatedInspectionRunner: CommandRunning {
    private let gate: InspectionGate
    private let result: CommandOutput
    private(set) var callCount = 0

    init(gate: InspectionGate, result: CommandOutput) {
        self.gate = gate
        self.result = result
    }

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        callCount += 1
        await gate.markStarted()
        await gate.waitForRelease()
        return result
    }
}

struct ToolHiveRuntimeInspectionTests {
    @Test func versionUsesDocumentedJSONShapeAndSeparatesAvailability() async throws {
        let runner = ToolHiveInspectionRunner(results: [
            CommandOutput(
                status: 0,
                standardOutput: #"{"version":"v0.8.0","commit":"abc123","build_date":"2026-09-09T00:00:00Z","go_version":"go1.25","platform":"darwin/arm64"}"#,
                standardError: ""
            )
        ])
        let result = try await ToolHiveRuntimeInspection(runner: runner).version()

        guard case let .available(version, diagnostic) = result else {
            Issue.record("expected a typed ToolHive version")
            return
        }
        #expect(version.version == "v0.8.0")
        #expect(version.platform == "darwin/arm64")
        #expect(diagnostic == nil)
        let versionCalls = await runner.recordedCalls()
        #expect(versionCalls.map { $0.1 } == [["version", "--format", "json"]])
    }

    @Test func versionDistinguishesUnavailableFromUnsupportedJSON() async throws {
        let unavailable = ToolHiveRuntimeInspection(runner: ToolHiveInspectionRunner(results: [
            CommandOutput(status: 127, standardOutput: "", standardError: "not found")
        ]))
        #expect(try await unavailable.version() == .unavailable(diagnostic: "not found"))

        let failed = ToolHiveRuntimeInspection(runner: ToolHiveInspectionRunner(results: [
            CommandOutput(status: 2, standardOutput: "", standardError: "unknown flag: --format")
        ]))
        #expect(try await failed.version() == .commandFailed(diagnostic: "unknown flag: --format"))

        let unsupported = ToolHiveRuntimeInspection(runner: ToolHiveInspectionRunner(results: [
            CommandOutput(status: 0, standardOutput: "{\"version\":true}", standardError: "")
        ]))
        guard case .unsupportedResponse = try await unsupported.version() else {
            Issue.record("expected unsupported JSON")
            return
        }
    }

    @Test func statusReturnsToolHiveEvidenceWithoutAHealthClaim() async throws {
        let runner = ToolHiveInspectionRunner(results: [
            CommandOutput(
                status: 0,
                standardOutput: #"{"name":"files","status":"running","health":"unknown","package":"registry/files","url":"http://127.0.0.1:8080/mcp","port":8080,"transport":"streamable-http","proxy_mode":"enabled","group":"local","uptime":"1m"}"#,
                standardError: "warning: token=secret"
            )
        ])
        let result = try await ToolHiveRuntimeInspection(runner: runner).status(workloadName: "files")

        guard case let .available(status, diagnostic) = result else {
            Issue.record("expected typed status")
            return
        }
        #expect(status.status == "running")
        #expect(status.health == "unknown")
        #expect(status.proxyMode == "enabled")
        #expect(diagnostic?.contains("secret") == false)
        let statusCalls = await runner.recordedCalls()
        #expect(statusCalls.map { $0.1 } == [["status", "files", "--format", "json"]])
    }

    @Test func mismatchedOrOversizedStatusResponsesAreUnsupportedBeforeUse() async throws {
        let mismatch = ToolHiveRuntimeInspection(runner: ToolHiveInspectionRunner(results: [
            CommandOutput(status: 0, standardOutput: #"{"name":"other","status":"running","package":"p","url":"u","port":1,"transport":"stdio"}"#, standardError: "")
        ]))
        guard case .unsupportedResponse = try await mismatch.status(workloadName: "files") else {
            Issue.record("expected name mismatch to be unsupported")
            return
        }

        let emptyIdentity = ToolHiveRuntimeInspection(runner: ToolHiveInspectionRunner(results: [
            CommandOutput(status: 0, standardOutput: #"{"name":"files","status":" ","package":"p","url":"u","port":1,"transport":"stdio"}"#, standardError: "")
        ]))
        guard case .unsupportedResponse = try await emptyIdentity.status(workloadName: "files") else {
            Issue.record("expected incomplete identity to be unsupported")
            return
        }

        let oversized = ToolHiveRuntimeInspection(runner: ToolHiveInspectionRunner(results: [
            CommandOutput(status: 0, standardOutput: String(repeating: "x", count: ToolHiveRuntimeInspection.maximumJSONBytes + 1), standardError: "")
        ]))
        guard case .unsupportedResponse = try await oversized.status(workloadName: "files") else {
            Issue.record("expected oversize response to be unsupported")
            return
        }
    }

    @Test func logSnapshotIsBoundedRedactedAndNeverFollows() async throws {
        let runner = ToolHiveInspectionRunner(results: [
            CommandOutput(status: 0, standardOutput: "token=secret\nabcdef", standardError: "")
        ])
        let snapshot = try await ToolHiveRuntimeInspection(runner: runner).logs(
            workloadName: "files",
            proxy: true,
            maximumCharacters: 12
        )

        #expect(snapshot.isProxyLog)
        #expect(snapshot.isTruncated)
        #expect(snapshot.output.count <= 12)
        #expect(snapshot.output.contains("secret") == false)
        let upstream = try await ToolHiveRuntimeInspection(runner: ToolHiveInspectionRunner(results: [
            CommandOutput(status: 0, standardOutput: "one\n[output truncated after 1048576 bytes]", standardError: "")
        ])).logs(workloadName: "files", maximumCharacters: 64)
        #expect(upstream.isTruncated)
        let logCalls = await runner.recordedCalls()
        #expect(logCalls.map { $0.1 } == [["logs", "files", "--proxy"]])
    }

    @Test func invalidNamesAndLimitsDoNotReachTheRunner() async throws {
        let runner = ToolHiveInspectionRunner(results: [])
        let inspector = ToolHiveRuntimeInspection(runner: runner)

        await #expect(throws: ToolHiveRuntimeInspectionError.invalidWorkloadName) {
            try await inspector.status(workloadName: "-option")
        }
        await #expect(throws: ToolHiveRuntimeInspectionError.invalidWorkloadName) {
            try await inspector.logs(workloadName: "name with spaces")
        }
        await #expect(throws: ToolHiveRuntimeInspectionError.invalidLogLimit) {
            try await inspector.logs(workloadName: "files", maximumCharacters: 0)
        }
        #expect(await runner.recordedCalls().isEmpty)
    }

    @Test func cancellationIsCheckedBeforeAndAfterAnInjectedRunner() async {
        let preflightGate = InspectionGate()
        let preflightRunner = ToolHiveInspectionRunner(results: [])
        let preflight = Task {
            await preflightGate.waitForRelease()
            return try await ToolHiveRuntimeInspection(runner: preflightRunner).version()
        }
        preflight.cancel()
        await preflightGate.open()
        await #expect(throws: CancellationError.self) { _ = try await preflight.value }
        #expect(await preflightRunner.recordedCalls().isEmpty)

        let inFlightGate = InspectionGate()
        let inFlightRunner = GatedInspectionRunner(
            gate: inFlightGate,
            result: CommandOutput(
                status: 0,
                standardOutput: #"{"version":"v1","commit":"c","build_date":"d","go_version":"g","platform":"p"}"#,
                standardError: ""
            )
        )
        let inFlight = Task {
            try await ToolHiveRuntimeInspection(runner: inFlightRunner).version()
        }
        await inFlightGate.waitUntilStarted()
        inFlight.cancel()
        await inFlightGate.open()
        await #expect(throws: CancellationError.self) { _ = try await inFlight.value }
        #expect(await inFlightRunner.callCount == 1)
    }
}

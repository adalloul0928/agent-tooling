import Foundation
import Testing

@testable import AgentToolingCore

@MainActor
struct MCPRuntimeRefreshTests {
    @Test func refreshProbesVersionAndListOnceAndPublishesWorkloads() async throws {
        let fixture = try Fixture(runner: RefreshRunner(listResult: .success))
        defer { fixture.remove() }

        await fixture.model.refreshMCPRuntimes()

        let calls = await fixture.runner.calls
        #expect(calls == [["version", "--format", "json"], ["list", "--all", "--format", "json"]])
        #expect(fixture.model.mcpRuntimeServers.map(\.name) == ["filesystem"])
        #expect(fixture.model.mcpRuntimeServers.first?.status == "running")
        #expect(fixture.model.mcpRuntimeError == nil)
        let toolHive = try #require(fixture.model.mcpRuntimeStatuses.first { $0.id == "toolhive" })
        #expect(toolHive.version == "0.34.0")
        #expect(toolHive.capabilities == [.health, .logs])
        #expect(!toolHive.capabilities.contains(.lifecycle))
        #expect(fixture.model.isRefreshingMCPRuntimes == false)
    }

    @Test func failedListKeepsFailureVisibleInsteadOfReportingAuthoritativeEmptySuccess() async throws {
        let fixture = try Fixture(runner: RefreshRunner(listResult: .failure))
        defer { fixture.remove() }

        await fixture.model.refreshMCPRuntimes()

        #expect(fixture.model.mcpRuntimeServers.isEmpty)
        #expect(fixture.model.mcpRuntimeError?.contains("could not list") == true)
        #expect(fixture.model.mcpRuntimeError?.contains("fixture list failure") == true)
        #expect(fixture.model.isRefreshingMCPRuntimes == false)
        #expect(await fixture.runner.callCount == 2)
    }

    @Test func overlappingRefreshesCoalesceToOneInFlightProbe() async throws {
        let runner = RefreshRunner(listResult: .success, holdList: true)
        let fixture = try Fixture(runner: runner)
        defer { fixture.remove() }

        let first = Task { @MainActor in await fixture.model.refreshMCPRuntimes() }
        await runner.waitForListStart()
        await fixture.model.refreshMCPRuntimes()
        #expect(fixture.model.isRefreshingMCPRuntimes)
        await runner.releaseList()
        await first.value

        #expect(await runner.callCount == 2)
        #expect(fixture.model.isRefreshingMCPRuntimes == false)
        #expect(fixture.model.mcpRuntimeServers.count == 1)
    }

    @MainActor private struct Fixture {
        let root: URL
        let runner: RefreshRunner
        let model: AppModel

        init(runner: RefreshRunner) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "mcp-runtime-refresh-\(UUID())")
            self.runner = runner
            model = try AppModel(store: WorkspaceStore(rootURL: root.appending(path: "store")),
                runner: runner, homeURL: root.appending(path: "home"))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor RefreshRunner: CommandRunning {
    enum ListResult: Sendable { case success, failure }

    let listResult: ListResult
    let holdList: Bool
    private(set) var calls: [[String]] = []
    private var listStarted = false
    private var listStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var listRelease: CheckedContinuation<Void, Never>?

    init(listResult: ListResult, holdList: Bool = false) {
        self.listResult = listResult
        self.holdList = holdList
    }

    var callCount: Int { calls.count }

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        #expect(executable == "thv")
        calls.append(arguments)
        if arguments == ["version", "--format", "json"] {
            return CommandOutput(status: 0,
                standardOutput: #"{"version":"0.34.0","commit":"abc","build_date":"fixture","go_version":"go1.25","platform":"darwin/arm64"}"#,
                standardError: "")
        }
        #expect(arguments == ["list", "--all", "--format", "json"])
        if holdList {
            listStarted = true
            listStartWaiters.forEach { $0.resume() }
            listStartWaiters.removeAll()
            await withCheckedContinuation { continuation in
                listRelease = continuation
            }
        }
        switch listResult {
        case .success:
            return CommandOutput(status: 0, standardOutput: #"[{"name":"filesystem","package":"ghcr.io/example/filesystem:1.0.0","url":"http://127.0.0.1:3000","transport_type":"stdio","status":"running","group":"local","remote":false}]"#, standardError: "")
        case .failure:
            return CommandOutput(status: 1, standardOutput: "", standardError: "fixture list failure")
        }
    }

    func waitForListStart() async {
        if listStarted { return }
        await withCheckedContinuation { continuation in listStartWaiters.append(continuation) }
    }

    func releaseList() async {
        listRelease?.resume()
        listRelease = nil
    }
}

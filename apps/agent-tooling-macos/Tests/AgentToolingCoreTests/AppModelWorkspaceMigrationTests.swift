import Foundation
import Testing

@testable import AgentToolingCore

@MainActor
struct AppModelWorkspaceMigrationTests {
    @Test func beginEntersGateWithoutCreatingOrRunningJobs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let location = try #require(fixture.model.beginWorkspaceMigrationReview())
        await fixture.model.refreshMCPRuntimes()
        await fixture.model.refreshSkillAvailability()

        #expect(fixture.model.isWorkspaceMigrationReviewActive)
        #expect(location.legacyRoot == fixture.store.rootURL)
        let calls = await fixture.runner.recordedInvocations()
        #expect(calls.isEmpty)
        #expect(fixture.model.mcpRuntimeStatuses.isEmpty)
    }

    @Test func busyOrSafetyReviewRefusesBeginUntilOperationFinishes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.model.isRunningDoctor = true
        #expect(fixture.model.beginWorkspaceMigrationReview() == nil)
        fixture.model.isRunningDoctor = false
        fixture.model.isExecutingPlan = true
        #expect(fixture.model.beginWorkspaceMigrationReview() == nil)
        fixture.model.isExecutingPlan = false
        #expect(fixture.model.beginWorkspaceMigrationReview() != nil)
    }

    @Test func awaitedRuntimeRefreshKeepsGateEntryClosedUntilItFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "migration-gate-await-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = HeldRunner()
        let store = try WorkspaceStore(rootURL: root.appending(path: "store"))
        let model = try AppModel(store: store, runner: runner, homeURL: root.appending(path: "home"))
        let refresh = Task { @MainActor in await model.refreshMCPRuntimes() }
        await runner.waitForStart()
        #expect(model.beginWorkspaceMigrationReview() == nil)
        await runner.release()
        await refresh.value
        #expect(model.beginWorkspaceMigrationReview() != nil)
        model.endWorkspaceMigrationReview()
    }

    @Test func gateBlocksConcretePersistenceUntilCancelled() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(fixture.model.beginWorkspaceMigrationReview() != nil)
        #expect(fixture.model.createProfile(name: "Blocked", summary: "No write", scope: .user, projectRoot: nil) == nil)
        #expect((try fixture.store.loadWorkspaceSnapshot()?.profiles ?? []).contains { $0.id == "blocked" } == false)
        fixture.model.endWorkspaceMigrationReview()
        #expect(fixture.model.createProfile(name: "Allowed", summary: "After cancel", scope: .user, projectRoot: nil) != nil)
        #expect(try fixture.store.loadWorkspaceSnapshot()?.profiles.contains { $0.id == "allowed" } == true)
    }

    @Test func cancellingGateRestoresNormalRefreshBehavior() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(fixture.model.beginWorkspaceMigrationReview() != nil)
        fixture.model.endWorkspaceMigrationReview()

        await fixture.model.refreshMCPRuntimes()

        #expect(fixture.model.isWorkspaceMigrationReviewActive == false)
        let calls = await fixture.runner.recordedInvocations()
        #expect(calls.contains { $0.first == "thv" })
    }

    @Test func reenteringActiveGateIsRefusedAndDoesNotReplaceLocation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try #require(fixture.model.beginWorkspaceMigrationReview())

        #expect(fixture.model.beginWorkspaceMigrationReview() == nil)
        #expect(fixture.model.isWorkspaceMigrationReviewActive)
        #expect(first.legacyRoot == fixture.store.rootURL)
        fixture.model.endWorkspaceMigrationReview()
    }

    @MainActor private struct Fixture {
        let root: URL
        let store: WorkspaceStore
        let runner: RecordingRunner
        let model: AppModel

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "migration-gate-\(UUID())")
            store = try WorkspaceStore(rootURL: root.appending(path: "store"))
            runner = RecordingRunner()
            model = try AppModel(store: store, runner: runner, homeURL: root.appending(path: "home"))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor RecordingRunner: CommandRunning {
    private var invocations: [[String]] = []

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        invocations.append([executable] + arguments)
        return CommandOutput(status: 127, standardOutput: "", standardError: "unavailable")
    }

    func recordedInvocations() -> [[String]] { invocations }
}

private actor HeldRunner: CommandRunning {
    private var callCount = 0
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        callCount += 1
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        if callCount == 1 { await withCheckedContinuation { releaseContinuation = $0 } }
        return CommandOutput(status: 127, standardOutput: "", standardError: "held")
    }

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

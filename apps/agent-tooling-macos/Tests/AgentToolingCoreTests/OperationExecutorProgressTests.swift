import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// The executor's step events: each step begins and ends in the plan's order,
/// each event is awaited before the run goes on, a step that never runs ends
/// without beginning, and a stopped plan stops between steps, finishing the
/// step it is on and writing its receipt.
@Suite("Operation executor progress", .timeLimit(.minutes(5)))
struct OperationExecutorProgressTests {
    @Test func eachStepBeginsAndEndsInThePlansOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let steps = [fixture.manual("One"), fixture.manual("Two"), fixture.manual("Three")]
        let recorder = EventRecorder<OperationStepEvent>()

        let receipt = await fixture.executor().execute(fixture.plan(steps)) { recorder.record($0) }

        #expect(
            Fixture.shape(recorder.events) == steps.flatMap { ["started \($0.id)", "finished \($0.id) manual"] })
        #expect(receipt.results.map(\.stepID) == steps.map(\.id))
        #expect(recorder.events.compactMap(\.result) == receipt.results)
    }

    /// Nothing runs ahead of what is drawing the progress: the next step waits
    /// until the event before it has been handled.
    @Test func eachEventIsAwaitedBeforeTheRunGoesOn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = GatedCommandRunner()
        let command = fixture.gitStatus()
        let steps = [fixture.manual("First"), command]
        let handler = GatedCommandRunner()
        let recorder = EventRecorder<OperationStepEvent>()

        let run = Task {
            await fixture.executor(runner: gate).execute(fixture.plan(steps)) { event in
                recorder.record(event)
                // The first step's end is held until the test lets it go.
                if case .finished(let result) = event, result.stepID == steps[0].id {
                    _ = try? await handler.run(executable: "progress", arguments: [], currentDirectory: nil)
                }
            }
        }
        await handler.waitUntilCalled()
        #expect(gate.launches.isEmpty)
        #expect(Fixture.shape(recorder.events) == ["started \(steps[0].id)", "finished \(steps[0].id) manual"])
        handler.release()
        await gate.waitUntilCalled()
        gate.release()
        let receipt = await run.value

        #expect(receipt.results.map(\.status) == [.manual, .succeeded])
        #expect(Fixture.shape(recorder.events).last == "finished \(command.id) succeeded")
    }

    /// Stopping a plan stops it between steps: the step under way runs to its
    /// end, uncancelled; every step after it ends skipped without beginning;
    /// and the receipt is written.
    @Test func aStoppedPlanFinishesTheStepItIsOnAndSkipsTheRest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = GatedCommandRunner()
        let steps = [fixture.manual("Before"), fixture.gitStatus(), fixture.manual("After"), fixture.manual("Last")]
        let recorder = EventRecorder<OperationStepEvent>()
        let executor = fixture.executor(runner: gate)

        let run = Task { await executor.execute(fixture.plan(steps)) { recorder.record($0) } }
        await gate.waitUntilCalled()
        run.cancel()
        gate.release()
        let receipt = await run.value

        #expect(gate.cancelledCalls == 0)
        #expect(
            Fixture.shape(recorder.events) == [
                "started \(steps[0].id)", "finished \(steps[0].id) manual", "started \(steps[1].id)",
                "finished \(steps[1].id) succeeded", "finished \(steps[2].id) skipped", "finished \(steps[3].id) skipped",
            ])
        #expect(receipt.results.map(\.status) == [.manual, .succeeded, .skipped, .skipped])
        #expect(receipt.results[2].output == "Cancelled before this step ran.")
        #expect(receipt.results[3].output == "Skipped because the operation was cancelled.")
        #expect(try fixture.store.operationReceipts().map(\.planID).contains(receipt.planID))
    }

    /// A required check that fails stops the plan, and the steps after it end
    /// skipped without beginning.
    @Test func aFailedRequiredStepEndsTheRestWithoutStartingThem() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let failing = OperationStep(
            kind: .command, title: "Check", detail: "", executable: "git",
            arguments: ["-C", fixture.backupRoot, "status", "--short"], stopsOnFailure: true)
        let steps = [failing, fixture.manual("Never")]
        let recorder = EventRecorder<OperationStepEvent>()
        let runner = ScriptedCommandRunner([:])

        let receipt = await fixture.executor(runner: runner).execute(fixture.plan(steps)) { recorder.record($0) }

        #expect(receipt.results.map(\.status) == [.failed, .skipped])
        #expect(
            Fixture.shape(recorder.events) == [
                "started \(failing.id)", "finished \(failing.id) failed", "finished \(steps[1].id) skipped",
            ])
    }

    @Test func withoutAListenerThePlanRunsAsItAlwaysHas() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let receipt = await fixture.executor().execute(fixture.plan([fixture.manual("Alone")]))
        #expect(receipt.results.map(\.status) == [.manual])
    }

    private struct Fixture {
        let root: URL
        let store: WorkspaceRevisionStore
        let home: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "executor-progress-\(UUID())")
            home = root.appending(path: "home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let document = try WorkspaceDocumentCoding.seal(
                .init(workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID())))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(
                containerRoot: root.appending(path: "workspace", directoryHint: .isDirectory),
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            try store.prepareManagedDirectories()
        }

        /// The git backup folder, the one place the executor lets `git` look.
        var backupRoot: String {
            store.rootURL.appending(path: "exports/git-backup", directoryHint: .isDirectory).standardizedFileURL
                .path(percentEncoded: false)
        }

        func executor(runner: some CommandRunning = RefusingCommandRunner()) -> OperationExecutor {
            OperationExecutor(store: store, runner: runner, homeURL: home)
        }

        /// A step that asks the person to do something: it ends at once,
        /// touching nothing.
        func manual(_ title: String) -> OperationStep {
            OperationStep(kind: .manual, title: title, detail: "\(title).")
        }

        /// A command step the policy admits, which runs through the runner.
        func gitStatus() -> OperationStep {
            OperationStep(
                kind: .command, title: "Status", detail: "", executable: "git", arguments: ["-C", backupRoot, "status", "--short"])
        }

        func plan(_ steps: [OperationStep]) -> OperationPlan {
            OperationPlan(kind: .installSkill, title: "Progress", summary: "", steps: steps)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        /// Each event as a line: "started <id>" or "finished <id> <status>".
        static func shape(_ events: [OperationStepEvent]) -> [String] {
            events.map { event in
                switch event {
                case .started(let id): "started \(id)"
                case .finished(let result): "finished \(result.stepID) \(result.status.rawValue)"
                }
            }
        }
    }
}

extension OperationStepEvent {
    /// The result a `finished` event carries.
    fileprivate var result: OperationStepResult? {
        if case .finished(let result) = self { result } else { nil }
    }
}

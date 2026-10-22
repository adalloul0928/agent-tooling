import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// What the setup stage needs of this Mac's device session: it opens on the
/// last recorded check, a check that was stopped records nothing, a re-check
/// of the apps an install touched leaves the others alone, and the stage's own
/// read is kept as a check without scanning again.
@Suite("Device session for setup", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct WorkspaceDeviceSessionLaunchpadTests {
    /// The first run's read is recorded in revision 1, so a session opened on
    /// that workspace shows it, dated as it was read, without a check.
    @Test func aNewSessionOpensOnTheRecordedCheck() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace

        let reopened = WorkspaceLaunch.sessions(
            store: workspace.store, homeRoot: fixture.home, isFirstRun: false, services: fixture.environment.sessions)

        #expect(reopened.device.observations == workspace.device.observations)
        #expect(reopened.device.observations.map(\.surface) == [.claudeCode, .codexCLI, .geminiCLI])
        #expect(reopened.device.lastCheckedAt == ClientHomeFixture.now)
        #expect(reopened.device.verdict(for: .claude).state == .healthy)
        #expect(fixture.observer.fullChecks == 0)
        #expect(fixture.observer.scopedChecks.isEmpty)
    }

    /// The consent and projects choices revision 1 recorded are read back,
    /// and the consent in force falls back to today's behaviour only when
    /// nothing was recorded.
    @Test func theRecordedChoicesAreReadBack() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace

        #expect(workspace.device.assistantRuns == .off)
        #expect(workspace.device.effectiveAssistantRuns == .off)
        #expect(workspace.device.findsProjectsFromClaudeHistory == true)

        let legacy = try await ShellRenderFixture()
        defer { legacy.remove() }
        #expect(legacy.workspace.device.assistantRuns == nil)
        #expect(legacy.workspace.device.effectiveAssistantRuns == .existingBehaviour)
    }

    /// The tool folders a Mac recorded are applied through the injected
    /// registration, never the process-wide one a fixture must not touch.
    @Test func recordedToolFoldersGoThroughTheInjectedRegistration() async throws {
        var fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let registered = RegisteredRoots()
        fixture.environment.sessions.registerToolRoots = { registered.append($0) }
        var seed = fixture.seed
        seed.toolDirectories = ["/opt/tools/bin"]

        _ = try await WorkspaceLaunch.create(
            observations: fixture.orderedObservations, preferences: seed.preferences, supportRoot: fixture.support,
            homeRoot: fixture.home, beforeRecord: { _ in }, services: fixture.environment.sessions)

        #expect(registered.calls == [["/opt/tools/bin"]])
    }

    /// A check that was stopped part-way is not a check: what it read is
    /// dropped, and nothing is recorded.
    @Test func aCancelledCheckRecordsNothing() async throws {
        var fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let observer = HeldDeviceObserver()
        fixture.environment.sessions.deviceObserver = observer
        let workspace = try await fixture.sample(.afterRead).workspace
        let before = workspace.device.observations
        let head = try fixture.head(of: workspace)
        observer.answer = Self.observations(fixture.orderedObservations, codexVersion: "codex-cli 0.170.0")

        let check = Task { await workspace.device.refresh() }
        await observer.waitUntilAsked()
        check.cancel()
        observer.release()
        await check.value

        #expect(workspace.device.observations == before)
        #expect(try fixture.head(of: workspace) == head)
        #expect(try workspace.store.snapshot()?.device.observations == before)
    }

    /// D29: after an install, only the apps it touched are checked again, and
    /// what they report replaces only their own readings.
    @Test func aScopedReCheckReplacesOnlyTheAppsItRead() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let gemini = try #require(workspace.device.observations.first { $0.surface == .geminiCLI })
        fixture.observer.answer(
            with: Self.observations(fixture.orderedObservations, codexVersion: "codex-cli 0.170.0", geminiVersion: "0.40.0"))

        await workspace.device.refresh(only: [.codex])

        #expect(fixture.observer.scopedChecks == [[.codex]])
        #expect(fixture.observer.fullChecks == 0)
        let observations = workspace.device.observations
        #expect(observations.map(\.surface) == [.claudeCode, .codexCLI, .geminiCLI])
        #expect(observations.first { $0.surface == .codexCLI }?.version == "codex-cli 0.170.0")
        #expect(observations.first { $0.surface == .geminiCLI } == gemini)
        #expect(try workspace.store.snapshot()?.device.observations == observations)
    }

    @Test func aScopedReCheckOfNothingChecksNothing() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace

        await workspace.device.refresh(only: [])

        #expect(fixture.observer.scopedChecks.isEmpty)
    }

    /// The stage's own read is kept as this Mac's check: nothing is scanned,
    /// the surfaces it read are replaced, and the others stay.
    @Test func theStagesReadIsAdoptedWithoutAScan() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let workspace = try await fixture.sample(.afterRead).workspace
        let read = Self.observations(fixture.orderedObservations, codexVersion: "codex-cli 0.171.0")
            .filter { $0.surface == .codexCLI }

        await workspace.device.adopt(read)

        #expect(fixture.observer.fullChecks == 0)
        #expect(fixture.observer.scopedChecks.isEmpty)
        #expect(workspace.device.observations.count == 3)
        #expect(workspace.device.observations.first { $0.surface == .codexCLI }?.version == "codex-cli 0.171.0")
        #expect(try workspace.store.snapshot()?.device.observations == workspace.device.observations)
    }

    /// The stage's read handed over while a check is running waits for that
    /// check and lands over it: it is never dropped, and it is the read the
    /// person was shown.
    @Test func aReadAdoptedDuringACheckWaitsForItAndLands() async throws {
        var fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let observer = HeldDeviceObserver()
        fixture.environment.sessions.deviceObserver = observer
        let workspace = try await fixture.sample(.afterRead).workspace
        observer.answer = Self.observations(fixture.orderedObservations, codexVersion: "codex-cli 0.170.0")
        let read = Self.observations(fixture.orderedObservations, codexVersion: "codex-cli 0.171.0")
            .filter { $0.surface == .codexCLI }

        let check = Task { await workspace.device.refresh() }
        await observer.waitUntilAsked()
        // Lets the check answer only once the adopted read is waiting on it.
        let letTheCheckAnswer = Task { observer.release() }
        await workspace.device.adopt(read)
        await check.value
        await letTheCheckAnswer.value

        #expect(observer.calls == 1)
        #expect(workspace.device.observations.first { $0.surface == .codexCLI }?.version == "codex-cli 0.171.0")
        #expect(try workspace.store.snapshot()?.device.observations == workspace.device.observations)
        #expect(!workspace.device.isChecking)
    }

    /// D29: the re-check after an install waits for a check already running
    /// (it may have read the apps before the install changed them), then runs.
    @Test func aScopedReCheckDuringACheckRunsAfterIt() async throws {
        var fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let observer = HeldDeviceObserver()
        fixture.environment.sessions.deviceObserver = observer
        let workspace = try await fixture.sample(.afterRead).workspace
        observer.answer = Self.observations(fixture.orderedObservations, codexVersion: "codex-cli 0.170.0")

        let check = Task { await workspace.device.refresh() }
        await observer.waitUntilAsked()
        let letTheCheckAnswer = Task { observer.release() }
        await workspace.device.refresh(only: [.codex])
        await check.value
        await letTheCheckAnswer.value

        #expect(observer.calls == 2)
        #expect(workspace.device.observations.first { $0.surface == .codexCLI }?.version == "codex-cli 0.170.0")
        #expect(!workspace.device.isChecking)
    }

    @Test func mergingReplacesBySurfaceInSurfaceOrder() {
        let existing = [
            ShellRenderFixture.observation(.codexCLI, installed: true, commandAvailable: true, version: "1"),
            ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true, version: "1"),
        ]
        let fresh = [
            ShellRenderFixture.observation(.geminiCLI, installed: true, commandAvailable: true, version: "2"),
            ShellRenderFixture.observation(.codexCLI, installed: true, commandAvailable: true, version: "2"),
        ]

        let merged = WorkspaceDeviceSession.merged(existing, with: fresh)

        #expect(merged.map(\.surface) == [.claudeCode, .codexCLI, .geminiCLI])
        #expect(merged.map(\.version) == ["1", "2", "2"])
    }

    // MARK: - Helpers

    /// `observations` with Codex's (and Gemini CLI's) version changed, as a
    /// later check would read them.
    private static func observations(
        _ observations: [TargetObservation], codexVersion: String, geminiVersion: String? = nil
    ) -> [TargetObservation] {
        observations.map { observation in
            var observation = observation
            if observation.surface == .codexCLI { observation.version = codexVersion }
            if observation.surface == .geminiCLI, let geminiVersion { observation.version = geminiVersion }
            return observation
        }
    }
}

/// A check that holds until the test lets it answer.
private final class HeldDeviceObserver: DeviceObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var answerValue: [TargetObservation] = []
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
    private var askedWaiters: [CheckedContinuation<Void, Never>] = []
    private var asked = false
    private var count = 0

    /// How many checks reached it.
    var calls: Int { lock.withLock { count } }

    var answer: [TargetObservation] {
        get { lock.withLock { answerValue } }
        set { lock.withLock { answerValue = newValue } }
    }

    func waitUntilAsked() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock {
                if asked { return true }
                askedWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock {
            released = true
            let continuation = held
            held = nil
            return continuation
        }
        continuation?.resume()
    }

    func observe(homeRoot: URL) async throws -> [TargetObservation] {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (waiters, ready) = lock.withLock {
                asked = true
                count += 1
                let waiters = askedWaiters
                askedWaiters = []
                if released { return (waiters, true) }
                held = continuation
                return (waiters, false)
            }
            for waiter in waiters { waiter.resume() }
            if ready { continuation.resume() }
        }
        return answer
    }
}

/// The tool folders each registration was handed.
private final class RegisteredRoots: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    var calls: [[String]] { lock.withLock { recorded } }

    func append(_ roots: [String]) {
        lock.withLock { recorded.append(roots) }
    }
}

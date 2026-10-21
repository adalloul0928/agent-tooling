import AgentToolingCore
import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// ⌘Q while something finishes waits it out, and then stops whatever that
/// left running: the read's commit is finishing work, but the sign-in reads
/// it started go on after it, stoppable, and no command they started may
/// outlive the app. Work asked to stop that does not is asked once, so a quit
/// waits one grace for it.
@Suite("App launch state · a finishing quit", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct AppLaunchStateFinishingQuitTests {
    @Test func aQuitStopsWhatFinishingWorkLeavesRunning() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let launch = AppLaunchStateTests.launch(fixture)
        let flow = try #require(launch.flow)
        // The read as ⌘Q lands mid-commit: finishing, then stoppable while
        // its sign-in reads land, then stopped.
        let read = QuitModel(.finishing(LaunchpadCopy.Footer.creatingLibrary), then: [.stoppable, .idle])
        _ = flow.model(for: .reads) { read }

        let plan = launch.terminationPlan()
        #expect(plan == .afterFinishing)
        await launch.prepareToTerminate(plan)

        // Waited out as it finished, then stopped once it could be.
        #expect(read.interrupted == 2)
        #expect(read.interruption == .idle)
        #expect(flow.interruption == .idle)
    }

    /// The real read, ⌘Q landing while its library is made and its sign-in
    /// reads are still out: the quit waits for the library, then stops the
    /// sign-in reads, and nothing is left running.
    @Test func aQuitMidCommitWaitsForTheLibraryThenStopsTheSignInReads() async throws {
        let signIn = GatedCommandRunner()
        defer { signIn.release() }
        var fixture = try await LaunchpadFixture(signInGate: signIn)
        defer { fixture.remove() }
        // The commit holds where it writes the setup record, between revision
        // 1 and the locator, until the quit is waiting for it.
        let commit = HeldFirstRecord()
        defer { commit.open() }
        let stores = fixture.environment.sessions.setupProgressStore
        fixture.environment.sessions.setupProgressStore = { commit.holding(stores($0)) }
        let launch = AppLaunchStateTests.launch(fixture)
        let flow = try #require(launch.flow)
        flow.choosePath(.startHere)
        LaunchpadStageView.footer(for: flow).primary?.action()
        #expect(flow.step == .reads)
        let read = LaunchpadReadSession.of(flow)
        LaunchpadStageView.footer(for: flow).primary?.action()
        await waitUntil { read.phase == .committing }
        await signIn.waitUntilCalled(times: 2)
        #expect(!fixture.hasWorkspace, "the library is not made yet")

        let plan = launch.terminationPlan()
        #expect(plan == .afterFinishing)
        let quit = Task { await launch.prepareToTerminate(plan) }
        // The quit runs up to its wait for the commit before the commit goes
        // on: both run on the main actor, the quit first.
        await Task.yield()
        commit.open()
        await quit.value

        #expect(fixture.hasWorkspace, "the library was made")
        #expect(read.phase == .finished)
        await waitUntil { signIn.cancelledCalls == 2 }
        #expect(read.signIn.isFinished)
        #expect(read.interruption == .idle)
        #expect(flow.interruption == .idle)
    }

    /// A model that is asked to stop and stays stoppable (a command that
    /// ignores its cancellation) is asked once: the quit goes on after one
    /// grace rather than asking again and waiting a second.
    @Test func workThatWillNotStopIsAskedOnce() async throws {
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let launch = AppLaunchStateTests.launch(fixture)
        let flow = try #require(launch.flow)
        let stuck = StuckModel()
        defer { stuck.release() }
        _ = flow.model(for: .reads) { stuck }

        let plan = launch.terminationPlan()
        #expect(plan == .afterStopping)
        let started = ContinuousClock.now
        await launch.prepareToTerminate(plan)

        #expect(stuck.interrupted == 1)
        #expect(ContinuousClock.now - started >= LaunchpadFlow.stopGrace, "it waited out the grace")
        #expect(flow.interruption == .stoppable)
    }
}

/// A model whose work moves on one state each time it is interrupted.
@MainActor
private final class QuitModel: LaunchpadInterruptible {
    private(set) var interruption: LaunchpadInterruption
    private(set) var interrupted = 0
    private var next: [LaunchpadInterruption]

    init(_ interruption: LaunchpadInterruption, then next: [LaunchpadInterruption]) {
        self.interruption = interruption
        self.next = next
    }

    func interrupt() async {
        interrupted += 1
        if !next.isEmpty { interruption = next.removeFirst() }
    }
}

/// A model whose stop never ends until the test lets it, and which stays
/// stoppable meanwhile.
@MainActor
private final class StuckModel: LaunchpadInterruptible {
    let interruption = LaunchpadInterruption.stoppable
    private(set) var interrupted = 0
    private var stops: [CheckedContinuation<Void, Never>] = []

    func interrupt() async {
        interrupted += 1
        await withCheckedContinuation { stops.append($0) }
    }

    func release() {
        let waiting = stops
        stops = []
        for stop in waiting { stop.resume() }
    }
}

/// Holds the first setup record any of its stores saves until the test
/// opens it; every later save goes straight through. The commit saves the
/// record off the main actor, between revision 1 and the locator, so
/// holding it there keeps the commit finishing without blocking the main
/// actor.
private final class HeldFirstRecord: @unchecked Sendable {
    private let opened = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasHeld = false
    private var isOpen = false

    func holding(_ store: any SetupProgressStoring) -> any SetupProgressStoring {
        HeldStore(inner: store, gate: self)
    }

    func open() {
        let opens = lock.withLock {
            defer { isOpen = true }
            return !isOpen
        }
        if opens { opened.signal() }
    }

    /// Waits for `open()` on the first save only.
    fileprivate func holdIfFirst() {
        let first = lock.withLock {
            defer { hasHeld = true }
            return !hasHeld
        }
        if first { opened.wait() }
    }

    private struct HeldStore: SetupProgressStoring {
        let inner: any SetupProgressStoring
        let gate: HeldFirstRecord

        func load() -> SetupProgressRecord? { inner.load() }

        func save(_ record: SetupProgressRecord) throws {
            gate.holdIfFirst()
            try inner.save(record)
        }

        func loadPlacementsMadeHere() -> [WorkspaceObjectID] { inner.loadPlacementsMadeHere() }

        func savePlacementsMadeHere(_ contributionIDs: [WorkspaceObjectID]) throws {
            try inner.savePlacementsMadeHere(contributionIDs)
        }
    }
}

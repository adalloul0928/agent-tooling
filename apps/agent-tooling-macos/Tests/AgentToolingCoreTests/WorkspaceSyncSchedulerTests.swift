import Foundation
import Testing

@testable import AgentToolingCore

/// When an automatic pass may run. Every refusal has a reason, so a quiet
/// scheduler is never mistaken for a working one.
@Suite("Workspace sync scheduler")
struct WorkspaceSyncSchedulerTests {
    @Test func aConnectedWorkspaceRunsOnceThenWaits() {
        let scheduler = WorkspaceSyncScheduler()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var state = WorkspaceSyncScheduler.State(isConnected: true)

        #expect(scheduler.decide(state, now: now) == .run)

        state.lastAttempt = now
        #expect(scheduler.decide(state, now: now.addingTimeInterval(60))
            == .tooSoon(nextEligible: now.addingTimeInterval(WorkspaceSyncScheduler.interval)))
        #expect(scheduler.decide(state, now: now.addingTimeInterval(WorkspaceSyncScheduler.interval)) == .run)
    }

    @Test func anUnresolvedConflictStopsAutomaticPasses() {
        let scheduler = WorkspaceSyncScheduler()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let state = WorkspaceSyncScheduler.State(isConnected: true, hasUnresolvedConflicts: true,
                                                 lastAttempt: now.addingTimeInterval(-86_400))

        // Repeating the pass would only produce the same question.
        #expect(scheduler.decide(state, now: now) == .waitingForDecisions)
    }

    @Test func everyOtherRefusalSaysWhy() {
        let scheduler = WorkspaceSyncScheduler()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(scheduler.decide(.init(isEnabled: false, isConnected: true), now: now) == .disabled)
        #expect(scheduler.decide(.init(isConnected: false), now: now) == .notConnected)
        #expect(scheduler.decide(.init(isConnected: true, isRunning: true), now: now) == .alreadyRunning)
    }

    @Test func repeatedFailuresBackOffToACeilingRatherThanRetryingConstantly() {
        let base = WorkspaceSyncScheduler.interval
        #expect(WorkspaceSyncScheduler.wait(afterFailures: 0) == base)
        #expect(WorkspaceSyncScheduler.wait(afterFailures: 1) == base * 2)
        #expect(WorkspaceSyncScheduler.wait(afterFailures: 3) == base * 8)
        #expect(WorkspaceSyncScheduler.wait(afterFailures: 99) == WorkspaceSyncScheduler.maximumBackoff)
        // A very large failure count must not overflow into an early retry.
        #expect(WorkspaceSyncScheduler.wait(afterFailures: Int.max) == WorkspaceSyncScheduler.maximumBackoff)
    }

    @Test func aFailingRepositoryIsRetriedLaterNotSooner() {
        let scheduler = WorkspaceSyncScheduler()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let state = WorkspaceSyncScheduler.State(isConnected: true, lastAttempt: now, consecutiveFailures: 2)

        let decision = scheduler.decide(state, now: now.addingTimeInterval(WorkspaceSyncScheduler.interval))

        #expect(decision == .tooSoon(nextEligible: now.addingTimeInterval(WorkspaceSyncScheduler.interval * 4)))
    }
}

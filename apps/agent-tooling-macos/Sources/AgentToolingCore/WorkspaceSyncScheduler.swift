import Foundation

/// Why a scheduled pass did or did not run, so a quiet scheduler is never
/// mistaken for a working one.
public enum WorkspaceSyncScheduleDecision: Hashable, Sendable {
    case run
    /// Too soon since the last attempt.
    case tooSoon(nextEligible: Date)
    /// A pass is already running; passes never overlap.
    case alreadyRunning
    /// The last pass ended in conflicts. Automatic passes stop until a person
    /// decides, because repeating them would only produce the same question.
    case waitingForDecisions
    /// This Mac is not connected to a repository.
    case notConnected
    /// The person turned automatic syncing off.
    case disabled
}

/// Decides when an automatic sync pass may run.
///
/// It is pure and takes the clock as an input, so its behavior is testable
/// rather than time-dependent. It never runs anything itself: a caller asks
/// whether now is a good moment and does the work. Passes never overlap, a
/// failure backs off instead of retrying immediately, and an unresolved conflict
/// stops automatic passes entirely until a person decides.
public struct WorkspaceSyncScheduler: Sendable {
    public struct State: Hashable, Sendable {
        public var isEnabled: Bool
        public var isConnected: Bool
        public var isRunning: Bool
        public var hasUnresolvedConflicts: Bool
        public var lastAttempt: Date?
        /// Consecutive failures, which lengthen the wait.
        public var consecutiveFailures: Int

        public init(
            isEnabled: Bool = true,
            isConnected: Bool = false,
            isRunning: Bool = false,
            hasUnresolvedConflicts: Bool = false,
            lastAttempt: Date? = nil,
            consecutiveFailures: Int = 0
        ) {
            self.isEnabled = isEnabled
            self.isConnected = isConnected
            self.isRunning = isRunning
            self.hasUnresolvedConflicts = hasUnresolvedConflicts
            self.lastAttempt = lastAttempt
            self.consecutiveFailures = consecutiveFailures
        }
    }

    /// Ordinary spacing between automatic passes.
    public static let interval: TimeInterval = 15 * 60
    /// The longest a run of failures will push the next attempt out.
    public static let maximumBackoff: TimeInterval = 4 * 60 * 60

    public init() {}

    public func decide(_ state: State, now: Date) -> WorkspaceSyncScheduleDecision {
        guard state.isEnabled else { return .disabled }
        guard state.isConnected else { return .notConnected }
        guard !state.isRunning else { return .alreadyRunning }
        guard !state.hasUnresolvedConflicts else { return .waitingForDecisions }
        guard let lastAttempt = state.lastAttempt else { return .run }
        let eligible = lastAttempt.addingTimeInterval(Self.wait(afterFailures: state.consecutiveFailures))
        return now >= eligible ? .run : .tooSoon(nextEligible: eligible)
    }

    /// Doubles per consecutive failure, up to a ceiling, so an unreachable
    /// repository is retried occasionally rather than constantly.
    public static func wait(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return interval }
        let multiplier = pow(2.0, Double(min(failures, 16)))
        return min(interval * multiplier, maximumBackoff)
    }
}

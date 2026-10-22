import AgentToolingCore
import Foundation

/// Holds every command it is asked to run until the test releases it, and
/// throws `CancellationError` at once when the calling task is cancelled, the
/// way the real runner stops its child.
///
/// A test of Stop, Skip or per-step progress waits on events with it, never
/// on time: `waitUntilCalled()` returns once the work has reached the runner,
/// `release()` lets it finish, and `cancelledCalls` says whether a
/// cancellation reached it.
public final class GatedCommandRunner: CommandRunning, Sendable {
    private enum Arrival: Sendable {
        case hold
        case release
        case cancel
    }

    private struct ArrivalWaiter: Sendable {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var launches: [CommandLaunch] = []
        var isReleased = false
        var cancelledCalls = 0
        var held: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var cancelledBeforeHeld: Set<UUID> = []
        var arrivalWaiters: [ArrivalWaiter] = []

        /// The waiters the calls so far satisfy, removed from the list.
        mutating func takeSatisfiedWaiters() -> [CheckedContinuation<Void, Never>] {
            let ready = arrivalWaiters.filter { $0.count <= launches.count }
            arrivalWaiters.removeAll { $0.count <= launches.count }
            return ready.map(\.continuation)
        }
    }

    private let state = LockedState(State())
    private let answer: CommandOutput

    /// Every released call returns `answer`.
    public init(answer: CommandOutput = CommandOutput(status: 0, standardOutput: "", standardError: "")) {
        self.answer = answer
    }

    /// Every call so far, in arrival order.
    public var launches: [CommandLaunch] { state.withLock { $0.launches } }

    /// How many calls ended because their task was cancelled.
    public var cancelledCalls: Int { state.withLock { $0.cancelledCalls } }

    /// Returns once `count` calls have arrived, at once if they already have.
    public func waitUntilCalled(times count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                guard state.launches.count < count else { return true }
                state.arrivalWaiters.append(ArrivalWaiter(count: count, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Lets every held call, and every later one, return its answer.
    public func release() {
        let held = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.isReleased = true
            let held = Array(state.held.values)
            state.held = [:]
            return held
        }
        for continuation in held { continuation.resume() }
    }

    public func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        let id = UUID()
        let launch = CommandLaunch(executable: executable, arguments: arguments)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (arrived, arrival) = state.withLock { state -> ([CheckedContinuation<Void, Never>], Arrival) in
                    state.launches.append(launch)
                    let arrived = state.takeSatisfiedWaiters()
                    if state.cancelledBeforeHeld.remove(id) != nil {
                        state.cancelledCalls += 1
                        return (arrived, .cancel)
                    }
                    if state.isReleased { return (arrived, .release) }
                    state.held[id] = continuation
                    return (arrived, .hold)
                }
                for waiter in arrived { waiter.resume() }
                switch arrival {
                case .release: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .hold: break
                }
            }
        } onCancel: {
            let held = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                if let held = state.held.removeValue(forKey: id) {
                    state.cancelledCalls += 1
                    return held
                }
                // Cancelled before the call was held, or after it was let go:
                // remembered, so a call that has not arrived yet ends at once.
                state.cancelledBeforeHeld.insert(id)
                return nil
            }
            held?.resume(throwing: CancellationError())
        }
        return answer
    }
}

/// Suspends until the calling task is cancelled. A primitive for doubles
/// that must hang the way a stuck command does, without a clock.
enum CancellationLatch {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Void, any Error>?
        var isCancelled = false
    }

    /// Returns only by throwing `CancellationError`, once the calling task is
    /// cancelled.
    static func waitUntilCancelled() async throws {
        let state = LockedState(State())
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state -> Bool in
                    if state.isCancelled { return true }
                    state.continuation = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiting = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                state.isCancelled = true
                let waiting = state.continuation
                state.continuation = nil
                return waiting
            }
            waiting?.resume(throwing: CancellationError())
        }
    }
}

/// A value behind a Foundation lock, for a double that tasks share. Every
/// read and write goes through `withLock`, which is what makes the unchecked
/// `Sendable` true.
final class LockedState<State: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(_ state: State) {
        self.state = state
    }

    func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

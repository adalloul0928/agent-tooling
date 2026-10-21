import Foundation

/// Collects what a progress closure or a hook reports, from whichever task
/// reports it, in the order it arrived. A test then compares the whole list,
/// which is how an order is pinned without a clock.
public final class EventRecorder<Event: Sendable>: Sendable {
    private let state = LockedState<[Event]>([])

    public init() {}

    public func record(_ event: Event) {
        state.withLock { $0.append(event) }
    }

    /// Everything recorded so far, oldest first.
    public var events: [Event] { state.withLock { $0 } }
}

import Foundation
import SwiftUI

/// Waits for observable state changes without polling a clock. The condition
/// must read an observable property to wake the wait. Suite cancellation returns
/// immediately so a failed condition cannot hold the entire test run open.
@MainActor
public func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        guard !Task.isCancelled else { return }
        let wake = Wake()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                wake.set(continuation)
                withObservationTracking {
                    _ = condition()
                } onChange: {
                    wake.resume()
                }
                // Cancelled before the continuation was kept: nothing else
                // would wake it.
                if Task.isCancelled { wake.resume() }
            }
        } onCancel: {
            wake.resume()
        }
    }
}

/// One wait's continuation, resumed once by whichever comes first: the
/// change it waits for, or its task's cancellation.
private final class Wake: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = lock.withLock {
            guard !resumed else { return true }
            self.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func resume() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !resumed else { return nil }
            resumed = true
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume()
    }
}

import Foundation

/// Something told of every place a read looks at.
///
/// A recorder may be told from several tasks at once, because a scan reads
/// its files while its commands run, so it must keep what it is told behind
/// a lock.
protocol ScanTraceRecording: Sendable {
    /// `url` was looked at: a file read or checked for, or a folder walked,
    /// listed or checked for.
    func read(_ url: URL)
}

/// Task-local read recorder for consent progress and trace tests. With no
/// recorder, hooks perform one lookup and do not construct URLs. Structured
/// children and `Task { }` inherit it; detached tasks do not.
enum ScanTrace {
    /// The recorder for the current task, if any.
    @TaskLocal static var current: (any ScanTraceRecording)? = nil

    /// Tells the current recorder that `url` was looked at. With no recorder,
    /// `url` is never built.
    static func read(_ url: @autoclosure () -> URL) {
        guard let current else { return }
        current.read(url())
    }

    /// Runs `body` with `recorder` told of every place it looks at, and the
    /// recorder already listening, if any, told too: a trace set around a
    /// first read still hears what the read touches.
    static func recording<Value>(into recorder: any ScanTraceRecording, _ body: () async -> Value) async -> Value {
        await $current.withValue(ScanTraceRecorders(first: recorder, then: current)) { await body() }
    }
}

/// Two recorders told the same thing, in order.
private struct ScanTraceRecorders: ScanTraceRecording {
    let first: any ScanTraceRecording
    let then: (any ScanTraceRecording)?

    func read(_ url: URL) {
        first.read(url)
        then?.read(url)
    }
}

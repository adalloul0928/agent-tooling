import Foundation
import os

/// Scans one chosen app in memory before workspace creation. Setup replays the
/// result to create the library; cancellation discards partial observations so
/// Stop cannot be mistaken for an absent app. Reports each own manifest line
/// once, unlisted reads, and command start/end events. Only the first line of
/// version output is forwarded.
public enum FirstRead {
    /// How one command ended.
    public enum Outcome: Sendable, Equatable {
        /// It ran and exited: its status, and the first line it printed when
        /// it was `--version`.
        case answered(status: Int32, firstLine: String?)
        /// There was nothing to run (status 126 or 127).
        case notFound
        /// It did not finish within the runner's time and was stopped.
        case timedOut
        /// It could not be started or its output could not be read.
        case failed
        /// The read was stopped while it ran.
        case cancelled
    }

    /// What a reading reports, in the order it happens.
    public enum Event: Sendable, Equatable {
        /// A line of the app's own column was read: one of its places, or a
        /// shared one. Each line is reported once.
        case placeRead(ClientKind, FirstReadManifest.Place.ID)
        /// A path was read that no line of the manifest holds, which setup
        /// shows as "Not listed before". Each path is reported once.
        case unlisted(ClientKind, URL)
        case commandStarted(ClientKind, FirstReadManifest.Command.ID)
        case commandFinished(ClientKind, FirstReadManifest.Command.ID, Outcome)
        /// The read is complete. Never yielded once the read was stopped.
        case finished(TargetObservation)
    }

    /// Single-consumer event stream with two cancellation modes. `stop()` waits for
    /// the scan and its child commands to exit; the live runner escalates SIGTERM
    /// to SIGKILL after one second. Cancelling iteration or releasing the reading
    /// ends events immediately while cleanup continues. Neither mode yields queued
    /// events or `.finished` after cancellation.
    public struct Reading: AsyncSequence, Sendable {
        public typealias Element = Event
        public typealias Failure = Never

        private let events: AsyncStream<Event>
        private let control: Control

        /// A reading of events produced elsewhere: a scripted read in a test
        /// or a preview. `onStop` runs once, on the first `stop()`; it should
        /// end `events` and return once whatever produces them has stopped.
        public init(_ events: AsyncStream<Event>, onStop: @escaping @Sendable () async -> Void = {}) {
            self.events = events
            control = Control(onStop: onStop)
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(base: events.makeAsyncIterator(), control: control)
        }

        /// Stops the read and returns once it has stopped. It can be called
        /// more than once and from any task: every call waits for the same
        /// stop, and it waits even when the calling task is cancelled.
        public func stop() async {
            await control.stop()
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            public typealias Failure = Never

            fileprivate var base: AsyncStream<Event>.Iterator
            fileprivate let control: Control

            public mutating func next() async -> Event? {
                guard !control.isStopped else { return nil }
                return kept(await base.next())
            }

            public mutating func next(isolation actor: isolated (any Actor)?) async -> Event? {
                guard !control.isStopped else { return nil }
                return kept(await base.next(isolation: actor))
            }

            /// The stream hands out what it already holds even to a reader
            /// that was cancelled, so a stopped read or a cancelled reader
            /// drops it here. The stream still saw the cancellation, which is
            /// what stops the scan.
            private func kept(_ event: Event?) -> Event? {
                control.isStopped || Task.isCancelled ? nil : event
            }
        }

        /// Whether the reading was stopped, and the one wind-down every
        /// `stop()` waits for.
        fileprivate final class Control: Sendable {
            private struct State: Sendable {
                var isStopped = false
                var windDown: Task<Void, Never>?
            }

            private let state = OSAllocatedUnfairLock(initialState: State())
            private let onStop: @Sendable () async -> Void

            init(onStop: @escaping @Sendable () async -> Void) {
                self.onStop = onStop
            }

            var isStopped: Bool { state.withLock { $0.isStopped } }

            func stop() async {
                let onStop = onStop
                let windDown = state.withLock { state -> Task<Void, Never> in
                    state.isStopped = true
                    if let started = state.windDown { return started }
                    let started = Task { await onStop() }
                    state.windDown = started
                    return started
                }
                await windDown.value
            }
        }
    }

    /// Starts reading `client` and returns the reading. An app with no
    /// adapter in `registry` finishes at once. Stopping the reading cancels
    /// the scan, which stops its commands, and the reading finishes with no
    /// `.finished`.
    ///
    /// `manifest` is the list the person was shown; the events name its
    /// lines. A place or command it does not list is still read and run,
    /// because the scan is the app's own, and is reported as such: a place
    /// as `.unlisted`, a command under an identifier no line has.
    public static func read(
        _ client: ClientKind,
        homeURL: URL,
        manifest: FirstReadManifest,
        runner: any CommandRunning,
        registry: ClientAdapterRegistry = ClientAdapterRegistry()
    ) -> Reading {
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        let reporter = Reporter(client: client, manifest: manifest, continuation: continuation)
        let scan = Task {
            guard let adapter = registry.adapter(for: client) else {
                continuation.finish()
                return
            }
            let observation = await ScanTrace.recording(into: reporter) {
                await adapter.scan(homeURL: homeURL, runner: ReportingCommandRunner(base: runner, reporter: reporter))
            }
            // A stopped read is never kept.
            if !Task.isCancelled { continuation.yield(.finished(observation)) }
            continuation.finish()
        }
        continuation.onTermination = { _ in scan.cancel() }
        return Reading(events) {
            scan.cancel()
            // Ends an iteration waiting for the next event now, rather than
            // once the scan has wound down.
            continuation.finish()
            await scan.value
        }
    }
}

extension FirstRead {
    /// Reports own/shared manifest lines and unlisted paths once, plus command
    /// start/end events. Paths belonging to another chosen client or sign-in read
    /// are accounted for by that reader. A lock serializes concurrent scan tasks.
    final class Reporter: ScanTraceRecording {
        private struct Said: Sendable {
            var places: Set<FirstReadManifest.Place.ID> = []
            var unlisted: Set<String> = []
        }

        private let client: ClientKind
        private let manifest: FirstReadManifest
        /// The lines this app's read ticks: its own places and the shared ones.
        private let lines: Set<FirstReadManifest.Place.ID>
        private let continuation: AsyncStream<Event>.Continuation
        private let said = OSAllocatedUnfairLock(initialState: Said())

        init(client: ClientKind, manifest: FirstReadManifest, continuation: AsyncStream<Event>.Continuation) {
            self.client = client
            self.manifest = manifest
            lines = Set(((manifest.apps.first { $0.client == client }?.places ?? []) + manifest.shared).map(\.id))
            self.continuation = continuation
        }

        func read(_ url: URL) {
            if let place = manifest.place(containing: url, for: client) {
                guard lines.contains(place.id), said.withLock({ $0.places.insert(place.id).inserted }) else { return }
                continuation.yield(.placeRead(client, place.id))
            } else if !manifest.lists(url) {
                guard said.withLock({ $0.unlisted.insert(FirstReadManifest.key(url)).inserted }) else { return }
                continuation.yield(.unlisted(client, url))
            }
        }

        /// Reports a command starting, and returns the identifier it was
        /// reported under.
        func commandStarted(executable: String, arguments: [String]) -> FirstReadManifest.Command.ID {
            let id = manifest.commandID(executable: executable, arguments: arguments, for: client)
            continuation.yield(.commandStarted(client, id))
            return id
        }

        func commandFinished(_ id: FirstReadManifest.Command.ID, _ outcome: Outcome) {
            continuation.yield(.commandFinished(client, id, outcome))
        }
    }
}

/// Runs a first read's commands through `base` and reports each one as it
/// starts and as it ends. It changes nothing about what runs or what comes
/// back: the scan gets the output, or the error, exactly as `base` gave it.
struct ReportingCommandRunner: CommandRunning {
    let base: any CommandRunning
    let reporter: FirstRead.Reporter

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        let id = reporter.commandStarted(executable: executable, arguments: arguments)
        do {
            let output = try await base.run(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
            reporter.commandFinished(id, Self.outcome(of: output, arguments: arguments))
            return output
        } catch {
            reporter.commandFinished(id, Self.outcome(of: error))
            throw error
        }
    }

    /// 126 and 127 are what a shell answers when there is nothing to run.
    /// Only `--version` says anything more, and only the line the scan
    /// records as the version.
    static func outcome(of output: CommandOutput, arguments: [String]) -> FirstRead.Outcome {
        guard output.status != 126, output.status != 127 else { return .notFound }
        let firstLine = arguments == ClientReadLocations.versionArguments ? LocalTargetScan.versionLine(from: output) : nil
        return .answered(status: output.status, firstLine: firstLine)
    }

    static func outcome(of error: any Error) -> FirstRead.Outcome {
        if let stopped = error as? ProcessCommandRunnerError, case .timedOut = stopped { return .timedOut }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        return .failed
    }
}

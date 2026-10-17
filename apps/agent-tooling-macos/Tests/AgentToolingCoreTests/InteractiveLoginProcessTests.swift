import Foundation
import Testing

@testable import AgentToolingCore

/// The pseudo-terminal runner is exercised with tiny shell children rather than
/// a real client, so the tests stay fast and need nothing installed. What they
/// pin down is the contract the login path relies on: the child really sees a
/// terminal, its exit status and output come back, the URL it prints is handed
/// over once, and the deadline stops a child that never finishes.
@Suite("Interactive login process")
struct InteractiveLoginProcessTests {
    private let home = FileManager.default.temporaryDirectory

    /// `claude mcp login` refuses to run without a terminal on standard input;
    /// the whole point of the runner is that the child's stdin is one.
    @Test func theChildSeesATerminal() async throws {
        let outcome = try await InteractiveLoginProcess(homeURL: home, timeout: .seconds(10))
            .run(executable: "/bin/sh", arguments: ["-c", "test -t 0 && echo TTY || echo NOTTY"], onAuthorizationURL: { _ in })
        guard case .completed(let transcript) = outcome else {
            Issue.record("expected a clean exit, got \(outcome)")
            return
        }
        #expect(transcript.contains("TTY"))
        #expect(!transcript.contains("NOTTY"))
    }

    /// A non-zero exit is reported with its status and everything the child
    /// printed on either stream, and the first https URL is announced once —
    /// unredacted to the opener, since it must be opened, while the transcript
    /// kept for display has the redactor applied to its query string.
    @Test func exitStatusOutputAndURLComeBack() async throws {
        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var urls: [URL] = []
            func add(_ url: URL) { lock.withLock { urls.append(url) } }
        }
        let sink = Sink()
        let outcome = try await InteractiveLoginProcess(homeURL: home, timeout: .seconds(10))
            .run(
                executable: "/bin/sh",
                arguments: ["-c", "echo visit https://a.example/authorize?x=1; echo again https://b.example/; echo bye >&2; exit 3"],
                onAuthorizationURL: { sink.add($0) })
        guard case .failed(let status, let transcript) = outcome else {
            Issue.record("expected a failed exit, got \(outcome)")
            return
        }
        #expect(status == 3)
        #expect(transcript.contains("visit https://a.example/authorize?"))
        #expect(!transcript.contains("x=1"))
        #expect(transcript.contains("bye"))
        #expect(sink.urls.map(\.absoluteString) == ["https://a.example/authorize?x=1"])
    }

    /// A child that never finishes is stopped at the deadline rather than
    /// holding the caller, and does not linger afterwards.
    @Test func theDeadlineStopsAChildThatNeverFinishes() async throws {
        let started = ContinuousClock.now
        let outcome = try await InteractiveLoginProcess(homeURL: home, timeout: .seconds(1))
            .run(executable: "/bin/sh", arguments: ["-c", "echo waiting; sleep 30"], onAuthorizationURL: { _ in })
        let elapsed = ContinuousClock.now - started
        guard case .timedOut(let transcript) = outcome else {
            Issue.record("expected a timeout, got \(outcome)")
            return
        }
        #expect(transcript.contains("waiting"))
        #expect(elapsed < .seconds(8))
    }
}

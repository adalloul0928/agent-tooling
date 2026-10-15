import Darwin
import Foundation

/// How one interactive sign-in ended.
public enum InteractiveLoginOutcome: Equatable, Sendable {
    /// The tool exited with status 0 after the browser flow completed.
    case completed(transcript: String)
    /// The tool exited non-zero; the transcript is what it printed.
    case failed(status: Int32, transcript: String)
    /// Nobody finished the browser flow before the deadline; the process was
    /// stopped so it does not sit on a callback port forever.
    case timedOut(transcript: String)
    /// The caller cancelled; the process was stopped.
    case cancelled
}

public enum InteractiveLoginProcessError: Error, Equatable, Sendable {
    case cannotOpenTerminal
    case cannotSpawn(Int32)
}

/// Runs a client's own sign-in command the way a person would in a terminal.
///
/// `claude mcp login` and `codex mcp login` refuse to run when their standard
/// input is not a terminal: the flow prints an authorization URL, opens a
/// callback listener, and waits, and they insist on an interactive session
/// for the paste-the-redirect fallback. A plain pipe therefore fails at once.
/// This type gives the tool a pseudo-terminal instead, so it behaves as it
/// does in Terminal.app, while the app still controls exactly which argv runs
/// (the caller has already checked it against the operation policy), which
/// environment it sees (the same HOME-scoped allowlist every other child
/// gets), and how long it may wait.
///
/// The app reads the terminal's output only to find the authorization URL the
/// tool prints with `--no-browser`, so it can open the browser itself and show
/// the person what it opened. It never reads a token: the OAuth code returns
/// to the tool's own localhost callback, and the tool stores the credential
/// where it always does. Nothing typed into the terminal is ever sent; the
/// pseudo-terminal exists so the tool will run at all.
public struct InteractiveLoginProcess: Sendable {
    /// Bounds on what is kept from the terminal, so a chatty tool cannot grow
    /// memory without limit while a person is away.
    private static let maximumTranscriptBytes = 262_144

    private let homeURL: URL
    private let timeout: Duration

    public init(homeURL: URL, timeout: Duration = .seconds(300)) {
        self.homeURL = homeURL
        self.timeout = timeout
    }

    /// Runs `executable arguments…` on a pseudo-terminal and waits for it to
    /// finish, calling `onAuthorizationURL` the first time an `https://` URL
    /// appears in its output. The URL is delivered once, unredacted, because
    /// it is the thing the person must open; the transcript returned at the
    /// end is redacted.
    public func run(
        executable: String,
        arguments: [String],
        onAuthorizationURL: @escaping @Sendable (URL) -> Void
    ) async throws -> InteractiveLoginOutcome {
        let environment = ProcessCommandRunner.childEnvironment(
            inheriting: ProcessInfo.processInfo.environment, homeURL: homeURL)
        // The tool needs a terminal type to believe it has a terminal at all.
        var terminalEnvironment = environment
        terminalEnvironment["TERM"] = "xterm-256color"

        var primary: Int32 = -1
        var replica: Int32 = -1
        guard openpty(&primary, &replica, nil, nil, nil) == 0 else {
            throw InteractiveLoginProcessError.cannotOpenTerminal
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A fresh session with the replica as controlling terminal is what makes
        // isatty(stdin) true inside the child. The signal mask and dispositions
        // are reset because the app (and the test runner) may block SIGTERM,
        // and a child that inherits that could not be stopped at the deadline.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, replica, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, replica, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, replica, STDERR_FILENO)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            terminalEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
        guard spawnStatus == 0 else {
            close(replica)
            close(primary)
            throw InteractiveLoginProcessError.cannotSpawn(spawnStatus)
        }
        // The parent keeps its copy of the replica open until the child has
        // exited. On macOS a pseudo-terminal drops output still buffered when
        // its last replica closes before anyone reads, which for a child that
        // prints one line and exits at once means an empty transcript. Holding
        // the replica open makes the reader see every byte; closing it after
        // the exit is what then gives the reader its end of file.

        let reader = TranscriptReader(descriptor: primary, limit: Self.maximumTranscriptBytes)
        let readTask = Task.detached(priority: .utility) { () -> String in
            await reader.readUntilClosed(onAuthorizationURL: onAuthorizationURL)
            return await reader.transcript()
        }

        let childPID = pid
        let waitTask = Task.detached(priority: .utility) { () -> Int32 in
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
            return status
        }

        let outcome: InteractiveLoginOutcome
        do {
            // A task group would wait for the blocked waitpid child before
            // returning, so the deadline is raced by hand: whichever of the
            // exit and the timer finishes first decides, and the other is left
            // to finish on its own.
            let status = try await Self.race(exit: waitTask, deadline: timeout)
            if let status {
                close(replica)
                let transcript = await Self.transcript(after: readTask, closing: primary)
                let exitCode = Self.exitCode(status)
                outcome = exitCode == 0
                    ? .completed(transcript: transcript)
                    : .failed(status: exitCode, transcript: transcript)
            } else {
                await Self.stop(childPID, waitTask: waitTask)
                close(replica)
                outcome = .timedOut(transcript: await Self.transcript(after: readTask, closing: primary))
            }
        } catch {
            // Cancellation from the caller: stop the tool so its callback
            // listener does not outlive the request.
            await Self.stop(childPID, waitTask: waitTask)
            close(replica)
            close(primary)
            readTask.cancel()
            outcome = .cancelled
        }
        return outcome
    }

    /// The child's exit status if it exits before the deadline, nil otherwise.
    /// Throws only when the caller cancels.
    private static func race(exit waitTask: Task<Int32, Never>, deadline: Duration) async throws -> Int32? {
        let timer = Task { try await Task.sleep(for: deadline) }
        let winner = Task<Int32?, Error> {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
                    let box = ContinuationBox<Int32?>(continuation)
                    Task { let status = await waitTask.value; box.resume(with: status) }
                    Task { try? await timer.value; box.resume(with: nil) }
                }
            } onCancel: { timer.cancel() }
        }
        defer { timer.cancel() }
        let result = try await winner.value
        try Task.checkCancellation()
        return result
    }

    /// Asks the child to stop and, if it has not gone within a few seconds,
    /// makes it. The wait is bounded so a stuck tool cannot hold the caller.
    private static func stop(_ pid: pid_t, waitTask: Task<Int32, Never>) async {
        kill(pid, SIGTERM)
        let exited = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await waitTask.value; return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !exited {
            kill(pid, SIGKILL)
            _ = await waitTask.value
        }
    }

    private static func transcript(after readTask: Task<String, Never>, closing descriptor: Int32) async -> String {
        // The child has exited, so once its side of the terminal closes the
        // reader sees end of file and finishes on its own; that is the normal
        // path and it is awaited outright. Closing our end first would make
        // the pending read fail and lose the last lines. The timer only
        // guards against a descendant that kept the terminal open (a tool that
        // left a helper behind), in which case the transcript so far is taken.
        let drained = await race(reader: readTask, deadline: .seconds(5))
        close(descriptor)
        let transcript: String
        if let drained { transcript = drained } else { transcript = await readTask.value }
        return SensitiveValueRedactor.redact(transcript)
    }

    /// The reader's transcript if it finishes before the deadline, else nil.
    private static func race(reader: Task<String, Never>, deadline: Duration) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let box = ContinuationBox<String?>(continuation)
            Task { let value = await reader.value; box.resume(with: value) }
            Task {
                try? await Task.sleep(for: deadline)
                box.resume(with: nil)
            }
        }
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        // WIFEXITED / WEXITSTATUS as macros are not imported into Swift.
        if status & 0x7f == 0 { return (status >> 8) & 0xff }
        return 128 + (status & 0x7f)
    }

    /// The first `https://` URL in a chunk of terminal output, with terminal
    /// escape sequences and hyperlink markers stripped so the URL is the one
    /// the browser should open.
    static func firstHTTPSURL(in text: String) -> URL? {
        // OSC 8 hyperlinks wrap the URL as ESC ] 8 ; ; <url> BEL <text> ESC ] 8 ; ; BEL.
        // Every control character becomes a separator, so the escape's bytes,
        // line endings and the bell all end a URL rather than gluing it to the
        // text that follows.
        let cleaned = String(text.map { character -> Character in
            (character.asciiValue.map { $0 < 0x20 || $0 == 0x7f } ?? false) ? " " : character
        })
        guard let range = cleaned.range(of: "https://") else { return nil }
        let tail = cleaned[range.lowerBound...]
        let end = tail.firstIndex { character in
            character == " " || character == "\"" || character == "'" || character == "<" || character == ">"
        } ?? tail.endIndex
        var candidate = String(tail[..<end])
        // The escape's parameter bytes ("]8;;") come right before the URL and
        // are already separated; a doubled URL from the hyperlink's visible
        // text is a second match and is simply not reached.
        if let second = candidate.range(of: "https://", range: candidate.index(after: candidate.startIndex)..<candidate.endIndex) {
            candidate = String(candidate[..<second.lowerBound])
        }
        while let last = candidate.last, ".,;)".contains(last) { candidate.removeLast() }
        guard candidate.count <= 4_096, let url = URL(string: candidate), url.scheme == "https", url.host != nil else {
            return nil
        }
        return url
    }
}

/// Reads a terminal descriptor to end of file, keeping a bounded transcript.
private actor TranscriptReader {
    private let descriptor: Int32
    private let limit: Int
    private var bytes = Data()

    init(descriptor: Int32, limit: Int) {
        self.descriptor = descriptor
        self.limit = limit
    }

    /// Reads until the other side closes. The authorization URL is reported
    /// once, from the first chunk that contains one; a URL split across two
    /// reads is caught by scanning the accumulated transcript rather than the
    /// chunk alone.
    func readUntilClosed(onAuthorizationURL: @Sendable (URL) -> Void) async {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var announced = false
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let chunk = Data(buffer[0..<count])
                if bytes.count < limit { bytes.append(chunk.prefix(limit - bytes.count)) }
                if !announced,
                    let url = InteractiveLoginProcess.firstHTTPSURL(in: String(decoding: bytes, as: UTF8.self))
                {
                    announced = true
                    onAuthorizationURL(url)
                }
                continue
            }
            // EIO is how a pseudo-terminal reports that the other side closed.
            if count == -1 && errno == EINTR { continue }
            return
        }
    }

    func transcript() -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

/// Resumes a continuation exactly once, whichever of two racing tasks gets
/// there first.
private final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(with value: Value) {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

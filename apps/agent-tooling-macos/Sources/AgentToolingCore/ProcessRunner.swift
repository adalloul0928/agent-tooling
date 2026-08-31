import Darwin
import Foundation

public struct CommandOutput: Sendable, Hashable {
    public var status: Int32
    public var standardOutput: String
    public var standardError: String

    public init(status: Int32, standardOutput: String, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput
}

/// Runs a process with a bounded, non-interactive standard-input payload.
///
/// This is deliberately separate from ``CommandRunning`` so existing read-only
/// probes and their test doubles do not need to accept input. Callers must still
/// provide an executable and an argument array; no shell command string is
/// accepted by this interface.
public protocol StandardInputCommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        standardInput: Data,
        currentDirectory: URL?
    ) async throws -> CommandOutput
}

public struct ProcessCommandRunner: CommandRunning, StandardInputCommandRunning {
    private static let maximumCapturedBytes = 1_048_576
    private static let maximumStandardInputBytes = 1_048_576
    private static let readChunkBytes = 65_536
    private let timeout: Duration

    public init(timeout: Duration = .seconds(60)) {
        self.timeout = timeout
    }

    public func run(executable: String, arguments: [String], currentDirectory: URL? = nil) async throws -> CommandOutput {
        try await runProcessWithTimeout(
            executable: executable,
            arguments: arguments,
            standardInput: nil,
            currentDirectory: currentDirectory
        )
    }

    public func run(
        executable: String,
        arguments: [String],
        standardInput: Data,
        currentDirectory: URL? = nil
    ) async throws -> CommandOutput {
        guard standardInput.count <= Self.maximumStandardInputBytes else {
            throw ProcessCommandRunnerError.standardInputTooLarge(executable, Self.maximumStandardInputBytes)
        }
        return try await runProcessWithTimeout(
            executable: executable,
            arguments: arguments,
            standardInput: standardInput,
            currentDirectory: currentDirectory
        )
    }

    private func runProcessWithTimeout(
        executable: String,
        arguments: [String],
        standardInput: Data?,
        currentDirectory: URL?
    ) async throws -> CommandOutput {
        try Task.checkCancellation()
        let controller = RunningProcessController()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandOutput.self) { group in
                group.addTask(priority: .userInitiated) {
                    try await Self.runProcess(
                        executable: executable,
                        arguments: arguments,
                        standardInput: standardInput,
                        currentDirectory: currentDirectory,
                        controller: controller
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    controller.terminate(dueToTimeout: true)
                    throw ProcessCommandRunnerError.timedOut(executable)
                }

                defer {
                    group.cancelAll()
                    controller.terminate()
                }
                guard let first = try await group.next() else {
                    throw ProcessCommandRunnerError.missingResult(executable)
                }
                // The process and timeout tasks can become ready in the same
                // scheduler turn after SIGTERM. A task group does not promise
                // which ready child `next()` returns first, so never interpret
                // the terminated process result as a successful command.
                if controller.didTimeOut {
                    throw ProcessCommandRunnerError.timedOut(executable)
                }
                return first
            }
        } onCancel: {
            controller.terminate()
        }
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        standardInput: Data?,
        currentDirectory: URL?,
        controller: RunningProcessController
    ) async throws -> CommandOutput {
        let process = Process()
        process.currentDirectoryURL = currentDirectory
        var environment = ProcessInfo.processInfo.environment
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let home = homeURL.path(percentEncoded: false)
        let applicationPaths = [
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let inheritedPaths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = Array(NSOrderedSet(array: applicationPaths + inheritedPaths)).compactMap { $0 as? String }.joined(
            separator: ":")
        process.environment = environment
        if let resolvedExecutable = canonicalExecutableURL(
            for: executable,
            environment: environment,
            currentDirectory: currentDirectory
        ) {
            // Foundation's Process launch path does not consistently follow a
            // PATH-installed symlink when the app itself was launched outside
            // a login shell. Resolve it first so app-bundled CLI targets (such
            // as ~/.local/bin/codex -> ChatGPT.app/.../codex) launch directly.
            process.executableURL = resolvedExecutable
            process.arguments = arguments
        } else {
            // Preserve the existing command-not-found behavior for probes of
            // optional tools. `/usr/bin/env` returns a normal nonzero status
            // instead of turning an unavailable client into a launch error.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        // App-launched commands have no interactive terminal. Giving a CLI the
        // app's inherited stdin can stop it with SIGTTIN while it waits for a
        // prompt, leaving the interface locked until the timeout expires.
        let inputPipe = standardInput.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        let exitWaiter = ProcessExitWaiter()
        process.terminationHandler = { _ in exitWaiter.signal() }
        try process.run()
        controller.install(process)
        // Start draining before writing input so a process that emits output
        // before consuming stdin cannot fill a pipe and deadlock the caller.
        async let output = drain(standardOutput.fileHandleForReading)
        async let error = drain(standardError.fileHandleForReading)
        if let standardInput, let inputPipe {
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
                try inputPipe.fileHandleForWriting.close()
            } catch {
                try? inputPipe.fileHandleForWriting.close()
                controller.terminate()
                throw error
            }
        }
        defer { controller.finish(process) }
        // Native catalog commands can emit hundreds of kilobytes. Drain both
        // pipes while the child runs; waiting first can fill a pipe buffer and
        // deadlock setup checks indefinitely.
        await exitWaiter.wait()
        let capturedOutput = try await output
        let capturedError = try await error
        if controller.didTimeOut {
            throw ProcessCommandRunnerError.timedOut(executable)
        }
        try Task.checkCancellation()
        return CommandOutput(
            status: process.terminationStatus,
            standardOutput: capturedOutput.text,
            standardError: capturedError.text
        )
    }

    /// Finds an executable using the exact environment used for launch and
    /// resolves every symlink component before returning it.
    ///
    /// This remains internal so tests can cover resolution without exposing a
    /// second public process-launch API. A missing executable returns `nil` and
    /// is intentionally handled by the `/usr/bin/env` fallback above.
    static func canonicalExecutableURL(
        for executable: String,
        environment: [String: String],
        currentDirectory: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        guard !executable.isEmpty, !executable.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }

        let candidates: [URL]
        if executable.hasPrefix("/") {
            candidates = [URL(fileURLWithPath: executable)]
        } else if executable.contains("/") {
            let base = currentDirectory ?? URL(filePath: fileManager.currentDirectoryPath, directoryHint: .isDirectory)
            candidates = [base.appending(path: executable)]
        } else {
            candidates = (environment["PATH"] ?? "").split(separator: ":").map {
                URL(filePath: String($0), directoryHint: .isDirectory).appending(path: executable)
            }
        }

        for candidate in candidates {
            let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            guard let values = try? canonical.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true,
                fileManager.isExecutableFile(atPath: canonical.path(percentEncoded: false))
            else { continue }
            return canonical
        }
        return nil
    }

    private static func drain(_ handle: FileHandle) async throws -> CapturedStream {
        var captured = Data()
        var wasTruncated = false
        while let chunk = try handle.read(upToCount: readChunkBytes), !chunk.isEmpty {
            let remaining = maximumCapturedBytes - captured.count
            if remaining > 0 { captured.append(chunk.prefix(remaining)) }
            if chunk.count > remaining { wasTruncated = true }
        }
        var text = String(decoding: captured, as: UTF8.self)
        if wasTruncated { text += "\n[output truncated after \(maximumCapturedBytes) bytes]" }
        return CapturedStream(text: text)
    }
}

private struct CapturedStream: Sendable {
    var text: String
}

private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var didExit = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didExit {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        didExit = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class RunningProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var processGroupIdentifier: pid_t?
    private var terminationRequested = false
    private var timeoutRequested = false

    var didTimeOut: Bool {
        lock.withLock { timeoutRequested }
    }

    func install(_ process: Process) {
        let processIdentifier = process.processIdentifier
        let groupIdentifier = Darwin.setpgid(processIdentifier, processIdentifier) == 0 ? processIdentifier : nil
        lock.lock()
        self.process = process
        processGroupIdentifier = groupIdentifier
        let terminateNow = terminationRequested
        lock.unlock()
        if terminateNow, process.isRunning { signal(process, groupIdentifier: groupIdentifier, signal: SIGTERM) }
    }

    func terminate(dueToTimeout: Bool = false) {
        lock.lock()
        terminationRequested = true
        timeoutRequested = timeoutRequested || dueToTimeout
        let process = process
        let groupIdentifier = processGroupIdentifier
        lock.unlock()
        guard let process, process.isRunning else { return }
        signal(process, groupIdentifier: groupIdentifier, signal: SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self, weak process] in
            guard let self, let process else { return }
            self.lock.lock()
            let isCurrentProcess = self.process === process
            let groupIdentifier = self.processGroupIdentifier
            self.lock.unlock()
            if isCurrentProcess, process.isRunning {
                self.signal(process, groupIdentifier: groupIdentifier, signal: SIGKILL)
            }
        }
    }

    func finish(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
            processGroupIdentifier = nil
        }
        lock.unlock()
    }

    private func signal(_ process: Process, groupIdentifier: pid_t?, signal: Int32) {
        if let groupIdentifier {
            _ = Darwin.kill(-groupIdentifier, signal)
        } else {
            for descendant in descendantProcessIdentifiers(of: process.processIdentifier).reversed() {
                _ = Darwin.kill(descendant, signal)
            }
            _ = Darwin.kill(process.processIdentifier, signal)
        }
    }

    private func descendantProcessIdentifiers(of parent: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var pending = [parent]
        var visited = Set([parent])
        while let current = pending.popLast(), result.count < 1_024 {
            let requiredBytes = Darwin.proc_listchildpids(current, nil, 0)
            guard requiredBytes > 0 else { continue }
            var children = [pid_t](repeating: 0, count: Int(requiredBytes) / MemoryLayout<pid_t>.stride)
            let populatedBytes = children.withUnsafeMutableBytes {
                Darwin.proc_listchildpids(current, $0.baseAddress, requiredBytes)
            }
            guard populatedBytes > 0 else { continue }
            let populatedCount = min(Int(populatedBytes) / MemoryLayout<pid_t>.stride, children.count)
            for child in children.prefix(populatedCount) where child > 0 && visited.insert(child).inserted {
                result.append(child)
                pending.append(child)
            }
        }
        return result
    }
}

public enum ProcessCommandRunnerError: LocalizedError, Sendable {
    case timedOut(String)
    case missingResult(String)
    case standardInputTooLarge(String, Int)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let command): "\(command) did not finish within the allowed time and was stopped."
        case .missingResult(let command): "\(command) ended without returning a result."
        case .standardInputTooLarge(let command, let maximumBytes):
            "\(command) standard input exceeds the \(maximumBytes / 1_024) KB limit."
        }
    }
}

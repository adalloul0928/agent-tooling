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

public struct ProcessCommandRunner: CommandRunning {
    private static let maximumCapturedBytes = 1_048_576
    private static let readChunkBytes = 65_536
    private let timeout: Duration

    public init(timeout: Duration = .seconds(60)) {
        self.timeout = timeout
    }

    public func run(executable: String, arguments: [String], currentDirectory: URL? = nil) async throws -> CommandOutput {
        try Task.checkCancellation()
        let controller = RunningProcessController()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandOutput.self) { group in
                group.addTask(priority: .userInitiated) {
                    try await Self.runProcess(
                        executable: executable,
                        arguments: arguments,
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
        currentDirectory: URL?,
        controller: RunningProcessController
    ) async throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = currentDirectory
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
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
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        let exitWaiter = ProcessExitWaiter()
        process.terminationHandler = { _ in exitWaiter.signal() }
        try process.run()
        controller.install(process)
        defer { controller.finish(process) }
        // Native catalog commands can emit hundreds of kilobytes. Drain both
        // pipes while the child runs; waiting first can fill a pipe buffer and
        // deadlock setup checks indefinitely.
        async let output = drain(standardOutput.fileHandleForReading)
        async let error = drain(standardError.fileHandleForReading)
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

    public var errorDescription: String? {
        switch self {
        case .timedOut(let command): "\(command) did not finish within the allowed time and was stopped."
        case .missingResult(let command): "\(command) ended without returning a result."
        }
    }
}

public actor OperationEngine {
    private let store: WorkspaceStore
    private let runner: any CommandRunning
    private let fileManager: FileManager
    private let homeURL: URL

    public init(
        store: WorkspaceStore,
        runner: any CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.store = store
        self.runner = runner
        self.fileManager = fileManager
        self.homeURL = homeURL
    }

    /// Executes a plan built by an adapter. Steps intentionally continue after
    /// a failure so multi-agent installs retain useful partial success.
    public func execute(_ plan: OperationPlan) async -> OperationReceipt {
        var results: [OperationStepResult] = []
        for (index, step) in plan.steps.enumerated() {
            let startedAt = Date.now
            do {
                try Task.checkCancellation()
                let result = try await execute(step)
                results.append(
                    OperationStepResult(
                        stepID: step.id,
                        status: result.status,
                        output: Self.persistableOutput(result.output),
                        startedAt: startedAt,
                        finishedAt: .now
                    )
                )
            } catch is CancellationError {
                results.append(
                    OperationStepResult(
                        stepID: step.id, status: .skipped, output: "Cancelled before this step ran.", startedAt: startedAt, finishedAt: .now
                    ))
                appendSkippedSteps(plan.steps.dropFirst(index + 1), reason: "Skipped because the operation was cancelled.", to: &results)
                break
            } catch {
                results.append(
                    OperationStepResult(
                        stepID: step.id, status: .failed, output: Self.persistableOutput(error.localizedDescription), startedAt: startedAt,
                        finishedAt: .now))
                if step.shouldStopOnFailure {
                    appendSkippedSteps(
                        plan.steps.dropFirst(index + 1), reason: "Skipped because a required preflight or integrity check failed.",
                        to: &results)
                    break
                }
            }
        }
        let state: HealthState
        if results.isEmpty {
            state = .attention
        } else if results.contains(where: { $0.status == .failed }) {
            state = .attention
        } else if results.contains(where: { $0.status == .manual || $0.status == .skipped }) {
            state = .pending
        } else {
            state = .healthy
        }
        let wasCancelled = results.contains { result in
            result.status == .skipped && result.output.localizedCaseInsensitiveContains("cancel")
        }
        let verification =
            results.isEmpty
            ? "No operation steps were provided. Nothing changed."
            : wasCancelled
                ? "The operation was stopped. Completed steps were kept; skipped steps did not run. Re-scan before retrying."
                : results.contains(where: { $0.status == .failed })
                    ? "Some steps failed. Re-scan the affected targets before retrying."
                    : results.contains(where: { $0.status == .manual })
                        ? "The local changes are complete; finish the marked account or restart steps manually, then re-scan."
                        : "All requested local steps completed. A fresh scan is recorded after the operation."
        var receipt = OperationReceipt(
            planID: plan.id,
            kind: plan.kind,
            title: plan.title,
            state: state,
            targetSurfaces: plan.targetSurfaces,
            results: results,
            verificationSummary: verification
        )
        do {
            try store.save(receipt, for: "receipt.\(receipt.id.uuidString)")
        } catch {
            receipt.state = .attention
            receipt.verificationSummary += " The operation completed, but its receipt could not be saved: \(error.localizedDescription)"
        }
        return receipt
    }

    private func appendSkippedSteps(
        _ steps: ArraySlice<OperationStep>,
        reason: String,
        to results: inout [OperationStepResult]
    ) {
        for step in steps {
            let now = Date.now
            results.append(
                OperationStepResult(
                    stepID: step.id,
                    status: .skipped,
                    output: reason,
                    startedAt: now,
                    finishedAt: now
                )
            )
        }
    }

    private func execute(_ step: OperationStep) async throws -> (status: OperationStepStatus, output: String) {
        switch step.kind {
        case .createDirectory:
            guard let destinationPath = step.destinationPath else { throw OperationEngineError.malformedStep(step.title) }
            let destination = try backupDirectoryDestination(destinationPath)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            return (.succeeded, "Created \(destination.path(percentEncoded: false)).")

        case .verifyCleanGitRepository:
            guard let destinationPath = step.destinationPath else { throw OperationEngineError.malformedStep(step.title) }
            let destination = try backupRootDestination(destinationPath)
            let gitDirectory = destination.appending(path: ".git", directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: gitDirectory.path(percentEncoded: false)) else {
                return (.succeeded, "No existing Git repository needs a cleanliness check.")
            }
            let output = try await runner.run(
                executable: "git",
                arguments: ["-C", destination.path(percentEncoded: false), "status", "--porcelain=v1", "--untracked-files=all"],
                currentDirectory: nil
            )
            let combined = [output.standardOutput, output.standardError].filter { !$0.isEmpty }.joined(separator: "\n")
            guard output.status == 0 else { throw OperationEngineError.commandFailed("git", output.status, combined) }
            guard output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OperationEngineError.dirtyGitBackup(destination.path(percentEncoded: false))
            }
            return (.succeeded, "The existing local Git backup is clean.")

        case .writeFile:
            guard let destinationPath = step.destinationPath, let contents = step.contents else {
                throw OperationEngineError.malformedStep(step.title)
            }
            guard contents.utf8.count <= Self.maximumBackupMetadataBytes else { throw OperationEngineError.sourceTooLarge }
            let destination = try backupMetadataDestination(destinationPath)
            try replaceFile(at: destination, contents: Data(contents.utf8), planStepID: step.id) {
                _ = try self.backupMetadataDestination(destinationPath)
            }
            return (.succeeded, "Wrote \(destination.path(percentEncoded: false)).")

        case .writeEncryptedArchive:
            guard let destinationPath = step.destinationPath, let contents = step.contents else {
                throw OperationEngineError.malformedStep(step.title)
            }
            let destination = try encryptedArchiveDestination(destinationPath)
            try replaceFile(at: destination, contents: Data(contents.utf8), planStepID: step.id) {
                _ = try self.encryptedArchiveDestination(destinationPath)
            }
            return (.succeeded, "Wrote encrypted archive at \(destination.path(percentEncoded: false)).")

        case .copyDirectory:
            guard let sourcePath = step.sourcePath,
                let sourceFingerprint = step.sourceFingerprint,
                let destinationPath = step.destinationPath
            else { throw OperationEngineError.malformedStep(step.title) }
            let source = URL(fileURLWithPath: sourcePath)
            try validateSource(source)
            let destination = try copyDestination(destinationPath, projectRootPath: step.projectRootPath)
            try replaceDirectory(
                at: destination,
                withCopyOf: source,
                expectedFingerprint: sourceFingerprint,
                projectRootPath: step.projectRootPath,
                planStepID: step.id
            )
            return (.succeeded, "Installed local package at \(destination.path(percentEncoded: false)).")

        case .replaceManagedLibrary:
            guard let destinationPath = step.destinationPath, let contents = step.contents else {
                throw OperationEngineError.malformedStep(step.title)
            }
            let destination = URL(fileURLWithPath: destinationPath).standardizedFileURL
            guard destination.standardizedFileURL == store.libraryURL.standardizedFileURL else {
                throw OperationEngineError.unsafeDestination(destinationPath)
            }
            let files = try JSONDecoder().decode([EncryptedLibraryFile].self, from: Data(contents.utf8))
            try validateArchiveFiles(files)
            try replaceManagedLibrary(at: destination, files: files, planStepID: step.id)
            return (.succeeded, "Restored \(files.count) managed library file\(files.count == 1 ? "" : "s").")

        case .command:
            guard let executable = step.executable else { throw OperationEngineError.malformedStep(step.title) }
            try validateCommand(executable: executable, arguments: step.arguments)
            let workingDirectory = try commandWorkingDirectory(
                step.currentDirectoryPath,
                authorizedProjectRootPath: step.projectRootPath
            )
            let output = try await runner.run(executable: executable, arguments: step.arguments, currentDirectory: workingDirectory)
            let combined = [output.standardOutput, output.standardError].filter { !$0.isEmpty }.joined(separator: "\n")
            guard output.status == 0 else { throw OperationEngineError.commandFailed(executable, output.status, combined) }
            return (.succeeded, combined.isEmpty ? "\(executable) completed." : combined)

        case .scan:
            return (.succeeded, "A post-operation scan is queued by the control plane.")

        case .openURL:
            return (.manual, step.detail)

        case .manual:
            return (.manual, step.detail)
        }
    }

    private func backupRootDestination(_ rawPath: String) throws -> URL {
        let destination = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard destination == gitBackupRoot else { throw OperationEngineError.unsafeDestination(rawPath) }
        try validateContainedPath(destination, within: store.rootURL)
        return destination
    }

    private func backupDirectoryDestination(_ rawPath: String) throws -> URL {
        let destination = URL(fileURLWithPath: rawPath).standardizedFileURL
        let allowed = [gitBackupRoot, gitBackupRoot.appending(path: "library", directoryHint: .isDirectory)]
            .map(\.standardizedFileURL)
        guard allowed.contains(destination) else { throw OperationEngineError.unsafeDestination(rawPath) }
        try validateContainedPath(destination, within: store.rootURL)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw OperationEngineError.unsafeDestination(rawPath)
            }
        }
        return destination
    }

    private func backupMetadataDestination(_ rawPath: String) throws -> URL {
        let destination = URL(fileURLWithPath: rawPath).standardizedFileURL
        let permitted = [
            gitBackupRoot.appending(path: "workspace.json", directoryHint: .notDirectory),
            gitBackupRoot.appending(path: "agent-tooling.lock.json", directoryHint: .notDirectory),
        ].map(\.standardizedFileURL)
        guard permitted.contains(destination) else { throw OperationEngineError.unsafeDestination(rawPath) }
        try validateContainedPath(destination.deletingLastPathComponent(), within: store.rootURL)
        return destination
    }

    private func copyDestination(_ rawPath: String, projectRootPath: String? = nil) throws -> URL {
        let destination = URL(fileURLWithPath: rawPath).standardizedFileURL
        let exactDestinations = [
            store.libraryURL,
            gitBackupRoot.appending(path: "library", directoryHint: .isDirectory),
        ].map(\.standardizedFileURL)
        if exactDestinations.contains(destination) {
            try validateContainedPath(destination, within: store.rootURL)
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw OperationEngineError.unsafeDestination(rawPath)
                }
            }
            return destination
        }

        var permittedSkillRoots: [(root: URL, anchor: URL)] = [
            (homeURL.appending(path: ".claude/skills", directoryHint: .isDirectory), homeURL),
            (homeURL.appending(path: ".agents/skills", directoryHint: .isDirectory), homeURL),
            (homeURL.appending(path: ".gemini/skills", directoryHint: .isDirectory), homeURL),
        ].map { ($0.0.standardizedFileURL, $0.1.standardizedFileURL) }

        if let projectRootPath {
            let projectRoot = URL(fileURLWithPath: projectRootPath).standardizedFileURL
            let directValues = try projectRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var isDirectory: ObjCBool = false
            guard directValues.isSymbolicLink != true,
                fileManager.fileExists(atPath: projectRoot.path(percentEncoded: false), isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw OperationEngineError.unsafeDestination(rawPath)
            }
            permittedSkillRoots.append(
                contentsOf: [
                    (projectRoot.appending(path: ".claude/skills", directoryHint: .isDirectory), projectRoot),
                    (projectRoot.appending(path: ".agents/skills", directoryHint: .isDirectory), projectRoot),
                    (projectRoot.appending(path: ".gemini/skills", directoryHint: .isDirectory), projectRoot),
                ].map { ($0.0.standardizedFileURL, $0.1.standardizedFileURL) })
        }

        guard Self.isSafeMCPIdentifier(destination.lastPathComponent),
            let permitted = permittedSkillRoots.first(where: {
                Self.samePath(destination.deletingLastPathComponent(), $0.root)
            })
        else {
            throw OperationEngineError.unsafeDestination(rawPath)
        }
        try validateContainedPath(permitted.root, within: permitted.anchor)
        return destination
    }

    private func commandWorkingDirectory(_ rawPath: String?, authorizedProjectRootPath: String?) throws -> URL? {
        guard let rawPath else {
            guard authorizedProjectRootPath == nil else {
                throw OperationEngineError.unsafeWorkingDirectory(authorizedProjectRootPath ?? "")
            }
            return nil
        }
        guard let authorizedProjectRootPath else { throw OperationEngineError.unsafeWorkingDirectory(rawPath) }
        let workingDirectory = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath()
        let authorizedRoot = URL(fileURLWithPath: authorizedProjectRootPath).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workingDirectory.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue,
            workingDirectory == authorizedRoot
        else {
            throw OperationEngineError.unsafeWorkingDirectory(rawPath)
        }
        return workingDirectory
    }

    private func encryptedArchiveDestination(_ rawPath: String) throws -> URL {
        let destination = URL(fileURLWithPath: rawPath).standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard destination.lastPathComponent == EncryptedSyncService.archiveFileName,
            parentValues.isDirectory == true,
            parentValues.isSymbolicLink != true
        else {
            throw OperationEngineError.unsafeDestination(rawPath)
        }
        guard Self.samePath(parent.resolvingSymlinksInPath(), parent) else {
            throw OperationEngineError.unsafeDestination(rawPath)
        }
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw OperationEngineError.unsafeDestination(rawPath)
            }
        }
        return destination
    }

    private func validateSource(_ source: URL) throws {
        let directValues = try source.standardizedFileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directValues.isDirectory == true, directValues.isSymbolicLink != true else {
            throw OperationEngineError.unsafeSource(source.path(percentEncoded: false))
        }
        let normalized = source.standardizedFileURL.resolvingSymlinksInPath()
        let library = store.libraryURL.standardizedFileURL.resolvingSymlinksInPath()
        let isManagedLibrary = isContained(normalized, in: library)
        let backupRoot = normalized.deletingLastPathComponent()
        let isCompleteBackupLibrary =
            normalized.lastPathComponent == "library"
            && fileManager.fileExists(atPath: backupRoot.appending(path: "workspace.json").path(percentEncoded: false))
            && fileManager.fileExists(atPath: backupRoot.appending(path: "agent-tooling.lock.json").path(percentEncoded: false))
        guard isManagedLibrary || isCompleteBackupLibrary,
            fileManager.fileExists(atPath: normalized.path(percentEncoded: false))
        else {
            throw OperationEngineError.unsafeSource(source.path(percentEncoded: false))
        }
        try validateDirectoryTree(normalized)
    }

    private var gitBackupRoot: URL {
        store.rootURL.appending(path: "exports/git-backup", directoryHint: .isDirectory).standardizedFileURL
    }

    private func replaceFile(
        at destination: URL,
        contents: Data,
        planStepID: UUID,
        revalidateDestination: () throws -> Void
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appending(path: ".agent-tooling-file-\(UUID().uuidString)", directoryHint: .notDirectory)
        defer { removeStagingItemIfPresent(staged) }
        try contents.write(to: staged, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path(percentEncoded: false))
        try commitPreparedItem(
            staged,
            to: destination,
            planStepID: planStepID,
            revalidateDestination: revalidateDestination
        )
    }

    private func replaceDirectory(
        at destination: URL,
        withCopyOf source: URL,
        expectedFingerprint: String,
        projectRootPath: String?,
        planStepID: UUID
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appending(path: ".agent-tooling-directory-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { removeStagingItemIfPresent(staged) }
        try fileManager.copyItem(at: source, to: staged)
        try validateDirectoryTree(staged)
        try normalizePrivatePermissions(under: staged)
        let actualFingerprint = try DirectoryFingerprint.sha256(
            of: staged,
            fileManager: fileManager,
            maximumItems: Self.maximumTreeItems,
            maximumBytes: Self.maximumTreeBytes
        )
        guard actualFingerprint == expectedFingerprint else { throw OperationEngineError.sourceChangedAfterReview }
        try commitPreparedItem(staged, to: destination, planStepID: planStepID) {
            _ = try self.copyDestination(destination.path(percentEncoded: false), projectRootPath: projectRootPath)
        }
    }

    private func replaceManagedLibrary(at destination: URL, files: [EncryptedLibraryFile], planStepID: UUID) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appending(path: ".agent-tooling-library-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { removeStagingItemIfPresent(staged) }
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.path(percentEncoded: false))
        for file in files {
            let fileURL = staged.appending(path: file.relativePath, directoryHint: .notDirectory)
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: file.isExecutable == true ? 0o700 : 0o600],
                ofItemAtPath: fileURL.path(percentEncoded: false)
            )
        }
        try normalizePrivatePermissions(under: staged)
        try commitPreparedItem(staged, to: destination, planStepID: planStepID) {
            let direct = destination.standardizedFileURL
            let values = try direct.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard direct == self.store.libraryURL.standardizedFileURL,
                values.isDirectory == true,
                values.isSymbolicLink != true
            else {
                throw OperationEngineError.unsafeDestination(destination.path(percentEncoded: false))
            }
            try self.validateContainedPath(direct, within: self.store.rootURL)
        }
    }

    private func commitPreparedItem(
        _ staged: URL,
        to destination: URL,
        planStepID: UUID,
        revalidateDestination: () throws -> Void
    ) throws {
        try revalidateDestination()
        let exists = fileManager.fileExists(atPath: destination.path(percentEncoded: false))
        if exists {
            let destinationValues = try destination.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            let stagedValues = try staged.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard destinationValues.isSymbolicLink != true,
                stagedValues.isSymbolicLink != true,
                destinationValues.isDirectory == stagedValues.isDirectory,
                destinationValues.isRegularFile == stagedValues.isRegularFile
            else {
                throw OperationEngineError.unsafeDestination(destination.path(percentEncoded: false))
            }
            try preserveRollbackCopy(of: destination, planStepID: planStepID)
        }
        try revalidateDestination()
        if exists {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged, backupItemName: nil, options: [.usingNewMetadataOnly])
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
    }

    private func preserveRollbackCopy(of destination: URL, planStepID: UUID) throws {
        let rollback = store.receiptsURL
            .appending(path: "rollback", directoryHint: .isDirectory)
            .appending(path: planStepID.uuidString, directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: destination.lastPathComponent, directoryHint: .isDirectory)
        try validateContainedPath(rollback.deletingLastPathComponent(), within: store.receiptsURL)
        try fileManager.createDirectory(at: rollback.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: destination, to: rollback)
    }

    private func removeStagingItemIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            // A failed cleanup must not report the committed replacement as a
            // failed user operation. Hidden staging entries are ignored by the
            // inventory and export scanners and remain recoverable for manual
            // cleanup if the filesystem continues refusing deletion.
        }
    }

    private func validateDirectoryTree(_ root: URL) throws {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw OperationEngineError.unsafeSource(root.path(percentEncoded: false))
        }
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            )
        else { throw OperationEngineError.unsafeSource(root.path(percentEncoded: false)) }

        var itemCount = 0
        var byteCount = 0
        for case let item as URL in enumerator {
            itemCount += 1
            guard itemCount <= Self.maximumTreeItems else { throw OperationEngineError.sourceTooLarge }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true,
                values.isDirectory == true || values.isRegularFile == true
            else {
                throw OperationEngineError.unsupportedSourceItem(item.path(percentEncoded: false))
            }
            if values.isRegularFile == true {
                guard let size = values.fileSize, size >= 0 else {
                    throw OperationEngineError.unsupportedSourceItem(item.path(percentEncoded: false))
                }
                let (total, overflow) = byteCount.addingReportingOverflow(size)
                guard !overflow, total <= Self.maximumTreeBytes else { throw OperationEngineError.sourceTooLarge }
                byteCount = total
            }
        }
    }

    private func validateArchiveFiles(_ files: [EncryptedLibraryFile]) throws {
        guard files.count <= Self.maximumTreeItems else { throw OperationEngineError.invalidArchive }
        var paths = Set<String>()
        var byteCount = 0
        for file in files {
            guard Self.isSafeArchivePath(file.relativePath), paths.insert(file.relativePath).inserted else {
                throw OperationEngineError.invalidArchive
            }
            let (total, overflow) = byteCount.addingReportingOverflow(file.data.count)
            guard !overflow, total <= Self.maximumTreeBytes else { throw OperationEngineError.invalidArchive }
            byteCount = total
        }
        for path in paths {
            var components = path.split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast()
                guard !paths.contains(components.joined(separator: "/")) else {
                    throw OperationEngineError.invalidArchive
                }
            }
        }
    }

    private func validateContainedPath(_ candidate: URL, within anchor: URL) throws {
        let normalizedAnchor = anchor.standardizedFileURL
        let normalizedCandidate = candidate.standardizedFileURL
        guard Self.isLexicallyContained(normalizedCandidate, in: normalizedAnchor) else {
            throw OperationEngineError.unsafeDestination(candidate.path(percentEncoded: false))
        }
        let anchorValues = try normalizedAnchor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard anchorValues.isDirectory == true, anchorValues.isSymbolicLink != true else {
            throw OperationEngineError.unsafeDestination(candidate.path(percentEncoded: false))
        }

        let anchorPath = Self.normalizedPath(normalizedAnchor)
        let candidatePath = Self.normalizedPath(normalizedCandidate)
        let suffix = candidatePath == anchorPath ? "" : String(candidatePath.dropFirst(anchorPath.count + 1))
        var current = normalizedAnchor
        for component in suffix.split(separator: "/").map(String.init) {
            current.append(path: component)
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]) else {
                continue
            }
            guard values.isSymbolicLink != true else {
                throw OperationEngineError.unsafeDestination(candidate.path(percentEncoded: false))
            }
        }
        guard Self.isLexicallyContained(normalizedCandidate.resolvingSymlinksInPath(), in: normalizedAnchor.resolvingSymlinksInPath())
        else {
            throw OperationEngineError.unsafeDestination(candidate.path(percentEncoded: false))
        }
    }

    private func normalizePrivatePermissions(under root: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path(percentEncoded: false))
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        else { throw OperationEngineError.unsafeSource(root.path(percentEncoded: false)) }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw OperationEngineError.unsupportedSourceItem(item.path(percentEncoded: false))
            }
            if values.isDirectory == true {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: item.path(percentEncoded: false))
            } else if values.isRegularFile == true {
                let attributes = try fileManager.attributesOfItem(atPath: item.path(percentEncoded: false))
                let existing = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                let permissions = existing & 0o111 == 0 ? 0o600 : 0o700
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: item.path(percentEncoded: false))
            }
        }
    }

    private func validateCommand(executable: String, arguments: [String]) throws {
        guard Self.allowedCommands.contains(executable) else { throw OperationEngineError.commandNotAllowed(executable) }
        guard arguments.count <= 64,
            arguments.allSatisfy({ $0.count <= 8_192 && !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r") })
        else {
            throw OperationEngineError.commandArgumentsNotAllowed(executable)
        }

        switch executable {
        case "git":
            let target = gitBackupRoot.path(percentEncoded: false)
            guard arguments == ["-C", target, "init"] || arguments == ["-C", target, "status", "--short"] else {
                throw OperationEngineError.commandArgumentsNotAllowed(executable)
            }
        case "claude":
            try validateClaudeCommand(arguments)
        case "codex":
            try validateCodexCommand(arguments)
        case "gemini":
            try validateGeminiCommand(arguments)
        default:
            throw OperationEngineError.commandNotAllowed(executable)
        }
    }

    private func validateClaudeCommand(_ arguments: [String]) throws {
        if arguments.count == 5,
            ["install", "uninstall"].contains(arguments[1]),
            arguments[0] == "plugin",
            arguments[3] == "--scope",
            arguments[4] == "user",
            Self.isSafePluginIdentifier(arguments[2])
        {
            return
        }
        if arguments.count == 5,
            arguments[0] == "mcp",
            arguments[1] == "remove",
            arguments[2] == "--scope",
            ["user", "project", "local"].contains(arguments[3]),
            Self.isSafeMCPIdentifier(arguments[4])
        {
            return
        }
        if arguments.count == 8,
            arguments[0] == "mcp",
            arguments[1] == "add",
            arguments[2] == "--transport",
            arguments[3] == "http",
            arguments[4] == "--scope",
            ["user", "project", "local"].contains(arguments[5]),
            Self.isSafeMCPIdentifier(arguments[6]),
            Self.isSafeHTTPDestination(arguments[7])
        {
            return
        }
        if arguments.count >= 9,
            arguments[0] == "mcp",
            arguments[1] == "add",
            arguments[2] == "--transport",
            arguments[3] == "stdio",
            arguments[4] == "--scope",
            ["user", "project", "local"].contains(arguments[5]),
            Self.isSafeMCPIdentifier(arguments[6]),
            arguments[7] == "--",
            Self.isSafeStdioCommand(Array(arguments.dropFirst(8)))
        {
            return
        }
        throw OperationEngineError.commandArgumentsNotAllowed("claude")
    }

    private func validateCodexCommand(_ arguments: [String]) throws {
        if arguments.count == 3,
            arguments[0] == "plugin",
            ["add", "remove"].contains(arguments[1]),
            Self.isSafePluginIdentifier(arguments[2])
        {
            return
        }
        if arguments.count == 3,
            arguments[0] == "mcp",
            arguments[1] == "remove",
            Self.isSafeMCPIdentifier(arguments[2])
        {
            return
        }
        if arguments.count == 5,
            arguments[0] == "mcp",
            arguments[1] == "add",
            Self.isSafeMCPIdentifier(arguments[2]),
            arguments[3] == "--url",
            Self.isSafeHTTPDestination(arguments[4])
        {
            return
        }
        if arguments.count >= 5,
            arguments[0] == "mcp",
            arguments[1] == "add",
            Self.isSafeMCPIdentifier(arguments[2]),
            arguments[3] == "--",
            Self.isSafeStdioCommand(Array(arguments.dropFirst(4)))
        {
            return
        }
        throw OperationEngineError.commandArgumentsNotAllowed("codex")
    }

    private func validateGeminiCommand(_ arguments: [String]) throws {
        if arguments.count == 5,
            arguments[0] == "mcp",
            arguments[1] == "remove",
            arguments[2] == "--scope",
            ["user", "project"].contains(arguments[3]),
            Self.isSafeMCPIdentifier(arguments[4])
        {
            return
        }
        if arguments.count == 8,
            arguments[0] == "mcp",
            arguments[1] == "add",
            arguments[2] == "--scope",
            ["user", "project"].contains(arguments[3]),
            arguments[4] == "--transport",
            arguments[5] == "http",
            Self.isSafeMCPIdentifier(arguments[6]),
            Self.isSafeHTTPDestination(arguments[7])
        {
            return
        }
        if arguments.count >= 9,
            arguments[0] == "mcp",
            arguments[1] == "add",
            arguments[2] == "--scope",
            ["user", "project"].contains(arguments[3]),
            arguments[4] == "--transport",
            arguments[5] == "stdio",
            Self.isSafeMCPIdentifier(arguments[6]),
            arguments[7] == "--",
            Self.isSafeStdioCommand(Array(arguments.dropFirst(8)))
        {
            return
        }
        if arguments.count == 3,
            arguments[0] == "extensions",
            arguments[1] == "link"
        {
            let source = URL(fileURLWithPath: arguments[2]).standardizedFileURL
            guard isContained(source, in: store.libraryURL) else {
                throw OperationEngineError.commandArgumentsNotAllowed("gemini")
            }
            return
        }
        throw OperationEngineError.commandArgumentsNotAllowed("gemini")
    }

    private func isContained(_ child: URL, in root: URL) -> Bool {
        let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    private static let allowedCommands: Set<String> = ["claude", "codex", "gemini", "git"]
    private static let maximumTreeItems = 10_000
    private static let maximumTreeBytes = 384 * 1_024 * 1_024
    private static let maximumBackupMetadataBytes = 32 * 1_024 * 1_024

    private static func isSafeArchivePath(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty
            && value.count <= 8_192
            && components.count <= 64
            && !value.hasPrefix("/")
            && !value.hasSuffix("/")
            && !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func isSafeMCPIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 512
            && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar)
            }
    }

    private static func isSafePluginIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 512
            && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || "._-@".unicodeScalars.contains(scalar)
            }
    }

    private static func isSafeHTTPDestination(_ value: String) -> Bool {
        guard SensitiveValueRedactor.redact(value) == value,
            let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            components.host?.isEmpty == false
        else { return false }
        return components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
    }

    private static func isSafeStdioCommand(_ values: [String]) -> Bool {
        guard let executable = values.first,
            !executable.isEmpty,
            !executable.hasPrefix("-"),
            SensitiveValueRedactor.redact(values.joined(separator: " ")) == values.joined(separator: " ")
        else { return false }
        return values.allSatisfy { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedPath(lhs) == normalizedPath(rhs)
    }

    private static func isLexicallyContained(_ child: URL, in root: URL) -> Bool {
        let childPath = normalizedPath(child)
        let rootPath = normalizedPath(root)
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func persistableOutput(_ text: String) -> String {
        let redacted = SensitiveValueRedactor.redact(text)
        guard redacted.count > maximumPersistedOutputCharacters else { return redacted }
        return String(redacted.prefix(maximumPersistedOutputCharacters)) + "\n[output truncated]"
    }

    private static let maximumPersistedOutputCharacters = 60_000
}

public enum OperationEngineError: LocalizedError, Sendable {
    case malformedStep(String)
    case unsafeDestination(String)
    case unsafeSource(String)
    case commandNotAllowed(String)
    case commandArgumentsNotAllowed(String)
    case commandFailed(String, Int32, String)
    case dirtyGitBackup(String)
    case sourceTooLarge
    case unsupportedSourceItem(String)
    case invalidArchive
    case unsafeWorkingDirectory(String)
    case sourceChangedAfterReview

    public var errorDescription: String? {
        switch self {
        case .malformedStep(let title): "The operation step \"\(title)\" is incomplete."
        case .unsafeDestination(let path):
            "Agent Tooling refused to write outside its managed library or a supported client skill folder: \(path)"
        case .unsafeSource(let path): "Agent Tooling refused to copy content outside its managed local library: \(path)"
        case .commandNotAllowed(let command): "Agent Tooling refused to run an unapproved executable: \(command)"
        case .commandArgumentsNotAllowed(let command):
            "Agent Tooling refused unapproved arguments for \(command). Refresh the source or create a new reviewed plan."
        case .commandFailed(let command, let status, let output): "\(command) exited with status \(status). \(output)"
        case .dirtyGitBackup(let path):
            "The local Git backup at \(path) has uncommitted or untracked changes. Review, commit, or discard them before exporting again."
        case .sourceTooLarge: "The source contains too many files or exceeds Agent Tooling's safe copy limit."
        case .unsupportedSourceItem(let path):
            "The source contains a symbolic link or unsupported file at \(path). Agent Tooling copies only regular files and directories."
        case .invalidArchive: "Agent Tooling refused an invalid encrypted archive payload."
        case .unsafeWorkingDirectory(let path):
            "Agent Tooling refused to run a command from an unreviewed or unavailable project folder: \(path)"
        case .sourceChangedAfterReview:
            "The source changed after it was reviewed. Refresh the plan and inspect the new contents before trying again."
        }
    }
}

import Darwin
import Foundation

/// One JSON-RPC conversation with a server under test.
///
/// Keeping the transport behind this protocol is what lets the protocol tests
/// exercise a real handshake, tool listing, and tool call against a fixture
/// without spawning a process or opening a socket.
public protocol MCPTestChannel: Sendable {
    /// Sends one request envelope and returns the matching response envelope.
    func send(request: Data, id: Int) async throws -> Data
    /// Sends one notification envelope. Notifications never carry a reply.
    func send(notification: Data) async throws
    /// Redacted, bounded text the server wrote outside the protocol.
    func diagnostics() async -> String
    /// Stops the connection. Safe to call more than once.
    func shutdown() async
}

// MARK: - stdio

/// Speaks MCP to a locally started program over newline-delimited stdin/stdout.
///
/// The process is started only when the first request is sent, which keeps the
/// "nothing runs until the person confirms" rule enforceable at the call site
/// rather than by convention.
public actor MCPStdioTestChannel: MCPTestChannel {
    private static let maximumSkippedMessages = 64

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private var process: MCPStdioProcess?
    private var isShutDown = false

    public init(executableURL: URL, arguments: [String], environment: [String: String]) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }

    public init(target: MCPTestTarget, homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard case .stdio(let executableURL, let arguments) = target else {
            throw MCPLiveTestError.definitionNotConnectable("This channel only speaks to a stdio server.")
        }
        self.init(
            executableURL: executableURL,
            arguments: arguments,
            environment: MCPTestConnectionPolicy.childEnvironment(homeURL: homeURL)
        )
    }

    public func send(request: Data, id: Int) async throws -> Data {
        let running = try startIfNeeded()
        try running.write(line: request)
        var skipped = 0
        while true {
            try Task.checkCancellation()
            guard let line = try await running.nextLine() else {
                throw MCPLiveTestError.serverStopped(running.diagnostics())
            }
            if let responseID = MCPJSONRPC.responseIdentifier(in: line), responseID == id {
                return line
            }
            skipped += 1
            guard skipped <= Self.maximumSkippedMessages else {
                throw MCPLiveTestError.protocolViolation("The server sent \(skipped) messages that were not the requested reply.")
            }
        }
    }

    public func send(notification: Data) async throws {
        let running = try startIfNeeded()
        try running.write(line: notification)
    }

    public func diagnostics() async -> String {
        process?.diagnostics() ?? ""
    }

    public func shutdown() async {
        isShutDown = true
        process?.terminate()
        process = nil
    }

    private func startIfNeeded() throws -> MCPStdioProcess {
        if let process { return process }
        guard !isShutDown else { throw MCPLiveTestError.cancelled }
        let started = try MCPStdioProcess(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            maximumMessageBytes: MCPTestConnectionPolicy.maximumMessageBytes
        )
        process = started
        return started
    }
}

/// Owns the child process, its pipes, and its line framing.
///
/// `Process`, `Pipe`, and `FileHandle` are not `Sendable`, so every touch of
/// them happens behind this class's own lock.
final class MCPStdioProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let reader: MCPLineReader
    private let errorBuffer = MCPBoundedTextBuffer(limit: MCPTestConnectionPolicy.maximumDiagnosticCharacters)
    private var processGroup: pid_t?
    private var isTerminated = false

    init(executableURL: URL, arguments: [String], environment: [String: String], maximumMessageBytes: Int) throws {
        reader = MCPLineReader(maximumMessageBytes: maximumMessageBytes)
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let reader = self.reader
        let errorBuffer = self.errorBuffer
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                reader.finish()
            } else {
                reader.append(chunk)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            errorBuffer.append(String(decoding: chunk, as: UTF8.self))
        }
        process.terminationHandler = { finished in
            errorBuffer.note("Process exited with status \(finished.terminationStatus).")
            reader.finish()
        }

        do {
            try process.run()
        } catch {
            throw MCPLiveTestError.executableNotFound(executableURL.lastPathComponent)
        }
        let identifier = process.processIdentifier
        // A managed server such as `npx` starts children of its own. Putting the
        // child in its own group is what lets cancel stop the whole tree.
        processGroup = Darwin.setpgid(identifier, identifier) == 0 ? identifier : nil
    }

    func write(line: Data) throws {
        guard line.count <= MCPTestConnectionPolicy.maximumMessageBytes else {
            throw MCPLiveTestError.protocolViolation("The request envelope exceeds the test connection's message size limit.")
        }
        lock.lock()
        let stopped = isTerminated
        lock.unlock()
        guard !stopped else { throw MCPLiveTestError.cancelled }
        var payload = line
        payload.append(0x0A)
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: payload)
        } catch {
            throw MCPLiveTestError.serverStopped(diagnostics())
        }
    }

    func nextLine() async throws -> Data? {
        try await reader.next()
    }

    func diagnostics() -> String {
        SensitiveValueRedactor.redact(errorBuffer.text())
    }

    func terminate() {
        lock.lock()
        if isTerminated {
            lock.unlock()
            return
        }
        isTerminated = true
        let group = processGroup
        lock.unlock()

        reader.fail(.cancelled)
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        guard process.isRunning else { return }
        signal(SIGTERM, group: group)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.signal(SIGKILL, group: group)
        }
    }

    private func signal(_ code: Int32, group: pid_t?) {
        if let group {
            _ = Darwin.kill(-group, code)
        } else {
            _ = Darwin.kill(process.processIdentifier, code)
        }
    }

    deinit {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
    }
}

/// Newline framing with a hard cap, so a server that never emits a newline
/// cannot grow the app's memory while the console waits.
final class MCPLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumMessageBytes: Int
    private var buffer = Data()
    private var pending: [Data] = []
    private var isFinished = false
    private var failure: MCPLiveTestError?
    private var waiter: CheckedContinuation<Data?, any Error>?

    init(maximumMessageBytes: Int) {
        self.maximumMessageBytes = maximumMessageBytes
    }

    func append(_ chunk: Data) {
        lock.lock()
        guard failure == nil, !isFinished else {
            lock.unlock()
            return
        }
        buffer.append(chunk)
        var ready: [Data] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            let trimmed = Data(line).trimmedTrailingCarriageReturn()
            if !trimmed.isEmpty { ready.append(trimmed) }
        }
        if buffer.count > maximumMessageBytes {
            buffer.removeAll(keepingCapacity: false)
            failure = .responseTooLarge
        }
        pending.append(contentsOf: ready)
        let delivery = takeDeliveryLocked()
        lock.unlock()
        deliver(delivery)
    }

    func finish() {
        lock.lock()
        isFinished = true
        let delivery = takeDeliveryLocked()
        lock.unlock()
        deliver(delivery)
    }

    func fail(_ error: MCPLiveTestError) {
        lock.lock()
        if failure == nil { failure = error }
        let delivery = takeDeliveryLocked()
        lock.unlock()
        deliver(delivery)
    }

    func next() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                lock.lock()
                if let outcome = nextOutcomeLocked() {
                    lock.unlock()
                    deliver((continuation, outcome))
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            fail(.cancelled)
        }
    }

    private enum Outcome {
        case line(Data)
        case end
        case failed(MCPLiveTestError)
    }

    private typealias Delivery = (continuation: CheckedContinuation<Data?, any Error>, outcome: Outcome)

    /// Only consumes a queued line when somebody is actually waiting for it.
    private func takeDeliveryLocked() -> Delivery? {
        guard let continuation = waiter, let outcome = nextOutcomeLocked() else { return nil }
        waiter = nil
        return (continuation, outcome)
    }

    private func nextOutcomeLocked() -> Outcome? {
        if let failure { return .failed(failure) }
        if !pending.isEmpty { return .line(pending.removeFirst()) }
        if isFinished { return .end }
        return nil
    }

    private func deliver(_ delivery: Delivery?) {
        guard let delivery else { return }
        switch delivery.outcome {
        case .line(let data): delivery.continuation.resume(returning: data)
        case .end: delivery.continuation.resume(returning: nil)
        case .failed(let error): delivery.continuation.resume(throwing: error)
        }
    }
}

/// Bounded, append-only text used for the diagnostics strip under the console.
final class MCPBoundedTextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var value = ""

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard value.count < limit else { return }
        value += String(text.prefix(limit - value.count))
    }

    func note(_ text: String) {
        append(value.isEmpty ? text : "\n\(text)")
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

extension Data {
    fileprivate func trimmedTrailingCarriageReturn() -> Data {
        guard last == 0x0D else { return self }
        return dropLast()
    }
}

// MARK: - HTTP

/// Speaks MCP over HTTP with an ephemeral session that holds no credentials.
///
/// The session is built rather than shared: no cookie jar, no credential
/// storage, no cache, and no default headers, so nothing the person has signed
/// into elsewhere can ride along on a test request.
public actor MCPHTTPTestChannel: MCPTestChannel {
    private let url: URL
    private let session: URLSession
    private var sessionIdentifier: String?
    private let notes = MCPBoundedTextBuffer(limit: MCPTestConnectionPolicy.maximumDiagnosticCharacters)

    public init(url: URL, timeout: Duration = MCPTestConnectionPolicy.toolCallTimeout) {
        self.url = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = max(1, timeout.milliseconds / 1_000)
        session = URLSession(configuration: configuration)
    }

    public init(target: MCPTestTarget) throws {
        guard case .http(let url) = target else {
            throw MCPLiveTestError.definitionNotConnectable("This channel only speaks to an HTTP server.")
        }
        self.init(url: url)
    }

    public func send(request: Data, id: Int) async throws -> Data {
        let (data, response) = try await post(request)
        try check(response)
        if let identifier = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !identifier.isEmpty {
            sessionIdentifier = String(identifier.prefix(512))
        }
        guard data.count <= MCPTestConnectionPolicy.maximumMessageBytes else {
            throw MCPLiveTestError.responseTooLarge
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let envelopes = contentType.contains("text/event-stream") ? Self.eventStreamPayloads(data) : [data]
        for envelope in envelopes where MCPJSONRPC.responseIdentifier(in: envelope) == id {
            return envelope
        }
        throw MCPLiveTestError.protocolViolation("No reply carrying request id \(id) was found in the response.")
    }

    public func send(notification: Data) async throws {
        let (_, response) = try await post(notification)
        try check(response)
    }

    public func diagnostics() async -> String {
        SensitiveValueRedactor.redact(notes.text())
    }

    public func shutdown() async {
        sessionIdentifier = nil
        session.invalidateAndCancel()
    }

    private func post(_ body: Data) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(MCPTestConnectionPolicy.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionIdentifier {
            request.setValue(sessionIdentifier, forHTTPHeaderField: "Mcp-Session-Id")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPLiveTestError.protocolViolation("The endpoint did not answer with an HTTP response.")
            }
            return (data, httpResponse)
        } catch let error as MCPLiveTestError {
            throw error
        } catch is CancellationError {
            throw MCPLiveTestError.cancelled
        } catch {
            notes.note(error.localizedDescription)
            throw MCPLiveTestError.serverStopped(SensitiveValueRedactor.redact(error.localizedDescription))
        }
    }

    private func check(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw MCPLiveTestError.authenticationRequired
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MCPLiveTestError.httpStatus(response.statusCode)
        }
    }

    /// Pulls the `data:` payloads out of a server-sent-event body. Anything that
    /// is not a complete JSON object is dropped rather than guessed at.
    static func eventStreamPayloads(_ data: Data) -> [Data] {
        let text = String(decoding: data, as: UTF8.self)
        var payloads: [Data] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, let encoded = payload.data(using: .utf8) else { continue }
            payloads.append(encoded)
        }
        return payloads
    }
}

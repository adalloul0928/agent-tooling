import Foundation

/// One line out and one line in, to a running `codex app-server`.
///
/// Kept behind a protocol so the JSON-RPC exchange is tested against a
/// scripted server rather than a real process.
public protocol CodexAppServerTransport: Sendable {
    func send(_ line: Data) async throws
    /// The next line the server wrote, or nil once it stopped writing.
    func receive() async throws -> Data?
    /// Redacted text the server wrote to standard error.
    func diagnostics() async -> String
    func close() async
}

enum CodexAppServerError: LocalizedError, Equatable, Sendable {
    case notAllowed(String)
    case launchFailed(String)
    case timedOut(String)
    case stopped(String)
    case serverError(method: String, message: String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .notAllowed(let method): "Agent Tooling does not send \(method) to Codex."
        case .launchFailed(let reason): "Codex could not be started: \(reason)"
        case .timedOut(let method): "Codex did not answer \(method) in time."
        case .stopped(let detail): detail.isEmpty ? "Codex stopped before it answered." : "Codex stopped before it answered: \(detail)"
        case .serverError(let method, let message): "Codex refused \(method): \(message)"
        case .malformedResponse(let method): "Codex answered \(method) in a shape this app does not read."
        }
    }
}

/// A short conversation with Codex's app server that can only read.
///
/// `codex app-server` speaks JSON-RPC over standard input and output, and its
/// method list includes writes: configuration edits, plugin installs, model
/// turns. This session sends only the methods named in `allowedMethods`, and
/// refuses any other before a byte is written, so the guarantee that the
/// account view reads and never changes anything lives here rather than in
/// every caller. Configuration changes go through the reviewed operation
/// engine instead, which backs a file up before touching it.
///
/// Verified against Codex 0.162.1: responses carry no `jsonrpc` field, the
/// server writes notifications between responses, and it exits when its
/// standard input closes, so the input stays open until the last answer.
public actor CodexAppServerSession {
    public static let allowedMethods: Set<String> = ["initialize", "account/read", "config/read", "app/list", "app/installed"]
    public static let allowedNotifications: Set<String> = ["initialized"]
    static let maximumSkippedMessages = 512

    private let transport: any CodexAppServerTransport
    private let requestTimeout: Duration
    private var nextIdentifier = 1
    private var isClosed = false

    public init(transport: any CodexAppServerTransport, requestTimeout: Duration = .seconds(30)) {
        self.transport = transport
        self.requestTimeout = requestTimeout
    }

    /// Starts `codex app-server` from the located executable, with the same
    /// allowlisted environment every other client command gets.
    public static func launch(executable: URL, homeURL: URL, requestTimeout: Duration = .seconds(30)) throws -> CodexAppServerSession {
        let transport = try CodexAppServerProcessTransport(executable: executable, homeURL: homeURL)
        return CodexAppServerSession(transport: transport, requestTimeout: requestTimeout)
    }

    /// The handshake. Returns what the server said about itself.
    public func initialize(clientName: String, clientTitle: String, version: String) async throws -> JSONValue {
        let result = try await request(
            "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string(clientName), "title": .string(clientTitle), "version": .string(version),
                ])
            ]))
        try await notify("initialized")
        return result
    }

    public func request(_ method: String, params: JSONValue? = nil, timeout: Duration? = nil) async throws -> JSONValue {
        guard Self.allowedMethods.contains(method) else { throw CodexAppServerError.notAllowed(method) }
        guard !isClosed else { throw CodexAppServerError.stopped("") }
        let identifier = nextIdentifier
        nextIdentifier += 1
        var body: [String: JSONValue] = ["id": .number(Double(identifier)), "method": .string(method)]
        if let params { body["params"] = params }
        try await transport.send(try Self.encode(.object(body)))
        let limit = timeout ?? requestTimeout
        let transport = self.transport
        do {
            return try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask { try await Self.awaitResponse(identifier: identifier, method: method, from: transport) }
                group.addTask {
                    try await Task.sleep(for: limit)
                    throw CodexAppServerError.timedOut(method)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CodexAppServerError.stopped("") }
                return first
            }
        } catch let error as CodexAppServerError {
            if case .timedOut = error { await close() }
            throw error
        }
    }

    public func notify(_ method: String, params: JSONValue? = nil) async throws {
        guard Self.allowedNotifications.contains(method) else { throw CodexAppServerError.notAllowed(method) }
        guard !isClosed else { throw CodexAppServerError.stopped("") }
        var body: [String: JSONValue] = ["method": .string(method)]
        if let params { body["params"] = params }
        try await transport.send(try Self.encode(.object(body)))
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        await transport.close()
    }

    // MARK: Framing

    static func encode(_ value: JSONValue) throws -> Data {
        try AgentToolingCoding.encoder().encode(value)
    }

    /// Reads until the reply to `identifier`, passing over notifications and
    /// any request the server makes of the client. A server that never stops
    /// talking is cut off rather than read forever.
    private static func awaitResponse(
        identifier: Int, method: String, from transport: any CodexAppServerTransport
    ) async throws -> JSONValue {
        var skipped = 0
        while true {
            try Task.checkCancellation()
            guard let line = try await transport.receive() else {
                throw CodexAppServerError.stopped(await transport.diagnostics())
            }
            guard let message = try? AgentToolingCoding.decoder().decode(JSONValue.self, from: line),
                case .object(let body) = message
            else {
                skipped += 1
                guard skipped <= maximumSkippedMessages else { throw CodexAppServerError.malformedResponse(method) }
                continue
            }
            if body["method"] == nil, case .number(let value)? = body["id"], value == Double(identifier) {
                if let error = body["error"] {
                    let text = error["message"]?.stringValue ?? "an error with no message"
                    throw CodexAppServerError.serverError(method: method, message: SensitiveValueRedactor.redact(String(text.prefix(400))))
                }
                guard let result = body["result"] else { throw CodexAppServerError.malformedResponse(method) }
                return result
            }
            skipped += 1
            guard skipped <= maximumSkippedMessages else { throw CodexAppServerError.malformedResponse(method) }
        }
    }
}

/// The real transport: a child process with newline framing, bounded the
/// same way the MCP test console bounds a server it starts.
final class CodexAppServerProcessTransport: CodexAppServerTransport, @unchecked Sendable {
    private let process: MCPStdioProcess

    init(executable: URL, homeURL: URL) throws {
        do {
            process = try MCPStdioProcess(
                executableURL: executable, arguments: ["app-server"],
                environment: ProcessCommandRunner.childEnvironment(
                    inheriting: ProcessInfo.processInfo.environment, homeURL: homeURL),
                maximumMessageBytes: MCPTestConnectionPolicy.maximumMessageBytes)
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
    }

    func send(_ line: Data) async throws {
        do { try process.write(line: line) } catch {
            throw CodexAppServerError.stopped(process.diagnostics())
        }
    }

    func receive() async throws -> Data? {
        do { return try await process.nextLine() } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerError.stopped(process.diagnostics())
        }
    }

    func diagnostics() async -> String { process.diagnostics() }

    func close() async { process.terminate() }
}

// MARK: - Reading JSON values

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

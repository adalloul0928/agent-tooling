import Foundation

// MARK: - JSON-RPC envelopes

/// Envelope handling for MCP's JSON-RPC 2.0 framing.
///
/// Everything here is pure: no I/O, no process, no socket. A malformed or
/// hostile payload has to be rejected as a typed error rather than trapping, so
/// there is no force unwrap, no `try!`, and no unbounded recursion on this path.
enum MCPJSONRPC {
    static func requestEnvelope(id: Int, method: String, params: JSONValue?) throws -> Data {
        var body: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params { body["params"] = params }
        return try AgentToolingCoding.encoder().encode(JSONValue.object(body))
    }

    static func notificationEnvelope(method: String, params: JSONValue?) throws -> Data {
        var body: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { body["params"] = params }
        return try AgentToolingCoding.encoder().encode(JSONValue.object(body))
    }

    /// The request id a payload is answering, or `nil` when the payload is not
    /// a reply at all. A server-initiated request also carries an id, so the
    /// presence of `method` disqualifies it.
    static func responseIdentifier(in data: Data) -> Int? {
        guard data.count <= MCPTestConnectionPolicy.maximumMessageBytes,
            let value = try? AgentToolingCoding.decoder().decode(JSONValue.self, from: data),
            case .object(let body) = value,
            case .string("2.0") = body["jsonrpc"],
            body["method"] == nil,
            case .number(let identifier) = body["id"],
            identifier.isFinite,
            identifier == identifier.rounded(),
            abs(identifier) <= Double(Int.max)
        else { return nil }
        return Int(identifier)
    }

    /// Decodes one reply into its `result` object, or throws a typed error.
    static func result(from data: Data, id: Int) throws -> [String: JSONValue] {
        guard data.count <= MCPTestConnectionPolicy.maximumMessageBytes else {
            throw MCPLiveTestError.responseTooLarge
        }
        guard let value = try? AgentToolingCoding.decoder().decode(JSONValue.self, from: data),
            case .object(let body) = value
        else {
            throw MCPLiveTestError.protocolViolation("The reply was not a JSON object.")
        }
        guard case .string("2.0") = body["jsonrpc"] else {
            throw MCPLiveTestError.protocolViolation("The reply did not declare JSON-RPC 2.0.")
        }
        if case .object(let failure) = body["error"] {
            let code: Int = {
                if case .number(let value) = failure["code"], value.isFinite, abs(value) <= Double(Int.max) { return Int(value) }
                return 0
            }()
            let message = MCPResponseReader.text(failure["message"], limit: 512) ?? "The server sent no message."
            throw MCPLiveTestError.serverError(code, message)
        }
        guard case .number(let identifier) = body["id"], identifier == Double(id) else {
            throw MCPLiveTestError.protocolViolation("The reply answered a different request.")
        }
        guard case .object(let result) = body["result"] else {
            throw MCPLiveTestError.protocolViolation("The reply carried no result object.")
        }
        return result
    }
}

// MARK: - MCP payload reading

/// Reads MCP result payloads defensively. Every string that reaches the
/// interface passes through here, so it is bounded and redacted at the seam.
enum MCPResponseReader {
    static func text(_ value: JSONValue?, limit: Int) -> String? {
        guard case .string(let raw) = value else { return nil }
        let cleaned = SensitiveValueRedactor.redact(raw)
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
    }

    static func flag(_ value: JSONValue?) -> Bool? {
        guard case .bool(let flag) = value else { return nil }
        return flag
    }

    static func annotations(_ value: JSONValue?) -> MCPLiveToolAnnotations? {
        guard case .object(let body) = value, !body.isEmpty else { return nil }
        let annotations = MCPLiveToolAnnotations(
            title: text(body["title"], limit: 200),
            readOnlyHint: flag(body["readOnlyHint"]),
            destructiveHint: flag(body["destructiveHint"]),
            idempotentHint: flag(body["idempotentHint"]),
            openWorldHint: flag(body["openWorldHint"])
        )
        return annotations.isEmpty ? nil : annotations
    }

    static func tools(in result: [String: JSONValue]) throws -> (tools: [MCPLiveTool], nextCursor: String?) {
        guard case .array(let entries) = result["tools"] else {
            throw MCPLiveTestError.protocolViolation("tools/list did not return a tools array.")
        }
        var tools: [MCPLiveTool] = []
        for entry in entries {
            guard case .object(let body) = entry else { continue }
            guard case .string(let rawName) = body["name"] else { continue }
            let name = String(SensitiveValueRedactor.redact(rawName).prefix(256))
            guard !name.isEmpty else { continue }
            tools.append(
                MCPLiveTool(
                    name: name,
                    title: text(body["title"], limit: 200),
                    summary: text(body["description"], limit: 1_024),
                    inputSchema: boundedSchema(body["inputSchema"]),
                    annotations: annotations(body["annotations"])
                )
            )
        }
        return (tools, text(result["nextCursor"], limit: 1_024))
    }

    static func entryCount(in result: [String: JSONValue], key: String) throws -> (count: Int, nextCursor: String?) {
        guard case .array(let entries) = result[key] else {
            throw MCPLiveTestError.protocolViolation("The server returned no \(key) array.")
        }
        return (entries.count, text(result["nextCursor"], limit: 1_024))
    }

    /// Refuses a schema that is too deep or too wide to render, so a hostile
    /// schema cannot drive the form generator into a pathological shape.
    static func boundedSchema(_ value: JSONValue?) -> JSONValue? {
        guard let value, depth(of: value, remaining: 12) <= 12, nodeCount(of: value, limit: 2_000) <= 2_000 else { return nil }
        return value
    }

    private static func depth(of value: JSONValue, remaining: Int) -> Int {
        guard remaining > 0 else { return 13 }
        switch value {
        case .object(let body): return 1 + (body.values.map { depth(of: $0, remaining: remaining - 1) }.max() ?? 0)
        case .array(let items): return 1 + (items.map { depth(of: $0, remaining: remaining - 1) }.max() ?? 0)
        case .string, .number, .bool, .null: return 1
        }
    }

    private static func nodeCount(of value: JSONValue, limit: Int) -> Int {
        var total = 1
        switch value {
        case .object(let body):
            for child in body.values {
                total += nodeCount(of: child, limit: limit)
                if total > limit { return total }
            }
        case .array(let items):
            for child in items {
                total += nodeCount(of: child, limit: limit)
                if total > limit { return total }
            }
        case .string, .number, .bool, .null: break
        }
        return total
    }

    static func callOutcome(_ result: [String: JSONValue], toolName: String, milliseconds: Double) -> MCPToolCallOutcome {
        var lines: [String] = []
        if case .array(let blocks) = result["content"] {
            for block in blocks.prefix(64) {
                guard case .object(let body) = block else { continue }
                if let value = text(body["text"], limit: MCPTestConnectionPolicy.maximumToolResultCharacters) {
                    lines.append(value)
                } else if case .string(let type) = body["type"] {
                    lines.append("[\(String(type.prefix(32))) content]")
                }
            }
        }
        let structured: String? = {
            guard let value = result["structuredContent"] else { return nil }
            let encoder = AgentToolingCoding.encoder(prettyPrinted: true)
            guard let data = try? encoder.encode(value), data.count <= MCPTestConnectionPolicy.maximumToolResultCharacters else {
                return nil
            }
            return SensitiveValueRedactor.redact(String(decoding: data, as: UTF8.self))
        }()
        let joined = lines.joined(separator: "\n")
        return MCPToolCallOutcome(
            toolName: toolName,
            isError: flag(result["isError"]) ?? false,
            text: String(joined.prefix(MCPTestConnectionPolicy.maximumToolResultCharacters)),
            structuredText: structured,
            latencyMilliseconds: milliseconds
        )
    }
}

// MARK: - Session

/// Drives one live MCP conversation: handshake, inventory, and at most one tool
/// call at a time.
///
/// The session never records anything. It returns observations and outcomes,
/// and the caller decides what, if anything, to show.
public actor MCPLiveTestSession {
    private let channel: any MCPTestChannel
    private let clientVersion: String
    private var nextIdentifier = 1
    private var offeredToolNames: Set<String> = []
    private var isClosed = false

    public init(channel: any MCPTestChannel, clientVersion: String = "1") {
        self.channel = channel
        self.clientVersion = clientVersion
    }

    public func diagnostics() async -> String {
        await channel.diagnostics()
    }

    public func close() async {
        isClosed = true
        await channel.shutdown()
    }

    /// Performs the handshake and reads the live inventory in one pass.
    public func open(
        handshakeTimeout: Duration = MCPTestConnectionPolicy.handshakeTimeout,
        inventoryTimeout: Duration = MCPTestConnectionPolicy.inventoryTimeout
    ) async throws -> MCPLiveObservation {
        guard !isClosed else { throw MCPLiveTestError.cancelled }
        let clock = ContinuousClock()

        let handshakeStart = clock.now
        let initializeResult = try await perform(
            method: "initialize",
            params: .object([
                "protocolVersion": .string(MCPTestConnectionPolicy.protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string(MCPTestConnectionPolicy.clientName),
                    "version": .string(clientVersion),
                ]),
            ]),
            timeout: handshakeTimeout,
            stage: "The MCP handshake"
        )
        let handshakeMilliseconds = (clock.now - handshakeStart).milliseconds

        guard let protocolVersion = MCPResponseReader.text(initializeResult["protocolVersion"], limit: 64) else {
            await shutdownAfterFatalError()
            throw MCPLiveTestError.handshakeRejected("It did not return a protocol version.")
        }
        var capabilities: [String: JSONValue] = [:]
        if case .object(let declared) = initializeResult["capabilities"] { capabilities = declared }
        var serverName: String?
        var serverVersion: String?
        if case .object(let info) = initializeResult["serverInfo"] {
            serverName = MCPResponseReader.text(info["name"], limit: 200)
            serverVersion = MCPResponseReader.text(info["version"], limit: 64)
        }

        try await notify(method: "notifications/initialized", timeout: handshakeTimeout)

        let declaresTools = capabilities["tools"] != nil
        let declaresResources = capabilities["resources"] != nil
        let declaresPrompts = capabilities["prompts"] != nil

        let inventoryStart = clock.now
        let tools = declaresTools ? try await listTools(timeout: inventoryTimeout) : []
        let resourceCount =
            declaresResources ? try await listCount(method: "resources/list", key: "resources", timeout: inventoryTimeout) : 0
        let promptCount = declaresPrompts ? try await listCount(method: "prompts/list", key: "prompts", timeout: inventoryTimeout) : 0
        let inventoryMilliseconds = (clock.now - inventoryStart).milliseconds

        offeredToolNames = Set(tools.map(\.name))
        return MCPLiveObservation(
            serverName: serverName,
            serverVersion: serverVersion,
            protocolVersion: protocolVersion,
            instructions: MCPResponseReader.text(initializeResult["instructions"], limit: 2_048),
            tools: tools.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            resourceCount: resourceCount,
            promptCount: promptCount,
            declaresTools: declaresTools,
            declaresResources: declaresResources,
            declaresPrompts: declaresPrompts,
            handshakeMilliseconds: handshakeMilliseconds,
            inventoryMilliseconds: inventoryMilliseconds
        )
    }

    /// Runs one tool. The caller is responsible for having taken consent; this
    /// only refuses a name the live inventory never offered.
    public func callTool(
        named name: String,
        arguments: [String: JSONValue],
        timeout: Duration = MCPTestConnectionPolicy.toolCallTimeout
    ) async throws -> MCPToolCallOutcome {
        guard !isClosed else { throw MCPLiveTestError.cancelled }
        guard offeredToolNames.contains(name) else { throw MCPLiveTestError.toolNotOffered(name) }
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await perform(
            method: "tools/call",
            params: .object(["name": .string(name), "arguments": .object(arguments)]),
            timeout: timeout,
            stage: "The \(name) call"
        )
        return MCPResponseReader.callOutcome(result, toolName: name, milliseconds: (clock.now - start).milliseconds)
    }

    // MARK: Request plumbing

    private func listTools(timeout: Duration) async throws -> [MCPLiveTool] {
        var collected: [MCPLiveTool] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<MCPTestConnectionPolicy.maximumListPages {
            let params: JSONValue? = cursor.map { .object(["cursor": .string($0)]) }
            let result = try await perform(method: "tools/list", params: params, timeout: timeout, stage: "The tool list")
            let page = try MCPResponseReader.tools(in: result)
            for tool in page.tools where seen.insert(tool.name).inserted {
                collected.append(tool)
                if collected.count >= MCPTestConnectionPolicy.maximumToolCount { return collected }
            }
            guard let next = page.nextCursor, next != cursor else { return collected }
            cursor = next
        }
        return collected
    }

    private func listCount(method: String, key: String, timeout: Duration) async throws -> Int {
        var total = 0
        var cursor: String?
        for _ in 0..<MCPTestConnectionPolicy.maximumListPages {
            let params: JSONValue? = cursor.map { .object(["cursor": .string($0)]) }
            let result: [String: JSONValue]
            do {
                result = try await perform(method: method, params: params, timeout: timeout, stage: "The \(key) list")
            } catch MCPLiveTestError.serverError {
                // A server may declare a capability and still refuse the list.
                // That is the server's answer, not a broken connection.
                return total
            }
            let page = try MCPResponseReader.entryCount(in: result, key: key)
            total += page.count
            guard let next = page.nextCursor, next != cursor else { return total }
            cursor = next
        }
        return total
    }

    private func perform(
        method: String,
        params: JSONValue?,
        timeout: Duration,
        stage: String
    ) async throws -> [String: JSONValue] {
        let identifier = nextIdentifier
        nextIdentifier += 1
        let envelope = try encode { try MCPJSONRPC.requestEnvelope(id: identifier, method: method, params: params) }
        let channel = self.channel
        do {
            let reply = try await withDeadline(timeout, stage: stage, channel: channel) {
                try await channel.send(request: envelope, id: identifier)
            }
            return try MCPJSONRPC.result(from: reply, id: identifier)
        } catch {
            let mapped = Self.normalize(error)
            if Self.isFatal(mapped) { await shutdownAfterFatalError() }
            throw mapped
        }
    }

    private func notify(method: String, timeout: Duration) async throws {
        let envelope = try encode { try MCPJSONRPC.notificationEnvelope(method: method, params: nil) }
        let channel = self.channel
        do {
            try await withDeadline(timeout, stage: "The \(method) notification", channel: channel) {
                try await channel.send(notification: envelope)
            }
        } catch {
            let mapped = Self.normalize(error)
            if Self.isFatal(mapped) { await shutdownAfterFatalError() }
            throw mapped
        }
    }

    private func encode(_ build: () throws -> Data) throws -> Data {
        do {
            return try build()
        } catch {
            throw MCPLiveTestError.protocolViolation("Agent Tooling could not encode the request.")
        }
    }

    private func shutdownAfterFatalError() async {
        isClosed = true
        await channel.shutdown()
    }

    /// Every stage is bounded. On expiry the channel is stopped before the
    /// error propagates, so no process or socket survives a timeout.
    private func withDeadline<Value: Sendable>(
        _ duration: Duration,
        stage: String,
        channel: any MCPTestChannel,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask(priority: .userInitiated) { try await operation() }
                group.addTask {
                    try await Task.sleep(for: duration)
                    await channel.shutdown()
                    throw MCPLiveTestError.timedOut(stage)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw MCPLiveTestError.protocolViolation("The request ended without a result.")
                }
                return first
            }
        } onCancel: {
            Task { await channel.shutdown() }
        }
    }

    private static func normalize(_ error: any Error) -> MCPLiveTestError {
        if let live = error as? MCPLiveTestError { return live }
        if error is CancellationError { return .cancelled }
        return .protocolViolation(SensitiveValueRedactor.redact(error.localizedDescription))
    }

    private static func isFatal(_ error: MCPLiveTestError) -> Bool {
        switch error {
        case .serverError, .toolNotOffered: false
        default: true
        }
    }
}

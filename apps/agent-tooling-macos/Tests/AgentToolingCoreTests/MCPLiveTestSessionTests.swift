import Foundation
import Testing

@testable import AgentToolingCore

// MARK: - Fixture server

/// A complete in-memory MCP server. It parses real request envelopes and
/// answers with real MCP payloads, so the protocol path is exercised end to end
/// without starting a process or opening a socket.
private actor FixtureMCPServer: MCPTestChannel {
    struct Script: Sendable {
        var capabilities: [String: JSONValue] = [
            "tools": .object([:]),
            "resources": .object([:]),
            "prompts": .object([:]),
        ]
        var tools: [JSONValue] = []
        var resources: [JSONValue] = []
        var prompts: [JSONValue] = []
        var toolResult: [String: JSONValue] = [
            "content": .array([.object(["type": .string("text"), "text": .string("ok")])])
        ]
        /// Raw bytes returned instead of a well-formed reply, keyed by method.
        var rawReplies: [String: Data] = [:]
        var stallForever = false
    }

    private(set) var script: Script
    private(set) var methods: [String] = []
    private(set) var lastCallArguments: [String: JSONValue] = [:]
    private(set) var shutdownCount = 0
    private(set) var sawCancellation = false

    init(script: Script = Script()) {
        self.script = script
    }

    func send(request: Data, id: Int) async throws -> Data {
        guard let value = try? AgentToolingCoding.decoder().decode(JSONValue.self, from: request),
            case .object(let body) = value,
            case .string(let method) = body["method"]
        else {
            throw MCPLiveTestError.protocolViolation("The fixture received a malformed request.")
        }
        methods.append(method)
        if script.stallForever {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                sawCancellation = true
                throw MCPLiveTestError.cancelled
            }
        }
        if let raw = script.rawReplies[method] { return raw }
        var params: [String: JSONValue] = [:]
        if case .object(let declared) = body["params"] { params = declared }
        return try reply(id: id, result: result(for: method, params: params))
    }

    func send(notification: Data) async throws {
        guard let value = try? AgentToolingCoding.decoder().decode(JSONValue.self, from: notification),
            case .object(let body) = value,
            case .string(let method) = body["method"]
        else {
            throw MCPLiveTestError.protocolViolation("The fixture received a malformed notification.")
        }
        methods.append(method)
    }

    func diagnostics() async -> String { "" }

    func shutdown() async { shutdownCount += 1 }

    private func result(for method: String, params: [String: JSONValue]) -> JSONValue {
        switch method {
        case "initialize":
            return .object([
                "protocolVersion": .string(MCPTestConnectionPolicy.protocolVersion),
                "capabilities": .object(script.capabilities),
                "serverInfo": .object(["name": .string("fixture"), "version": .string("0.1.0")]),
                "instructions": .string("Fixture server."),
            ])
        case "tools/list": return .object(["tools": .array(script.tools)])
        case "resources/list": return .object(["resources": .array(script.resources)])
        case "prompts/list": return .object(["prompts": .array(script.prompts)])
        case "tools/call":
            if case .object(let arguments) = params["arguments"] { lastCallArguments = arguments }
            return .object(script.toolResult)
        default: return .object([:])
        }
    }

    private func reply(id: Int, result: JSONValue) throws -> Data {
        try AgentToolingCoding.encoder().encode(
            JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": result])
        )
    }
}

private func rawReply(_ text: String) -> Data {
    Data(text.utf8)
}

private func toolEntry(
    name: String,
    annotations: [String: JSONValue]? = nil,
    schema: JSONValue? = nil
) -> JSONValue {
    var body: [String: JSONValue] = ["name": .string(name), "description": .string("\(name) tool")]
    if let annotations { body["annotations"] = .object(annotations) }
    if let schema { body["inputSchema"] = schema }
    return .object(body)
}

// MARK: - Protocol handling

struct MCPLiveTestSessionTests {
    @Test func handshakeListsToolsResourcesAndPromptsFromOneLiveConnection() async throws {
        var script = FixtureMCPServer.Script()
        script.tools = [
            toolEntry(name: "search", annotations: ["readOnlyHint": .bool(true)]),
            toolEntry(name: "delete_all", annotations: ["destructiveHint": .bool(true)]),
            toolEntry(name: "write_note"),
        ]
        script.resources = [.object(["uri": .string("file:///a")]), .object(["uri": .string("file:///b")])]
        script.prompts = [.object(["name": .string("summarize")])]
        let server = FixtureMCPServer(script: script)
        let session = MCPLiveTestSession(channel: server)

        let observation = try await session.open()

        #expect(observation.protocolVersion == MCPTestConnectionPolicy.protocolVersion)
        #expect(observation.serverName == "fixture")
        #expect(observation.tools.count == 3)
        #expect(observation.resourceCount == 2)
        #expect(observation.promptCount == 1)
        #expect(observation.headline == "Responding · 3 tools")
        #expect(observation.handshakeMilliseconds >= 0)
        #expect(observation.inventoryMilliseconds >= 0)
        let methods = await server.methods
        #expect(methods.prefix(2) == ["initialize", "notifications/initialized"])
        #expect(methods.contains("tools/list"))
    }

    @Test func toolCallSendsTheGeneratedArgumentsAndReportsLatency() async throws {
        var script = FixtureMCPServer.Script()
        script.tools = [toolEntry(name: "echo", annotations: ["readOnlyHint": .bool(true)])]
        script.toolResult = [
            "content": .array([.object(["type": .string("text"), "text": .string("hello world")])]),
            "isError": .bool(false),
        ]
        let server = FixtureMCPServer(script: script)
        let session = MCPLiveTestSession(channel: server)
        _ = try await session.open()

        let outcome = try await session.callTool(named: "echo", arguments: ["message": .string("hello")])

        #expect(outcome.toolName == "echo")
        #expect(outcome.isError == false)
        #expect(outcome.text == "hello world")
        #expect(outcome.latencyMilliseconds >= 0)
        let arguments = await server.lastCallArguments
        #expect(arguments["message"] == .string("hello"))
    }

    @Test func aToolTheLiveInventoryNeverOfferedIsRefusedBeforeAnyRequestIsSent() async throws {
        var script = FixtureMCPServer.Script()
        script.tools = [toolEntry(name: "echo")]
        let server = FixtureMCPServer(script: script)
        let session = MCPLiveTestSession(channel: server)
        _ = try await session.open()
        let methodsBefore = await server.methods

        await #expect(throws: MCPLiveTestError.toolNotOffered("rm")) {
            try await session.callTool(named: "rm", arguments: [:])
        }
        #expect(await server.methods == methodsBefore)
    }

    @Test func anUndeclaredCapabilityIsReportedAsZeroRatherThanProbed() async throws {
        var script = FixtureMCPServer.Script()
        script.capabilities = ["tools": .object([:])]
        script.tools = [toolEntry(name: "search", annotations: ["readOnlyHint": .bool(true)])]
        let server = FixtureMCPServer(script: script)
        let session = MCPLiveTestSession(channel: server)

        let observation = try await session.open()

        #expect(observation.declaresResources == false)
        #expect(observation.declaresPrompts == false)
        #expect(observation.resourceCount == 0)
        #expect(observation.promptCount == 0)
        let methods = await server.methods
        #expect(!methods.contains("resources/list"))
        #expect(!methods.contains("prompts/list"))
    }

    // MARK: Timeout and cancel

    @Test func aStalledServerTimesOutAndTheChannelIsStopped() async throws {
        var script = FixtureMCPServer.Script()
        script.stallForever = true
        let server = FixtureMCPServer(script: script)
        let session = MCPLiveTestSession(channel: server)

        await #expect(throws: MCPLiveTestError.timedOut("The MCP handshake")) {
            try await session.open(handshakeTimeout: .milliseconds(60))
        }
        #expect(await server.shutdownCount >= 1)
    }

    @Test func cancellingTheOpeningTaskStopsTheConnection() async throws {
        var script = FixtureMCPServer.Script()
        script.stallForever = true
        let server = FixtureMCPServer(script: script)
        let session = MCPLiveTestSession(channel: server)

        let task = Task { try await session.open(handshakeTimeout: .seconds(30)) }
        while await server.methods.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()

        await #expect(throws: MCPLiveTestError.cancelled) { try await task.value }
        #expect(await server.sawCancellation)
        var attempts = 0
        while await server.shutdownCount == 0, attempts < 200 {
            try await Task.sleep(for: .milliseconds(5))
            attempts += 1
        }
        #expect(await server.shutdownCount >= 1)
    }

    @Test func closingASessionRefusesFurtherWork() async throws {
        let server = FixtureMCPServer()
        let session = MCPLiveTestSession(channel: server)
        await session.close()

        await #expect(throws: MCPLiveTestError.cancelled) { try await session.open() }
        #expect(await server.shutdownCount == 1)
    }

    // MARK: Malformed responses

    @Test func malformedRepliesAreRejectedAsTypedErrors() async throws {
        let cases: [(String, Data)] = [
            ("not json", rawReply("this is not json at all")),
            ("json array", rawReply("[1, 2, 3]")),
            ("missing jsonrpc", rawReply(#"{"id":1,"result":{}}"#)),
            ("wrong jsonrpc", rawReply(#"{"jsonrpc":"1.0","id":1,"result":{}}"#)),
            ("mismatched id", rawReply(#"{"jsonrpc":"2.0","id":99,"result":{}}"#)),
            ("result not an object", rawReply(#"{"jsonrpc":"2.0","id":1,"result":"nope"}"#)),
            ("empty payload", Data()),
        ]
        for (label, payload) in cases {
            var script = FixtureMCPServer.Script()
            script.rawReplies["initialize"] = payload
            let session = MCPLiveTestSession(channel: FixtureMCPServer(script: script))
            var thrown: (any Error)?
            do {
                _ = try await session.open()
            } catch {
                thrown = error
            }
            let live = thrown as? MCPLiveTestError
            #expect(live != nil, "\(label) should surface a typed error")
            if case .protocolViolation = live {
            } else {
                Issue.record("\(label) produced \(String(describing: live)) instead of a protocol violation")
            }
        }
    }

    @Test func aServerErrorObjectBecomesAServerErrorNotACrash() async throws {
        var script = FixtureMCPServer.Script()
        script.rawReplies["initialize"] = rawReply(
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"unsupported protocol"}}"#
        )
        let session = MCPLiveTestSession(channel: FixtureMCPServer(script: script))

        await #expect(throws: MCPLiveTestError.serverError(-32_000, "unsupported protocol")) {
            try await session.open()
        }
    }

    @Test func aHandshakeWithoutAProtocolVersionIsRejected() async throws {
        var script = FixtureMCPServer.Script()
        script.rawReplies["initialize"] = rawReply(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#)
        let server = FixtureMCPServer(script: script)
        let session = MCPLiveTestSession(channel: server)

        await #expect(throws: MCPLiveTestError.handshakeRejected("It did not return a protocol version.")) {
            try await session.open()
        }
        #expect(await server.shutdownCount >= 1)
    }

    @Test func anOversizedReplyIsRefusedBeforeItIsDecoded() async throws {
        let filler = String(repeating: "a", count: MCPTestConnectionPolicy.maximumMessageBytes + 64)
        var script = FixtureMCPServer.Script()
        script.rawReplies["initialize"] = rawReply(#"{"jsonrpc":"2.0","id":1,"result":{"note":"\#(filler)"}}"#)
        let session = MCPLiveTestSession(channel: FixtureMCPServer(script: script))

        await #expect(throws: MCPLiveTestError.responseTooLarge) { try await session.open() }
    }

    @Test func aToolsListWithoutAToolsArrayIsRejected() async throws {
        var script = FixtureMCPServer.Script()
        script.rawReplies["tools/list"] = rawReply(#"{"jsonrpc":"2.0","id":3,"result":{"items":[]}}"#)
        let session = MCPLiveTestSession(channel: FixtureMCPServer(script: script))

        var thrown: MCPLiveTestError?
        do {
            _ = try await session.open()
        } catch let error as MCPLiveTestError {
            thrown = error
        }
        if case .protocolViolation = thrown {
        } else {
            Issue.record("Expected a protocol violation, got \(String(describing: thrown))")
        }
    }

    @Test func toolEntriesWithoutAUsableNameAreDroppedInsteadOfFailingTheList() async throws {
        var script = FixtureMCPServer.Script()
        script.tools = [
            .object(["description": .string("no name")]),
            .string("not an object"),
            toolEntry(name: "keep"),
        ]
        let session = MCPLiveTestSession(channel: FixtureMCPServer(script: script))

        let observation = try await session.open()

        #expect(observation.tools.map(\.name) == ["keep"])
    }

    // MARK: Envelope helpers

    @Test func responseMatchingIgnoresServerInitiatedTraffic() {
        let response = rawReply(#"{"jsonrpc":"2.0","id":7,"result":{}}"#)
        let serverRequest = rawReply(#"{"jsonrpc":"2.0","id":7,"method":"roots/list"}"#)
        let logNotification = rawReply(#"{"jsonrpc":"2.0","method":"notifications/message","params":{}}"#)

        #expect(MCPJSONRPC.responseIdentifier(in: response) == 7)
        #expect(MCPJSONRPC.responseIdentifier(in: serverRequest) == nil)
        #expect(MCPJSONRPC.responseIdentifier(in: logNotification) == nil)
        #expect(MCPJSONRPC.responseIdentifier(in: rawReply("garbage")) == nil)
    }

    @Test func eventStreamBodiesYieldTheirJSONPayloads() {
        let body = Data(
            """
            event: message
            data: {"jsonrpc":"2.0","id":1,"result":{}}

            data: not-json-but-kept-as-bytes
            """.utf8
        )

        let payloads = MCPHTTPTestChannel.eventStreamPayloads(body)

        #expect(payloads.count == 2)
        #expect(MCPJSONRPC.responseIdentifier(in: payloads[0]) == 1)
        #expect(MCPJSONRPC.responseIdentifier(in: payloads[1]) == nil)
    }
}

// MARK: - Annotations

struct MCPToolAnnotationTests {
    @Test func anUnannotatedToolIsNeverTreatedAsReadOnly() {
        let bare = MCPLiveTool(name: "run")
        let emptyAnnotations = MCPLiveTool(name: "run", annotations: MCPLiveToolAnnotations())
        let titleOnly = MCPLiveTool(name: "run", annotations: MCPLiveToolAnnotations(title: "Run"))
        let idempotentOnly = MCPLiveTool(name: "run", annotations: MCPLiveToolAnnotations(idempotentHint: true))

        for tool in [bare, emptyAnnotations, titleOnly, idempotentOnly] {
            #expect(tool.safety == .undeclared)
            #expect(tool.safety != .readOnly)
            #expect(tool.requiresRunConfirmation)
        }
    }

    @Test func hintsMapToTheVerdictMCPItselfUses() {
        #expect(MCPLiveTool(name: "a", annotations: MCPLiveToolAnnotations(readOnlyHint: true)).safety == .readOnly)
        // Read-only wins: MCP only reads destructiveHint when a tool is not read-only.
        #expect(
            MCPLiveTool(name: "b", annotations: MCPLiveToolAnnotations(readOnlyHint: true, destructiveHint: true)).safety == .readOnly
        )
        // An explicit "not read-only" with no destructive hint keeps MCP's own default of destructive.
        #expect(MCPLiveTool(name: "c", annotations: MCPLiveToolAnnotations(readOnlyHint: false)).safety == .destructive)
        #expect(MCPLiveTool(name: "d", annotations: MCPLiveToolAnnotations(destructiveHint: false)).safety == .additive)
        #expect(MCPLiveTool(name: "e", annotations: MCPLiveToolAnnotations(destructiveHint: true)).safety == .destructive)
        #expect(MCPLiveTool(name: "f", annotations: MCPLiveToolAnnotations(readOnlyHint: true)).requiresRunConfirmation == false)
    }

    @Test func annotationsDecodedFromAnEmptyObjectStayUnknown() {
        #expect(MCPResponseReader.annotations(.object([:])) == nil)
        #expect(MCPResponseReader.annotations(.string("nope")) == nil)
        #expect(MCPResponseReader.annotations(.object(["readOnlyHint": .string("true")])) == nil)
        #expect(MCPResponseReader.annotations(.object(["readOnlyHint": .bool(true)]))?.readOnlyHint == true)
    }

    @Test func liveObservationCountsWhatAPersonNeedsToSeeBeforeRunningAnything() {
        let observation = MCPLiveObservation(
            protocolVersion: "2025-06-18",
            tools: [
                MCPLiveTool(name: "read", annotations: MCPLiveToolAnnotations(readOnlyHint: true)),
                MCPLiveTool(name: "wipe", annotations: MCPLiveToolAnnotations(destructiveHint: true)),
                MCPLiveTool(name: "mystery"),
            ],
            resourceCount: 0,
            promptCount: 0,
            declaresTools: true,
            declaresResources: false,
            declaresPrompts: false,
            handshakeMilliseconds: 12,
            inventoryMilliseconds: 8
        )

        #expect(observation.headline == "Responding · 3 tools")
        #expect(observation.destructiveToolCount == 1)
        #expect(observation.unannotatedToolCount == 1)
    }
}

// MARK: - Generated form

struct MCPToolInputFormTests {
    @Test func aSupportedSchemaBecomesNativeFields() throws {
        let schema = JSONValue.object([
            "type": .string("object"),
            "required": .array([.string("query")]),
            "properties": .object([
                "query": .object(["type": .string("string"), "description": .string("What to search for")]),
                "limit": .object(["type": .string("integer"), "default": .number(10)]),
                "recursive": .object(["type": .string("boolean")]),
                "mode": .object(["type": .string("string"), "enum": .array([.string("fast"), .string("deep")])]),
            ]),
        ])

        let form = MCPToolInputForm.make(from: schema)

        #expect(form.takesNoArguments == false)
        #expect(form.requiresRawObjectEditor == false)
        #expect(form.fields.map(\.name) == ["limit", "mode", "query", "recursive"])
        #expect(form.fields.first { $0.name == "query" }?.isRequired == true)
        #expect(form.fields.first { $0.name == "limit" }?.kind == .number(isInteger: true))
        #expect(form.fields.first { $0.name == "limit" }?.defaultText == "10")
        #expect(form.fields.first { $0.name == "recursive" }?.kind == .boolean)
        #expect(form.fields.first { $0.name == "mode" }?.kind == .choice(["fast", "deep"]))
    }

    @Test func anUnsupportedShapeAsksForJSONInsteadOfShowingAWrongControl() {
        let nested = JSONValue.object([
            "type": .string("object"),
            "properties": .object(["filter": .object(["type": .string("object")])]),
        ])

        let form = MCPToolInputForm.make(from: nested)

        #expect(form.fields.first?.kind == .rawJSON)
    }

    @Test func aToolWithNoArgumentsIsRecognized() {
        let empty = JSONValue.object(["type": .string("object"), "properties": .object([:])])

        #expect(MCPToolInputForm.make(from: empty).takesNoArguments)
        #expect(MCPToolInputForm.make(from: nil).takesNoArguments)
    }

    @Test func aPathologicalSchemaIsRefusedBeforeItReachesTheFormGenerator() {
        var deep = JSONValue.string("leaf")
        for _ in 0..<40 { deep = .object(["nested": deep]) }

        #expect(MCPResponseReader.boundedSchema(deep) == nil)
        #expect(MCPResponseReader.boundedSchema(.object(["type": .string("object")])) != nil)
    }
}

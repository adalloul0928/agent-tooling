import AgentToolingCore
import Foundation

/// The MCP server itself: `initialize`, `tools/list`, `tools/call`, and nothing
/// that is not one of those.
///
/// Protocol handling is written out here rather than pulled from a package
/// because this repository has no third-party dependencies and JSON-RPC over a
/// pipe is a small thing to own. For a target whose whole purpose is to be the
/// narrow, auditable path between an agent and a person's machine, a dependency
/// tree nobody reads would be the wrong trade.
final class ToolingMCPService {
    /// Revisions this server speaks, newest first. A client asking for one of
    /// these gets it back; anything else gets the newest and may disconnect.
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static var preferredProtocolVersion: String { supportedProtocolVersions[0] }

    private let store: WorkspaceStore
    private let clock: () -> Date
    private let identifierFactory: () -> UUID
    /// Self-reported by the caller, unverified, display only.
    private(set) var client: UntrustedClientIdentity = .unknown
    private(set) var isInitialized = false

    init(
        store: WorkspaceStore,
        clock: @escaping () -> Date = { .now },
        identifierFactory: @escaping () -> UUID = { UUID() }
    ) {
        self.store = store
        self.clock = clock
        self.identifierFactory = identifierFactory
    }

    /// Serves until end of input. Returns the process exit status.
    func run(transport: MessageTransport) -> Int32 {
        while true {
            do {
                guard let frame = try transport.readMessage() else { return 0 }
                do {
                    let request = try JSONRPCDecoding.decode(frame)
                    guard let response = respond(to: request) else { continue }
                    transport.write(response)
                } catch let failure {
                    // A notification that fails to decode still gets an answer
                    // when no identifier survived, because the alternative is a
                    // caller waiting forever on a request it thinks it sent.
                    if let data = try? JSONRPCEncoding.failure(id: failure.id, error: failure.error) {
                        transport.write(data)
                    }
                }
            } catch {
                let jsonrpcError = JSONRPCError(
                    code: .parse,
                    message: (error as? LocalizedError)?.errorDescription ?? "The message could not be read."
                )
                if let data = try? JSONRPCEncoding.failure(id: nil, error: jsonrpcError) {
                    transport.write(data)
                }
            }
        }
    }

    /// Answers one request. Returns `nil` for a notification, which JSON-RPC
    /// forbids answering.
    func respond(to request: JSONRPCRequest) -> Data? {
        let result: Result<JSONValue, JSONRPCError>
        switch request.method {
        case "initialize":
            result = .success(initialize(request.params))
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            result = .success(.object([:]))
        case "tools/list":
            result = requireInitialized().map { _ in listTools() }
        case "tools/call":
            result = requireInitialized().flatMap { _ in callTool(request.params) }
        default:
            result = .failure(JSONRPCError(code: .methodNotFound, message: "This server does not implement '\(request.method)'."))
        }

        guard let id = request.id else { return nil }
        switch result {
        case .success(let value): return try? JSONRPCEncoding.response(id: id, result: ResponseRedaction.redacted(value))
        case .failure(let error): return try? JSONRPCEncoding.failure(id: id, error: error)
        }
    }

    // MARK: - Handshake

    private func initialize(_ params: JSONValue?) -> JSONValue {
        client = UntrustedClientIdentity.fromInitializeParams(params)
        isInitialized = true

        var negotiated = Self.preferredProtocolVersion
        if case .object(let fields)? = params,
            case .string(let requested)? = fields["protocolVersion"],
            Self.supportedProtocolVersions.contains(requested)
        {
            negotiated = requested
        }

        return .object([
            "protocolVersion": .string(negotiated),
            // `tools` is the only capability declared. In particular there is
            // no `elicitation`: a dialog rendered in the caller's own client
            // from text this server supplies can collect a missing parameter,
            // but it can never be the surface where a person approves a change
            // — only the app's review sheet shows the real redacted command
            // next to the file it would change. Not declaring it removes the
            // temptation entirely.
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object([
                "name": .string(ToolCatalog.serverName),
                "title": .string("Agent Tooling"),
                "version": .string(ToolCatalog.serverVersion),
            ]),
            "instructions": .string(
                """
                Agent Tooling manages Agent Skills, MCP servers and plugins across Claude Code, Codex and Gemini CLI on this Mac.

                Read tools tell you what is installed and what has happened. Request tools queue one change for the person at this \
                machine to review in the Agent Tooling app; they change nothing themselves and return a link to open.

                There is no tool that applies, approves or denies a change, and there will not be one: approval happens in the app, \
                where a person sees the real command next to the file it would change. If you need something applied, queue the \
                request and tell the person to open the link.
                """
            ),
        ])
    }

    private func requireInitialized() -> Result<Void, JSONRPCError> {
        guard isInitialized else {
            return .failure(JSONRPCError(code: .invalidRequest, message: "Send 'initialize' before any other request."))
        }
        return .success(())
    }

    // MARK: - Tools

    private func listTools() -> JSONValue {
        .object(["tools": .array(ToolCatalog.tools.map(\.descriptor))])
    }

    private func callTool(_ params: JSONValue?) -> Result<JSONValue, JSONRPCError> {
        guard case .object(let fields)? = params, case .string(let name)? = fields["name"] else {
            return .failure(JSONRPCError(code: .invalidParams, message: "'tools/call' requires a 'name'."))
        }
        guard let tool = ToolCatalog.tool(named: name) else {
            return .failure(
                JSONRPCError(
                    code: .invalidParams,
                    message: "'\(name)' is not a tool on this server. Call 'tools/list' for what is available."
                ))
        }

        do {
            let context = ToolCallContext(
                arguments: try ToolArguments(tool: tool, params: params),
                client: client,
                store: store,
                now: clock(),
                identifierFactory: identifierFactory
            )
            let outcome =
                switch tool.tier {
                case .readOnly: try ReadOnlyTools.handle(tool.name, context: context)
                case .queuesReview: try RequestTools.handle(tool.name, context: context)
                }
            record(tool: tool, outcome: outcome.isError ? .attention : .healthy, detail: outcome.summary)
            return .success(result(for: outcome))
        } catch let error as ToolInputError {
            // An invalid argument is a protocol-level mistake, so it travels as
            // a JSON-RPC error rather than as tool output the model might read
            // as data it can work around.
            record(tool: tool, outcome: .attention, detail: error.errorDescription ?? "Invalid arguments.")
            return .failure(JSONRPCError(code: .invalidParams, message: error.errorDescription ?? "Invalid arguments."))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "The request could not be completed."
            record(tool: tool, outcome: .attention, detail: message)
            return .success(
                result(
                    for: ToolOutcome(
                        payload: .object(["error": .string(message)]),
                        summary: message,
                        isError: true
                    )))
        }
    }

    private func result(for outcome: ToolOutcome) -> JSONValue {
        let payload = ResponseRedaction.redacted(outcome.payload)
        let summary = ResponseRedaction.redactedText(outcome.summary)
        let encoded = (try? AgentToolingCoding.encoder(prettyPrinted: true).encode(payload)).map { String(decoding: $0, as: UTF8.self) }
        var content: [JSONValue] = [.object(["type": .string("text"), "text": .string(summary)])]
        if let encoded {
            content.append(.object(["type": .string("text"), "text": .string(encoded)]))
        }
        return .object([
            "content": .array(content),
            "structuredContent": payload,
            "isError": .bool(outcome.isError),
        ])
    }

    /// Every call, including every read, is journaled. See
    /// `AgentActivityJournal` for why reads count.
    private func record(tool: ToolDefinition, outcome: HealthState, detail: String) {
        AgentActivityJournalService.record(
            tool: tool.name,
            tier: tool.tier,
            outcome: outcome,
            detail: detail,
            client: client,
            store: store,
            now: clock()
        )
    }
}

import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingMCP

/// Drives a `ToolingMCPService` over an in-memory transport against a scratch
/// workspace, so a test exercises the same code path a real client would.
///
/// The scratch workspace is passed to the service constructor, never through a
/// tool argument or a process flag: that distinction is the whole point of
/// excluding `--home` and `--workspace` from the tool surface.
final class MCPTestHarness {
    let store: WorkspaceStore
    let service: ToolingMCPService
    private let rootURL: URL
    private var nextID = 0
    private var issuedIdentifiers: [UUID] = []

    init(snapshot: WorkspaceSnapshot? = nil, now: Date = Date(timeIntervalSince1970: 1_756_000_000)) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "AgentToolingMCPTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = try WorkspaceStore(rootURL: rootURL)
        if let snapshot { try store.saveWorkspaceSnapshot(snapshot) }
        service = ToolingMCPService(store: store, clock: { now })
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    @discardableResult
    func initialize(clientName: String = "Claude Code", clientVersion: String = "2.0.1") throws -> [String: JSONValue] {
        try send(
            method: "initialize",
            params: .object([
                "protocolVersion": .string(ToolingMCPService.preferredProtocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string(clientName), "version": .string(clientVersion)]),
            ])
        )
    }

    /// Returns the `result` object of a successful response.
    @discardableResult
    func send(method: String, params: JSONValue? = nil) throws -> [String: JSONValue] {
        let response = try require(rawSend(method: method, params: params))
        if case .object(let fields)? = response["error"] {
            Issue.record("\(method) failed: \(fields["message"] ?? .null)")
            return [:]
        }
        guard case .object(let result)? = response["result"] else { return [:] }
        return result
    }

    /// Returns the whole response envelope, including a JSON-RPC error.
    func rawSend(method: String, params: JSONValue? = nil) -> [String: JSONValue]? {
        nextID += 1
        var message: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(nextID)),
            "method": .string(method),
        ]
        if let params { message["params"] = params }
        guard let frame = try? AgentToolingCoding.encoder().encode(JSONValue.object(message)),
            let request = try? JSONRPCDecoding.decode(frame),
            let responseData = service.respond(to: request),
            case .object(let fields)? = try? AgentToolingCoding.decoder().decode(JSONValue.self, from: responseData)
        else { return nil }
        return fields
    }

    /// Calls a tool and returns its `structuredContent`.
    func callTool(_ name: String, arguments: [String: JSONValue] = [:]) throws -> [String: JSONValue] {
        let result = try send(method: "tools/call", params: .object(["name": .string(name), "arguments": .object(arguments)]))
        guard case .object(let structured)? = result["structuredContent"] else { return [:] }
        return structured
    }

    /// Calls a tool and returns the raw `tools/call` envelope, for tests that
    /// need `isError` or a JSON-RPC failure.
    func rawCallTool(_ name: String, arguments: [String: JSONValue] = [:]) -> [String: JSONValue]? {
        rawSend(method: "tools/call", params: .object(["name": .string(name), "arguments": .object(arguments)]))
    }

    func pendingRequests() throws -> [PendingAgentRequest] {
        try store.loadPendingAgentRequestQueue().requests
    }

    private func require(_ value: [String: JSONValue]?) throws -> [String: JSONValue] {
        guard let value else {
            Issue.record("The service produced no response.")
            return [:]
        }
        return value
    }
}

extension JSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    /// Every string that appears anywhere in the value, at any depth. Used to
    /// assert that nothing sensitive survives anywhere in a response.
    var allStrings: [String] {
        switch self {
        case .string(let value): [value]
        case .array(let values): values.flatMap(\.allStrings)
        case .object(let fields): fields.values.flatMap(\.allStrings)
        case .number, .bool, .null: []
        }
    }
}

import AgentToolingCore
import Foundation

/// JSON-RPC 2.0 identifier. The specification allows a string, a number, or
/// null; MCP forbids null, so a null identifier is treated as an invalid
/// request rather than silently answered.
enum JSONRPCID: Hashable, Sendable {
    case string(String)
    case number(Double)

    init?(_ value: JSONValue?) {
        switch value {
        case .string(let text): self = .string(text)
        case .number(let number): self = .number(number)
        default: return nil
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .string(let text): .string(text)
        case .number(let number): .number(number)
        }
    }
}

enum JSONRPCErrorCode: Int, Sendable {
    case parse = -32_700
    case invalidRequest = -32_600
    case methodNotFound = -32_601
    case invalidParams = -32_602
    case internalError = -32_603
}

struct JSONRPCError: Error, Sendable {
    var code: JSONRPCErrorCode
    var message: String

    var jsonValue: JSONValue {
        .object(["code": .number(Double(code.rawValue)), "message": .string(message)])
    }
}

/// One decoded incoming message. A message without an identifier is a
/// notification and must never be answered.
struct JSONRPCRequest: Sendable {
    var id: JSONRPCID?
    var method: String
    var params: JSONValue?

    var isNotification: Bool { id == nil }
}

/// A message that could not be turned into a request, carrying whatever
/// identifier could still be recovered so the caller is not left waiting.
struct JSONRPCDecodeFailure: Error, Sendable {
    var id: JSONRPCID?
    var error: JSONRPCError
}

enum JSONRPCDecoding {
    /// The largest single message this server will parse. MCP frames one JSON
    /// object per line, and every input this server accepts is small, so a
    /// generous cap still refuses a memory-exhaustion frame.
    static let maximumMessageBytes = 1_048_576

    static func decode(_ data: Data) throws(JSONRPCDecodeFailure) -> JSONRPCRequest {
        guard data.count <= maximumMessageBytes else {
            throw failure(nil, .parse, "The message exceeds the \(maximumMessageBytes)-byte limit.")
        }
        guard let value = try? AgentToolingCoding.decoder().decode(JSONValue.self, from: data) else {
            throw failure(nil, .parse, "The message is not valid JSON.")
        }
        guard case .object(let fields) = value else {
            throw failure(nil, .invalidRequest, "A JSON-RPC message must be a JSON object.")
        }
        let id = JSONRPCID(fields["id"])
        if let rawID = fields["id"], id == nil {
            throw failure(nil, .invalidRequest, "The request identifier must be a string or a number, not \(describe(rawID)).")
        }
        guard case .string("2.0")? = fields["jsonrpc"] else {
            throw failure(id, .invalidRequest, "Only JSON-RPC 2.0 messages are supported.")
        }
        guard case .string(let method)? = fields["method"], !method.isEmpty, method.utf8.count <= 256 else {
            throw failure(id, .invalidRequest, "The message is missing a usable 'method'.")
        }
        let params = fields["params"]
        if let params {
            guard case .object = params else {
                throw failure(id, .invalidParams, "The 'params' member must be a JSON object.")
            }
        }
        return JSONRPCRequest(id: id, method: method, params: params)
    }

    private static func failure(_ id: JSONRPCID?, _ code: JSONRPCErrorCode, _ message: String) -> JSONRPCDecodeFailure {
        JSONRPCDecodeFailure(id: id, error: JSONRPCError(code: code, message: message))
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .object: "an object"
        case .array: "an array"
        case .string: "a string"
        case .number: "a number"
        case .bool: "a boolean"
        case .null: "null"
        }
    }
}

enum JSONRPCEncoding {
    static func response(id: JSONRPCID, result: JSONValue) throws -> Data {
        try encode(.object(["jsonrpc": .string("2.0"), "id": id.jsonValue, "result": result]))
    }

    static func failure(id: JSONRPCID?, error: JSONRPCError) throws -> Data {
        try encode(
            .object([
                "jsonrpc": .string("2.0"),
                "id": id?.jsonValue ?? .null,
                "error": error.jsonValue,
            ]))
    }

    /// Serializes one line-delimited frame. A newline inside the payload would
    /// split the frame, so encoded control characters are the only newlines the
    /// transport can see.
    private static func encode(_ value: JSONValue) throws -> Data {
        var data = try AgentToolingCoding.encoder().encode(value)
        data.append(0x0A)
        return data
    }
}

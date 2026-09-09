import AgentToolingCore
import Foundation

/// What a tool produces: a one-line summary for the model to read, and a
/// structured payload. `isError` marks a domain failure the caller can act on
/// (nothing found, queue full); protocol failures travel as JSON-RPC errors.
struct ToolOutcome {
    var payload: JSONValue
    var summary: String
    var isError = false
}

/// Everything a tool handler is allowed to reach.
///
/// The absence of things here is the point: there is no command runner, no file
/// manager, no operation engine, and no way to name a different workspace. A
/// handler can read the one real workspace and append to the review queue. That
/// is the entire surface.
struct ToolCallContext {
    var arguments: ToolArguments
    /// Self-reported and unverified. Display only — never a permission input.
    var client: UntrustedClientIdentity
    /// The one workspace this server can reach. There is no second store to
    /// fall back to and no argument that names a different one.
    var store: WorkspaceRevisionStore
    /// This Mac's home, for reading a client's own configuration files. Reads
    /// only; this server never writes a native file.
    var homeRoot: URL
    var now: Date
    var identifierFactory: () -> UUID

    /// One workspace, read fresh.
    ///
    /// Items, this Mac's client observations and its operation receipts all come
    /// from the same store. A failure to read travels as an error — never as an
    /// empty result, which would read to a caller as "there is nothing".
    func snapshot() throws -> WorkspaceSnapshot {
        try VersionedInventorySource(store: store).workspaceSnapshot()
    }
}

enum JSONValueCoding {
    static func value(from encodable: some Encodable) throws -> JSONValue {
        let data = try AgentToolingCoding.encoder().encode(encodable)
        return try AgentToolingCoding.decoder().decode(JSONValue.self, from: data)
    }
}

func iso8601(_ date: Date) -> String {
    date.formatted(.iso8601)
}

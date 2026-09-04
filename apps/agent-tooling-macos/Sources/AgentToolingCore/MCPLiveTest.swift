import Foundation

// MARK: - Tool annotations

/// The optional behavior hints an MCP server may declare for a tool.
///
/// Every field is optional on purpose. MCP treats a missing hint as unknown,
/// and unknown is never the same as safe, so nothing here is defaulted to a
/// reassuring value while decoding.
public struct MCPLiveToolAnnotations: Codable, Hashable, Sendable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    public var isEmpty: Bool {
        title == nil && readOnlyHint == nil && destructiveHint == nil && idempotentHint == nil && openWorldHint == nil
    }
}

/// How a tool must be treated before it is run.
///
/// `undeclared` exists so the interface can say "the server did not say" rather
/// than borrowing the appearance of `readOnly`. For consent purposes it is
/// handled exactly like `destructive`.
public enum MCPToolSafety: String, Codable, Hashable, Sendable {
    case readOnly
    case additive
    case destructive
    case undeclared

    /// Server annotations are display metadata, never local authorization.
    /// Every live invocation requires a fresh confirmation in Agent Tooling.
    public var requiresRunConfirmation: Bool { true }

    public var label: String {
        switch self {
        case .readOnly: "Server says read-only"
        case .additive: "Changes data"
        case .destructive: "Destructive"
        case .undeclared: "Not annotated"
        }
    }

    public var detail: String {
        switch self {
        case .readOnly:
            "The server claims this tool does not change its environment. Agent Tooling cannot verify that claim and still asks before every run."
        case .additive: "The server declares that this tool changes data but does not delete or overwrite it."
        case .destructive: "The server declares that this tool may delete or overwrite data."
        case .undeclared:
            "The server declared no behavior hints. MCP treats an unannotated tool as one that may change or delete data."
        }
    }

    public var symbolName: String {
        switch self {
        case .readOnly: "eye"
        case .additive: "square.and.pencil"
        case .destructive: "exclamationmark.octagon"
        case .undeclared: "questionmark.circle"
        }
    }
}

// MARK: - Tool descriptor

public struct MCPLiveTool: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var title: String?
    public var summary: String?
    public var inputSchema: JSONValue?
    public var annotations: MCPLiveToolAnnotations?

    public init(
        name: String,
        title: String? = nil,
        summary: String? = nil,
        inputSchema: JSONValue? = nil,
        annotations: MCPLiveToolAnnotations? = nil
    ) {
        self.name = name
        self.title = title
        self.summary = summary
        self.inputSchema = inputSchema
        self.annotations = annotations
    }

    public var displayName: String {
        if let title, !title.isEmpty { return title }
        if let annotationTitle = annotations?.title, !annotationTitle.isEmpty { return annotationTitle }
        return name
    }

    /// The single place that turns hints into a verdict.
    ///
    /// Classification is presentation only. A tool counts as declared
    /// read-only when the server says so, but that untrusted hint never waives
    /// the app's confirmation requirement.
    public var safety: MCPToolSafety {
        guard let annotations, !annotations.isEmpty else { return .undeclared }
        if annotations.readOnlyHint == true { return .readOnly }
        guard let destructiveHint = annotations.destructiveHint else {
            return annotations.readOnlyHint == false ? .destructive : .undeclared
        }
        return destructiveHint ? .destructive : .additive
    }

    /// True only when the server explicitly declared idempotency.
    public var declaresIdempotent: Bool { annotations?.idempotentHint == true }

    /// True only when the server explicitly declared an open-world tool.
    public var declaresOpenWorld: Bool { annotations?.openWorldHint == true }

    public var requiresRunConfirmation: Bool { safety.requiresRunConfirmation }
}

// MARK: - Generated input form

public struct MCPToolInputField: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case text(multiline: Bool)
        case number(isInteger: Bool)
        case boolean
        case choice([String])
        /// A shape the generated form cannot represent safely, so the person
        /// types JSON for this argument instead of being shown a wrong control.
        case rawJSON
    }

    public var id: String { name }
    public var name: String
    public var title: String?
    public var summary: String?
    public var kind: Kind
    public var isRequired: Bool
    public var defaultText: String?

    public init(
        name: String,
        title: String? = nil,
        summary: String? = nil,
        kind: Kind,
        isRequired: Bool,
        defaultText: String? = nil
    ) {
        self.name = name
        self.title = title
        self.summary = summary
        self.kind = kind
        self.isRequired = isRequired
        self.defaultText = defaultText
    }

    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return name
    }
}

public struct MCPToolInputForm: Hashable, Sendable {
    public static let maximumFieldCount = 40

    public var fields: [MCPToolInputField]
    /// True when the tool takes no arguments at all.
    public var takesNoArguments: Bool
    /// True when the schema had shapes the generated form could not express and
    /// the person is offered a JSON editor for the whole argument object.
    public var requiresRawObjectEditor: Bool
    public var schemaText: String?

    public init(
        fields: [MCPToolInputField],
        takesNoArguments: Bool,
        requiresRawObjectEditor: Bool,
        schemaText: String? = nil
    ) {
        self.fields = fields
        self.takesNoArguments = takesNoArguments
        self.requiresRawObjectEditor = requiresRawObjectEditor
        self.schemaText = schemaText
    }

    /// Builds a form from the JSON Schema subset that maps cleanly onto native
    /// controls. Anything else falls back to a JSON editor rather than guessing.
    public static func make(from schema: JSONValue?) -> MCPToolInputForm {
        let schemaText = schema.flatMap(Self.prettyPrinted)
        guard case .object(let root) = schema else {
            return MCPToolInputForm(
                fields: [],
                takesNoArguments: schema == nil,
                requiresRawObjectEditor: schema != nil,
                schemaText: schemaText
            )
        }
        if case .string(let type) = root["type"], type != "object" {
            return MCPToolInputForm(fields: [], takesNoArguments: false, requiresRawObjectEditor: true, schemaText: schemaText)
        }
        guard case .object(let properties) = root["properties"] else {
            let declaresObject = root["type"] != nil
            return MCPToolInputForm(
                fields: [],
                takesNoArguments: declaresObject,
                requiresRawObjectEditor: !declaresObject,
                schemaText: schemaText
            )
        }
        if properties.isEmpty {
            return MCPToolInputForm(fields: [], takesNoArguments: true, requiresRawObjectEditor: false, schemaText: schemaText)
        }
        var required: Set<String> = []
        if case .array(let values) = root["required"] {
            for value in values {
                if case .string(let name) = value { required.insert(name) }
            }
        }
        let names = properties.keys.sorted().prefix(maximumFieldCount)
        var fields: [MCPToolInputField] = []
        for name in names {
            guard let definition = properties[name] else { continue }
            fields.append(field(name: name, definition: definition, isRequired: required.contains(name)))
        }
        return MCPToolInputForm(
            fields: fields,
            takesNoArguments: false,
            requiresRawObjectEditor: properties.count > maximumFieldCount,
            schemaText: schemaText
        )
    }

    private static func field(name: String, definition: JSONValue, isRequired: Bool) -> MCPToolInputField {
        guard case .object(let body) = definition else {
            return MCPToolInputField(name: name, kind: .rawJSON, isRequired: isRequired)
        }
        let title = boundedString(body["title"], limit: 120)
        let summary = boundedString(body["description"], limit: 400)
        let defaultText = body["default"].flatMap(Self.plainText)
        if case .array(let cases) = body["enum"] {
            let options = cases.compactMap { value -> String? in
                if case .string(let text) = value { return text }
                return nil
            }
            if !options.isEmpty, options.count == cases.count, options.count <= 64 {
                return MCPToolInputField(
                    name: name,
                    title: title,
                    summary: summary,
                    kind: .choice(options),
                    isRequired: isRequired,
                    defaultText: defaultText
                )
            }
        }
        guard case .string(let type) = body["type"] else {
            return MCPToolInputField(
                name: name,
                title: title,
                summary: summary,
                kind: .rawJSON,
                isRequired: isRequired,
                defaultText: defaultText
            )
        }
        let kind: MCPToolInputField.Kind
        switch type {
        case "string":
            if case .string(let format) = body["format"], format == "textarea" {
                kind = .text(multiline: true)
            } else {
                kind = .text(multiline: (summary?.count ?? 0) > 160)
            }
        case "number": kind = .number(isInteger: false)
        case "integer": kind = .number(isInteger: true)
        case "boolean": kind = .boolean
        default: kind = .rawJSON
        }
        return MCPToolInputField(
            name: name,
            title: title,
            summary: summary,
            kind: kind,
            isRequired: isRequired,
            defaultText: defaultText
        )
    }

    private static func boundedString(_ value: JSONValue?, limit: Int) -> String? {
        guard case .string(let text) = value, !text.isEmpty else { return nil }
        return String(text.prefix(limit))
    }

    private static func plainText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): text
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number): number == number.rounded() ? String(Int(number)) : String(number)
        case .null, .array, .object: nil
        }
    }

    private static func prettyPrinted(_ value: JSONValue) -> String? {
        let encoder = AgentToolingCoding.encoder(prettyPrinted: true)
        guard let data = try? encoder.encode(value), data.count <= 64 * 1_024 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Live observation

/// What one live connection actually saw.
///
/// This is deliberately a timestamped value rather than a health verdict.
/// Nothing here is written back into a server's recorded state.
public struct MCPLiveObservation: Hashable, Sendable {
    public var serverName: String?
    public var serverVersion: String?
    public var protocolVersion: String
    public var instructions: String?
    public var tools: [MCPLiveTool]
    public var resourceCount: Int
    public var promptCount: Int
    public var declaresTools: Bool
    public var declaresResources: Bool
    public var declaresPrompts: Bool
    public var handshakeMilliseconds: Double
    public var inventoryMilliseconds: Double
    public var observedAt: Date

    public init(
        serverName: String? = nil,
        serverVersion: String? = nil,
        protocolVersion: String,
        instructions: String? = nil,
        tools: [MCPLiveTool],
        resourceCount: Int,
        promptCount: Int,
        declaresTools: Bool,
        declaresResources: Bool,
        declaresPrompts: Bool,
        handshakeMilliseconds: Double,
        inventoryMilliseconds: Double,
        observedAt: Date = .now
    ) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion
        self.instructions = instructions
        self.tools = tools
        self.resourceCount = resourceCount
        self.promptCount = promptCount
        self.declaresTools = declaresTools
        self.declaresResources = declaresResources
        self.declaresPrompts = declaresPrompts
        self.handshakeMilliseconds = handshakeMilliseconds
        self.inventoryMilliseconds = inventoryMilliseconds
        self.observedAt = observedAt
    }

    /// The one stronger sentence a live connection earns.
    public var headline: String {
        "Responding · \(tools.count) tool\(tools.count == 1 ? "" : "s")"
    }

    public var unannotatedToolCount: Int { tools.filter { $0.safety == .undeclared }.count }

    public var destructiveToolCount: Int { tools.filter { $0.safety == .destructive }.count }
}

// MARK: - Tool call outcome

public struct MCPToolCallOutcome: Hashable, Sendable {
    public var toolName: String
    public var isError: Bool
    public var text: String
    public var structuredText: String?
    public var latencyMilliseconds: Double
    public var completedAt: Date

    public init(
        toolName: String,
        isError: Bool,
        text: String,
        structuredText: String? = nil,
        latencyMilliseconds: Double,
        completedAt: Date = .now
    ) {
        self.toolName = toolName
        self.isError = isError
        self.text = text
        self.structuredText = structuredText
        self.latencyMilliseconds = latencyMilliseconds
        self.completedAt = completedAt
    }
}

// MARK: - Errors

public enum MCPLiveTestError: LocalizedError, Equatable, Sendable {
    case definitionNotConnectable(String)
    case executableNotFound(String)
    case executableNotPermitted(String)
    case insecureEndpoint(String)
    case handshakeRejected(String)
    case protocolViolation(String)
    case responseTooLarge
    case timedOut(String)
    case cancelled
    case serverError(Int, String)
    case httpStatus(Int)
    case authenticationRequired
    case serverStopped(String)
    case toolNotOffered(String)

    public var errorDescription: String? {
        switch self {
        case .definitionNotConnectable(let detail): detail
        case .executableNotFound(let name):
            "\(name) is not an executable file on this Mac, so there is nothing to start. The test console never falls back to a shell."
        case .executableNotPermitted(let name):
            "\(name) is a shell or privilege wrapper. A test connection must show the exact program it runs, so command wrappers are refused."
        case .insecureEndpoint(let detail): detail
        case .handshakeRejected(let detail): "The server answered, but the MCP handshake failed. \(detail)"
        case .protocolViolation(let detail): "The server sent a response Agent Tooling could not read as MCP. \(detail)"
        case .responseTooLarge: "The server sent a message larger than the test console's limit and the connection was stopped."
        case .timedOut(let stage): "\(stage) did not finish within the test connection's time limit, so the connection was stopped."
        case .cancelled: "The test connection was stopped."
        case .serverError(let code, let message): "The server returned error \(code). \(message)"
        case .httpStatus(let code): "The server answered with HTTP \(code)."
        case .authenticationRequired:
            "The server requires credentials. The test console never sends your tokens, so sign in through the owning client instead."
        case .serverStopped(let detail): "The server process stopped before answering. \(detail)"
        case .toolNotOffered(let name): "\(name) was not in the tool list this connection observed."
        }
    }
}

// MARK: - Duration helper

extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}

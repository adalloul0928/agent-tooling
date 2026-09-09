import AgentToolingCore
import Foundation

/// The two things a tool in this server is allowed to be.
///
/// There is no third tier. Anything that would need one — apply, approve, deny,
/// execute — is excluded by construction; see `ExcludedCapabilities`.
enum ToolTier: String, CaseIterable, Sendable {
    /// Reads persisted state. Writes nothing, spawns nothing.
    case readOnly = "read-only"
    /// Appends one bounded row to the review queue and returns a deep link.
    /// Changes no client configuration and builds no operation plan.
    case queuesReview = "queues-review"
}

struct ToolDefinition: Sendable {
    var name: String
    var tier: ToolTier
    var title: String
    var description: String
    var inputSchema: JSONValue

    var descriptor: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(tier == .readOnly),
                // Nothing in this server destroys or overwrites anything. A
                // tier 2 tool only adds a row a person can ignore.
                "destructiveHint": .bool(false),
                // A repeat collapses into the existing row, so calling twice
                // leaves the same single row behind.
                "idempotentHint": .bool(true),
                "openWorldHint": .bool(false),
            ]),
        ])
    }
}

/// Small helpers for writing JSON Schema without a dependency.
enum ToolSchema {
    static func object(properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var fields: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { fields["required"] = .array(required.sorted().map(JSONValue.string)) }
        return .object(fields)
    }

    static func string(_ description: String, maximumLength: Int) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "maxLength": .number(Double(maximumLength)),
        ])
    }

    static func enumeration(_ description: String, values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(values.map(JSONValue.string)),
        ])
    }

    static func integer(_ description: String, minimum: Int, maximum: Int) -> JSONValue {
        .object([
            "type": .string("integer"),
            "description": .string(description),
            "minimum": .number(Double(minimum)),
            "maximum": .number(Double(maximum)),
        ])
    }

    static func uuid(_ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "format": .string("uuid"),
            "maxLength": .number(36),
        ])
    }

    static var targets: JSONValue {
        .object([
            "type": .string("array"),
            "description": .string("Which coding agents the request covers."),
            "items": .object(["type": .string("string"), "enum": .array(["codex", "claude-code", "gemini"].map(JSONValue.string))]),
            "minItems": .number(1),
            "maxItems": .number(3),
            "uniqueItems": .bool(true),
        ])
    }

    static var scope: JSONValue {
        enumeration("Install for this Mac, or only inside one project.", values: ["user", "project"])
    }

    static var projectRoot: JSONValue {
        string(
            "Absolute directory of the project, required when scope is 'project'. It is recorded for the reviewer to confirm; "
                + "nothing is read or written there by this server.",
            maximumLength: 1_024
        )
    }

    static var componentKind: JSONValue {
        enumeration("Which kind of component.", values: ["skill", "mcp-server", "plugin"])
    }

    static var reason: JSONValue {
        string("One sentence a reviewer will read explaining why this is being asked for.", maximumLength: 500)
    }
}

enum ToolCatalog {
    static let serverName = "agent-tooling"
    static let serverVersion = "1.0.0"

    /// Progressive disclosure: eight small read tools and five request tools,
    /// each doing one nameable thing, rather than a handful of tools with a
    /// mode parameter. A caller that only wants to look never touches a tool
    /// that can write a row.
    static let tools: [ToolDefinition] = readOnlyTools + reviewQueueTools

    static let readOnlyTools: [ToolDefinition] = [
        ToolDefinition(
            name: "search_inventory",
            tier: .readOnly,
            title: "Search the inventory",
            description: """
                Search the skills, MCP servers and plugins Agent Tooling knows about, across Claude Code, Codex and Gemini CLI. \
                Returns names, summaries, scopes and per-client status. Configuration file paths and secret values are never \
                included.
                """,
            inputSchema: ToolSchema.object(properties: [
                "query": ToolSchema.string(
                    "Free text matched against identifiers, names, summaries and scopes. Omit to list everything.",
                    maximumLength: IntegrationResponseLimits.searchQueryMaximumCharacters
                ),
                "kind": ToolSchema.componentKind,
                "limit": ToolSchema.integer(
                    "Maximum results to return.",
                    minimum: 1,
                    maximum: IntegrationResponseLimits.searchMaximumLimit
                ),
            ])
        ),
        ToolDefinition(
            name: "get_component",
            tier: .readOnly,
            title: "Get one component",
            description: """
                Read the details Agent Tooling holds for one skill, MCP server or plugin: its summary, scope, per-client state and \
                the names of any secrets it references. Secret values, endpoints, commands and file paths are never returned.
                """,
            inputSchema: ToolSchema.object(
                properties: [
                    "kind": ToolSchema.componentKind,
                    "id": ToolSchema.string(
                        "Component identifier from search_inventory.",
                        maximumLength: IntegrationResponseLimits.identifierMaximumCharacters
                    ),
                ],
                required: ["kind", "id"]
            )
        ),
        ToolDefinition(
            name: "get_client_status",
            tier: .readOnly,
            title: "Get client status",
            description: """
                Report what Agent Tooling last observed about each installed coding agent: whether it is present, its version, and \
                how many skills, plugins and MCP servers it has. Reflects the last setup check run in the app; this tool starts no \
                scan and runs no command. Configuration paths are omitted.
                """,
            inputSchema: ToolSchema.object(properties: [:])
        ),
        ToolDefinition(
            name: "get_effective_settings",
            tier: .readOnly,
            title: "Get effective app settings",
            description: """
                Report what an installed coding agent will actually use on this Mac: each setting's value, which file defines it, \
                which files it overrides, whether the values combine, whether a new session is required, and whether a higher \
                layer fixes it so a change lower down would not take effect. Reads the agent's own configuration files and writes \
                nothing. Settings this build does not interpret are listed separately and never presented as effective.
                """,
            inputSchema: ToolSchema.object(
                properties: [
                    "client": ToolSchema.string("Which agent to report: 'claude-code' or 'codex'.",
                                                maximumLength: 32),
                    "project_path": ToolSchema.string("Optional absolute path to a project whose files also apply.",
                                                      maximumLength: 4_096),
                ],
                required: ["client"]
            )
        ),
        ToolDefinition(
            name: "list_receipts",
            tier: .readOnly,
            title: "List operation receipts",
            description: """
                List the receipts for changes a person already reviewed and applied, newest first. A receipt is evidence of what \
                happened; it cannot be replayed through this server.
                """,
            inputSchema: ToolSchema.object(properties: [
                "limit": ToolSchema.integer("Maximum receipts to return.", minimum: 1, maximum: 50)
            ])
        ),
        ToolDefinition(
            name: "get_receipt",
            tier: .readOnly,
            title: "Get one receipt",
            description: """
                Read one operation receipt, including per-step outcomes and its verification summary. Step output is truncated and \
                stripped of file paths.
                """,
            inputSchema: ToolSchema.object(
                properties: ["receiptID": ToolSchema.uuid("Receipt identifier from list_receipts.")],
                required: ["receiptID"]
            )
        ),
        ToolDefinition(
            name: "list_pending_requests",
            tier: .readOnly,
            title: "List pending requests",
            description: """
                List the requests waiting for a person to review, including anything queued earlier in this session. Shows how many \
                times each was asked for and which client asked.
                """,
            inputSchema: ToolSchema.object(properties: [:])
        ),
        ToolDefinition(
            name: "get_request_status",
            tier: .readOnly,
            title: "Get request status",
            description: """
                Check one queued request. A request stays 'pending-review' until a person opens it in Agent Tooling and decides; \
                this server is never told to approve it and cannot report an approval it made itself.
                """,
            inputSchema: ToolSchema.object(
                properties: ["requestID": ToolSchema.uuid("Request identifier returned when the request was queued.")],
                required: ["requestID"]
            )
        ),
        ToolDefinition(
            name: "open_review_screen",
            tier: .readOnly,
            title: "Get a review deep link",
            description: """
                Return an agent-tooling:// link to a screen in the Agent Tooling app. This only builds and validates the link; it \
                does not open, focus or navigate anything. Give the link to the person to click.
                """,
            inputSchema: ToolSchema.object(
                properties: [
                    "screen": ToolSchema.enumeration(
                        "Which screen the link should point at.",
                        values: ExternalAppSection.allCases.map(\.rawValue).sorted() + ["request"]
                    ),
                    "requestID": ToolSchema.uuid("Required when screen is 'request'."),
                    "skillID": ToolSchema.string(
                        "Optional skill identifier when screen is 'skills'.",
                        maximumLength: IntegrationResponseLimits.identifierMaximumCharacters
                    ),
                ],
                required: ["screen"]
            )
        ),
    ]

    /// Every tool here appends exactly one row for exactly one component and
    /// returns a link. None of them accepts a list of components: a bulk form
    /// would let one injected instruction become twenty rows, and twenty rows
    /// is how a review queue stops being reviewed.
    static let reviewQueueTools: [ToolDefinition] = [
        ToolDefinition(
            name: "request_add_mcp_server",
            tier: .queuesReview,
            title: "Ask a person to add an MCP server",
            description: """
                Queue a request for a person to add one MCP server. Nothing is configured by this call: it appends one row to the \
                review queue and returns a link. The person sees the endpoint next to the file it would change and decides there. \
                Do not put API keys, tokens or passwords in the endpoint — the request is refused if it contains one.
                """,
            inputSchema: ToolSchema.object(
                properties: [
                    "name": ToolSchema.string("Short name for the server, lower case with hyphens.", maximumLength: 96),
                    "transport": ToolSchema.enumeration("How the server is reached.", values: ["http", "stdio"]),
                    "endpoint": ToolSchema.string(
                        "The https URL for an http server, or the command line for a stdio server.",
                        maximumLength: MCPDefinitionValidator.maximumDestinationLength
                    ),
                    "scope": ToolSchema.scope,
                    "projectRoot": ToolSchema.projectRoot,
                    "targets": ToolSchema.targets,
                    "reason": ToolSchema.reason,
                ],
                required: ["name", "transport", "endpoint", "scope", "targets"]
            )
        ),
        ToolDefinition(
            name: "request_create_skill",
            tier: .queuesReview,
            title: "Ask a person to create a skill",
            description: """
                Queue a request for a person to create one new Agent Skill from an instruction. The skill is drafted in the app, \
                where the person reads it before anything is written. This call writes no files.
                """,
            inputSchema: ToolSchema.object(
                properties: [
                    "instruction": ToolSchema.string(
                        "What the skill should do, in plain language.",
                        maximumLength: CodexSkillDraftRequest.maximumInstructionCharacters
                    ),
                    "proposedName": ToolSchema.string(
                        "Suggested skill identifier, lower case with hyphens.",
                        maximumLength: 96
                    ),
                    "scope": ToolSchema.scope,
                    "projectRoot": ToolSchema.projectRoot,
                    "targets": ToolSchema.targets,
                ],
                required: ["instruction", "scope", "targets"]
            )
        ),
        ToolDefinition(
            name: "request_install_skill",
            tier: .queuesReview,
            title: "Ask a person to install a skill",
            description: """
                Queue a request for a person to install one skill that already exists in the library or marketplace. Installs \
                nothing; it appends one row and returns a link.
                """,
            inputSchema: ToolSchema.object(
                properties: [
                    "skillID": ToolSchema.string(
                        "Skill identifier from search_inventory.",
                        maximumLength: IntegrationResponseLimits.identifierMaximumCharacters
                    ),
                    "scope": ToolSchema.scope,
                    "projectRoot": ToolSchema.projectRoot,
                    "targets": ToolSchema.targets,
                    "reason": ToolSchema.reason,
                ],
                required: ["skillID", "scope", "targets"]
            )
        ),
        ToolDefinition(
            name: "request_install_plugin",
            tier: .queuesReview,
            title: "Ask a person to install a plugin",
            description: """
                Queue a request for a person to install one plugin from a marketplace source. Installs nothing; it appends one row \
                and returns a link.
                """,
            inputSchema: ToolSchema.object(
                properties: [
                    "pluginID": ToolSchema.string(
                        "Plugin identifier from search_inventory.",
                        maximumLength: IntegrationResponseLimits.identifierMaximumCharacters
                    ),
                    "source": ToolSchema.string(
                        "Optional marketplace or repository name the plugin comes from. Local file paths are refused.",
                        maximumLength: 256
                    ),
                    "scope": ToolSchema.scope,
                    "projectRoot": ToolSchema.projectRoot,
                    "targets": ToolSchema.targets,
                    "reason": ToolSchema.reason,
                ],
                required: ["pluginID", "scope", "targets"]
            )
        ),
        ToolDefinition(
            name: "request_remove_component",
            tier: .queuesReview,
            title: "Ask a person to remove a component",
            description: """
                Queue a request for a person to remove one skill, MCP server or plugin. Nothing is removed by this call, and the \
                request expires unread if the person never opens it.
                """,
            inputSchema: ToolSchema.object(
                properties: [
                    "kind": ToolSchema.componentKind,
                    "id": ToolSchema.string(
                        "Component identifier from search_inventory.",
                        maximumLength: IntegrationResponseLimits.identifierMaximumCharacters
                    ),
                    "targets": ToolSchema.targets,
                    "reason": ToolSchema.reason,
                ],
                required: ["kind", "id", "targets"]
            )
        ),
    ]

    static func tool(named name: String) -> ToolDefinition? {
        tools.first { $0.name == name }
    }

    /// Every property name declared anywhere in the catalog, used by the test
    /// suite to prove no tool ever grows a `home` or `workspace` parameter.
    ///
    /// This walks nested objects and array items rather than reading only the
    /// top level. A schema is a tree, so a check that stopped at the root would
    /// pass while a tool quietly declared the parameter one level down — the
    /// assertion has to cover everywhere the parameter could actually appear.
    static func declaredParameterNames() -> [String] {
        tools.flatMap { declaredParameterNames(in: $0.inputSchema) }
    }

    private static func declaredParameterNames(in schema: JSONValue, depth: Int = 0) -> [String] {
        guard depth < 16, case .object(let fields) = schema else { return [] }
        var names: [String] = []
        if case .object(let properties)? = fields["properties"] {
            names.append(contentsOf: properties.keys)
            for nested in properties.values {
                names.append(contentsOf: declaredParameterNames(in: nested, depth: depth + 1))
            }
        }
        if let items = fields["items"] {
            names.append(contentsOf: declaredParameterNames(in: items, depth: depth + 1))
            // `items` is a list of schemas in the tuple form of the spec.
            if case .array(let variants) = items {
                names.append(contentsOf: variants.flatMap { declaredParameterNames(in: $0, depth: depth + 1) })
            }
        }
        return names
    }
}

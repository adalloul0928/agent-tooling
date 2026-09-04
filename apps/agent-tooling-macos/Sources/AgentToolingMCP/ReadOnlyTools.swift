import AgentToolingCore
import Foundation

/// Tier 1. Reads persisted workspace state, writes nothing, spawns nothing.
///
/// Two rules hold across every response here:
///
/// * Only secret *reference names* are returned, never a secret value.
/// * Configuration paths are omitted by default, so a home directory cannot
///   reach a transcript. Where a count is useful the count is returned instead.
enum ReadOnlyTools {
    static func handle(_ name: String, context: ToolCallContext) throws -> ToolOutcome {
        switch name {
        case "search_inventory": try searchInventory(context)
        case "get_component": try getComponent(context)
        case "get_client_status": try getClientStatus(context)
        case "list_receipts": try listReceipts(context)
        case "get_receipt": try getReceipt(context)
        case "list_pending_requests": try listPendingRequests(context)
        case "get_request_status": try getRequestStatus(context)
        case "open_review_screen": try openReviewScreen(context)
        default: throw ToolInputError.unknownTool(name)
        }
    }

    // MARK: - Inventory

    private static func searchInventory(_ context: ToolCallContext) throws -> ToolOutcome {
        let query = try context.arguments.optionalString("query", maximum: IntegrationResponseLimits.searchQueryMaximumCharacters) ?? ""
        let kind = try context.arguments.optionalEnumeration("kind", allowed: ["skill", "mcp-server", "plugin"])
        let limit =
            try context.arguments.optionalInteger("limit", minimum: 1, maximum: IntegrationResponseLimits.searchMaximumLimit)
            ?? IntegrationResponseLimits.searchDefaultLimit
        let snapshot = try context.snapshot()
        let response = IntegrationSearchIndex.response(
            for: snapshot,
            query: query,
            kinds: kind.map { [$0] },
            limit: limit
        )
        return ToolOutcome(
            payload: try JSONValueCoding.value(from: response),
            summary: "\(response.results.count) of \(response.totalResults) matching components."
        )
    }

    private static func getComponent(_ context: ToolCallContext) throws -> ToolOutcome {
        let kind = try context.arguments.requiredEnumeration("kind", allowed: ["skill", "mcp-server", "plugin"])
        let id = try context.arguments.requiredIdentifier("id")
        let snapshot = try context.snapshot()

        switch kind {
        case "skill":
            guard let skill = snapshot.skills.first(where: { $0.id == id }) else { return notFound(kind: kind, id: id) }
            return ToolOutcome(payload: describe(skill), summary: "Skill \(skill.displayName).")
        case "mcp-server":
            guard let server = snapshot.mcpServers.first(where: { $0.id == id }) else { return notFound(kind: kind, id: id) }
            return ToolOutcome(payload: describe(server), summary: "MCP server \(server.name).")
        default:
            guard let plugin = snapshot.plugins.first(where: { $0.id == id }) else { return notFound(kind: kind, id: id) }
            return ToolOutcome(payload: describe(plugin), summary: "Plugin \(plugin.name).")
        }
    }

    private static func notFound(kind: String, id: String) -> ToolOutcome {
        ToolOutcome(
            payload: .object(["kind": .string(kind), "id": .string(id), "found": .bool(false)]),
            summary: "No \(kind) with the identifier '\(id)' is known. Run search_inventory to see what exists.",
            isError: true
        )
    }

    private static func describe(_ skill: Skill) -> JSONValue {
        .object([
            "id": .string(skill.id),
            "kind": .string("skill"),
            "name": .string(IntegrationTextSanitizer.bounded(skill.displayName, maximum: IntegrationResponseLimits.nameMaximumCharacters)),
            "summary": optionalString(
                IntegrationTextSanitizer.boundedOptional(skill.summary, maximum: IntegrationResponseLimits.descriptionMaximumCharacters)
            ),
            "source": optionalString(IntegrationTextSanitizer.nonPathSource(skill.bundle)),
            "scope": .string(skill.scope),
            // The project root itself is a path, so only its presence is reported.
            "isProjectScoped": .bool(skill.projectRoot != nil),
            "managed": .bool(skill.owned),
            "triggers": .array(skill.triggers.prefix(12).map { JSONValue.string(IntegrationTextSanitizer.bounded($0, maximum: 240)) }),
            "fileCount": .number(Double(skill.files.count)),
            "validationCount": .number(Double(skill.validationCount)),
            "authoringOrigin": optionalString(skill.authoringOrigin?.rawValue),
            "clients": clientStates(skill.clients),
        ])
    }

    private static func describe(_ server: MCPServer) -> JSONValue {
        // The endpoint is a URL or a command line. Neither is returned as
        // written: an http endpoint collapses to scheme and host, and a stdio
        // endpoint collapses to the executable's base name, so a token in a
        // query string or an argument has nothing to ride out on.
        let endpointSummary: String? =
            switch server.transport {
            case .http: ResponseRedaction.locationFreeSummary(server.endpoint)
            case .stdio: ResponseRedaction.executableName(from: server.endpoint)
            }
        return .object([
            "id": .string(server.id),
            "kind": .string("mcp-server"),
            "name": .string(IntegrationTextSanitizer.bounded(server.name, maximum: IntegrationResponseLimits.nameMaximumCharacters)),
            "summary": optionalString(
                IntegrationTextSanitizer.boundedOptional(server.summary, maximum: IntegrationResponseLimits.descriptionMaximumCharacters)
            ),
            "transport": .string(server.transport.rawValue),
            "endpointSummary": optionalString(endpointSummary),
            "authentication": .string(IntegrationTextSanitizer.bounded(server.authentication, maximum: 120)),
            "scope": .string(server.scope),
            "isProjectScoped": .bool(server.projectRoot != nil),
            "definitionSource": .string(server.isManagedDefinition ? "Managed library" : "Local configuration"),
            // Reference names only. This server has no tool that resolves one
            // to a value, and adding one is excluded by construction.
            "secretReferenceNames": .array(server.secretNames.prefix(32).map { JSONValue.string(String($0.prefix(120))) }),
            "state": .string(server.aggregateState.rawValue),
            "clients": clientStates(server.clients),
        ])
    }

    private static func describe(_ plugin: Plugin) -> JSONValue {
        .object([
            "id": .string(plugin.id),
            "kind": .string("plugin"),
            "name": .string(IntegrationTextSanitizer.bounded(plugin.name, maximum: IntegrationResponseLimits.nameMaximumCharacters)),
            "summary": optionalString(
                IntegrationTextSanitizer.boundedOptional(plugin.summary, maximum: IntegrationResponseLimits.descriptionMaximumCharacters)
            ),
            "source": optionalString(IntegrationTextSanitizer.nonPathSource(plugin.source)),
            "scope": .string(plugin.scope),
            "revision": .string(IntegrationTextSanitizer.bounded(plugin.revision, maximum: 120)),
            "skills": .array(plugin.skills.prefix(64).map { JSONValue.string(String($0.prefix(120))) }),
            "profiles": .array(plugin.profiles.prefix(64).map { JSONValue.string(String($0.prefix(120))) }),
            "installed": .bool(plugin.installed),
            "clients": clientStates(plugin.clients),
        ])
    }

    private static func clientStates(_ states: [ClientState]) -> JSONValue {
        .array(
            states.map { state in
                .object([
                    "client": .string(IntegrationTextSanitizer.targetName(state.client)),
                    "state": .string(state.state.rawValue),
                    "detail": .string(IntegrationTextSanitizer.bounded(state.detail, maximum: 400)),
                    "installed": .bool(state.reportsLocalPresence),
                ])
            })
    }

    // MARK: - Clients

    private static func getClientStatus(_ context: ToolCallContext) throws -> ToolOutcome {
        let snapshot = try context.snapshot()
        let observations = snapshot.targetObservations
        let unavailable = observations.filter { !$0.isCommandAvailable }.map(\.surface)
        let lastScannedAt = observations.map(\.lastScannedAt).max()

        let clients = observations.map { observation -> JSONValue in
            .object([
                "surface": .string(observation.surface.rawValue),
                "displayName": .string(observation.surface.displayName),
                "installed": .bool(observation.installed),
                "commandAvailable": .bool(observation.commandAvailable),
                "version": optionalString(observation.version.map { String($0.prefix(64)) }),
                "skillCount": .number(Double(observation.discoveredSkills.count)),
                "pluginCount": .number(Double(observation.discoveredPlugins.count)),
                "mcpServerCount": .number(Double(observation.discoveredMCPServers.count)),
                // Deliberately a count. The paths themselves are home
                // directories, and the person can see them in the app.
                "configurationFileCount": .number(Double(observation.configurationPaths.count)),
                "lastScannedAt": .string(iso8601(observation.lastScannedAt)),
                "notes": .array(observation.notes.prefix(8).map { JSONValue.string(String($0.prefix(300))) }),
            ])
        }

        let report = JSONValue.object([
            "schemaVersion": .number(Double(IntegrationResponseLimits.schemaVersion)),
            "isHealthy": .bool(unavailable.isEmpty && !observations.isEmpty),
            "unavailableTargets": .array(unavailable.map { JSONValue.string($0.rawValue) }),
            "clients": .array(clients),
            "lastScannedAt": optionalString(lastScannedAt.map { iso8601($0) }),
            // This tool reports what the app last observed. It starts no scan
            // and runs no client command, so there is no process-execution
            // primitive in this address space for a caller to borrow.
            "isLiveScan": .bool(false),
            "note": .string(
                observations.isEmpty
                    ? "Agent Tooling has not run a setup check yet. Ask the person to open the app and run one."
                    : "Reflects the last setup check run in Agent Tooling, not a live probe."
            ),
        ])
        return ToolOutcome(payload: report, summary: "\(observations.count) observed clients, \(unavailable.count) unavailable.")
    }

    // MARK: - Receipts

    private static func listReceipts(_ context: ToolCallContext) throws -> ToolOutcome {
        let limit = try context.arguments.optionalInteger("limit", minimum: 1, maximum: 50) ?? 20
        let receipts = try context.snapshot().operationReceipts.sorted { $0.createdAt > $1.createdAt }
        let limited = Array(receipts.prefix(limit))
        return ToolOutcome(
            payload: .object([
                "schemaVersion": .number(Double(IntegrationResponseLimits.schemaVersion)),
                "receipts": .array(limited.map(summarize)),
                "totalReceipts": .number(Double(receipts.count)),
                "truncated": .bool(limited.count < receipts.count),
            ]),
            summary: "\(limited.count) of \(receipts.count) receipts."
        )
    }

    private static func getReceipt(_ context: ToolCallContext) throws -> ToolOutcome {
        let id = try context.arguments.requiredUUID("receiptID")
        guard let receipt = try context.snapshot().operationReceipts.first(where: { $0.id == id }) else {
            return ToolOutcome(
                payload: .object(["receiptID": .string(id.uuidString.lowercased()), "found": .bool(false)]),
                summary: "No receipt with that identifier exists.",
                isError: true
            )
        }
        guard case .object(var fields) = summarize(receipt) else {
            throw ToolInputError.wrongType("receiptID", "a receipt")
        }
        fields["steps"] = .array(
            receipt.results.prefix(200).map { result in
                .object([
                    "stepID": .string(result.stepID.uuidString.lowercased()),
                    "status": .string(result.status.rawValue),
                    "output": .string(String(result.output.prefix(600))),
                    "startedAt": .string(iso8601(result.startedAt)),
                    "finishedAt": .string(iso8601(result.finishedAt)),
                ])
            })
        return ToolOutcome(
            payload: .object([
                "schemaVersion": .number(Double(IntegrationResponseLimits.schemaVersion)),
                "receipt": .object(fields),
            ]),
            summary: "Receipt \(receipt.title) finished \(receipt.state.rawValue)."
        )
    }

    private static func summarize(_ receipt: OperationReceipt) -> JSONValue {
        .object([
            "id": .string(receipt.id.uuidString.lowercased()),
            "planID": .string(receipt.planID.uuidString.lowercased()),
            "kind": .string(receipt.kind.rawValue),
            "title": .string(IntegrationTextSanitizer.bounded(receipt.title, maximum: IntegrationResponseLimits.nameMaximumCharacters)),
            "state": .string(receipt.state.rawValue),
            "targets": .array(receipt.targetSurfaces.map { JSONValue.string($0.rawValue) }),
            "stepCount": .number(Double(receipt.results.count)),
            "createdAt": .string(iso8601(receipt.createdAt)),
            "verificationSummary": .string(String(receipt.verificationSummary.prefix(600))),
        ])
    }

    // MARK: - Pending requests

    private static func listPendingRequests(_ context: ToolCallContext) throws -> ToolOutcome {
        let requests = try PendingRequestQueueService.pendingRequests(store: context.store, now: context.now)
        return ToolOutcome(
            payload: .object([
                "schemaVersion": .number(Double(IntegrationResponseLimits.schemaVersion)),
                "requests": .array(requests.map(PendingRequestResponses.row)),
                "pendingCount": .number(Double(requests.count)),
                "maximumPending": .number(Double(PendingAgentRequestQueue.maximumPendingRequests)),
            ]),
            summary: "\(requests.count) requests waiting for a person to review."
        )
    }

    private static func getRequestStatus(_ context: ToolCallContext) throws -> ToolOutcome {
        let id = try context.arguments.requiredUUID("requestID")
        let requests = try PendingRequestQueueService.pendingRequests(store: context.store, now: context.now)
        guard let request = requests.first(where: { $0.id == id }) else {
            return ToolOutcome(
                payload: .object([
                    "requestID": .string(id.uuidString.lowercased()),
                    "found": .bool(false),
                    // A row leaves this queue when a person acts on it in the
                    // app. This server is not told which way they decided, and
                    // must not guess: reporting "approved" here would be an
                    // approval invented by the thing that asked for it.
                    "note": .string(
                        "No pending request with that identifier. It was either never queued, or a person has already dealt with it "
                            + "in Agent Tooling. Ask them what they decided."
                    ),
                ]),
                summary: "That request is not in the pending queue.",
                isError: true
            )
        }
        return ToolOutcome(
            payload: .object([
                "schemaVersion": .number(Double(IntegrationResponseLimits.schemaVersion)),
                "request": PendingRequestResponses.row(request),
            ]),
            summary: "Request \(request.title) is still pending review."
        )
    }

    // MARK: - Deep links

    private static func openReviewScreen(_ context: ToolCallContext) throws -> ToolOutcome {
        let sections = ExternalAppSection.allCases.map(\.rawValue).sorted()
        let screen = try context.arguments.requiredEnumeration("screen", allowed: sections + ["request"])
        let requestID = try context.arguments.optionalUUID("requestID")
        let skillID = try context.arguments.optionalString("skillID", maximum: IntegrationResponseLimits.identifierMaximumCharacters)

        let raw: String
        switch screen {
        case "request":
            guard let requestID else { throw ToolInputError.missing("requestID") }
            raw = "agent-tooling://requests/\(requestID.uuidString.lowercased())"
        case "skills" where skillID != nil:
            guard let skillID, let normalized = try? WorkspaceLibrary.normalizedIdentifier(skillID), normalized == skillID else {
                throw ToolInputError.invalidIdentifier("skillID")
            }
            raw = "agent-tooling://skills/\(normalized)"
        default:
            raw = "agent-tooling://\(screen)"
        }

        // Round-trip through the app's own parser so this tool can only ever
        // hand out a link the app already accepts. A link it would reject is a
        // bug here, not something to send to a person.
        guard let url = URL(string: raw), ExternalAppRoute(url: url) != nil else {
            throw ToolInputError.notInEnumeration("screen", sections + ["request"])
        }
        return ToolOutcome(
            payload: .object([
                "schemaVersion": .number(Double(IntegrationResponseLimits.schemaVersion)),
                "url": .string(raw),
                "screen": .string(screen),
                "note": .string("Give this link to the person. This server does not open, focus or navigate anything itself."),
            ]),
            summary: "Review link: \(raw)"
        )
    }

    private static func optionalString(_ value: String?) -> JSONValue {
        guard let value else { return .null }
        return .string(value)
    }
}

/// Shared rendering for a queue row, used by both the read tools and the
/// request tools so there is exactly one place that decides what a caller may
/// see about a pending request.
enum PendingRequestResponses {
    static func row(_ request: PendingAgentRequest) -> JSONValue {
        // `request.reviewDetails` is intentionally absent: the project root,
        // endpoint, source and instruction exist for the person reviewing in
        // the app, not for whatever is reading this response.
        .object([
            "id": .string(request.id.uuidString.lowercased()),
            "kind": .string(request.kind.rawValue),
            "title": .string(request.title),
            "summary": .string(request.summary),
            "componentID": request.componentID.map(JSONValue.string) ?? .null,
            "scope": .string(request.scope.rawValue),
            "targets": .array(request.targets.map { JSONValue.string(IntegrationTextSanitizer.targetName($0)) }),
            "state": .string("pending-review"),
            "reviewURL": .string(request.reviewURL),
            "createdAt": .string(iso8601(request.createdAt)),
            "lastRequestedAt": .string(iso8601(request.lastRequestedAt)),
            "timesRequested": .number(Double(request.repeatCount)),
            "requestedByUnverifiedClients": .array(request.requestedByLabels.map(JSONValue.string)),
        ])
    }
}

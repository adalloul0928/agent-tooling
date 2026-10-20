import AgentToolingCore
import Foundation

/// Queues one bounded request per call and returns its review link.
/// These tools cannot build plans or modify clients, library items or files.
/// The app constructs the operation from its own state during human review.
enum RequestTools {
    static func handle(_ name: String, context: ToolCallContext) throws -> ToolOutcome {
        switch name {
        case "request_add_mcp_server": try addMCPServer(context)
        case "request_create_skill": try createSkill(context)
        case "request_install_skill": try installSkill(context)
        case "request_install_plugin": try installPlugin(context)
        case "request_remove_component": try removeComponent(context)
        default: throw ToolInputError.unknownTool(name)
        }
    }

    // MARK: - Tools

    private static func addMCPServer(_ context: ToolCallContext) throws -> ToolOutcome {
        let name = try context.arguments.requiredString("name", maximum: 96)
        guard let serverID = try? WorkspaceLibrary.normalizedIdentifier(name) else {
            throw ToolInputError.invalidIdentifier("name")
        }
        let transport: MCPTransport =
            try context.arguments.requiredEnumeration("transport", allowed: ["http", "stdio"]) == "http"
            ? .http : .stdio
        let rawEndpoint = try context.arguments.requiredString("endpoint", maximum: MCPDefinitionValidator.maximumDestinationLength)
        // The same validator the app uses. It refuses inline API keys, tokens,
        // basic-auth URLs and query-string credentials, so a caller cannot park
        // a secret in the queue for a person to approve unread.
        let destination = try MCPDefinitionValidator.validate(rawEndpoint, transport: transport)
        let scope = try context.arguments.requiredScope()
        let projectRoot = try context.arguments.projectRoot(for: scope)
        let targets = try context.arguments.requiredTargets()
        let reason = try context.arguments.optionalString("reason", maximum: 500)

        return try enqueue(
            context: context,
            kind: .addMCPServer,
            title: "Add the MCP server '\(serverID)'",
            summary: "\(context.client.displayLabel) is asking to add a \(transport.rawValue) MCP server named '\(serverID)'.",
            componentID: serverID,
            scope: scope,
            targets: targets,
            reason: reason,
            reviewDetails: PendingRequestReviewDetails(
                projectRoot: projectRoot,
                endpoint: destination.endpoint,
                transport: transport.rawValue
            ),
            fingerprintInputs: [serverID, transport.rawValue, destination.endpoint, projectRoot ?? ""]
        )
    }

    private static func createSkill(_ context: ToolCallContext) throws -> ToolOutcome {
        let instruction = try context.arguments.requiredString(
            "instruction",
            maximum: SkillDraftRequest.maximumInstructionCharacters,
            allowsLineBreaks: true
        )
        let scope = try context.arguments.requiredScope()
        let projectRoot = try context.arguments.projectRoot(for: scope)
        let targets = try context.arguments.requiredTargets()
        var proposedName: String?
        if let raw = try context.arguments.optionalString("proposedName", maximum: 96) {
            guard let normalized = try? WorkspaceLibrary.normalizedIdentifier(raw) else {
                throw ToolInputError.invalidIdentifier("proposedName")
            }
            proposedName = normalized
        }

        // Which local assistant drafts it. Codex when unsaid, as every request
        // before there was a choice was.
        let assistant: ClientKind
        switch try context.arguments.optionalString("assistant", maximum: 32)?.lowercased() {
        case nil, "codex": assistant = .codex
        case "claude", "claude-code": assistant = .claude
        default: throw ToolInputError.notInEnumeration("assistant", ["claude-code", "codex"])
        }

        let identifier = context.identifierFactory()
        let outcome = try enqueueRequest(
            context: context,
            kind: .createSkill,
            title: "Create the skill '\(proposedName ?? "(unnamed)")'",
            summary: "\(context.client.displayLabel) is asking to create a skill"
                + (proposedName.map { " named '\($0)'" } ?? "") + ".",
            componentID: proposedName,
            scope: scope,
            targets: targets,
            reason: nil,
            reviewDetails: PendingRequestReviewDetails(projectRoot: projectRoot, instruction: instruction),
            fingerprintInputs: [proposedName ?? "", instruction, projectRoot ?? ""],
            identifier: identifier
        )

        // Keep the app's local draft payload bound to the queue row even when
        // this call collapsed into an identical older request. That repairs a
        // missing payload instead of leaving a review row that can never open.
        let draft = SkillDraftRequest(
            id: outcome.request.id,
            client: assistant,
            instruction: instruction,
            proposedName: proposedName,
            scope: scope,
            projectRoot: projectRoot,
            targets: targets
        )
        do {
            try context.store.saveRequestDraft(draft.id, draft)
        } catch {
            if !outcome.collapsed {
                _ = try? PendingRequestQueueService.resolve(
                    id: outcome.request.id,
                    expectedFingerprint: outcome.request.fingerprint,
                    store: context.store
                )
            }
            throw error
        }
        return response(for: outcome, context: context)
    }

    private static func installSkill(_ context: ToolCallContext) throws -> ToolOutcome {
        let skillID = try context.arguments.requiredIdentifier("skillID")
        let scope = try context.arguments.requiredScope()
        let projectRoot = try context.arguments.projectRoot(for: scope)
        let targets = try context.arguments.requiredTargets()
        let reason = try context.arguments.optionalString("reason", maximum: 500)
        return try enqueue(
            context: context,
            kind: .installSkill,
            title: "Install the skill '\(skillID)'",
            summary: "\(context.client.displayLabel) is asking to install the skill '\(skillID)'.",
            componentID: skillID,
            scope: scope,
            targets: targets,
            reason: reason,
            reviewDetails: PendingRequestReviewDetails(projectRoot: projectRoot),
            fingerprintInputs: [skillID, projectRoot ?? ""]
        )
    }

    private static func installPlugin(_ context: ToolCallContext) throws -> ToolOutcome {
        let pluginID = try context.arguments.requiredIdentifier("pluginID")
        let scope = try context.arguments.requiredScope()
        let projectRoot = try context.arguments.projectRoot(for: scope)
        let targets = try context.arguments.requiredTargets()
        let reason = try context.arguments.optionalString("reason", maximum: 500)
        var source: String?
        if let raw = try context.arguments.optionalString("source", maximum: 256) {
            // A local path as a plugin source would ask a person to approve
            // installing from a directory the caller controls.
            guard let portable = IntegrationTextSanitizer.nonPathSource(raw),
                !ResponseRedaction.containsFileSystemPath(portable),
                !ResponseRedaction.containsSecretMarker(portable)
            else { throw ToolInputError.invalidIdentifier("source") }
            source = portable
        }
        return try enqueue(
            context: context,
            kind: .installPlugin,
            title: "Install the plugin '\(pluginID)'",
            summary: "\(context.client.displayLabel) is asking to install the plugin '\(pluginID)'"
                + (source.map { " from \($0)" } ?? "") + ".",
            componentID: pluginID,
            scope: scope,
            targets: targets,
            reason: reason,
            reviewDetails: PendingRequestReviewDetails(projectRoot: projectRoot, source: source),
            fingerprintInputs: [pluginID, source ?? "", projectRoot ?? ""]
        )
    }

    private static func removeComponent(_ context: ToolCallContext) throws -> ToolOutcome {
        let kind = try context.arguments.requiredEnumeration("kind", allowed: ["skill", "mcp-server", "plugin"])
        let id = try context.arguments.requiredIdentifier("id")
        let targets = try context.arguments.requiredTargets()
        let reason = try context.arguments.optionalString("reason", maximum: 500)
        return try enqueue(
            context: context,
            kind: .removeComponent,
            title: "Remove the \(kind) '\(id)'",
            summary: "\(context.client.displayLabel) is asking to remove the \(kind) '\(id)'. Nothing is removed until a person "
                + "reviews this.",
            componentID: id,
            scope: .user,
            targets: targets,
            reason: reason,
            reviewDetails: PendingRequestReviewDetails(componentKind: kind),
            fingerprintInputs: [kind, id]
        )
    }

    // MARK: - Queueing

    private static func enqueue(
        context: ToolCallContext,
        kind: PendingRequestKind,
        title: String,
        summary: String,
        componentID: String?,
        scope: ToolingScope,
        targets: [ClientKind],
        reason: String?,
        reviewDetails: PendingRequestReviewDetails,
        fingerprintInputs: [String],
        identifier: UUID? = nil
    ) throws -> ToolOutcome {
        let outcome = try enqueueRequest(
            context: context,
            kind: kind,
            title: title,
            summary: summary,
            componentID: componentID,
            scope: scope,
            targets: targets,
            reason: reason,
            reviewDetails: reviewDetails,
            fingerprintInputs: fingerprintInputs,
            identifier: identifier
        )
        return response(for: outcome, context: context)
    }

    private static func enqueueRequest(
        context: ToolCallContext,
        kind: PendingRequestKind,
        title: String,
        summary: String,
        componentID: String?,
        scope: ToolingScope,
        targets: [ClientKind],
        reason: String?,
        reviewDetails: PendingRequestReviewDetails,
        fingerprintInputs: [String],
        identifier: UUID?
    ) throws -> PendingRequestOutcome {
        try PendingRequestQueueService.enqueue(
            kind: kind,
            title: ResponseRedaction.redactedText(String(title.prefix(200))),
            summary: ResponseRedaction.redactedText(String(summary.prefix(600))),
            componentID: componentID,
            scope: scope,
            targets: targets,
            reason: reason.map { ResponseRedaction.redactedText(String($0.prefix(500))) },
            reviewDetails: reviewDetails,
            fingerprintInputs: fingerprintInputs,
            clientLabel: context.client.displayLabel,
            store: context.store,
            now: context.now,
            identifier: identifier ?? context.identifierFactory()
        )
    }

    private static func response(for outcome: PendingRequestOutcome, context: ToolCallContext) -> ToolOutcome {
        let pendingCount = (try? context.store.pendingRequestQueue().requests.count) ?? 0
        let request = outcome.request
        let payload = JSONValue.object([
            "schemaVersion": .number(Double(IntegrationResponseLimits.schemaVersion)),
            // The exact shape `agent-tooling request create-skill` returns, so
            // a caller that already speaks to the CLI helper does not need a
            // second vocabulary.
            "request": .object([
                "id": .string(request.id.uuidString.lowercased()),
                "state": .string("pending-review"),
            ]),
            "state": .string("pending-review"),
            "reviewURL": .string(request.reviewURL),
            "collapsedIntoExistingRequest": .bool(outcome.collapsed),
            "timesRequested": .number(Double(request.repeatCount)),
            "pendingCount": .number(Double(pendingCount)),
            "maximumPending": .number(Double(PendingAgentRequestQueue.maximumPendingRequests)),
            "note": .string(
                "Nothing has been changed. A person must open this link in Agent Tooling and approve it there; this server cannot "
                    + "approve it and will not report an approval."
            ),
        ])
        let summary =
            outcome.collapsed
            ? "An identical request was already waiting, so this did not add another row. Review link: \(request.reviewURL)"
            : "Queued for a person to review. Nothing has changed yet. Review link: \(request.reviewURL)"
        return ToolOutcome(payload: payload, summary: summary)
    }
}

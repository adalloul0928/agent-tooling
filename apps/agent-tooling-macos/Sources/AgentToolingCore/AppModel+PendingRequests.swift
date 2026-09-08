import Foundation

public enum PendingRequestContinuation: Sendable, Equatable {
    case skillCreation(UUID)
    case operationPlan
}

extension AppModel {
    public func refreshPendingRequests() {
        do {
            pendingAgentRequests = try PendingRequestQueueService.pendingRequests(store: store)
        } catch {
            presentError("The request queue could not be refreshed: \(error.localizedDescription)")
        }
    }

    public func pendingRequest(id: UUID) -> PendingAgentRequest? {
        do {
            let current = try PendingRequestQueueService.pendingRequests(store: store)
            pendingAgentRequests = current
            guard let request = current.first(where: { $0.id == id }) else {
                presentError("That request is no longer waiting for review.")
                return nil
            }
            return request
        } catch {
            presentError("The request queue could not be opened: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    public func rejectPendingRequest(id: UUID, expectedFingerprint: String) -> Bool {
        do {
            guard
                let request = try PendingRequestQueueService.resolve(
                    id: id,
                    expectedFingerprint: expectedFingerprint,
                    store: store
                )
            else {
                presentError("That request is no longer waiting for review.")
                return false
            }
            if request.kind == .createSkill {
                try? store.deleteCodexSkillDraftRequest(id: request.id)
            }
            pendingAgentRequests.removeAll { $0.id == id }
            return true
        } catch PendingRequestQueueError.requestConflict {
            refreshPendingRequests()
            presentError("That request changed after you opened it. Nothing was rejected; reopen the current queue entry.")
            return false
        } catch {
            presentError("The request could not be removed from the queue: \(error.localizedDescription)")
            return false
        }
    }

    /// Converts an untrusted wish into app-owned desired state or an
    /// app-constructed operation plan, then removes the queue row. No request
    /// ever carries executable plan bytes across this boundary.
    public func acceptPendingRequest(id: UUID, expectedFingerprint: String) -> PendingRequestContinuation? {
        guard ensureReadyForChange(), let request = pendingRequest(id: id) else { return nil }
        guard request.fingerprint == expectedFingerprint else {
            presentError("That request changed after you opened it. Nothing was approved; reopen the current queue entry.")
            return nil
        }
        guard validatePendingRequestEnvelope(request), requireEnabledClients(Set(request.targets)) else { return nil }

        var skillDraft: CodexSkillDraftRequest?
        if request.kind == .createSkill {
            guard let draft = try? store.loadCodexSkillDraftRequest(id: id) else {
                presentError("The skill request payload is no longer available. Reject this row and ask the client to submit it again.")
                return nil
            }
            guard skillDraftMatchesRequest(draft, request: request) else {
                presentError(
                    "The saved skill payload does not match the request you reviewed. Nothing was approved; reject it and ask the client to submit it again."
                )
                return nil
            }
            skillDraft = draft
        }

        let claimed: PendingAgentRequest
        do {
            guard
                let current = try PendingRequestQueueService.resolve(
                    id: id,
                    expectedFingerprint: expectedFingerprint,
                    store: store
                )
            else {
                presentError("That request changed while it was being reviewed. Nothing was approved.")
                return nil
            }
            guard current.fingerprint == request.fingerprint, validatePendingRequestEnvelope(current) else {
                _ = try? PendingRequestQueueService.restore(current, store: store)
                presentError("That request changed while it was being reviewed. Nothing was approved; reopen the current queue entry.")
                return nil
            }
            claimed = current
            pendingAgentRequests.removeAll { $0.id == id }
        } catch PendingRequestQueueError.requestConflict {
            refreshPendingRequests()
            presentError("That request changed after you opened it. Nothing was approved; reopen the current queue entry.")
            return nil
        } catch {
            presentError("The request decision could not be saved: \(error.localizedDescription)")
            return nil
        }

        if claimed.kind == .createSkill, skillDraft != nil {
            return .skillCreation(id)
        }

        let previousSnapshot = currentSnapshot()
        let prepared: Bool
        switch claimed.kind {
        case .addMCPServer:
            prepared = prepareRequestedMCPServer(claimed)
        case .installSkill:
            prepared = prepareRequestedSkillInstall(claimed)
        case .installPlugin:
            prepared = prepareRequestedPluginInstall(claimed)
        case .removeComponent:
            prepared = prepareRequestedRemoval(claimed)
        case .createSkill:
            prepared = false
        }

        guard prepared, pendingPlan != nil else {
            let preparationError = lastError ?? "Agent Tooling could not build a review plan from the current local state."
            pendingPlan = nil
            var recoveryErrors: [String] = []
            if claimed.kind == .addMCPServer {
                do {
                    try store.saveWorkspaceSnapshot(previousSnapshot)
                    applyPersisted(previousSnapshot)
                } catch {
                    recoveryErrors.append("desired-state rollback failed: \(error.localizedDescription)")
                }
            }
            do {
                try PendingRequestQueueService.restore(claimed, store: store)
                refreshPendingRequests()
            } catch {
                recoveryErrors.append("queue restore failed: \(error.localizedDescription)")
            }
            let recovery =
                recoveryErrors.isEmpty
                ? " The request is still waiting for review." : " Recovery also reported: \(recoveryErrors.joined(separator: "; "))."
            presentError(preparationError + recovery)
            return nil
        }
        return .operationPlan
    }

    private func prepareRequestedMCPServer(_ request: PendingAgentRequest) -> Bool {
        guard let name = request.componentID,
            let endpoint = request.reviewDetails.endpoint,
            let rawTransport = request.reviewDetails.transport,
            let transport = MCPTransport(rawValue: rawTransport)
        else {
            presentError("The MCP request is incomplete. Reject it and ask the client to submit a new request.")
            return false
        }
        var draft = MCPDraft()
        draft.name = name
        draft.endpoint = endpoint
        draft.transport = transport
        draft.authentication = transport == .http ? "OAuth" : "None"
        draft.scope = request.scope
        draft.projectRoot = request.reviewDetails.projectRoot ?? ""
        let targets = Set(request.targets)
        draft.addToClaude = targets.contains(.claude)
        draft.addToCodex = targets.contains(.codex)
        draft.addToGemini = targets.contains(.gemini)
        return addMCPServer(from: draft) != nil && pendingPlan != nil
    }

    private func prepareRequestedSkillInstall(_ request: PendingAgentRequest) -> Bool {
        guard let identifier = request.componentID,
            let skill = skills.first(where: { $0.id == identifier }), skill.owned
        else {
            presentError("The requested skill is not in the managed library. Adopt or create it before installing it into a client.")
            return false
        }
        guard let recordedScope = ToolingScope.allCases.first(where: { $0.displayName == skill.scope }) else {
            presentError("The managed skill has an unsupported scope. Open it and choose a supported placement first.")
            return false
        }
        guard recordedScope == request.scope else {
            presentError("The request's scope does not match the managed skill. Open the skill to change its placement first.")
            return false
        }
        if request.scope == .project {
            let requested = request.reviewDetails.projectRoot.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path(percentEncoded: false)
            }
            let recorded = skill.projectRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.path(percentEncoded: false) }
            guard requested == recorded else {
                presentError("The request names a different project folder than the managed skill.")
                return false
            }
        }
        planInstall(skillID: identifier, targets: Set(request.targets))
        return pendingPlan != nil
    }

    private func prepareRequestedPluginInstall(_ request: PendingAgentRequest) -> Bool {
        guard let identifier = request.componentID else { return false }
        let matches = marketplacePackages.filter {
            ($0.id == identifier || $0.name == identifier || $0.id.hasSuffix(":" + identifier))
                && (request.reviewDetails.source == nil
                    || $0.sourceName == request.reviewDetails.source
                    || $0.location == request.reviewDetails.source)
        }
        guard matches.count == 1, let package = matches.first else {
            presentError(
                "The requested plugin does not resolve to one current catalog listing. Refresh Marketplace and choose the exact listing there."
            )
            return false
        }
        guard
            !managedPolicies.contains(where: {
                $0.blockedPluginIDs.contains(package.name) || $0.blockedPluginIDs.contains(package.id)
            })
        else {
            presentError("A managed policy blocks installation of \(package.name). Review the policy source in Settings.")
            return false
        }
        let requestedTargets = Set(request.targets)
        let routes = package.nativeInstalls.filter { requestedTargets.contains($0.client) }
        guard Set(routes.map(\.client)) == requestedTargets, Set(routes.map(\.scope)) == Set([request.scope]) else {
            presentError("The catalog does not provide the requested app and scope combination for this plugin.")
            return false
        }
        let steps =
            routes.sorted { $0.client.rawValue < $1.client.rawValue }.map { route in
                OperationStep(
                    kind: .command,
                    title: "Install \(package.name) in \(route.client.rawValue)",
                    detail: route.detail,
                    executable: route.executable,
                    arguments: route.arguments
                )
            } + [
                OperationStep(
                    kind: .scan,
                    title: "Re-scan requested clients",
                    detail: "Confirm local installation state without claiming remote authentication or connector health.",
                    isReversible: false
                )
            ]
        pendingPlan = OperationPlan(
            kind: package.components == [.mcpServer] ? .configureMCP : .installPlugin,
            title: "Install \(package.name)",
            summary:
                "Install the exact current catalog listing in \(requestedTargets.count) selected app\(requestedTargets.count == 1 ? "" : "s").",
            targetSurfaces: requestedTargets.sorted { $0.rawValue < $1.rawValue }.map(Self.requestSurface),
            scope: request.scope,
            steps: steps
        )
        return true
    }

    private func prepareRequestedRemoval(_ request: PendingAgentRequest) -> Bool {
        guard let identifier = request.componentID, let kind = request.reviewDetails.componentKind else {
            presentError("The removal request is incomplete. Reject it and ask the client to submit a new request.")
            return false
        }
        let targets = Set(request.targets)
        switch kind {
        case "mcp-server":
            guard let server = mcpServers.first(where: { $0.id == identifier }) else {
                presentError("The requested MCP server is no longer in the current inventory.")
                return false
            }
            guard let scope = ToolingScope.allCases.first(where: { $0.displayName == server.scope }), scope == request.scope else {
                presentError("The request's scope does not match the current MCP server. Review the server directly in Agent Tooling.")
                return false
            }
            guard targets.isSubset(of: Set(server.clients.map(\.client))) else {
                presentError("At least one requested app is not recorded for this MCP server. Check setup and reopen the request.")
                return false
            }
            let root = scope == .user ? nil : server.projectRoot
            let steps = targets.sorted { $0.rawValue < $1.rawValue }.map { client in
                OperationStep(
                    kind: .command,
                    title: "Remove \(server.name) from \(client.rawValue)",
                    detail: "Remove only the exact server identifier through the client's native MCP command.",
                    executable: MCPClientCommand.executable(for: client),
                    arguments: MCPClientCommand.removeArguments(serverID: server.id, client: client, scope: scope),
                    currentDirectoryPath: root,
                    projectRootPath: root,
                    isReversible: false
                )
            }
            pendingPlan = requestedRemovalPlan(title: server.name, kind: .configureMCP, scope: scope, targets: targets, steps: steps)
        case "plugin":
            guard request.scope == .user else {
                presentError(
                    "Client-submitted plugin removals are supported only at This Mac scope. Review project removal directly in Marketplace."
                )
                return false
            }
            var steps: [OperationStep] = []
            for client in targets.sorted(by: { $0.rawValue < $1.rawValue }) {
                let prefix = client == .claude ? "claude" : client == .codex ? "codex" : "gemini"
                guard let package = marketplacePackages.first(where: { $0.id == "\(prefix):\(identifier)" }),
                    let route = package.nativeInstalls.first(where: { $0.client == client }),
                    let arguments = route.removalArguments
                else {
                    presentError("No verified \(client.rawValue) removal route is available for \(identifier). Refresh Marketplace first.")
                    return false
                }
                steps.append(
                    OperationStep(
                        kind: .command,
                        title: "Remove \(identifier) from \(client.rawValue)",
                        detail: "Remove this exact plugin identifier through the native plugin manager.",
                        executable: route.executable,
                        arguments: arguments,
                        isReversible: false
                    ))
            }
            pendingPlan = requestedRemovalPlan(title: identifier, kind: .installPlugin, scope: .user, targets: targets, steps: steps)
        case "skill":
            guard let skill = skills.first(where: { $0.id == identifier }) else {
                presentError("The requested skill is no longer in the current inventory.")
                return false
            }
            guard let recordedScope = ToolingScope.allCases.first(where: { $0.displayName == skill.scope }),
                recordedScope == request.scope
            else {
                presentError("The request's scope does not match the current skill. Review the skill directly in Agent Tooling.")
                return false
            }
            guard targets.isSubset(of: Set(skill.clients.map(\.client))) else {
                presentError("At least one requested app is not recorded for this skill. Check setup and reopen the request.")
                return false
            }
            let steps = targets.sorted { $0.rawValue < $1.rawValue }.map { client in
                OperationStep(
                    kind: .manual,
                    title: "Remove \(identifier) from \(client.rawValue)",
                    detail:
                        "Open \(client.rawValue)'s skill folder and remove only \(identifier). Agent Tooling will not delete an unverified path automatically.",
                    isReversible: false,
                    requiresUserAction: true
                )
            }
            pendingPlan = requestedRemovalPlan(title: identifier, kind: .installSkill, scope: request.scope, targets: targets, steps: steps)
        default:
            presentError("The requested component type is not supported.")
            return false
        }
        return pendingPlan != nil
    }

    private func requestedRemovalPlan(
        title: String,
        kind: OperationKind,
        scope: ToolingScope,
        targets: Set<ClientKind>,
        steps: [OperationStep]
    ) -> OperationPlan {
        OperationPlan(
            kind: kind,
            title: "Remove \(title)",
            summary: "Review each selected client's removal independently. Provider accounts and other clients remain untouched.",
            targetSurfaces: targets.sorted { $0.rawValue < $1.rawValue }.map(Self.requestSurface),
            scope: scope,
            steps: steps + [
                OperationStep(
                    kind: .scan,
                    title: "Verify requested removals",
                    detail: "Re-scan local client state after the reviewed removal steps.",
                    isReversible: false
                )
            ]
        )
    }

    private nonisolated static func requestSurface(_ client: ClientKind) -> TargetSurface {
        switch client {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .gemini: .geminiCLI
        }
    }

    private func validatePendingRequestEnvelope(_ request: PendingAgentRequest) -> Bool {
        let targets = Set(request.targets)
        guard !targets.isEmpty, targets.count == request.targets.count, targets.isSubset(of: Set(ClientKind.allCases)) else {
            presentError("The request has an invalid app selection. Nothing was approved.")
            return false
        }
        guard request.scope == .user || request.scope == .project else {
            presentError("The request has an unsupported scope. Nothing was approved.")
            return false
        }
        let root = request.reviewDetails.projectRoot
        if request.scope == .project {
            guard let root, root != "/", normalizedRequestPath(root) == root else {
                presentError("The request does not name one canonical project folder. Nothing was approved.")
                return false
            }
        } else if root != nil {
            presentError("A This Mac request cannot carry a project folder. Nothing was approved.")
            return false
        }
        let now = Date()
        guard !request.title.isEmpty, request.title.count <= 200,
            !request.summary.isEmpty, request.summary.count <= 600,
            (request.reason?.count ?? 0) <= 500,
            !request.requestedByLabels.isEmpty, request.requestedByLabels.count <= 8,
            request.requestedByLabels.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
            request.repeatCount >= 1,
            request.lastRequestedAt >= request.createdAt,
            request.lastRequestedAt <= now.addingTimeInterval(300),
            now.timeIntervalSince(request.createdAt) <= PendingAgentRequestQueue.maximumPendingAge,
            request.fingerprint.count == 64,
            request.fingerprint.allSatisfy({ $0.isHexDigit })
        else {
            presentError("The request metadata is invalid or expired. Reject it and ask the client to submit it again.")
            return false
        }

        guard let fingerprintInputs = validatedFingerprintInputs(for: request) else {
            presentError("The request is incomplete or contains unexpected fields. Nothing was approved.")
            return false
        }
        let expected = PendingRequestQueueService.fingerprint(
            kind: request.kind,
            inputs: fingerprintInputs,
            scope: request.scope,
            targets: request.targets
        )
        guard expected == request.fingerprint else {
            presentError("The request payload no longer matches its integrity fingerprint. Nothing was approved.")
            return false
        }
        return true
    }

    private func validatedFingerprintInputs(for request: PendingAgentRequest) -> [String]? {
        let details = request.reviewDetails
        switch request.kind {
        case .addMCPServer:
            guard let identifier = request.componentID, !identifier.isEmpty,
                let endpoint = details.endpoint,
                endpoint.count <= MCPDefinitionValidator.maximumDestinationLength,
                let transport = details.transport,
                MCPTransport(rawValue: transport) != nil,
                details.source == nil, details.instruction == nil, details.componentKind == nil
            else { return nil }
            return [identifier, transport, endpoint, details.projectRoot ?? ""]
        case .createSkill:
            guard let instruction = details.instruction,
                !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                instruction.count <= CodexSkillDraftRequest.maximumInstructionCharacters,
                instruction.utf8.count <= CodexSkillDraftRequest.maximumInstructionBytes,
                details.endpoint == nil, details.transport == nil, details.source == nil, details.componentKind == nil
            else { return nil }
            return [request.componentID ?? "", instruction, details.projectRoot ?? ""]
        case .installSkill:
            guard let identifier = request.componentID, !identifier.isEmpty,
                details.endpoint == nil, details.transport == nil, details.source == nil,
                details.instruction == nil, details.componentKind == nil
            else { return nil }
            return [identifier, details.projectRoot ?? ""]
        case .installPlugin:
            guard let identifier = request.componentID, !identifier.isEmpty,
                (details.source?.count ?? 0) <= 256,
                details.endpoint == nil, details.transport == nil, details.instruction == nil, details.componentKind == nil
            else { return nil }
            return [identifier, details.source ?? "", details.projectRoot ?? ""]
        case .removeComponent:
            guard request.scope == .user, details.projectRoot == nil,
                let identifier = request.componentID, !identifier.isEmpty,
                let kind = details.componentKind, ["skill", "mcp-server", "plugin"].contains(kind),
                details.endpoint == nil, details.transport == nil, details.source == nil, details.instruction == nil
            else { return nil }
            return [kind, identifier]
        }
    }

    private func skillDraftMatchesRequest(_ draft: CodexSkillDraftRequest, request: PendingAgentRequest) -> Bool {
        draft.id == request.id
            && draft.instruction == request.reviewDetails.instruction
            && draft.proposedName == request.componentID
            && draft.scope == request.scope
            && normalizedOptionalRequestPath(draft.projectRoot) == normalizedOptionalRequestPath(request.reviewDetails.projectRoot)
            && draft.targets.count == request.targets.count
            && Set(draft.targets) == Set(request.targets)
    }

    private func normalizedOptionalRequestPath(_ value: String?) -> String? {
        value.map(normalizedRequestPath)
    }

    private func normalizedRequestPath(_ value: String) -> String {
        URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path(percentEncoded: false)
    }
}

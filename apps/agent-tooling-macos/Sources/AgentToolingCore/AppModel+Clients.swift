import Foundation

extension AppModel {
    /// An empty selection is intentional. Keep the stable registry order in every picker.
    public var availableClients: [ClientKind] { ClientKind.allCases.filter(enabledClients.contains) }
    public var availableTargetSurfaces: [TargetSurface] { TargetSurface.allCases.filter { isClientEnabled($0.client) } }

    public func isClientEnabled(_ client: ClientKind?) -> Bool {
        client.map(enabledClients.contains) ?? true
    }

    /// Selection is local workspace metadata. Retain all underlying desired state and
    /// observations so opting out never becomes an uninstall or destructive migration.
    @discardableResult
    public func setClientEnabled(_ client: ClientKind, enabled: Bool) -> Bool {
        guard ensureReadyForChange() else { return false }
        var candidate = currentSnapshot()
        if enabled { candidate.preferences.enabledClients.insert(client) } else { candidate.preferences.enabledClients.remove(client) }
        guard commit(candidate) else { return false }
        projects = []
        hasDiscoveredProjects = false
        return true
    }

    func requireEnabledClients(_ clients: Set<ClientKind>) -> Bool {
        guard clients.isSubset(of: enabledClients) else {
            presentError("This action includes an unchecked client. Choose clients in Clients before preparing a new action.")
            return false
        }
        return true
    }

    /// Check both the declared targets and native commands. Composed plans cannot
    /// bypass the selection by omitting their target metadata.
    func validateEnabledClients(in plan: OperationPlan) -> Bool {
        var clients = Set(plan.targetSurfaces.compactMap(\.client))
        for step in plan.steps {
            for client in ClientKind.allCases {
                let command = MCPClientCommand.executable(for: client)
                if step.executable.map({ URL(fileURLWithPath: $0).lastPathComponent }) == command {
                    clients.insert(client)
                }
                let folder = client == .claude ? ".claude" : client == .codex ? ".codex" : ".gemini"
                if let path = step.destinationPath, URL(fileURLWithPath: path).pathComponents.contains(folder) {
                    clients.insert(client)
                }
                if client == .codex, let path = step.destinationPath,
                    URL(fileURLWithPath: path).pathComponents.contains(".agents")
                {
                    clients.insert(client)
                }
            }
        }
        return requireEnabledClients(clients)
    }

    func retainingExcludedClients<Item: Identifiable>(
        _ observed: [Item], existing: [Item], clients: WritableKeyPath<Item, [ClientState]>
    ) -> [Item] {
        let previous = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let observedIDs = Set(observed.map(\.id))
        var result = observed.map { item in
            var item = item
            item[keyPath: clients].removeAll { !isClientEnabled($0.client) }
            if let old = previous[item.id] {
                item[keyPath: clients] += old[keyPath: clients].filter { !isClientEnabled($0.client) }
            }
            return item
        }
        for var item in existing where !observedIDs.contains(item.id) {
            item[keyPath: clients].removeAll { isClientEnabled($0.client) }
            if !item[keyPath: clients].isEmpty { result.append(item) }
        }
        return result
    }

    public var visibleInstallDrift: [InstalledPackageDrift] {
        installDrift.filter { ClientSelection.includes(path: $0.destinationPath, clients: enabledClients) }
    }

    public func isItemVisible(_ item: ToolingItemReference) -> Bool {
        switch item.kind {
        case .skill: !skills.contains { $0.id == item.identifier } || visibleSkills.contains { $0.id == item.identifier }
        case .plugin: !plugins.contains { $0.id == item.identifier } || visiblePlugins.contains { $0.id == item.identifier }
        case .mcpServer: !mcpServers.contains { $0.id == item.identifier } || visibleMCPServers.contains { $0.id == item.identifier }
        }
    }

    public var visibleSkills: [Skill] {
        skills.compactMap { value in
            var value = value
            value.clients.removeAll { !isClientEnabled($0.client) }
            return value.owned || value.clients.contains(where: \.reportsLocalPresence) ? value : nil
        }
    }
    public var visibleMCPServers: [MCPServer] {
        mcpServers.compactMap { value in
            var value = value
            value.clients.removeAll { !isClientEnabled($0.client) }
            return value.isManagedDefinition || value.clients.contains(where: \.reportsLocalPresence) ? value : nil
        }
    }
    public var visiblePlugins: [Plugin] {
        plugins.compactMap { value in
            var value = value
            value.clients.removeAll { !isClientEnabled($0.client) }
            return value.clients.contains(where: \.reportsLocalPresence) ? value : nil
        }
    }
    public var visibleTargetObservations: [TargetObservation] { targetObservations.filter { isClientEnabled($0.surface.client) } }
    public var visibleAccountSurfaces: [AccountSurface] { accountSurfaces.filter { isClientEnabled($0.surface.client) } }
    public var visibleConnectors: [ConnectorRecord] {
        connectors.compactMap { value in
            var value = value
            value.bindings.removeAll { !isClientEnabled($0.target.client) }
            return value.bindings.isEmpty ? nil : value
        }
    }
    public var visibleMarketplacePackages: [MarketplacePackage] {
        marketplacePackages.compactMap { value in
            var value = value
            value.supportedClients.formIntersection(enabledClients)
            value.nativeInstalls.removeAll { !isClientEnabled($0.client) }
            return value.supportedClients.isEmpty ? nil : value
        }
    }
    public var visibleSources: [ToolingSource] {
        sources.filter { source in
            switch source.kind {
            case .claudeMarketplace: isClientEnabled(.claude)
            case .openAIPluginDirectory: isClientEnabled(.codex)
            case .geminiExtensionGallery: isClientEnabled(.gemini)
            default: true
            }
        }
    }
    public var visibleProjects: [DiscoveredProject] { projects }
    public var visibleSyncStages: [SyncStage] {
        syncStages.filter { stage in
            switch stage.id {
            case "claude": isClientEnabled(.claude)
            case "codex": isClientEnabled(.codex)
            case "gemini": isClientEnabled(.gemini)
            default: true
            }
        }
    }
    // Receipts remain intact on disk. Hide records involving an unchecked client
    // rather than rewriting an immutable record or misrepresenting partial history.
    public var visibleOperationReceipts: [OperationReceipt] {
        operationReceipts.filter { $0.targetSurfaces.allSatisfy { isClientEnabled($0.client) } }
    }
    public var visibleActivities: [ActivityReceipt] {
        let hiddenReceiptIDs = Set(operationReceipts.filter { !($0.targetSurfaces.allSatisfy { isClientEnabled($0.client) }) }.map(\.id))
        return activities.filter { activity in
            if let id = activity.operationReceiptID, hiddenReceiptIDs.contains(id) { return false }
            // Legacy activity rows have no structured client metadata.
            let text = ([activity.title, activity.detail, activity.command ?? ""] + activity.affectedPaths).joined(separator: " ")
            return !ClientKind.allCases.filter { !isClientEnabled($0) }.contains { client in
                let aliases: [String] =
                    switch client {
                    case .claude: ["claude"]
                    case .codex: ["codex", "chatgpt", ".agents/"]
                    case .gemini: ["gemini"]
                    }
                return aliases.contains { text.localizedCaseInsensitiveContains($0) }
            }
        }
    }
    public var visiblePendingAgentRequests: [PendingAgentRequest] {
        pendingAgentRequests.filter { Set($0.targets).isSubset(of: enabledClients) }
    }
    public var visibleInsightsReport: InsightsReport? {
        guard let report = insightsReport, Set(report.coverage.map(\.client)).isSubset(of: enabledClients) else { return nil }
        return report
    }
}

/// Native destination classification shared by execution checks and drift reads.
enum ClientSelection {
    static func includes(path: String, clients: Set<ClientKind>) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if parts.contains(".claude") { return clients.contains(.claude) }
        if parts.contains(".codex") || parts.contains(".agents") { return clients.contains(.codex) }
        if parts.contains(".gemini") { return clients.contains(.gemini) }
        return true
    }
}

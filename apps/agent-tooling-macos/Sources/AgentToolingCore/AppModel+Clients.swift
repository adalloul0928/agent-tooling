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
        let source = skills
        let clients = enabledClients
        if let cached = visibleInventoryCache.skills { return cached }
        let result: [Skill] = source.compactMap { value in
            var value = value
            value.clients.removeAll { !clients.contains($0.client) }
            // Keep an explicit upstream relationship inspectable after its
            // installation disappears. Use recorded paths for client scope:
            // inventory client arrays also contain absent-client placeholders.
            let linkedToEnabledClient =
                value.repositoryBinding?.installedFingerprints.keys.contains { path in
                    guard let client = ClientSelection.client(for: path) else { return false }
                    return clients.contains(client)
                } == true
            return value.owned || value.clients.contains(where: \.reportsLocalPresence) || linkedToEnabledClient ? value : nil
        }
        visibleInventoryCache.skills = result
        return result
    }
    public var visibleMCPServers: [MCPServer] {
        let source = mcpServers
        let clients = enabledClients
        if let cached = visibleInventoryCache.mcpServers { return cached }
        let result: [MCPServer] = source.compactMap { value in
            var value = value
            value.clients.removeAll { !clients.contains($0.client) }
            return value.isManagedDefinition || value.clients.contains(where: \.reportsLocalPresence) ? value : nil
        }
        visibleInventoryCache.mcpServers = result
        return result
    }
    public var visiblePlugins: [Plugin] {
        let source = plugins
        let clients = enabledClients
        if let cached = visibleInventoryCache.plugins { return cached }
        let result: [Plugin] = source.compactMap { value in
            var value = value
            value.clients.removeAll { !clients.contains($0.client) }
            return value.clients.contains(where: \.reportsLocalPresence) ? value : nil
        }
        visibleInventoryCache.plugins = result
        return result
    }
    public var visibleTargetObservations: [TargetObservation] {
        let source = targetObservations
        let clients = enabledClients
        if let cached = visibleInventoryCache.targetObservations { return cached }
        let result = source.filter { $0.surface.client.map(clients.contains) ?? true }
        visibleInventoryCache.targetObservations = result
        return result
    }
    public var visibleAccountSurfaces: [AccountSurface] {
        let source = accountSurfaces
        let clients = enabledClients
        if let cached = visibleInventoryCache.accountSurfaces { return cached }
        let result = source.filter { $0.surface.client.map(clients.contains) ?? true }
        visibleInventoryCache.accountSurfaces = result
        return result
    }
    public var visibleConnectors: [ConnectorRecord] {
        let source = connectors
        let clients = enabledClients
        if let cached = visibleInventoryCache.connectors { return cached }
        let result: [ConnectorRecord] = source.compactMap { value in
            var value = value
            value.bindings.removeAll { !($0.target.client.map(clients.contains) ?? true) }
            return value.bindings.isEmpty ? nil : value
        }
        visibleInventoryCache.connectors = result
        return result
    }
    public var visibleMarketplacePackages: [MarketplacePackage] {
        let source = marketplacePackages
        let clients = enabledClients
        if let cached = visibleInventoryCache.marketplacePackages { return cached }
        let result: [MarketplacePackage] = source.compactMap { value in
            var value = value
            value.supportedClients.formIntersection(clients)
            value.nativeInstalls.removeAll { !clients.contains($0.client) }
            return value.supportedClients.isEmpty ? nil : value
        }
        visibleInventoryCache.marketplacePackages = result
        return result
    }
    public var visibleSources: [ToolingSource] {
        let inventory = sources
        let clients = enabledClients
        if let cached = visibleInventoryCache.sources { return cached }
        let result = inventory.filter { source in
            switch source.kind {
            case .claudeMarketplace: clients.contains(.claude)
            case .openAIPluginDirectory: clients.contains(.codex)
            case .geminiExtensionGallery: clients.contains(.gemini)
            default: true
            }
        }
        visibleInventoryCache.sources = result
        return result
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
        let source = operationReceipts
        let clients = enabledClients
        if let cached = visibleInventoryCache.operationReceipts { return cached }
        let result = source.filter { $0.targetSurfaces.allSatisfy { $0.client.map(clients.contains) ?? true } }
        visibleInventoryCache.operationReceipts = result
        return result
    }
    public var visibleActivities: [ActivityReceipt] {
        let receipts = operationReceipts
        let source = activities
        let clients = enabledClients
        if let cached = visibleInventoryCache.activities { return cached }
        let hiddenReceiptIDs = Set(receipts.filter { !($0.targetSurfaces.allSatisfy { $0.client.map(clients.contains) ?? true }) }.map(\.id))
        let excludedAliases = ClientKind.allCases.filter { !clients.contains($0) }.flatMap { client -> [String] in
            switch client {
            case .claude: ["claude"]
            case .codex: ["codex", "chatgpt", ".agents/"]
            case .gemini: ["gemini"]
            }
        }
        let result = source.filter { activity in
            if let id = activity.operationReceiptID, hiddenReceiptIDs.contains(id) { return false }
            // Legacy activity rows have no structured client metadata.
            guard !excludedAliases.isEmpty else { return true }
            let text = ([activity.title, activity.detail, activity.command ?? ""] + activity.affectedPaths).joined(separator: " ")
            return !excludedAliases.contains { text.localizedCaseInsensitiveContains($0) }
        }
        visibleInventoryCache.activities = result
        return result
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
        client(for: path).map(clients.contains) ?? true
    }

    static func client(for path: String) -> ClientKind? {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if parts.contains(".claude") { return .claude }
        if parts.contains(".codex") || parts.contains(".agents") { return .codex }
        if parts.contains(".gemini") { return .gemini }
        return nil
    }
}

/// Main-actor-owned, disposable derived state. Never persisted or used to
/// authorize a filesystem operation; native writes revalidate their own inputs.
struct VisibleInventoryCache {
    var skills: [Skill]?
    var mcpServers: [MCPServer]?
    var plugins: [Plugin]?
    var targetObservations: [TargetObservation]?
    var accountSurfaces: [AccountSurface]?
    var connectors: [ConnectorRecord]?
    var marketplacePackages: [MarketplacePackage]?
    var sources: [ToolingSource]?
    var operationReceipts: [OperationReceipt]?
    var activities: [ActivityReceipt]?
}

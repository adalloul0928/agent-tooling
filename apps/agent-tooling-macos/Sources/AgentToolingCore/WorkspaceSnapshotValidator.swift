import Foundation

enum WorkspaceSnapshotValidationMode: Sendable {
    case localState
    case portableImport
}

enum WorkspaceSnapshotValidator {
    private enum Limit {
        static let recordsPerKind = 10_000
        static let historyRecords = 1_000
        static let identifierCharacters = 512
        static let shortTextCharacters = 4_096
        static let longTextCharacters = 65_536
        static let pathCharacters = 8_192
        static let childRecords = 10_000
    }

    static func validate(_ snapshot: WorkspaceSnapshot, mode: WorkspaceSnapshotValidationMode) throws {
        try validateCounts(snapshot, mode: mode)
        try requireUnique(snapshot.skills.map(\.id), field: "skill identifiers")
        try requireUnique(snapshot.mcpServers.map(\.id), field: "MCP server identifiers")
        try requireUnique(snapshot.plugins.map(\.id), field: "plugin identifiers")
        try requireUnique(snapshot.profiles.map(\.id), field: "configuration identifiers")
        try requireUnique(snapshot.sources.map(\.id), field: "source identifiers")
        try requireUnique(snapshot.marketplacePackages.map(\.id), field: "marketplace package identifiers")
        try requireUnique(snapshot.accountSurfaces.map(\.id), field: "account identifiers")
        try requireUnique(snapshot.connectors.map(\.id), field: "connection identifiers")
        try requireUnique(snapshot.managedPolicies.map(\.id), field: "policy identifiers")
        try requireUnique(snapshot.targetObservations.map(\.surface), field: "target observations")
        try requireUnique(snapshot.activities.map(\.id), field: "activity identifiers")
        try requireUnique(snapshot.operationReceipts.map(\.id), field: "operation receipt identifiers")

        for skill in snapshot.skills { try validate(skill, mode: mode) }
        for server in snapshot.mcpServers { try validate(server, mode: mode) }
        for plugin in snapshot.plugins { try validate(plugin) }
        try validateProfiles(snapshot.profiles, mode: mode)
        for source in snapshot.sources { try validate(source, mode: mode) }
        for package in snapshot.marketplacePackages { try validate(package, sources: snapshot.sources) }
        for account in snapshot.accountSurfaces { try validate(account) }
        for connector in snapshot.connectors { try validate(connector) }
        for policy in snapshot.managedPolicies { try validate(policy, mode: mode) }
        for observation in snapshot.targetObservations { try validate(observation) }
        for activity in snapshot.activities { try validate(activity) }
        for receipt in snapshot.operationReceipts { try validate(receipt) }

        if !snapshot.profiles.isEmpty, !snapshot.activeProfileID.isEmpty {
            guard snapshot.profiles.contains(where: { $0.id == snapshot.activeProfileID }) else {
                throw WorkspaceSnapshotValidationError.inconsistent("The active configuration does not exist.")
            }
        }
        try validateText(snapshot.activeProfileID, field: "active configuration identifier", maximum: Limit.identifierCharacters)
        try validateOptionalPath(snapshot.importedRepositoryPath, field: "imported repository", requireAbsolute: true)
        try validateOptionalPath(snapshot.backupConfiguration.location, field: "backup location", requireAbsolute: true)
        try validateOptionalPath(snapshot.encryptedSyncConfiguration.location, field: "encrypted sync location", requireAbsolute: true)
        try validateText(snapshot.backupConfiguration.remoteName ?? "", field: "backup remote name", maximum: Limit.shortTextCharacters)
        if snapshot.backupConfiguration.isEnabled, snapshot.backupConfiguration.location == nil {
            throw WorkspaceSnapshotValidationError.inconsistent("Backup is enabled without a local backup folder.")
        }
        if snapshot.encryptedSyncConfiguration.isEnabled, snapshot.encryptedSyncConfiguration.location == nil {
            throw WorkspaceSnapshotValidationError.inconsistent("Encrypted sync is enabled without an archive location.")
        }
        for date in [
            snapshot.backupConfiguration.lastExportAt,
            snapshot.encryptedSyncConfiguration.lastExportAt,
            snapshot.encryptedSyncConfiguration.lastImportAt,
        ].compactMap({ $0 }) {
            try validateDate(date, field: "configuration timestamp")
        }
    }

    private static func validateCounts(_ snapshot: WorkspaceSnapshot, mode: WorkspaceSnapshotValidationMode) throws {
        let desiredCounts = [
            snapshot.skills.count,
            snapshot.mcpServers.count,
            snapshot.profiles.count,
            snapshot.sources.count,
            snapshot.accountSurfaces.count,
            snapshot.connectors.count,
            snapshot.managedPolicies.count,
        ]
        guard desiredCounts.allSatisfy({ $0 <= Limit.recordsPerKind }),
            snapshot.plugins.count <= Limit.recordsPerKind,
            snapshot.marketplacePackages.count <= Limit.recordsPerKind,
            snapshot.targetObservations.count <= TargetSurface.allCases.count,
            snapshot.activities.count <= Limit.historyRecords,
            snapshot.operationReceipts.count <= Limit.historyRecords
        else {
            throw WorkspaceSnapshotValidationError.tooManyRecords
        }
        if mode == .portableImport {
            guard snapshot.plugins.isEmpty,
                snapshot.marketplacePackages.isEmpty,
                snapshot.targetObservations.isEmpty,
                snapshot.activities.isEmpty,
                snapshot.operationReceipts.isEmpty
            else {
                throw WorkspaceSnapshotValidationError.inconsistent("Portable state contains machine-derived inventory or history.")
            }
        }
    }

    private static func validate(_ skill: Skill, mode: WorkspaceSnapshotValidationMode) throws {
        try validateIdentifier(skill.id, field: "skill identifier", strictPortableName: skill.owned)
        try validateText(skill.name, field: "skill name", maximum: Limit.shortTextCharacters, required: true)
        try validateText(skill.displayName, field: "skill display name", maximum: Limit.shortTextCharacters, required: true)
        try validateText(skill.summary, field: "skill summary", maximum: Limit.longTextCharacters)
        try requireRedacted(skill.summary, field: "skill summary")
        if skill.owned {
            try validateManagedBundleIdentifier(skill.bundle)
        } else {
            try validateIdentifier(skill.bundle, field: "skill bundle")
        }
        guard skill.triggers.count <= Limit.childRecords,
            skill.files.count <= Limit.childRecords,
            skill.clients.count <= ClientKind.allCases.count,
            skill.validationCount >= 0
        else { throw WorkspaceSnapshotValidationError.tooManyRecords }
        try requireUnique(skill.clients.map(\.client), field: "skill client states")
        try requireUnique(skill.files, field: "skill files")
        try validateText(skill.scope, field: "skill scope", maximum: Limit.shortTextCharacters, required: true)
        for trigger in skill.triggers { try validateText(trigger, field: "skill trigger", maximum: Limit.longTextCharacters) }
        try validateText(skill.negativeTrigger, field: "negative trigger", maximum: Limit.longTextCharacters)
        for file in skill.files { try validateRelativePath(file, field: "skill file") }
        for client in skill.clients { try validate(client) }
        try validateScopedRoot(skill.projectRoot, scopeName: skill.scope, field: "skill project", mode: mode)
    }

    private static func validate(_ server: MCPServer, mode: WorkspaceSnapshotValidationMode) throws {
        try validateIdentifier(server.id, field: "MCP server identifier")
        try validateText(server.name, field: "MCP server name", maximum: Limit.shortTextCharacters, required: true)
        try validateText(server.summary, field: "MCP server summary", maximum: Limit.longTextCharacters)
        try validateText(server.endpoint, field: "MCP destination", maximum: Limit.pathCharacters, required: true)
        try validateText(server.authentication, field: "MCP authentication", maximum: Limit.shortTextCharacters)
        try requireRedacted(server.endpoint, field: "MCP destination")
        try requireRedacted(server.authentication, field: "MCP authentication")
        guard server.clients.count <= ClientKind.allCases.count,
            server.secretNames.count <= Limit.childRecords
        else { throw WorkspaceSnapshotValidationError.tooManyRecords }
        try requireUnique(server.clients.map(\.client), field: "MCP client states")
        try requireUnique(server.secretNames, field: "MCP secret reference names")
        for name in server.secretNames { try validateIdentifier(name, field: "MCP secret reference") }
        for client in server.clients { try validate(client) }
        try validateText(server.scope, field: "MCP scope", maximum: Limit.shortTextCharacters, required: true)
        if let command = server.repairCommand {
            try validateText(command, field: "MCP repair command", maximum: Limit.longTextCharacters)
            try requireRedacted(command, field: "MCP repair command")
        }
        try validateScopedRoot(server.projectRoot, scopeName: server.scope, field: "MCP project", mode: mode)

        guard server.isManagedDefinition else { return }
        if server.transport == .http {
            guard let components = URLComponents(string: server.endpoint),
                let scheme = components.scheme?.lowercased(),
                ["http", "https"].contains(scheme),
                components.host?.isEmpty == false,
                components.user == nil,
                components.password == nil,
                components.query == nil,
                components.fragment == nil
            else {
                throw WorkspaceSnapshotValidationError.inconsistent(
                    "A managed HTTP MCP destination is invalid or contains secret-bearing URL fields.")
            }
        }
    }

    private static func validate(_ plugin: Plugin) throws {
        try validateIdentifier(plugin.id, field: "plugin identifier")
        try validateText(plugin.name, field: "plugin name", maximum: Limit.shortTextCharacters, required: true)
        try validateText(plugin.summary, field: "plugin summary", maximum: Limit.longTextCharacters)
        try validateText(plugin.source, field: "plugin source", maximum: Limit.pathCharacters)
        try validateText(plugin.scope, field: "plugin scope", maximum: Limit.shortTextCharacters)
        try validateText(plugin.revision, field: "plugin revision", maximum: Limit.shortTextCharacters)
        for (value, field) in [(plugin.summary, "plugin summary"), (plugin.source, "plugin source")] {
            try requireRedacted(value, field: field)
        }
        guard plugin.skills.count <= Limit.childRecords,
            plugin.profiles.count <= Limit.childRecords,
            plugin.clients.count <= ClientKind.allCases.count
        else { throw WorkspaceSnapshotValidationError.tooManyRecords }
        try requireUnique(plugin.clients.map(\.client), field: "plugin client states")
        try requireUnique(plugin.skills, field: "plugin skill identifiers")
        try requireUnique(plugin.profiles, field: "plugin configuration identifiers")
        for value in plugin.skills {
            try validateText(value, field: "plugin skill identifier", maximum: Limit.identifierCharacters, required: true)
        }
        for value in plugin.profiles {
            try validateText(value, field: "plugin configuration identifier", maximum: Limit.identifierCharacters, required: true)
        }
        for client in plugin.clients { try validate(client) }
    }

    private static func validate(_ client: ClientState) throws {
        try validateText(client.detail, field: "client state detail", maximum: Limit.longTextCharacters)
        try validateText(client.revision ?? "", field: "client revision", maximum: Limit.shortTextCharacters)
        try requireRedacted(client.detail, field: "client state detail")
    }

    private static func validateProfiles(_ profiles: [ToolingProfile], mode: WorkspaceSnapshotValidationMode) throws {
        var byID: [String: ToolingProfile] = [:]
        for profile in profiles {
            try validateIdentifier(profile.id, field: "configuration identifier", strictPortableName: true)
            try validateText(profile.name, field: "configuration name", maximum: Limit.shortTextCharacters, required: true)
            try validateText(profile.summary, field: "configuration summary", maximum: Limit.longTextCharacters)
            try requireRedacted(profile.summary, field: "configuration summary")
            guard profile.checks.count <= Limit.childRecords,
                profile.enabledPlugins.count <= Limit.childRecords,
                profile.requiredMCPs.count <= Limit.childRecords
            else { throw WorkspaceSnapshotValidationError.tooManyRecords }
            try requireUnique(profile.checks.map(\.id), field: "configuration checks")
            try requireUnique(profile.enabledPlugins, field: "enabled plugin identifiers")
            try requireUnique(profile.requiredMCPs, field: "required MCP identifiers")
            for check in profile.checks {
                try validateIdentifier(check.id, field: "check identifier", strictPortableName: true)
                try validateText(check.name, field: "check name", maximum: Limit.shortTextCharacters, required: true)
                try validateText(check.detail, field: "check detail", maximum: Limit.longTextCharacters)
                try requireRedacted(check.detail, field: "check detail")
            }
            if let parent = profile.inheritedFrom {
                try validateIdentifier(parent, field: "inherited configuration identifier", strictPortableName: true)
            }
            for value in profile.enabledPlugins {
                try validateText(value, field: "enabled plugin identifier", maximum: Limit.identifierCharacters, required: true)
            }
            for value in profile.requiredMCPs {
                try validateText(value, field: "required MCP identifier", maximum: Limit.identifierCharacters, required: true)
            }
            try validateScopedRoot(profile.projectRoot, scopeName: profile.scope.displayName, field: "configuration project", mode: mode)
            byID[profile.id] = profile
        }
        for profile in profiles {
            if let parent = profile.inheritedFrom, byID[parent] == nil {
                throw WorkspaceSnapshotValidationError.inconsistent(
                    "Configuration \(profile.id) inherits from missing configuration \(parent).")
            }
            var visited: Set<String> = []
            var current: String? = profile.id
            while let id = current {
                guard visited.insert(id).inserted else {
                    throw WorkspaceSnapshotValidationError.inconsistent("Configuration inheritance contains a cycle at \(id).")
                }
                current = byID[id]?.inheritedFrom
            }
        }
    }

    private static func validate(_ source: ToolingSource, mode: WorkspaceSnapshotValidationMode) throws {
        try validateText(source.name, field: "source name", maximum: Limit.shortTextCharacters, required: true)
        try validateText(source.location, field: "source location", maximum: Limit.pathCharacters, required: true)
        try validateText(source.trustSummary, field: "source review", maximum: Limit.longTextCharacters)
        try validateText(source.lastRevision ?? "", field: "source revision", maximum: Limit.shortTextCharacters)
        if let date = source.lastRefreshedAt { try validateDate(date, field: "source refresh timestamp") }
        try requireRedacted(source.location, field: "source location")
        try requireRedacted(source.trustSummary, field: "source review")
        if mode == .portableImport {
            try validateWebURL(source.location, field: "portable source")
            return
        }
        switch source.kind {
        case .localFolder, .gitRepository:
            try validateOptionalPath(source.location, field: "local source", requireAbsolute: true)
        case .agentPlugins:
            if source.location.hasPrefix("/") {
                try validateOptionalPath(source.location, field: "Agent Plugins source", requireAbsolute: true)
            } else {
                try validateWebURL(source.location, field: "Agent Plugins source")
            }
        case .claudeMarketplace, .openAIPluginDirectory, .geminiExtensionGallery, .mcpRegistry:
            try validateWebURL(source.location, field: "catalog source")
        }
    }

    private static func validate(_ package: MarketplacePackage, sources: [ToolingSource]) throws {
        try validateText(package.id, field: "marketplace package identifier", maximum: Limit.identifierCharacters, required: true)
        try validateText(package.name, field: "marketplace package name", maximum: Limit.shortTextCharacters, required: true)
        try validateText(package.publisher, field: "marketplace publisher", maximum: Limit.shortTextCharacters, required: true)
        try validateText(package.summary, field: "marketplace package summary", maximum: Limit.longTextCharacters)
        try validateText(package.sourceName, field: "marketplace source name", maximum: Limit.shortTextCharacters, required: true)
        try validateText(package.revision ?? "", field: "marketplace revision", maximum: Limit.shortTextCharacters)
        try validateText(package.license ?? "", field: "marketplace license", maximum: Limit.longTextCharacters)
        try validateText(package.authentication ?? "", field: "marketplace authentication", maximum: Limit.shortTextCharacters)
        try validateText(package.trustSummary, field: "marketplace trust review", maximum: Limit.longTextCharacters)
        try validateText(package.location, field: "marketplace location", maximum: Limit.pathCharacters, required: true)
        for (value, field) in [
            (package.summary, "marketplace package summary"),
            (package.authentication ?? "", "marketplace authentication"),
            (package.trustSummary, "marketplace trust review"),
        ] {
            try requireRedacted(value, field: field)
        }
        guard !package.components.isEmpty,
            package.nativeInstalls.count <= Limit.childRecords
        else {
            throw WorkspaceSnapshotValidationError.inconsistent(
                "A marketplace package has no recognized components or too many install routes.")
        }
        try requireUnique(package.nativeInstalls.map(\.id), field: "marketplace install routes")
        if let sourceID = package.sourceID, !sources.contains(where: { $0.id == sourceID }) {
            throw WorkspaceSnapshotValidationError.inconsistent("A marketplace package references a missing source.")
        }
        try requireRedacted(package.location, field: "marketplace location")
        if let scheme = URLComponents(string: package.location)?.scheme?.lowercased() {
            guard ["http", "https"].contains(scheme) else {
                throw WorkspaceSnapshotValidationError.inconsistent("A marketplace package uses an unsupported location scheme.")
            }
            try validateWebURL(package.location, field: "marketplace package URL")
        } else if package.sourceID != nil {
            try validateOptionalPath(package.location, field: "marketplace package location", requireAbsolute: true)
        }
        for route in package.nativeInstalls {
            try validate(route, package: package)
        }
    }

    private static func validate(_ route: NativeInstall, package: MarketplacePackage) throws {
        let expectedExecutable: [ClientKind: String] = [.claude: "claude", .codex: "codex", .gemini: "gemini"]
        guard package.supportedClients.contains(route.client),
            route.executable == expectedExecutable[route.client],
            !route.arguments.isEmpty,
            route.arguments.count <= 256,
            (route.removalArguments?.count ?? 0) <= 256,
            ConfigurationValidator.editableScopes.contains(route.scope)
        else {
            throw WorkspaceSnapshotValidationError.inconsistent("A marketplace install route does not match its client or supported scope.")
        }
        try validateText(route.detail, field: "marketplace install detail", maximum: Limit.longTextCharacters)
        try requireRedacted(route.detail, field: "marketplace install detail")
        for argument in route.arguments + (route.removalArguments ?? []) {
            try validateText(argument, field: "marketplace install argument", maximum: Limit.shortTextCharacters, required: true)
            try requireRedacted(argument, field: "marketplace install argument")
        }
    }

    private static func validate(_ observation: TargetObservation) throws {
        let collections = [
            observation.configurationPaths,
            observation.discoveredSkills,
            observation.discoveredPlugins,
            observation.discoveredMCPServers,
            observation.notes,
        ]
        guard collections.allSatisfy({ $0.count <= Limit.childRecords }),
            observation.skillMetadata.count <= Limit.childRecords,
            observation.pluginMetadata.count <= Limit.childRecords,
            observation.mcpMetadata.count <= Limit.childRecords
        else {
            throw WorkspaceSnapshotValidationError.tooManyRecords
        }
        try requireUnique(observation.configurationPaths, field: "target configuration paths")
        try requireUnique(observation.discoveredSkills, field: "discovered skills")
        try requireUnique(observation.discoveredPlugins, field: "discovered plugins")
        try requireUnique(observation.discoveredMCPServers, field: "discovered MCP servers")
        try validateText(observation.version ?? "", field: "target version", maximum: Limit.shortTextCharacters)
        for path in observation.configurationPaths {
            try validateOptionalPath(path, field: "target configuration path", requireAbsolute: true)
        }
        for value in observation.discoveredSkills + observation.discoveredPlugins + observation.discoveredMCPServers {
            try validateText(value, field: "discovered component identifier", maximum: Limit.identifierCharacters, required: true)
        }
        for note in observation.notes {
            try validateText(note, field: "target note", maximum: Limit.longTextCharacters)
            try requireRedacted(note, field: "target note")
        }
        for (id, metadata) in observation.skillMetadata {
            try validateText(id, field: "observed skill identifier", maximum: Limit.identifierCharacters, required: true)
            try validateOptionalPath(metadata.path, field: "observed skill path", requireAbsolute: true)
            try validateText(metadata.source, field: "observed skill source", maximum: Limit.pathCharacters)
            try validateText(
                metadata.providerPluginID ?? "", field: "skill provider plugin identifier", maximum: Limit.identifierCharacters)
            try requireRedacted(metadata.source, field: "observed skill source")
        }
        for (id, metadata) in observation.pluginMetadata {
            try validateText(id, field: "observed plugin identifier", maximum: Limit.identifierCharacters, required: true)
            try validateText(metadata.name, field: "observed plugin name", maximum: Limit.shortTextCharacters, required: true)
            try validateText(metadata.source, field: "observed plugin source", maximum: Limit.pathCharacters)
            try validateText(metadata.scope, field: "observed plugin scope", maximum: Limit.shortTextCharacters)
            try validateText(metadata.revision ?? "", field: "observed plugin revision", maximum: Limit.shortTextCharacters)
            try requireRedacted(metadata.source, field: "observed plugin source")
            guard metadata.skillIDs.count <= Limit.childRecords,
                metadata.mcpServerIDs.count <= Limit.childRecords
            else { throw WorkspaceSnapshotValidationError.tooManyRecords }
            try requireUnique(metadata.skillIDs, field: "observed plugin skills")
            try requireUnique(metadata.mcpServerIDs, field: "observed plugin MCP servers")
        }
        for (id, metadata) in observation.mcpMetadata {
            try validateText(id, field: "observed MCP identifier", maximum: Limit.identifierCharacters, required: true)
            try validateText(metadata.transport, field: "observed MCP transport", maximum: Limit.shortTextCharacters)
            try validateText(metadata.authentication, field: "observed MCP authentication", maximum: Limit.shortTextCharacters)
            try validateText(metadata.source, field: "observed MCP source", maximum: Limit.pathCharacters)
            try requireRedacted(metadata.authentication, field: "observed MCP authentication")
            try requireRedacted(metadata.source, field: "observed MCP source")
        }
        try validateDate(observation.lastScannedAt, field: "target scan timestamp")
    }

    private static func validate(_ activity: ActivityReceipt) throws {
        try validateText(activity.title, field: "activity title", maximum: Limit.shortTextCharacters, required: true)
        try validateText(activity.detail, field: "activity detail", maximum: Limit.longTextCharacters)
        try validateText(activity.command ?? "", field: "activity command", maximum: Limit.longTextCharacters)
        guard activity.affectedPaths.count <= Limit.childRecords else { throw WorkspaceSnapshotValidationError.tooManyRecords }
        for path in activity.affectedPaths { try validateOptionalPath(path, field: "activity path", requireAbsolute: true) }
        if let duration = activity.duration, !duration.isFinite || duration < 0 {
            throw WorkspaceSnapshotValidationError.invalidField("activity duration")
        }
        try validateDate(activity.date, field: "activity timestamp")
        try requireRedacted(activity.title, field: "activity title")
        try requireRedacted(activity.detail, field: "activity detail")
        if let command = activity.command { try requireRedacted(command, field: "activity command") }
    }

    private static func validate(_ receipt: OperationReceipt) throws {
        try validateText(receipt.title, field: "operation title", maximum: Limit.shortTextCharacters, required: true)
        try validateText(receipt.verificationSummary, field: "operation verification", maximum: Limit.longTextCharacters)
        guard receipt.targetSurfaces.count <= TargetSurface.allCases.count,
            receipt.results.count <= Limit.childRecords
        else { throw WorkspaceSnapshotValidationError.tooManyRecords }
        try requireUnique(receipt.targetSurfaces, field: "operation target surfaces")
        try requireUnique(receipt.results.map(\.id), field: "operation result identifiers")
        try requireUnique(receipt.results.map(\.stepID), field: "operation step results")
        try validateDate(receipt.createdAt, field: "operation timestamp")
        try requireRedacted(receipt.verificationSummary, field: "operation verification")
        for result in receipt.results {
            try validateText(result.output, field: "operation output", maximum: Limit.longTextCharacters)
            try requireRedacted(result.output, field: "operation output")
            try validateDate(result.startedAt, field: "operation start timestamp")
            try validateDate(result.finishedAt, field: "operation finish timestamp")
            guard result.finishedAt >= result.startedAt else {
                throw WorkspaceSnapshotValidationError.inconsistent("An operation result finishes before it starts.")
            }
        }
    }

    private static func validate(_ connector: ConnectorRecord) throws {
        try validateText(connector.name, field: "connection name", maximum: Limit.shortTextCharacters, required: true)
        try validateText(connector.provider, field: "connection provider", maximum: Limit.shortTextCharacters)
        try validateText(connector.description, field: "connection description", maximum: Limit.longTextCharacters)
        try requireRedacted(connector.description, field: "connection description")
        guard connector.secretReferenceNames.count <= Limit.childRecords,
            !connector.bindings.isEmpty,
            connector.bindings.count <= Limit.childRecords
        else { throw WorkspaceSnapshotValidationError.tooManyRecords }
        try requireUnique(connector.secretReferenceNames, field: "connection secret reference names")
        try requireUnique(connector.bindings.map(\.id), field: "connection bindings")
        try requireUnique(
            connector.bindings.map { "\($0.target.rawValue)|\($0.scope.rawValue)" }, field: "connection target and scope bindings")
        for name in connector.secretReferenceNames { try validateIdentifier(name, field: "connection secret reference") }
        for binding in connector.bindings {
            try validateText(binding.guidance, field: "connection guidance", maximum: Limit.longTextCharacters)
            try requireRedacted(binding.guidance, field: "connection guidance")
            if let date = binding.lastVerifiedAt { try validateDate(date, field: "connection verification timestamp") }
            do {
                _ = try ConnectorValidator.validate(
                    name: connector.name,
                    provider: connector.provider,
                    target: binding.target,
                    scope: binding.scope,
                    secretReferenceNames: connector.secretReferenceNames
                )
            } catch {
                throw WorkspaceSnapshotValidationError.inconsistent(error.localizedDescription)
            }
        }
    }

    private static func validate(_ account: AccountSurface) throws {
        guard account.surface.isCloud else {
            throw WorkspaceSnapshotValidationError.inconsistent("An account check targets a local app.")
        }
        try validateText(account.name, field: "account name", maximum: Limit.shortTextCharacters, required: true)
        try validateText(account.guidance, field: "account guidance", maximum: Limit.longTextCharacters)
        try requireRedacted(account.guidance, field: "account guidance")
        if let date = account.lastVerifiedAt { try validateDate(date, field: "account verification timestamp") }
        guard let value = account.verificationURL else { return }
        try validateText(value, field: "account settings URL", maximum: Limit.pathCharacters, required: true)
        guard let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil,
            components.query == nil
        else {
            throw WorkspaceSnapshotValidationError.inconsistent("An account settings URL is not a credential-free HTTPS URL.")
        }
    }

    private static func validate(_ policy: ManagedPolicy, mode: WorkspaceSnapshotValidationMode) throws {
        try validateIdentifier(policy.id, field: "policy identifier", strictPortableName: true)
        try validateText(policy.name, field: "policy name", maximum: Limit.shortTextCharacters, required: true)
        try validateDate(policy.importedAt, field: "policy import timestamp")
        if mode == .portableImport {
            try validateRelativePath(policy.sourcePath, field: "policy source")
        } else {
            try validateOptionalPath(policy.sourcePath, field: "policy source", requireAbsolute: true)
        }
        for values in [policy.requiredPluginIDs, policy.requiredMCPIDs, policy.blockedPluginIDs] {
            guard values.count <= Limit.childRecords else { throw WorkspaceSnapshotValidationError.tooManyRecords }
            try requireUnique(values, field: "policy rules")
            for value in values { try validateIdentifier(value, field: "policy rule") }
        }
        guard Set(policy.requiredPluginIDs).isDisjoint(with: Set(policy.blockedPluginIDs)) else {
            throw WorkspaceSnapshotValidationError.inconsistent("A policy both requires and blocks the same plugin.")
        }
        try validateProfiles(policy.profiles, mode: mode)
    }

    private static func validateIdentifier(_ value: String, field: String, strictPortableName: Bool = false) throws {
        try validateText(value, field: field, maximum: Limit.identifierCharacters, required: true)
        guard !value.hasPrefix("-"), !value.contains("/") else {
            throw WorkspaceSnapshotValidationError.invalidField(field)
        }
        if strictPortableName {
            guard (try? WorkspaceLibrary.normalizedIdentifier(value)) == value else {
                throw WorkspaceSnapshotValidationError.invalidField(field)
            }
        }
    }

    private static func validateManagedBundleIdentifier(_ value: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !value.isEmpty,
            value.count <= WorkspaceLibrary.maximumIdentifierLength + "local-".count,
            value.unicodeScalars.allSatisfy(allowed.contains),
            !value.hasPrefix("-"),
            !value.hasSuffix("-"),
            !value.contains("--")
        else {
            throw WorkspaceSnapshotValidationError.invalidField("skill bundle")
        }
    }

    private static func validateText(_ value: String, field: String, maximum: Int, required: Bool = false) throws {
        guard !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            value.count <= maximum,
            !value.unicodeScalars.contains(where: isUnsafeControlCharacter)
        else {
            throw WorkspaceSnapshotValidationError.invalidField(field)
        }
    }

    private static func requireRedacted(_ value: String, field: String) throws {
        guard !SensitiveValueRedactor.containsCredentialValue(in: value) else {
            throw WorkspaceSnapshotValidationError.inconsistent("The \(field) contains credential-like material that must not be stored.")
        }
    }

    private static func validateDate(_ value: Date, field: String) throws {
        guard value.timeIntervalSinceReferenceDate.isFinite else {
            throw WorkspaceSnapshotValidationError.invalidField(field)
        }
    }

    private static func validateWebURL(_ value: String, field: String) throws {
        guard let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil,
            components.query == nil
        else {
            throw WorkspaceSnapshotValidationError.inconsistent("The \(field) is not a credential-free web URL.")
        }
    }

    private static func validateScopedRoot(_ value: String?, scopeName: String, field: String, mode: WorkspaceSnapshotValidationMode) throws
    {
        let requiresRoot = [ToolingScope.project.displayName, ToolingScope.localProject.displayName, ToolingScope.workspace.displayName]
            .contains(scopeName)
        if mode == .localState, requiresRoot, value == nil {
            throw WorkspaceSnapshotValidationError.inconsistent("The \(field) folder is missing.")
        }
        try validateOptionalPath(value, field: field, requireAbsolute: true)
    }

    private static func validateOptionalPath(_ value: String?, field: String, requireAbsolute: Bool) throws {
        guard let value else { return }
        try validateText(value, field: field, maximum: Limit.pathCharacters, required: true)
        guard !requireAbsolute || value.hasPrefix("/") else { throw WorkspaceSnapshotValidationError.invalidField(field) }
    }

    private static func validateRelativePath(_ value: String, field: String) throws {
        try validateText(value, field: field, maximum: Limit.pathCharacters, required: true)
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.hasPrefix("/"), !value.hasSuffix("/"),
            !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw WorkspaceSnapshotValidationError.invalidField(field)
        }
    }

    private static func requireUnique<Value: Hashable>(_ values: [Value], field: String) throws {
        guard Set(values).count == values.count else { throw WorkspaceSnapshotValidationError.duplicate(field) }
    }

    private static func isUnsafeControlCharacter(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 && ![0x09, 0x0A, 0x0D].contains(scalar.value)
    }
}

enum WorkspaceSnapshotValidationError: LocalizedError, Sendable {
    case tooManyRecords
    case duplicate(String)
    case invalidField(String)
    case inconsistent(String)

    var errorDescription: String? {
        switch self {
        case .tooManyRecords: "Workspace state exceeds the supported record limits."
        case .duplicate(let field): "Workspace state contains duplicate \(field)."
        case .invalidField(let field): "Workspace state contains an invalid \(field)."
        case .inconsistent(let reason): "Workspace state is inconsistent. \(reason)"
        }
    }
}

extension WorkspaceSnapshot {
    func portableDesiredState() -> WorkspaceSnapshot {
        var portable = self
        portable.skills = skills.filter(\.owned).map { skill in
            var copy = skill
            copy.projectRoot = nil
            copy.clients = skill.clients.map {
                ClientState(client: $0.client, state: .pending, detail: "Selected installation target")
            }
            return copy
        }
        portable.mcpServers = mcpServers.filter(\.isManagedDefinition).map { server in
            var copy = server
            copy.projectRoot = nil
            copy.clients = server.clients.map {
                ClientState(client: $0.client, state: .pending, detail: "Selected configuration target")
            }
            copy.repairCommand = nil
            return copy
        }
        portable.plugins = []
        portable.profiles = profiles.map { profile in
            var copy = profile
            copy.projectRoot = nil
            return copy
        }
        portable.activities = []
        portable.operationReceipts = []
        portable.targetObservations = []
        portable.sources = sources.filter { source in
            guard let scheme = URLComponents(string: source.location)?.scheme?.lowercased() else { return false }
            return ["http", "https"].contains(scheme)
        }
        portable.marketplacePackages = []
        portable.accountSurfaces = accountSurfaces.map { account in
            var copy = account
            copy.status = .manual
            copy.lastVerifiedAt = nil
            return copy
        }
        portable.connectors = connectors.map { connector in
            var copy = connector
            copy.bindings = connector.bindings.map { binding in
                var copy = binding
                copy.status = .manual
                copy.lastVerifiedAt = nil
                return copy
            }
            return copy
        }
        portable.importedRepositoryPath = nil
        portable.backupConfiguration = .init()
        portable.encryptedSyncConfiguration = .init()
        portable.managedPolicies = managedPolicies.map { policy in
            var copy = policy
            copy.sourcePath = URL(fileURLWithPath: policy.sourcePath).lastPathComponent
            copy.profiles = policy.profiles.map { profile in
                var copy = profile
                copy.projectRoot = nil
                return copy
            }
            return copy
        }
        return portable
    }
}

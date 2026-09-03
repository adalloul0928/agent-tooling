import Foundation
import Observation

@MainActor
@Observable
public final class AppModel {
    public private(set) var skills: [Skill]
    public private(set) var mcpServers: [MCPServer]
    public private(set) var plugins: [Plugin]
    public private(set) var profiles: [ToolingProfile]
    /// Reusable shelves. There is deliberately no "current" collection: being
    /// active belongs to a configuration, not to the material it is built from.
    public private(set) var collections: [ToolingCollection]
    /// Tags filter. They never change what is installed.
    public private(set) var tagAssignments: [TagAssignment]
    public private(set) var activities: [ActivityReceipt]
    public private(set) var syncStages: [SyncStage]
    public private(set) var targetObservations: [TargetObservation]
    public private(set) var sources: [ToolingSource]
    public private(set) var marketplacePackages: [MarketplacePackage]
    public private(set) var accountSurfaces: [AccountSurface]
    public private(set) var connectors: [ConnectorRecord]
    public private(set) var operationReceipts: [OperationReceipt]
    /// Installed copies compared against the fingerprint recorded when they
    /// were reviewed. Refreshed by `runDoctor()`.
    public private(set) var installDrift: [InstalledPackageDrift] = []
    public private(set) var mcpRuntimeStatuses: [MCPRuntimeStatus] = []
    public private(set) var mcpRuntimeServers: [MCPRuntimeServer] = []
    public private(set) var pendingPlan: OperationPlan?
    public private(set) var backupImportPreview: BackupImportPreview?
    public private(set) var insightsReport: InsightsReport?

    public private(set) var activeProfileID: String
    /// A Git repository can be imported as a source or backup. It is not the
    /// database or a prerequisite for using the app.
    public private(set) var repositoryPath: String
    public private(set) var automaticallyCheckHealth = true
    public private(set) var isSyncing = false
    public private(set) var isRunningDoctor = false
    public private(set) var isExecutingPlan = false
    public private(set) var isRefreshingMarketplace = false
    public private(set) var isGeneratingSkill = false
    public private(set) var isScanningInsights = false
    public private(set) var lastError: String?
    public private(set) var workspacePath: String
    public private(set) var backupConfiguration: BackupConfiguration
    public private(set) var encryptedSyncConfiguration: EncryptedSyncConfiguration
    public private(set) var managedPolicies: [ManagedPolicy]

    private let store: WorkspaceStore
    private let library: WorkspaceLibrary
    private let engine: OperationEngine
    private let adapters: ClientAdapterRegistry
    private let runner: any CommandRunning
    private let homeURL: URL
    private let marketplace: MarketplaceService
    private let marketplaceProviders: [any MarketplaceProvider]
    private let backupService: BackupService
    private let encryptedSyncService: EncryptedSyncService
    private let policyService: PolicyService
    private let codexSkillDraftService: CodexSkillDraftService
    private let toolingInsightsService: ToolingInsightsService
    private var pendingRestoreSnapshot: WorkspaceSnapshot?
    private var pendingEncryptedSyncSnapshot: WorkspaceSnapshot?
    private var pendingSkillAdoption: SkillAdoption?
    public private(set) var encryptedSyncImportPreview: EncryptedSyncImportPreview?
    private var hasBootstrapped = false

    public init(
        store: WorkspaceStore,
        runner: any CommandRunning = ProcessCommandRunner(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        marketplaceProviders: [any MarketplaceProvider] = [],
        codexSkillDraftService: CodexSkillDraftService? = nil,
        toolingInsightsService: ToolingInsightsService = ToolingInsightsService()
    ) throws {
        self.store = store
        self.library = WorkspaceLibrary(store: store)
        self.runner = runner
        self.homeURL = homeURL
        self.engine = OperationEngine(store: store, runner: runner, homeURL: homeURL)
        self.adapters = ClientAdapterRegistry()
        self.marketplace = MarketplaceService()
        self.marketplaceProviders = marketplaceProviders
        self.backupService = BackupService(store: store)
        self.encryptedSyncService = EncryptedSyncService(store: store)
        self.policyService = PolicyService()
        self.codexSkillDraftService =
            codexSkillDraftService
            ?? CodexSkillDraftService(stagingRootURL: store.cacheURL.appending(path: "skill-drafts", directoryHint: .isDirectory))
        self.toolingInsightsService = toolingInsightsService
        self.workspacePath = store.rootURL.path(percentEncoded: false)
        self.insightsReport = try? store.loadInsightsReport()

        let snapshot = try store.loadWorkspaceSnapshot() ?? Self.initialSnapshot()
        try WorkspaceSnapshotValidator.validate(snapshot, mode: .localState)
        self.skills = snapshot.skills
        self.mcpServers = snapshot.mcpServers
        self.plugins = snapshot.plugins
        self.profiles = snapshot.profiles
        self.collections = snapshot.collections
        self.tagAssignments = snapshot.tagAssignments
        self.activities = snapshot.activities
        self.operationReceipts = snapshot.operationReceipts
        self.targetObservations = snapshot.targetObservations
        self.sources = snapshot.sources.isEmpty ? marketplace.defaultSources() : snapshot.sources
        self.marketplacePackages = snapshot.marketplacePackages
        self.accountSurfaces = snapshot.accountSurfaces
        self.connectors = snapshot.connectors
        self.activeProfileID = snapshot.activeProfileID
        self.repositoryPath = snapshot.importedRepositoryPath ?? store.rootURL.path(percentEncoded: false)
        self.backupConfiguration = snapshot.backupConfiguration
        self.encryptedSyncConfiguration = snapshot.encryptedSyncConfiguration
        self.automaticallyCheckHealth = snapshot.preferences.automaticallyCheckHealth
        self.managedPolicies = snapshot.managedPolicies
        self.syncStages = Self.syncStages(from: snapshot.targetObservations)
    }

    public static func live(
        runner: any CommandRunning = ProcessCommandRunner(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> AppModel {
        try AppModel(
            store: WorkspaceStore(),
            runner: runner,
            homeURL: homeURL,
            marketplaceProviders: builtInMarketplaceProviders()
        )
    }

    public static func builtInMarketplaceProviders() -> [any MarketplaceProvider] {
        guard let provider = try? OfficialMCPRegistryProvider() else { return [] }
        return [provider]
    }

    public var activeProfile: ToolingProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    public var isBusy: Bool {
        isSyncing || isRunningDoctor || isExecutingPlan || isRefreshingMarketplace || isGeneratingSkill
    }

    /// Disables competing commands while a change is running or awaiting
    /// review. A prepared plan is a snapshot of source and destination state;
    /// allowing another action to replace or invalidate it would make the
    /// review sheet misleading.
    public var isInteractionLocked: Bool {
        isBusy || pendingPlan != nil
    }

    public var attentionCount: Int {
        let mcpAttention = mcpServers.filter { $0.aggregateState == .attention || $0.aggregateState == .unavailable }.count
        let profileAttention = activeProfile?.checks.filter { $0.state == .attention || $0.state == .unavailable }.count ?? 0
        let clientAttention = targetObservations.filter { !$0.isCommandAvailable }.count
        return mcpAttention + profileAttention + clientAttention
    }

    @discardableResult
    public func setAutomaticallyCheckHealth(_ value: Bool) -> Bool {
        var candidate = currentSnapshot()
        candidate.preferences.automaticallyCheckHealth = value
        return commit(candidate)
    }

    public func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        if automaticallyCheckHealth {
            await runDoctor()
        }
        await refreshMCPRuntimes()
        await refreshMarketplace()
    }

    /// Detects optional MCP runtime support without changing workloads. Direct
    /// native client configuration remains available even when ToolHive is not
    /// installed.
    public func refreshMCPRuntimes() async {
        let direct = DirectMCPRuntimeProvider()
        let toolHive = ToolHiveMCPRuntimeProvider(runner: runner)
        async let directStatus = direct.status()
        async let toolHiveStatus = toolHive.status()
        let statuses = await (directStatus, toolHiveStatus)
        mcpRuntimeStatuses = [statuses.0, statuses.1]
        do {
            mcpRuntimeServers = try await toolHive.servers()
        } catch {
            mcpRuntimeServers = []
        }
    }

    /// Reviews bounded, recent local conversation history on explicit request.
    /// Raw messages are tokenized and discarded inside the service; only the
    /// aggregate report is stored in this machine's local workspace database.
    public func runInsightsScan(options: InsightScanOptions) async {
        guard !isScanningInsights else { return }
        guard !options.clients.intersection([.claude, .codex]).isEmpty else {
            presentError("Select Claude Code, Codex, or both before scanning recent work.")
            return
        }

        isScanningInsights = true
        lastError = nil
        defer { isScanningInsights = false }

        if options.includeMarketplaceRecommendations, !isRefreshingMarketplace {
            await refreshMarketplace()
        }
        guard !Task.isCancelled else { return }

        let report = await toolingInsightsService.scan(
            options: options,
            skills: skills,
            marketplacePackages: marketplacePackages,
            homeURL: homeURL,
            marketplaceProviders: marketplaceProviders
        )
        guard !Task.isCancelled else { return }
        do {
            try store.saveInsightsReport(report)
            insightsReport = report
            let hasIncompleteCoverage =
                report.coverage.isEmpty
                || report.coverage.contains {
                    $0.status != .scanned
                }
            activities.insert(
                ActivityReceipt(
                    kind: .validation,
                    title: "Tooling insights updated",
                    detail:
                        "Reviewed \(report.conversationsScanned) bounded conversation\(report.conversationsScanned == 1 ? "" : "s") and saved only aggregate usage, quality, and recommendation data.",
                    date: report.generatedAt,
                    state: hasIncompleteCoverage ? .attention : .healthy
                ),
                at: 0
            )
            trimHistory()
            try persistOrThrow()
        } catch {
            presentError("The insights report could not be saved locally: \(error.localizedDescription)")
        }
    }

    public func clearInsightsReport() {
        guard !isScanningInsights else { return }
        do {
            try store.removeInsightsReport()
            insightsReport = nil
        } catch {
            presentError("The insights report could not be removed: \(error.localizedDescription)")
        }
    }

    /// Retains the exact catalog record attached to an insights recommendation
    /// so Marketplace can review it without repeating the search. This only
    /// updates local catalog metadata; it never prepares or executes an install.
    @discardableResult
    public func retainMarketplaceRecommendation(
        _ package: MarketplacePackage,
        expectedPackageID: String
    ) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard package.id == expectedPackageID else {
            presentError("The marketplace recommendation no longer matches its catalog package.")
            return false
        }

        // Installation state is observed from client scans and native catalogs,
        // never trusted from a persisted recommendation report.
        var retained = package
        retained.isInstalled = false
        retained.nativeInstalls = retained.nativeInstalls.map { route in
            var route = route
            route.isInstalled = false
            return route
        }

        var candidate = currentSnapshot()
        candidate.marketplacePackages = marketplace.deduplicatedPackages(
            candidate.marketplacePackages + [retained]
        )
        return commit(candidate)
    }

    @discardableResult
    public func exportDiagnostics(to destination: URL, appVersion: String) -> Bool {
        do {
            let exporter = DiagnosticBundleExporter(homeURL: homeURL)
            let manifest = exporter.manifest(
                snapshot: currentSnapshot(),
                appVersion: appVersion,
                errors: lastError.map { [$0] } ?? []
            )
            try exporter.export(manifest, to: destination)
            return true
        } catch {
            presentError("The support bundle could not be exported: \(error.localizedDescription)")
            return false
        }
    }

    /// Reads real client state and never mutates a client configuration.
    public func runDoctor() async {
        guard ensureReadyForChange() else { return }
        isRunningDoctor = true
        defer { isRunningDoctor = false }
        let start = Date.now
        let observations = await adapters.scanAll(homeURL: homeURL, runner: runner)
        let compiled = InventoryCompiler.compile(observations: observations, homeURL: homeURL)
        let missing = observations.filter { !$0.isCommandAvailable }.map { $0.surface.displayName }
        // Compare every install this app can prove it made against the
        // fingerprint recorded when the operator reviewed it. Drift is
        // reported as information; it never changes the setup-check state.
        installDrift = await InstalledPackageDriftInspector.inspect(store: store)
        let driftSummary = InstalledPackageDriftInspector.summary(for: installDrift)
        let state: HealthState = missing.isEmpty ? .healthy : .attention
        var candidate = currentSnapshot()
        candidate.targetObservations = observations
        candidate.skills = mergeSkills(existing: candidate.skills, observed: compiled.skills)
        candidate.mcpServers = mergeMCPServers(existing: candidate.mcpServers, observed: compiled.mcpServers)
        candidate.plugins = compiled.plugins
        candidate.activities.insert(
            ActivityReceipt(
                kind: .validation,
                title: "Setup check completed",
                detail: [
                    missing.isEmpty
                        ? "Claude Code, Codex, and Gemini CLI were inspected from local state."
                        : "Not found: \(Array(Set(missing)).sorted().joined(separator: ", ")). Existing configuration was still inspected.",
                    driftSummary,
                ].compactMap { $0 }.joined(separator: " "),
                date: start,
                state: state,
                command: "Local configuration inspection",
                duration: Date.now.timeIntervalSince(start),
                affectedPaths: Array(Set(observations.flatMap(\.configurationPaths))).sorted()
            ),
            at: 0
        )
        candidate.activities = Array(candidate.activities.prefix(200))
        _ = commit(candidate)
    }

    /// Builds a reviewable plan. It does not perform changes until the user
    /// confirms the plan through `executePendingPlan()`.
    public func runSync() async {
        guard ensureReadyForChange() else { return }
        isSyncing = true
        defer { isSyncing = false }
        let installable = skills.filter { $0.owned && !$0.clients.isEmpty }
        var steps: [OperationStep] = []
        var selectedClients = Set<ClientKind>()
        var scopes = Set<ToolingScope>()
        for skill in installable {
            let configuredTargets = Set(skill.clients.map(\.client))
            do {
                let plan = try library.installPlan(for: skill, targets: configuredTargets, homeURL: homeURL)
                steps.append(contentsOf: plan.steps)
                selectedClients.formUnion(configuredTargets)
                scopes.insert(plan.scope)
            } catch {
                lastError = "Could not prepare \(skill.displayName): \(error.localizedDescription)"
                return
            }
        }
        guard !steps.isEmpty else {
            pendingPlan = OperationPlan(
                kind: .installSkill,
                title: "Sync local library",
                summary: skills.contains(where: \.owned)
                    ? "Choose at least one app for a local skill before syncing."
                    : "Create or import a skill first. Agent Tooling will never fabricate sample content to sync.",
                steps: [
                    OperationStep(
                        kind: .manual,
                        title: skills.contains(where: \.owned) ? "No app selected" : "No local skills to install",
                        detail: skills.contains(where: \.owned)
                            ? "Open a local skill, choose Claude Code, Codex, or Gemini CLI, then sync again."
                            : "Create a local skill or import a package, then choose the targets and scope.",
                        requiresUserAction: true
                    )
                ],
                requiresConfirmation: false
            )
            return
        }
        pendingPlan = OperationPlan(
            kind: .installSkill,
            title: "Sync local skills to selected clients",
            summary:
                "Review \(steps.count) local file changes. GitHub is not involved; every existing target is installed independently and partial success is retained.",
            targetSurfaces: selectedClients.sorted(by: { $0.rawValue < $1.rawValue }).map { surface(for: $0) },
            scope: scopes.count == 1 ? scopes.first ?? .user : .workspace,
            steps: steps + [
                OperationStep(
                    kind: .scan, title: "Verify local installations",
                    detail: "Re-scan each target's supported native skill locations after the write operations.", isReversible: false)
            ],
            requiresConfirmation: true
        )
        syncStages = syncStages.map { stage in
            var updated = stage
            if ["claude", "codex", "gemini"].contains(stage.id) {
                updated.state = .waiting
                updated.detail = "Awaiting review"
            }
            return updated
        }
    }

    public func executePendingPlan() async {
        guard let pendingPlan, !isBusy else { return }
        isExecutingPlan = true
        do {
            try store.saveEntity(
                pendingPlan,
                id: pendingPlan.id.uuidString.lowercased(),
                domain: .plans
            )
        } catch {
            isExecutingPlan = false
            presentError("The approved plan could not be recorded before execution: \(error.localizedDescription)")
            return
        }
        // Receipt redaction is a product invariant, not a user preference.
        let receipt = await engine.execute(pendingPlan)
        operationReceipts.insert(receipt, at: 0)
        activities.insert(activity(from: receipt, plan: pendingPlan), at: 0)
        trimHistory()
        self.pendingPlan = nil
        let completedRequiredSteps = operationCompletedRequiredSteps(plan: pendingPlan, receipt: receipt)
        if pendingPlan.kind == .exportBackup, completedRequiredSteps {
            backupConfiguration.isEnabled = true
            backupConfiguration.location = backupService.exportURL.path(percentEncoded: false)
            backupConfiguration.lastExportAt = .now
        }
        if pendingPlan.kind == .restoreBackup, let restored = pendingRestoreSnapshot, completedRequiredSteps {
            apply(restoredSnapshot: restored)
            backupImportPreview = nil
            pendingRestoreSnapshot = nil
        }
        if pendingPlan.kind == .exportEncryptedSync, completedRequiredSteps {
            encryptedSyncConfiguration.isEnabled = true
            encryptedSyncConfiguration.location = pendingPlan.steps.first(where: { $0.kind == .writeEncryptedArchive })?.destinationPath
            encryptedSyncConfiguration.lastExportAt = .now
        }
        if pendingPlan.kind == .restoreEncryptedSync, let restored = pendingEncryptedSyncSnapshot, completedRequiredSteps {
            apply(restoredSnapshot: restored)
            encryptedSyncConfiguration.isEnabled = true
            encryptedSyncConfiguration.lastImportAt = .now
            encryptedSyncImportPreview = nil
            pendingEncryptedSyncSnapshot = nil
        }
        if let adoption = pendingSkillAdoption, adoption.plan.id == pendingPlan.id {
            if completedRequiredSteps { applyAdoptedSkills(adoption) }
            library.discardAdoption(adoption)
            pendingSkillAdoption = nil
        }
        isExecutingPlan = false
        if !Task.isCancelled {
            await runDoctor()
        }
        persist()
    }

    private func operationCompletedRequiredSteps(plan: OperationPlan, receipt: OperationReceipt) -> Bool {
        guard receipt.planID == plan.id else { return false }
        let results = Dictionary(uniqueKeysWithValues: receipt.results.map { ($0.stepID, $0.status) })
        return plan.steps.allSatisfy { step in
            guard let status = results[step.id] else { return false }
            return step.requiresUserAction || step.kind == .manual || step.kind == .openURL
                ? status == .manual || status == .succeeded
                : status == .succeeded
        }
    }

    public func discardPendingPlan() {
        guard !isExecutingPlan else { return }
        pendingPlan = nil
        pendingRestoreSnapshot = nil
        pendingEncryptedSyncSnapshot = nil
        if let adoption = pendingSkillAdoption {
            library.discardAdoption(adoption)
            pendingSkillAdoption = nil
        }
    }

    /// Presents a plan composed outside the model — a stack of picks reviewed
    /// together — through the same review sheet. Composition grants no new
    /// authority: the engine still checks every command against its fixed
    /// allowlist before anything runs.
    @discardableResult
    public func reviewComposedPlan(_ plan: OperationPlan) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard !plan.steps.isEmpty else {
            lastError = "There is nothing to review in this plan."
            return false
        }
        pendingPlan = plan
        return true
    }

    public func presentError(_ message: String) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = normalized.isEmpty ? "An unknown error occurred." : normalized
    }

    public func dismissError() {
        lastError = nil
    }

    @discardableResult
    public func createSkill(from draft: SkillDraft) -> Skill? {
        guard ensureReadyForChange() else { return nil }
        let previousSnapshot = currentSnapshot()
        var createdResult: CreatedSkill?
        do {
            let created = try library.createSkill(from: draft)
            createdResult = created
            var skill = created.skill
            skill.validationCount = try library.validateSkill(skill)
            skills.removeAll { $0.id == skill.id }
            skills.insert(skill, at: 0)
            activities.insert(
                ActivityReceipt(
                    kind: .configuration,
                    title: "\(skill.displayName) created locally",
                    detail: "Portable package saved in Agent Tooling's managed library. Review installation before changing any client.",
                    date: .now,
                    state: .healthy,
                    affectedPaths: [
                        created.skillURL.path(percentEncoded: false),
                        created.packageURL.appending(path: "plugin.json").path(percentEncoded: false),
                    ]
                ),
                at: 0
            )
            prepareInstallPlanAfterSaving(skill: skill, draft: draft)
            try persistOrThrow()
            return skill
        } catch {
            let persistenceError = error
            pendingPlan = nil
            applyPersisted(previousSnapshot)
            if let createdResult {
                do {
                    try library.rollbackCreation(createdResult)
                    lastError = persistenceError.localizedDescription
                } catch {
                    lastError = "Saving the new skill failed, and its package could not be removed safely: \(error.localizedDescription)"
                }
            } else {
                lastError = persistenceError.localizedDescription
            }
            return nil
        }
    }

    @discardableResult
    public func saveCodexSkillDraftRequest(_ request: CodexSkillDraftRequest) -> Bool {
        do {
            try store.saveCodexSkillDraftRequest(request)
            return true
        } catch {
            presentError("The Codex skill request could not be saved: \(error.localizedDescription)")
            return false
        }
    }

    public func loadCodexSkillDraftRequest(id: UUID) -> CodexSkillDraftRequest? {
        do {
            guard let request = try store.loadCodexSkillDraftRequest(id: id) else {
                presentError("The requested Codex skill draft is no longer available.")
                return nil
            }
            return request
        } catch {
            presentError("The Codex skill request could not be opened: \(error.localizedDescription)")
            return nil
        }
    }

    public func generateCodexSkillDraft(_ request: CodexSkillDraftRequest) async -> CodexSkillDraftResult? {
        guard ensureReadyForChange() else { return nil }
        guard saveCodexSkillDraftRequest(request) else { return nil }
        isGeneratingSkill = true
        defer { isGeneratingSkill = false }
        do {
            return try await codexSkillDraftService.createDraft(request)
        } catch is CancellationError {
            return nil
        } catch {
            presentError(error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    public func adoptCodexSkillDraft(_ result: CodexSkillDraftResult) async -> Skill? {
        guard ensureReadyForChange() else { return nil }
        let previousSnapshot = currentSnapshot()
        var createdResult: CreatedSkill?
        do {
            let created = try library.adoptCodexDraft(result)
            createdResult = created
            var skill = created.skill
            skill.validationCount = try library.validateSkill(skill)
            skills.removeAll { $0.id == skill.id }
            skills.insert(skill, at: 0)
            activities.insert(
                ActivityReceipt(
                    kind: .configuration,
                    title: "\(skill.displayName) generated with Codex",
                    detail: "The reviewed portable package was saved locally. Client installation still requires plan approval.",
                    date: .now,
                    state: .healthy,
                    affectedPaths: [created.skillURL.path(percentEncoded: false)]
                ),
                at: 0
            )
            try persistOrThrow()
            try? store.deleteCodexSkillDraftRequest(id: result.request.id)
            try? await codexSkillDraftService.discardDraft(result)
            return skill
        } catch {
            let persistenceError = error
            pendingPlan = nil
            applyPersisted(previousSnapshot)
            if let createdResult {
                do {
                    try library.rollbackCreation(createdResult)
                    lastError = persistenceError.localizedDescription
                } catch {
                    lastError =
                        "Saving the generated skill failed, and its package could not be removed safely: \(error.localizedDescription)"
                }
            } else {
                lastError = persistenceError.localizedDescription
            }
            return nil
        }
    }

    public func discardCodexSkillDraft(_ result: CodexSkillDraftResult) async {
        do {
            try await codexSkillDraftService.discardDraft(result)
            try store.deleteCodexSkillDraftRequest(id: result.request.id)
        } catch {
            presentError("The generated draft could not be discarded safely: \(error.localizedDescription)")
        }
    }

    public func discardCodexSkillDraftRequest(id: UUID) async {
        var cleanupError: Error?
        do {
            try await codexSkillDraftService.discardRequest(id: id)
        } catch {
            cleanupError = error
        }
        do {
            try store.deleteCodexSkillDraftRequest(id: id)
        } catch {
            cleanupError = cleanupError ?? error
        }
        if let cleanupError {
            presentError("The pending Codex skill request could not be removed: \(cleanupError.localizedDescription)")
        }
    }

    /// A discovered skill can be adopted once a scan has recorded where its
    /// files are. Without that path the app would have to guess a location, so
    /// the row is not offered for adoption until the next setup check.
    public func canAdoptSkill(id: String) -> Bool {
        guard let skill = skills.first(where: { $0.id == id }), !skill.owned else { return false }
        return observedSkillSourcePath(for: id) != nil
    }

    /// Indexed in one pass. The Skills list asks for this on every layout pass
    /// with a few hundred rows on screen, so it must not be quadratic.
    public var adoptableSkillIDs: [String] {
        let sources = observedSkillSourcePaths()
        return skills.filter { !$0.owned && sources[$0.id] != nil }.map(\.id)
    }

    /// Builds one reviewable plan that copies the selected discovered skills
    /// into the managed library. Nothing is written until the plan is approved,
    /// and the clients keep their own copies either way.
    public func planSkillAdoption(skillIDs: Set<String>) {
        guard ensureReadyForChange() else { return }
        let sources = observedSkillSourcePaths()
        let candidates =
            skills
            .filter { skillIDs.contains($0.id) }
            .map { SkillAdoptionCandidate(skill: $0, sourcePath: sources[$0.id]) }
        guard !candidates.isEmpty else {
            lastError = "The selected skills are no longer available. Check setup again, then try adopting them."
            return
        }
        do {
            let adoption = try library.adoptionPlan(
                for: candidates,
                reservedIdentifiers: Set(skills.map(\.id)).subtracting(skillIDs)
            )
            pendingSkillAdoption = adoption
            pendingPlan = adoption.plan
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Uses only what the last setup check actually observed. Client folder
    /// layouts differ per plugin, so a guessed path could copy the wrong tree.
    /// Surfaces are read in a stable order so the same skill observed by two
    /// clients always adopts the same copy.
    private func observedSkillSourcePaths() -> [String: String] {
        var paths: [String: String] = [:]
        for observation in targetObservations.sorted(by: { $0.surface.displayName < $1.surface.displayName }) {
            for (id, metadata) in observation.skillMetadata where paths[id] == nil {
                paths[id] = metadata.path
            }
        }
        return paths
    }

    private func observedSkillSourcePath(for skillID: String) -> String? {
        observedSkillSourcePaths()[skillID]
    }

    /// Records the adopted packages after the approved plan wrote them. The
    /// managed-library checker runs against the committed copy so a skill only
    /// reports validation it actually passed.
    private func applyAdoptedSkills(_ adoption: SkillAdoption) {
        var adopted: [Skill] = []
        var unchecked: [String] = []
        for var skill in adoption.skills {
            do {
                skill.validationCount = try library.validateSkill(skill)
            } catch {
                skill.validationCount = 0
                unchecked.append(skill.displayName)
            }
            adopted.append(skill)
        }
        let adoptedIDs = Set(adopted.map(\.id))
        skills.removeAll { adoptedIDs.contains($0.id) }
        skills.insert(contentsOf: adopted, at: 0)

        var detail =
            "The managed library now owns \(adopted.count) portable package\(adopted.count == 1 ? "" : "s"). Each client keeps its own copy; installing from Agent Tooling replaces it with the managed source."
        if !unchecked.isEmpty {
            detail +=
                " Not validated by the managed-library checker: \(unchecked.prefix(5).joined(separator: ", "))."
        }
        if !adoption.rejections.isEmpty {
            detail += " Skipped: \(adoption.rejections.prefix(5).map { "\($0.displayName) — \($0.reason)" }.joined(separator: " "))"
        }
        activities.insert(
            ActivityReceipt(
                kind: .configuration,
                title: adopted.count == 1
                    ? "\(adopted.first?.displayName ?? "Skill") adopted into the managed library"
                    : "\(adopted.count) skills adopted into the managed library",
                detail: boundedActivityDetail(detail),
                date: .now,
                state: unchecked.isEmpty && adoption.rejections.isEmpty ? .healthy : .pending,
                affectedPaths: adopted.prefix(20).map { library.skillURL(for: $0).path(percentEncoded: false) }
            ),
            at: 0
        )
    }

    public func planInstall(
        skillID: String,
        targets: Set<ClientKind>? = nil,
        includeFreshSessionCanary: Bool = false
    ) {
        guard ensureReadyForChange() else { return }
        guard let skill = skills.first(where: { $0.id == skillID }) else {
            lastError = "The selected skill is no longer available."
            return
        }
        do {
            pendingPlan = try library.installPlan(
                for: skill,
                targets: targets ?? Set(skill.clients.map(\.client)),
                homeURL: homeURL,
                includeFreshSessionCanary: includeFreshSessionCanary
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    public func updateSkill(id: String, from draft: SkillDraft) -> Skill? {
        guard ensureReadyForChange() else { return nil }
        guard let existing = skills.first(where: { $0.id == id }) else {
            lastError = "The selected skill is no longer available."
            return nil
        }
        let previousSnapshot = currentSnapshot()
        var updateResult: CreatedSkill?
        do {
            let result = try library.updateSkill(existing, from: draft)
            updateResult = result
            var updated = result.skill
            updated.validationCount = try library.validateSkill(updated)
            skills.removeAll { $0.id == id }
            skills.insert(updated, at: 0)
            activities.insert(
                ActivityReceipt(
                    kind: .configuration, title: "\(updated.displayName) updated",
                    detail: "The managed source changed locally. Review the install plan before updating any client.", date: .now,
                    state: .healthy, affectedPaths: [result.skillURL.path(percentEncoded: false)]), at: 0)
            prepareInstallPlanAfterSaving(skill: updated, draft: draft)
            try persistOrThrow()
            if let warning = library.commitUpdate(result) {
                lastError = warning
            }
            return updated
        } catch {
            let persistenceError = error
            pendingPlan = nil
            applyPersisted(previousSnapshot)
            if let updateResult {
                do {
                    if let warning = try library.rollbackUpdate(updateResult) {
                        lastError = "\(persistenceError.localizedDescription) \(warning)"
                    } else {
                        lastError = persistenceError.localizedDescription
                    }
                } catch {
                    lastError =
                        "Saving the skill update failed, and restoring its previous package also failed: \(error.localizedDescription)"
                }
            } else {
                lastError = persistenceError.localizedDescription
            }
            return nil
        }
    }

    @discardableResult
    public func addMCPServer(from draft: MCPDraft) -> MCPServer? {
        guard ensureReadyForChange() else { return nil }
        let id: String
        do {
            id = try WorkspaceLibrary.normalizedIdentifier(draft.name)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        guard !mcpServers.contains(where: { $0.id == id }) else {
            lastError = "An MCP server named \(id) already exists. Remove it or choose a different name."
            return nil
        }
        let selected = draft.selectedTargets
        guard !selected.isEmpty else {
            lastError = "Choose at least one app for this MCP server."
            return nil
        }
        let destination: ValidatedMCPDestination
        do {
            destination = try MCPDefinitionValidator.validate(draft.endpoint, transport: draft.transport)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        guard Self.supportedMCPCreationScopes.contains(draft.scope) else {
            lastError = "Choose This Mac, Project, This project only, or Workspace scope for an MCP server."
            return nil
        }
        let projectRoot: String?
        do {
            projectRoot = try ConfigurationValidator.normalizedScopedRoot(
                scope: draft.scope,
                value: draft.projectRoot,
                noun: "MCP server"
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        let displayName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard displayName.count <= 128, id.count <= 64 else {
            lastError = "MCP server names must be at most 128 characters and produce an identifier of at most 64 characters."
            return nil
        }
        guard ["OAuth", "API key", "Doppler", "None"].contains(draft.authentication) else {
            lastError = "Choose one of the supported authentication descriptions. Secret values are never stored here."
            return nil
        }
        var clients: [ClientState] = []
        if draft.addToCodex {
            clients.append(ClientState(client: .codex, state: .pending, detail: "Desired state saved; review native config plan"))
        }
        if draft.addToClaude {
            clients.append(ClientState(client: .claude, state: .pending, detail: "Desired state saved; review native config plan"))
        }
        if draft.addToGemini {
            clients.append(ClientState(client: .gemini, state: .pending, detail: "Desired state saved; review native config plan"))
        }
        let server = MCPServer(
            id: id,
            name: displayName,
            summary: "Managed by Agent Tooling",
            endpoint: destination.endpoint,
            transport: draft.transport,
            authentication: draft.authentication,
            scope: draft.scope.displayName,
            projectRoot: projectRoot,
            clients: clients,
            definitionOrigin: .managed
        )
        var candidate = currentSnapshot()
        candidate.mcpServers.insert(server, at: 0)
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration, title: "\(draft.name) added to desired state",
                detail: "No client configuration changed. Choose a target-specific installer from the review plan.", date: .now,
                state: .pending), at: 0)
        guard commit(candidate) else { return nil }
        planMCPConfiguration(server: server, targets: Set(clients.map(\.client)))
        return server
    }

    public func planMCPConfiguration(server: MCPServer, targets: Set<ClientKind>? = nil) {
        guard ensureReadyForChange() else { return }
        let selected = targets ?? Set(server.clients.map(\.client))
        guard !selected.isEmpty else {
            lastError = "Choose at least one app before reviewing this MCP configuration."
            return
        }
        let destination: ValidatedMCPDestination
        do {
            destination = try MCPDefinitionValidator.validate(server.endpoint, transport: server.transport)
        } catch {
            lastError = error.localizedDescription
            return
        }
        var steps: [OperationStep] = []
        let requestedScope = mcpScopeArgument(server.scope)
        let operationScope = ToolingScope.allCases.first(where: { $0.displayName == server.scope }) ?? .user
        let workingDirectory: String?
        if operationScope == .user {
            workingDirectory = nil
        } else {
            guard let projectRoot = server.projectRoot else {
                lastError =
                    "Choose the project folder for this \(server.scope.lowercased()) MCP configuration before reviewing native commands."
                return
            }
            workingDirectory = projectRoot
        }
        for client in selected.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard isCommandAvailable(for: client) else {
                steps.append(
                    OperationStep(
                        kind: .manual,
                        title: "Install \(client.rawValue) before configuring \(server.name)",
                        detail:
                            "The local CLI was not found. The desired MCP definition remains saved; run Check setup after installing \(client.rawValue), then review this configuration again.",
                        requiresUserAction: true
                    ))
                continue
            }
            if client == .codex, requestedScope != "user" {
                steps.append(
                    OperationStep(
                        kind: .manual, title: "Configure \(server.name) at \(server.scope) scope in Codex",
                        detail:
                            "The current Codex MCP CLI exposes no scope flag. Review the project-specific Codex configuration location before adding this server; Agent Tooling will not silently place a project server in global config.",
                        requiresUserAction: true))
                continue
            }
            let arguments = MCPClientCommand.addArguments(
                serverID: server.id,
                transport: server.transport,
                destination: destination,
                client: client,
                scope: operationScope
            )
            steps.append(
                OperationStep(
                    kind: .command, title: "Configure \(server.name) for \(client.rawValue)",
                    detail:
                        "Uses \(client.rawValue)'s native MCP command at \(server.scope.lowercased()) scope. Authentication and tool approval remain separate.",
                    executable: executable(for: client), arguments: arguments, currentDirectoryPath: workingDirectory,
                    projectRootPath: workingDirectory))
        }
        steps.append(
            OperationStep(
                kind: .scan, title: "Re-scan local MCP configuration",
                detail:
                    "Confirm the server is present in each selected local client configuration; this does not prove remote health or OAuth."
            ))
        pendingPlan = OperationPlan(
            kind: .configureMCP,
            title: "Configure \(server.name)",
            summary:
                "Review \(selected.count) independent target command\(selected.count == 1 ? "" : "s"). Secrets and OAuth tokens are never placed in the plan or copied between clients.",
            targetSurfaces: selected.sorted(by: { $0.rawValue < $1.rawValue }).map { surface(for: $0) },
            scope: operationScope,
            steps: steps
        )
    }

    public func planPluginRemoval(pluginID: String, client: ClientKind) async {
        guard ensureReadyForChange() else { return }
        if marketplacePackages.isEmpty { await refreshMarketplace() }
        let catalogPrefix = client == .claude ? "claude" : client == .codex ? "codex" : "gemini"
        guard
            let package = marketplacePackages.first(where: {
                $0.supportedClients.contains(client) && $0.id == "\(catalogPrefix):\(pluginID)"
            })
        else {
            lastError =
                "The native \(client.rawValue) catalog did not provide a verified removal route for \(pluginID). Refresh Marketplace and inspect the plugin source before removing it."
            return
        }
        planMarketplaceInstall(packageID: package.id, client: client, remove: true)
    }

    @discardableResult
    public func updateProfile(
        id: String,
        name: String,
        summary: String,
        scope: ToolingScope,
        projectRoot: String?,
        enabledPlugins: [String],
        requiredMCPs: [String]
    ) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            lastError = "The selected configuration is no longer available."
            return false
        }
        guard profiles[index].scope != .managed else {
            lastError = "Managed configurations are read-only. Update the policy source and import it again."
            return false
        }
        let fields: ValidatedConfigurationFields
        let normalizedPlugins: [String]
        let normalizedMCPs: [String]
        do {
            fields = try ConfigurationValidator.validateProfile(
                name: name,
                summary: summary,
                scope: scope,
                projectRoot: projectRoot
            )
            normalizedPlugins = try ConfigurationValidator.normalizedDesiredStateIDs(enabledPlugins, kind: "plugin")
            normalizedMCPs = try ConfigurationValidator.normalizedDesiredStateIDs(requiredMCPs, kind: "MCP server")
        } catch {
            lastError = error.localizedDescription
            return false
        }
        let requestedIdentifier = try? WorkspaceLibrary.normalizedIdentifier(fields.name)
        guard
            !profiles.contains(where: { candidate in
                candidate.id != id
                    && (candidate.name.localizedCaseInsensitiveCompare(fields.name) == .orderedSame
                        || requestedIdentifier == candidate.id)
            })
        else {
            lastError = "Another configuration already uses that name. Choose a distinct name."
            return false
        }
        var candidate = currentSnapshot()
        candidate.profiles[index].name = fields.name
        candidate.profiles[index].summary = fields.summary
        candidate.profiles[index].scope = scope
        candidate.profiles[index].projectRoot = fields.projectRoot
        candidate.profiles[index].enabledPlugins = normalizedPlugins
        candidate.profiles[index].requiredMCPs = normalizedMCPs
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration, title: "\(fields.name) updated",
                detail: "Desired state saved locally; no agent settings were changed.", date: .now, state: .healthy,
                affectedPaths: [store.databaseURL.path(percentEncoded: false)]), at: 0)
        return commit(candidate)
    }

    public func createProfile(name: String, summary: String, scope: ToolingScope, projectRoot: String?, inheritedFrom: String? = nil)
        -> ToolingProfile?
    {
        guard ensureReadyForChange() else { return nil }
        let fields: ValidatedConfigurationFields
        let id: String
        do {
            fields = try ConfigurationValidator.validateProfile(
                name: name,
                summary: summary,
                scope: scope,
                projectRoot: projectRoot
            )
            id = try WorkspaceLibrary.normalizedIdentifier(fields.name)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        guard !profiles.contains(where: { $0.id == id }) else {
            lastError = "A configuration with this identifier already exists. Choose a distinct name."
            return nil
        }
        if let inheritedFrom, !profiles.contains(where: { $0.id == inheritedFrom }) {
            lastError = "The inherited configuration is no longer available."
            return nil
        }
        let profile = ToolingProfile(
            id: id,
            name: fields.name,
            summary: fields.summary,
            inheritedFrom: inheritedFrom,
            scope: scope,
            projectRoot: fields.projectRoot,
            checks: [
                ProfileCheck(
                    id: "apps", name: "App status", detail: "Check setup to compare this configuration with the apps on this Mac.",
                    state: .pending)
            ],
            enabledPlugins: [],
            requiredMCPs: []
        )
        var candidate = currentSnapshot()
        candidate.profiles.append(profile)
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration, title: "\(profile.name) configuration created",
                detail: "Desired state only; no client configuration changed.", date: .now, state: .healthy), at: 0)
        return commit(candidate) ? profile : nil
    }

    /// The resolved contract for a configuration: its own items, everything it
    /// inherits, and everything on the collections it includes — unioned, so an
    /// item named by three overlapping shelves still appears once.
    public func effectiveProfile(for id: String) -> ToolingProfile? {
        guard let selected = profiles.first(where: { $0.id == id }) else { return nil }

        var chain: [ToolingProfile] = []
        var visited: Set<String> = []
        var cursor: ToolingProfile? = selected
        while let profile = cursor, visited.insert(profile.id).inserted {
            chain.append(profile)
            cursor = profile.inheritedFrom.flatMap { parentID in profiles.first(where: { $0.id == parentID }) }
        }

        var enabledPlugins: Set<String> = []
        var requiredMCPs: Set<String> = []
        var requiredSkills: Set<String> = []
        var includedCollections: Set<String> = []
        var checks: [ProfileCheck] = []
        // Ancestors first, so an inherited check keeps its original position and
        // a child never repeats one it already has.
        for profile in chain.reversed() {
            enabledPlugins.formUnion(profile.enabledPlugins)
            requiredMCPs.formUnion(profile.requiredMCPs)
            requiredSkills.formUnion(profile.requiredSkills)
            includedCollections.formUnion(profile.includedCollections)
            checks.append(contentsOf: profile.checks.filter { candidate in !checks.contains(where: { $0.id == candidate.id }) })
        }

        for item in resolvedItems(ofCollections: includedCollections) {
            switch item.kind {
            case .skill: requiredSkills.insert(item.identifier)
            case .plugin: enabledPlugins.insert(item.identifier)
            case .mcpServer: requiredMCPs.insert(item.identifier)
            }
        }

        var result = selected
        result.enabledPlugins = enabledPlugins.sorted()
        result.requiredMCPs = requiredMCPs.sorted()
        result.requiredSkills = requiredSkills.sorted()
        result.includedCollections = includedCollections.sorted()
        result.checks = checks
        return result
    }

    /// Every item a configuration reaches through its included collections,
    /// de-duplicated across overlapping shelves.
    private func resolvedItems(ofCollections identifiers: Set<String>) -> [ToolingItemReference] {
        var seen: Set<String> = []
        var result: [ToolingItemReference] = []
        for collection in collections where identifiers.contains(collection.id) {
            for item in collection.items where seen.insert(item.id).inserted {
                result.append(item)
            }
        }
        return result
    }

    // MARK: - Collections

    public func collection(id: String) -> ToolingCollection? {
        collections.first { $0.id == id }
    }

    /// Collections are shelves, so one item sitting on three of them is
    /// ordinary. Nothing here enforces a single owner.
    public func collections(containing item: ToolingItemReference) -> [ToolingCollection] {
        collections.filter { $0.contains(item) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func createCollection(name: String, summary: String = "") -> ToolingCollection? {
        guard ensureReadyForChange() else { return nil }
        let fields: ValidatedConfigurationFields
        let id: String
        do {
            fields = try ConfigurationValidator.validateProfile(name: name, summary: summary, scope: .user, projectRoot: nil)
            id = try WorkspaceLibrary.normalizedIdentifier(fields.name)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        guard !collections.contains(where: { $0.id == id }) else {
            lastError = "A collection with this identifier already exists. Choose a distinct name."
            return nil
        }
        let collection = ToolingCollection(id: id, name: fields.name, summary: fields.summary)
        var candidate = currentSnapshot()
        candidate.collections.append(collection)
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration, title: "\(collection.name) collection created",
                detail: "A collection is reusable material. Nothing is applied until a configuration includes it and you sync.",
                date: .now, state: .healthy), at: 0)
        return commit(candidate) ? collection : nil
    }

    @discardableResult
    public func updateCollection(id: String, name: String, summary: String) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard let index = collections.firstIndex(where: { $0.id == id }) else {
            lastError = "The selected collection is no longer available."
            return false
        }
        let fields: ValidatedConfigurationFields
        do {
            fields = try ConfigurationValidator.validateProfile(name: name, summary: summary, scope: .user, projectRoot: nil)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        guard
            !collections.contains(where: { candidate in
                candidate.id != id && candidate.name.localizedCaseInsensitiveCompare(fields.name) == .orderedSame
            })
        else {
            lastError = "Another collection already uses that name. Choose a distinct name."
            return false
        }
        var candidate = currentSnapshot()
        candidate.collections[index].name = fields.name
        candidate.collections[index].summary = fields.summary
        return commit(candidate)
    }

    /// Removing a shelf also removes it from every configuration that included
    /// it, so no configuration is left pointing at something that is gone.
    @discardableResult
    public func deleteCollection(id: String) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard let collection = collections.first(where: { $0.id == id }) else {
            lastError = "The selected collection is no longer available."
            return false
        }
        var candidate = currentSnapshot()
        candidate.collections.removeAll { $0.id == id }
        for index in candidate.profiles.indices {
            candidate.profiles[index].includedCollections.removeAll { $0 == id }
        }
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration, title: "\(collection.name) collection removed",
                detail: "Desired state only. No skill, plugin, or MCP server was uninstalled.", date: .now, state: .healthy), at: 0)
        return commit(candidate)
    }

    @discardableResult
    public func setCollectionMembership(id: String, items: [ToolingItemReference]) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard let index = collections.firstIndex(where: { $0.id == id }) else {
            lastError = "The selected collection is no longer available."
            return false
        }
        guard items.count <= ConfigurationValidator.maximumDesiredStateItems else {
            lastError = "A collection can hold at most \(ConfigurationValidator.maximumDesiredStateItems) items."
            return false
        }
        var seen: Set<String> = []
        let deduplicated = items.filter { seen.insert($0.id).inserted }
        var candidate = currentSnapshot()
        candidate.collections[index].items = deduplicated.sorted { $0.id < $1.id }
        return commit(candidate)
    }

    @discardableResult
    public func setCollectionMembership(_ isMember: Bool, of id: String, for item: ToolingItemReference) -> Bool {
        guard let collection = collections.first(where: { $0.id == id }) else {
            lastError = "The selected collection is no longer available."
            return false
        }
        var items = collection.items
        if isMember {
            guard !items.contains(item) else { return true }
            items.append(item)
        } else {
            items.removeAll { $0 == item }
        }
        return setCollectionMembership(id: id, items: items)
    }

    /// Attaching and detaching is the whole interaction. It edits desired
    /// state; client files change only after a reviewed sync.
    @discardableResult
    public func setCollectionInclusion(_ isIncluded: Bool, of collectionID: String, inProfile profileID: String) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            lastError = "The selected configuration is no longer available."
            return false
        }
        guard profiles[index].scope != .managed else {
            lastError = "Managed configurations are read-only. Update the policy source and import it again."
            return false
        }
        guard let collection = collections.first(where: { $0.id == collectionID }) else {
            lastError = "The selected collection is no longer available."
            return false
        }
        var included = Set(profiles[index].includedCollections)
        if isIncluded { included.insert(collectionID) } else { included.remove(collectionID) }
        guard included != Set(profiles[index].includedCollections) else { return true }
        let profileName = profiles[index].name
        var candidate = currentSnapshot()
        candidate.profiles[index].includedCollections = included.sorted()
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration,
                title: isIncluded
                    ? "\(collection.name) included in \(profileName)" : "\(collection.name) removed from \(profileName)",
                detail: "Desired state changed. Review and sync to apply it to Claude Code, Codex, or Gemini CLI.", date: .now,
                state: .healthy), at: 0)
        return commit(candidate)
    }

    public func isCollectionIncluded(_ collectionID: String, inProfile profileID: String) -> Bool {
        effectiveProfile(for: profileID)?.includedCollections.contains(collectionID) ?? false
    }

    /// How much of a shelf a configuration already covers directly. This is
    /// what lets the menu show a partial count instead of a checkmark when a
    /// configuration happens to require part of a collection without
    /// including the collection itself.
    public func collectionCoverage(_ collectionID: String, inProfile profileID: String) -> (covered: Int, total: Int) {
        guard let collection = collections.first(where: { $0.id == collectionID }),
            let profile = effectiveProfile(for: profileID)
        else { return (0, 0) }
        let plugins = Set(profile.enabledPlugins)
        let mcps = Set(profile.requiredMCPs)
        let skills = Set(profile.requiredSkills)
        let covered = collection.items.count { item in
            switch item.kind {
            case .skill: skills.contains(item.identifier)
            case .plugin: plugins.contains(item.identifier)
            case .mcpServer: mcps.contains(item.identifier)
            }
        }
        return (covered, collection.items.count)
    }

    // MARK: - Tags

    public func tags(for item: ToolingItemReference) -> [String] {
        tagAssignments.first { $0.item == item }?.tags ?? []
    }

    /// Every tag in use, ordered for display. Filtering reads this; tagging
    /// never changes what is installed.
    public var allTags: [String] {
        ToolingTag.normalizedList(tagAssignments.flatMap(\.tags))
    }

    public func itemsTagged(_ tag: String) -> [ToolingItemReference] {
        tagAssignments.filter { assignment in assignment.tags.contains { ToolingTag.matches($0, tag) } }.map(\.item)
    }

    /// Replaces the tag list on a selection. Tags are multi-valued and
    /// normalized on the way in, so one word typed three ways stays one tag.
    @discardableResult
    public func setTags(_ tags: [String], for items: [ToolingItemReference]) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard !items.isEmpty else { return true }
        let normalized = ToolingTag.normalizedList(tags)
        guard normalized.count <= ToolingTag.maximumTagsPerItem else {
            lastError = "An item can carry at most \(ToolingTag.maximumTagsPerItem) tags."
            return false
        }
        var candidate = currentSnapshot()
        for item in items {
            candidate.tagAssignments.removeAll { $0.item == item }
            if !normalized.isEmpty {
                candidate.tagAssignments.append(TagAssignment(item: item, tags: normalized))
            }
        }
        candidate.tagAssignments.sort { $0.id < $1.id }
        return commit(candidate)
    }

    /// Adds and removes tags across a selection without disturbing tags an
    /// item already carries that were not part of the edit.
    @discardableResult
    public func applyTagEdits(adding added: [String], removing removed: [String], to items: [ToolingItemReference]) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard !items.isEmpty, !(added.isEmpty && removed.isEmpty) else { return true }
        let toAdd = ToolingTag.normalizedList(added)
        let toRemove = ToolingTag.normalizedList(removed)
        var candidate = currentSnapshot()
        for item in items {
            let existing = candidate.tagAssignments.first { $0.item == item }?.tags ?? []
            let kept = existing.filter { tag in !toRemove.contains { ToolingTag.matches($0, tag) } }
            let merged = ToolingTag.normalizedList(kept + toAdd)
            guard merged.count <= ToolingTag.maximumTagsPerItem else {
                lastError = "An item can carry at most \(ToolingTag.maximumTagsPerItem) tags."
                return false
            }
            candidate.tagAssignments.removeAll { $0.item == item }
            if !merged.isEmpty {
                candidate.tagAssignments.append(TagAssignment(item: item, tags: merged))
            }
        }
        candidate.tagAssignments.sort { $0.id < $1.id }
        return commit(candidate)
    }

    @discardableResult

    // MARK: - Collection export

    /// Builds the shareable document. Redaction happens here rather than at the
    /// file boundary, so a Share Sheet payload carries the same guarantee.
    public func collectionExportDocument(id: String) throws -> CollectionExportDocument {
        guard let collection = collections.first(where: { $0.id == id }) else {
            throw CollectionExportError.unknownCollection
        }
        var tags: [ToolingItemReference: [String]] = [:]
        for assignment in tagAssignments { tags[assignment.item] = assignment.tags }
        return CollectionExporter.document(
            for: collection,
            skills: skills,
            plugins: plugins,
            mcpServers: mcpServers,
            tags: tags
        )
    }

    public func collectionExportData(id: String) throws -> Data {
        try CollectionExporter.encode(collectionExportDocument(id: id))
    }

    /// Writes the document and records a receipt naming the file, so an export
    /// is visible in Activity like every other side effect.
    @discardableResult
    public func exportCollection(id: String, to url: URL) -> Bool {
        guard ensureReadyForChange() else { return false }
        guard let collection = collections.first(where: { $0.id == id }) else {
            lastError = CollectionExportError.unknownCollection.localizedDescription
            return false
        }
        do {
            let data = try collectionExportData(id: id)
            try data.write(to: url, options: [.atomic])
            var candidate = currentSnapshot()
            candidate.activities.insert(
                ActivityReceipt(
                    kind: .publication, title: "\(collection.name) collection exported",
                    detail: CollectionExportDocument.securityNote, date: .now, state: .healthy,
                    affectedPaths: [url.path(percentEncoded: false)]), at: 0)
            return commit(candidate)
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    public func authenticate(serverID: String, client: ClientKind) {
        guard ensureReadyForChange() else { return }
        guard let server = mcpServers.first(where: { $0.id == serverID }) else {
            lastError = "The selected MCP server is no longer available."
            return
        }
        let guidance: String
        switch client {
        case .claude: guidance = "Use Claude Code's MCP login or settings flow. Agent Tooling never copies OAuth tokens between clients."
        case .codex: guidance = "Use Codex's MCP authentication flow. Agent Tooling will re-scan local configuration afterward."
        case .gemini: guidance = "Use Gemini CLI's native authentication flow, then re-scan this target."
        }
        pendingPlan = OperationPlan(
            kind: .guidedAccountCheck,
            title: "Authenticate \(server.name) for \(client.rawValue)",
            summary: "Authentication is owned by \(client.rawValue), not by this app or its Git backup.",
            targetSurfaces: [surface(for: client)],
            steps: [
                OperationStep(kind: .manual, title: "Authenticate in \(client.rawValue)", detail: guidance, requiresUserAction: true),
                OperationStep(
                    kind: .scan, title: "Re-scan local configuration",
                    detail: "This confirms configuration presence, not an OAuth token or remote runtime health."),
            ],
            requiresConfirmation: false
        )
    }

    public func planMCPRemoval(serverID: String, client: ClientKind) {
        guard ensureReadyForChange() else { return }
        guard let server = mcpServers.first(where: { $0.id == serverID }) else {
            lastError = "The selected MCP server is no longer available."
            return
        }
        let requestedScope = mcpScopeArgument(server.scope)
        let operationScope = ToolingScope.allCases.first(where: { $0.displayName == server.scope }) ?? .user
        let workingDirectory: String?
        if operationScope == .user {
            workingDirectory = nil
        } else {
            guard let projectRoot = server.projectRoot else {
                lastError = "Choose the original project folder before removing this project-scoped MCP server."
                return
            }
            workingDirectory = projectRoot
        }
        if client == .codex, operationScope != .user {
            pendingPlan = OperationPlan(
                kind: .configureMCP,
                title: "Remove \(server.name) from Codex",
                summary:
                    "Codex does not expose a scoped MCP removal command. Remove only the project entry manually; global configuration will not be changed.",
                targetSurfaces: [.codexCLI],
                scope: operationScope,
                steps: [
                    OperationStep(
                        kind: .manual, title: "Remove from the project Codex configuration",
                        detail:
                            "Open the Codex configuration under \(workingDirectory ?? "the selected project") and remove only \(server.id).",
                        requiresUserAction: true)
                ]
            )
            return
        }
        let arguments = MCPClientCommand.removeArguments(
            serverID: server.id,
            client: client,
            scope: MCPClientCommand.scope(fromDisplayName: server.scope)
        )
        pendingPlan = OperationPlan(
            kind: .configureMCP,
            title: "Remove \(server.name) from \(client.rawValue)",
            summary: "Only \(client.rawValue)'s native configuration changes. Other clients and any provider account remain untouched.",
            targetSurfaces: [surface(for: client)],
            scope: operationScope,
            steps: [
                OperationStep(
                    kind: .command, title: "Remove through \(client.rawValue)",
                    detail: "Runs the native MCP removal command for the exact server identifier \(server.id).",
                    executable: executable(for: client), arguments: arguments, currentDirectoryPath: workingDirectory,
                    projectRootPath: workingDirectory),
                OperationStep(
                    kind: .scan, title: "Verify removal",
                    detail: "Re-scan local configuration and preserve any independently configured copies in other clients.",
                    isReversible: false),
            ]
        )
    }

    public func applyProfile(id: String) {
        guard ensureReadyForChange() else { return }
        guard profiles.contains(where: { $0.id == id }) else {
            lastError = "The selected configuration is no longer available."
            return
        }
        var candidate = currentSnapshot()
        candidate.activeProfileID = id
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration, title: "Configuration selected", detail: profiles.first(where: { $0.id == id })?.name ?? id,
                date: .now, state: .healthy), at: 0)
        _ = commit(candidate)
    }

    @discardableResult
    public func importRepository(at url: URL) -> Bool {
        guard ensureReadyForChange() else { return false }
        do {
            let source = try library.importRepositorySource(at: url)
            var candidate = currentSnapshot()
            candidate.sources.removeAll { $0.location == source.location }
            candidate.sources.append(source)
            candidate.importedRepositoryPath = source.location
            candidate.activities.insert(
                ActivityReceipt(
                    kind: .configuration, title: "Imported optional source",
                    detail:
                        "\(source.name) is available as a \(source.kind.displayName.lowercased()); the local workspace remains authoritative.",
                    date: .now, state: .healthy, affectedPaths: [source.location]), at: 0)
            guard commit(candidate) else { return false }
            Task { await refreshMarketplace() }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    public func addMarketplaceSource(at url: URL) {
        guard ensureReadyForChange() else { return }
        do {
            let source = try library.importRepositorySource(at: url)
            var candidate = currentSnapshot()
            candidate.sources.removeAll { $0.location == source.location }
            candidate.sources.append(source)
            guard commit(candidate) else { return }
            Task { await refreshMarketplace() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func removeMarketplaceSource(id: UUID) {
        guard ensureReadyForChange() else { return }
        guard let source = sources.first(where: { $0.id == id }) else {
            lastError = "The selected marketplace source is no longer available."
            return
        }
        guard [.localFolder, .gitRepository].contains(source.kind) else {
            lastError = "Built-in catalog references cannot be removed."
            return
        }
        var candidate = currentSnapshot()
        candidate.sources.removeAll { $0.id == id }
        candidate.marketplacePackages.removeAll { $0.sourceID == id }
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration,
                title: "\(source.name) source removed",
                detail: "The source reference and its cached listings were removed. No files were deleted.",
                date: .now,
                state: .healthy,
                affectedPaths: [source.location]
            ),
            at: 0
        )
        _ = commit(candidate)
    }

    /// Refreshes imported portable packages, reviewed remote providers, and the
    /// machine-readable catalogs exposed by installed Claude Code and Codex
    /// CLIs. Hosted HTML listings are never scraped; Gemini's gallery stays a
    /// native source link until it exposes a documented API.
    public func refreshMarketplace() async {
        guard ensureReadyForChange() else { return }
        isRefreshingMarketplace = true
        defer { isRefreshingMarketplace = false }
        var candidate = currentSnapshot()
        var packages: [MarketplacePackage] = []
        var failures: [String] = []
        for index in candidate.sources.indices {
            guard [.localFolder, .gitRepository].contains(candidate.sources[index].kind) else { continue }
            do {
                let inspected = try marketplace.inspect(candidate.sources[index])
                packages.append(contentsOf: inspected)
                candidate.sources[index].lastRefreshedAt = .now
                candidate.sources[index].trustSummary =
                    inspected.isEmpty
                    ? "No portable packages found"
                    : "\(inspected.count) package\(inspected.count == 1 ? "" : "s") discovered; review before installing"
            } catch {
                let diagnostic = SensitiveValueRedactor.redact(error.localizedDescription)
                candidate.sources[index].trustSummary = diagnostic
                failures.append("\(candidate.sources[index].name): \(diagnostic)")
            }
        }
        for provider in marketplaceProviders {
            do {
                let page = try await provider.search(MarketplaceQuery(limit: 100))
                packages.append(contentsOf: page.packages)
                updateNativeSource(
                    .mcpRegistry,
                    detail:
                        "\(page.packages.count) server\(page.packages.count == 1 ? "" : "s") loaded from \(provider.displayName); package execution still requires review",
                    in: &candidate.sources
                )
            } catch {
                let diagnostic = SensitiveValueRedactor.redact(error.localizedDescription)
                updateNativeSource(.mcpRegistry, detail: "Unavailable: \(diagnostic)", in: &candidate.sources)
                failures.append("\(provider.displayName): \(diagnostic)")
            }
        }
        let native = await MarketplaceService.discoverNativeCatalogs(runner: runner)
        packages.append(contentsOf: native.packages)
        updateNativeSource(.claudeMarketplace, detail: native.notes[.claude], in: &candidate.sources)
        updateNativeSource(.openAIPluginDirectory, detail: native.notes[.codex], in: &candidate.sources)
        failures.append(
            contentsOf: native.notes.compactMap { client, note in
                note.localizedCaseInsensitiveContains("unavailable") ? "\(client.rawValue): \(note)" : nil
            })
        if let index = candidate.sources.firstIndex(where: { $0.kind == .geminiExtensionGallery }) {
            candidate.sources[index].lastRefreshedAt = .now
            candidate.sources[index].trustSummary =
                "Browse Gemini's native gallery or install a reviewed Git/local extension; installed extensions are observed by the scanner."
        }
        candidate.marketplacePackages = marketplace.deduplicatedPackages(packages)
        let detail =
            candidate.marketplacePackages.isEmpty
            ? "No portable or native catalog packages were found. Add a local folder or check the installed client CLIs."
            : "Found \(candidate.marketplacePackages.count) reviewable package\(candidate.marketplacePackages.count == 1 ? "" : "s"). \(native.notes.values.sorted().joined(separator: " · "))"
        let failureDetail = boundedActivityDetail(failures.isEmpty ? detail : "\(detail) Issues: \(failures.joined(separator: " · "))")
        candidate.activities.insert(
            ActivityReceipt(
                kind: .validation, title: "Marketplace sources refreshed", detail: failureDetail, date: .now,
                state: failures.isEmpty ? .healthy : .attention), at: 0)
        candidate.activities = Array(candidate.activities.prefix(200))
        _ = commit(candidate)
    }

    public func prepareBackup() {
        guard ensureReadyForChange() else { return }
        do {
            pendingPlan = try backupService.exportPlan(snapshot: currentSnapshot())
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func inspectBackup(at url: URL) {
        guard ensureReadyForChange() else { return }
        do {
            let preview = try backupService.importPreview(at: url, current: currentSnapshot().portableDesiredState())
            backupImportPreview = preview
            if preview.conflicts.isEmpty {
                pendingRestoreSnapshot = preview.snapshot
                pendingPlan = preview.plan
            } else {
                var candidate = currentSnapshot()
                candidate.activities.insert(
                    ActivityReceipt(
                        kind: .validation, title: "Backup conflicts need review",
                        detail:
                            "\(preview.conflicts.count) desired-state conflict\(preview.conflicts.count == 1 ? "" : "s") found. Review them before accepting this backup.",
                        date: .now, state: .attention, affectedPaths: [url.path(percentEncoded: false)]), at: 0)
                _ = commit(candidate)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func acceptInspectedBackup() {
        guard ensureReadyForChange() else { return }
        guard let preview = backupImportPreview else {
            lastError = "Choose and inspect a backup before accepting it."
            return
        }
        pendingRestoreSnapshot = preview.snapshot
        var plan = preview.plan
        if !preview.conflicts.isEmpty {
            plan.summary +=
                " This restore accepts \(preview.conflicts.count) reviewed desired-state conflict\(preview.conflicts.count == 1 ? "" : "s")."
        }
        pendingPlan = plan
    }

    public func prepareEncryptedSync(to folder: URL) {
        guard ensureReadyForChange() else { return }
        do {
            pendingPlan = try encryptedSyncService.exportPlan(snapshot: currentSnapshot(), destinationFolder: folder)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func inspectEncryptedSync(at archive: URL) {
        guard ensureReadyForChange() else { return }
        do {
            let preview = try encryptedSyncService.importPreview(at: archive)
            encryptedSyncImportPreview = preview
            pendingEncryptedSyncSnapshot = preview.snapshot
            pendingPlan = preview.plan
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func reviewInspectedEncryptedSyncRestore() {
        guard ensureReadyForChange() else { return }
        guard let preview = encryptedSyncImportPreview else {
            lastError = "Choose and inspect an encrypted archive before restoring it."
            return
        }
        pendingEncryptedSyncSnapshot = preview.snapshot
        pendingPlan = preview.plan
    }

    public func encryptedSyncRecoveryKey() -> String? {
        do { return try encryptedSyncService.recoveryKey() } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func importEncryptedSyncRecoveryKey(_ value: String) -> Bool {
        guard ensureReadyForChange() else { return false }
        do {
            try encryptedSyncService.importRecoveryKey(value.trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    public func importManagedPolicy(at url: URL) {
        guard ensureReadyForChange() else { return }
        do {
            let policy = try policyService.load(at: url)
            let prefix = "policy-\(policy.id)-"
            let remapped = try policy.profiles.map { profile in
                let remappedID = prefix + profile.id
                guard (try? WorkspaceLibrary.normalizedIdentifier(remappedID)) == remappedID else {
                    throw WorkspaceSnapshotValidationError.inconsistent(
                        "Managed policy \(policy.id) produces a configuration identifier longer than the supported portable limit."
                    )
                }
                return ToolingProfile(
                    id: remappedID,
                    name: "\(policy.name) · \(profile.name)",
                    summary: profile.summary,
                    inheritedFrom: profile.inheritedFrom.map { prefix + $0 },
                    scope: .managed,
                    projectRoot: profile.projectRoot,
                    checks: profile.checks,
                    enabledPlugins: profile.enabledPlugins,
                    requiredMCPs: profile.requiredMCPs
                )
            }
            var candidate = currentSnapshot()
            candidate.managedPolicies.removeAll { $0.id == policy.id }
            candidate.managedPolicies.append(policy)
            candidate.profiles.removeAll { $0.id.hasPrefix(prefix) }
            candidate.profiles.append(contentsOf: remapped)
            candidate.activities.insert(
                ActivityReceipt(
                    kind: .configuration, title: "\(policy.name) policy imported",
                    detail:
                        "\(remapped.count) managed profile\(remapped.count == 1 ? "" : "s") and \(policy.blockedPluginIDs.count) blocked plugin rule\(policy.blockedPluginIDs.count == 1 ? "" : "s") are active locally. The manifest source was explicitly selected.",
                    date: .now, state: .healthy, affectedPaths: [policy.sourcePath]), at: 0)
            try WorkspaceSnapshotValidator.validate(candidate, mode: .localState)
            try store.saveWorkspaceSnapshot(candidate)
            applyPersisted(candidate)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func reviewMarketplacePackage(_ id: String) {
        guard ensureReadyForChange() else { return }
        guard let package = marketplacePackages.first(where: { $0.id == id }) else {
            lastError = "The selected marketplace package is no longer available."
            return
        }
        let componentText = package.components.map(\.displayName).sorted().joined(separator: ", ")
        pendingPlan = OperationPlan(
            kind: .importSource,
            title: "Review \(package.name)",
            summary:
                "\(package.trustSummary). This package contains: \(componentText.isEmpty ? "no recognized portable components" : componentText).",
            targetSurfaces: package.supportedClients.compactMap { client in surface(for: client) },
            steps: [
                OperationStep(
                    kind: .manual, title: "Inspect package source",
                    detail:
                        "Review \(package.location), its license (\(package.license ?? "not declared")), scripts, hooks, and target compatibility before installation.",
                    requiresUserAction: true),
                OperationStep(
                    kind: .manual, title: "Choose an installation route",
                    detail: package.nativeInstalls.isEmpty
                        ? "This local package has no verified automatic installer yet. Keep it as a reviewed source; do not copy it into a client manually without checking its target-specific instructions."
                        : "Choose one of the verified target-specific install buttons after reviewing the source.", requiresUserAction: true
                ),
            ],
            requiresConfirmation: false
        )
    }

    public func planMarketplaceInstall(packageID: String, client: ClientKind, remove: Bool = false) {
        guard ensureReadyForChange() else { return }
        guard let package = marketplacePackages.first(where: { $0.id == packageID }),
            let route = package.nativeInstalls.first(where: { $0.client == client })
        else {
            lastError = "This package does not expose a verified native installer for \(client.rawValue)."
            return
        }
        if !remove,
            managedPolicies.contains(where: { $0.blockedPluginIDs.contains(package.name) || $0.blockedPluginIDs.contains(package.id) })
        {
            lastError = "A managed policy blocks installation of \(package.name). Review the policy source in Settings."
            return
        }
        let arguments: [String]
        if remove {
            guard let removal = route.removalArguments else {
                lastError = "This package does not expose a verified native removal command."
                return
            }
            arguments = removal
        } else {
            arguments = route.arguments
        }
        let action = remove ? "Remove" : "Install"
        let routeDetail =
            remove
            ? "Remove this exact plugin identifier through \(client.rawValue)'s native plugin manager."
            : route.detail
        let operationKind: OperationKind =
            package.components == [.mcpServer] ? .configureMCP : .installPlugin
        pendingPlan = OperationPlan(
            kind: operationKind,
            title: "\(action) \(package.name) in \(client.rawValue)",
            summary: "\(routeDetail) Authentication, connector consent, and target reloads remain under \(client.rawValue).",
            targetSurfaces: [surface(for: client)],
            scope: route.scope,
            steps: [
                OperationStep(
                    kind: .command, title: "\(action) through \(client.rawValue)", detail: routeDetail, executable: route.executable,
                    arguments: arguments),
                OperationStep(
                    kind: .scan, title: "Re-scan \(client.rawValue)",
                    detail: "Confirm local installation state. This does not prove remote authentication or a live connector.",
                    isReversible: false),
            ]
        )
    }

    public func markAccountSurfaceVerified(_ id: UUID) {
        guard ensureReadyForChange() else { return }
        guard let index = accountSurfaces.firstIndex(where: { $0.id == id }) else {
            lastError = "The selected account check is no longer available."
            return
        }
        var candidate = currentSnapshot()
        candidate.accountSurfaces[index].status = .verified
        candidate.accountSurfaces[index].lastVerifiedAt = .now
        candidate.activities.insert(
            ActivityReceipt(
                kind: .authentication, title: "\(accountSurfaces[index].name) marked verified",
                detail: "Verification is an explicit user attestation for this account-side surface.", date: .now, state: .healthy), at: 0)
        _ = commit(candidate)
    }

    @discardableResult
    public func addConnector(
        name: String, provider: String, ownership: ConnectionOwner, target: TargetSurface, scope: ToolingScope,
        secretReferenceNames: [String]
    ) -> Bool {
        guard ensureReadyForChange() else { return false }
        let draft: ValidatedConnectorDraft
        do {
            draft = try ConnectorValidator.validate(
                name: name,
                provider: provider,
                target: target,
                scope: scope,
                secretReferenceNames: secretReferenceNames
            )
        } catch {
            lastError = error.localizedDescription
            return false
        }
        guard
            !connectors.contains(where: {
                $0.name.localizedCaseInsensitiveCompare(draft.name) == .orderedSame
                    && $0.bindings.contains(where: { $0.target == target })
            })
        else {
            lastError = "A connection with that name is already recorded for \(target.displayName)."
            return false
        }
        let guidance =
            "Authenticate through \(ownership.displayName.lowercased()) ownership. Agent Tooling stores only reference names, never secret values."
        let record = ConnectorRecord(
            name: draft.name, provider: draft.provider, ownership: ownership, description: guidance,
            secretReferenceNames: draft.secretReferenceNames,
            bindings: [ConnectionBinding(target: target, scope: scope, guidance: guidance)])
        var candidate = currentSnapshot()
        candidate.connectors.insert(record, at: 0)
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration, title: "\(draft.name) connection recorded",
                detail: "Metadata only; no credential or target configuration was written.", date: .now, state: .pending), at: 0)
        return commit(candidate)
    }

    public func removeConnector(id: UUID) {
        guard ensureReadyForChange() else { return }
        guard let connector = connectors.first(where: { $0.id == id }) else {
            lastError = "The selected connection record is no longer available."
            return
        }
        var candidate = currentSnapshot()
        candidate.connectors.removeAll { $0.id == id }
        candidate.activities.insert(
            ActivityReceipt(
                kind: .configuration,
                title: "\(connector.name) connection record removed",
                detail: "Only Agent Tooling metadata was removed. No account authorization or secret was changed.",
                date: .now,
                state: .healthy
            ),
            at: 0
        )
        _ = commit(candidate)
    }

    public func markConnectorBindingVerified(connectorID: UUID, bindingID: UUID) {
        guard ensureReadyForChange() else { return }
        guard let connector = connectors.firstIndex(where: { $0.id == connectorID }),
            let binding = connectors[connector].bindings.firstIndex(where: { $0.id == bindingID })
        else {
            lastError = "The selected connection check is no longer available."
            return
        }
        var candidate = currentSnapshot()
        candidate.connectors[connector].bindings[binding].status = .verified
        candidate.connectors[connector].bindings[binding].lastVerifiedAt = .now
        candidate.activities.insert(
            ActivityReceipt(
                kind: .authentication, title: "\(connectors[connector].name) binding marked verified",
                detail: "Verification is user-attested; Agent Tooling did not read or copy credentials.", date: .now, state: .healthy),
            at: 0)
        _ = commit(candidate)
    }

    /// Saving the canonical local definition and preparing target writes are
    /// separate outcomes. A target-path problem must not make a successful
    /// local authoring operation appear to have been rolled back.
    private func prepareInstallPlanAfterSaving(skill: Skill, draft: SkillDraft) {
        guard draft.syncClients else {
            pendingPlan = nil
            return
        }
        do {
            pendingPlan = try library.installPlan(
                for: skill,
                targets: draft.selectedTargets,
                homeURL: homeURL,
                includeFreshSessionCanary: draft.runCanary
            )
        } catch {
            pendingPlan = nil
            lastError = "\(skill.displayName) was saved locally, but its install plan could not be prepared: \(error.localizedDescription)"
        }
    }

    private func ensureReadyForChange() -> Bool {
        guard !isBusy else {
            lastError = "Wait for the current operation to finish before starting another action."
            return false
        }
        guard pendingPlan == nil else {
            lastError = "Finish or discard the current review before starting another action."
            return false
        }
        return true
    }

    private func apply(restoredSnapshot: WorkspaceSnapshot) {
        skills = restoredSnapshot.skills
        mcpServers = restoredSnapshot.mcpServers
        plugins = restoredSnapshot.plugins
        profiles = restoredSnapshot.profiles
        collections = restoredSnapshot.collections
        tagAssignments = restoredSnapshot.tagAssignments
        sources = restoredSnapshot.sources.isEmpty ? marketplace.defaultSources() : restoredSnapshot.sources
        marketplacePackages = restoredSnapshot.marketplacePackages
        accountSurfaces = restoredSnapshot.accountSurfaces
        connectors = restoredSnapshot.connectors
        activeProfileID = restoredSnapshot.activeProfileID
        repositoryPath = restoredSnapshot.importedRepositoryPath ?? workspacePath
        backupConfiguration = restoredSnapshot.backupConfiguration
        encryptedSyncConfiguration = restoredSnapshot.encryptedSyncConfiguration
        automaticallyCheckHealth = restoredSnapshot.preferences.automaticallyCheckHealth
        managedPolicies = restoredSnapshot.managedPolicies
        let encrypted = encryptedSyncImportPreview != nil
        let restoredPath =
            encrypted
            ? encryptedSyncImportPreview?.archiveURL.path(percentEncoded: false)
            : backupImportPreview?.backupURL.path(percentEncoded: false)
        activities.insert(
            ActivityReceipt(
                kind: .configuration, title: encrypted ? "Encrypted sync restored" : "Local backup restored",
                detail: "Desired state was restored locally; a fresh setup check follows.", date: .now, state: .pending,
                affectedPaths: restoredPath.map { [$0] } ?? []), at: 0)
    }

    private func applyPersisted(_ snapshot: WorkspaceSnapshot) {
        skills = snapshot.skills
        mcpServers = snapshot.mcpServers
        plugins = snapshot.plugins
        profiles = snapshot.profiles
        collections = snapshot.collections
        tagAssignments = snapshot.tagAssignments
        activities = snapshot.activities
        operationReceipts = snapshot.operationReceipts
        targetObservations = snapshot.targetObservations
        sources = snapshot.sources
        marketplacePackages = snapshot.marketplacePackages
        accountSurfaces = snapshot.accountSurfaces
        connectors = snapshot.connectors
        activeProfileID = snapshot.activeProfileID
        repositoryPath = snapshot.importedRepositoryPath ?? workspacePath
        backupConfiguration = snapshot.backupConfiguration
        encryptedSyncConfiguration = snapshot.encryptedSyncConfiguration
        automaticallyCheckHealth = snapshot.preferences.automaticallyCheckHealth
        managedPolicies = snapshot.managedPolicies
        syncStages = Self.syncStages(from: snapshot.targetObservations)
    }

    private func mergeSkills(existing: [Skill], observed: [Skill]) -> [Skill] {
        // Preserve only skills authored in the managed library. Vendor and
        // standalone discoveries are rebuilt on every scan so removals and
        // scope changes are reflected immediately.
        var values: [String: Skill] = [:]
        for skill in existing where skill.owned { values[skill.id] = skill }
        for item in observed {
            guard var local = values[item.id], local.owned else {
                values[item.id] = item
                continue
            }
            local.clients = item.clients
            local.files = item.files.isEmpty ? local.files : item.files
            values[item.id] = local
        }
        return values.values.sorted { $0.id < $1.id }
    }

    private func mergeMCPServers(existing: [MCPServer], observed: [MCPServer]) -> [MCPServer] {
        // Desired MCP definitions remain portable; purely observed definitions
        // are replaced by the current client inventories.
        var values: [String: MCPServer] = [:]
        for server in existing where server.isManagedDefinition { values[server.id] = server }
        for item in observed {
            guard var desired = values[item.id], desired.isManagedDefinition else {
                values[item.id] = item
                continue
            }
            desired.clients = item.clients
            values[item.id] = desired
        }
        return values.values.sorted { $0.id < $1.id }
    }

    private func updateNativeSource(_ kind: SourceKind, detail: String?, in sources: inout [ToolingSource]) {
        guard let index = sources.firstIndex(where: { $0.kind == kind }) else { return }
        sources[index].lastRefreshedAt = .now
        if let detail { sources[index].trustSummary = detail }
    }

    private func activity(from receipt: OperationReceipt, plan: OperationPlan) -> ActivityReceipt {
        let commands: [String] = receipt.results.compactMap { result in
            guard let step = plan.steps.first(where: { $0.id == result.stepID }),
                let command = step.renderedCommand
            else { return nil }
            return command
        }
        let paths: [String] = receipt.results.compactMap { result -> String? in
            guard let step = plan.steps.first(where: { $0.id == result.stepID }) else { return nil }
            return step.destinationPath ?? step.sourcePath
        }
        return ActivityReceipt(
            kind: activityKind(for: receipt.kind),
            title: receipt.title,
            detail: receipt.verificationSummary,
            date: receipt.createdAt,
            state: receipt.state,
            command: commands.first,
            duration: receipt.results.reduce(0) { $0 + $1.finishedAt.timeIntervalSince($1.startedAt) },
            affectedPaths: paths,
            operationReceiptID: receipt.id
        )
    }

    /// Plan-time safety review: what a step would remove, whether Agent Tooling
    /// can prove it owns the destination, and what the content scan found. It
    /// only reads; approving the plan remains a separate, explicit act.
    public func safetyReview(for plan: OperationPlan) -> OperationPlanSafetyReview {
        OperationPlanSafetyReviewer.fromStore(store).review(plan)
    }

    private func activityKind(for kind: OperationKind) -> ActivityKind {
        switch kind {
        case .scan, .doctor: .validation
        case .installSkill, .installPlugin, .configureMCP: .configuration
        case .createSkill, .importSource, .exportBackup, .restoreBackup: .publication
        case .exportEncryptedSync, .restoreEncryptedSync: .publication
        case .guidedAccountCheck: .authentication
        }
    }

    private func surface(for client: ClientKind) -> TargetSurface {
        switch client {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .gemini: .geminiCLI
        }
    }

    private func executable(for client: ClientKind) -> String {
        MCPClientCommand.executable(for: client)
    }

    private func isCommandAvailable(for client: ClientKind) -> Bool {
        let observations = targetObservations.filter { $0.surface.client == client }
        return observations.contains(where: \.isCommandAvailable)
    }

    private func mcpScopeArgument(_ displayScope: String) -> String {
        MCPClientCommand.scopeArgument(for: MCPClientCommand.scope(fromDisplayName: displayScope), client: .claude)
    }

    private func currentSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            skills: skills,
            mcpServers: mcpServers,
            plugins: plugins,
            profiles: profiles,
            activities: Array(activities.prefix(200)),
            operationReceipts: Array(operationReceipts.prefix(200)),
            targetObservations: targetObservations,
            sources: sources,
            marketplacePackages: marketplacePackages,
            accountSurfaces: accountSurfaces,
            connectors: connectors,
            activeProfileID: activeProfileID,
            importedRepositoryPath: repositoryPath == workspacePath ? nil : repositoryPath,
            backupConfiguration: backupConfiguration,
            encryptedSyncConfiguration: encryptedSyncConfiguration,
            preferences: WorkspacePreferences(
                automaticallyCheckHealth: automaticallyCheckHealth
            ),
            managedPolicies: managedPolicies,
            collections: collections,
            tagAssignments: tagAssignments
        )
    }

    private func persist() {
        do {
            try persistOrThrow()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persistOrThrow() throws {
        let snapshot = currentSnapshot()
        try WorkspaceSnapshotValidator.validate(snapshot, mode: .localState)
        try store.saveWorkspaceSnapshot(snapshot)
    }

    @discardableResult
    private func commit(_ candidate: WorkspaceSnapshot) -> Bool {
        do {
            try WorkspaceSnapshotValidator.validate(candidate, mode: .localState)
            try store.saveWorkspaceSnapshot(candidate)
            applyPersisted(candidate)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private static let supportedMCPCreationScopes = ConfigurationValidator.editableScopes

    private func trimHistory() {
        if activities.count > 200 { activities = Array(activities.prefix(200)) }
        if operationReceipts.count > 200 { operationReceipts = Array(operationReceipts.prefix(200)) }
    }

    private func boundedActivityDetail(_ value: String) -> String {
        let redacted = SensitiveValueRedactor.redact(value)
        guard redacted.count > 32_000 else { return redacted }
        return String(redacted.prefix(31_997)) + "…"
    }

    private static func initialSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            profiles: [
                ToolingProfile(
                    id: "local-library",
                    name: "Local Library",
                    summary: "Portable packages and desired state managed on this Mac. It works without a Git account.",
                    scope: .user,
                    checks: [
                        ProfileCheck(
                            id: "workspace", name: "Local workspace", detail: "Managed package library and SQLite state", state: .healthy),
                        ProfileCheck(
                            id: "apps", name: "App status", detail: "Check setup to inspect Claude Code, Codex, and Gemini CLI",
                            state: .pending),
                    ],
                    enabledPlugins: [],
                    requiredMCPs: []
                )
            ],
            accountSurfaces: [
                AccountSurface(
                    surface: .claudeCloud, name: "Claude.ai connectors", status: .manual,
                    guidance: "Account connectors are separate from Claude Code. Verify them in Claude's account settings.",
                    verificationURL: "https://claude.ai/settings/connectors"),
                AccountSurface(
                    surface: .codexCloud, name: "ChatGPT apps and connectors", status: .manual,
                    guidance:
                        "ChatGPT web does not inherit local Codex configuration. Verify hosted apps and connectors in ChatGPT settings.",
                    verificationURL: "https://chatgpt.com/#settings"),
                AccountSurface(
                    surface: .geminiCloud, name: "Gemini account and enterprise extensions", status: .manual,
                    guidance: "Gemini web and managed workspace resources require account or administrator verification.",
                    verificationURL: "https://gemini.google.com"),
            ]
        )
    }

    private static func syncStages(from observations: [TargetObservation]) -> [SyncStage] {
        var lookup: [ClientKind: [TargetObservation]] = [:]
        for observation in observations {
            if let client = observation.surface.client { lookup[client, default: []].append(observation) }
        }
        return [
            SyncStage(id: "library", title: "Library", detail: "Local SQLite + packages", symbol: "folder", state: .complete),
            SyncStage(
                id: "claude", title: "Claude", detail: targetStageDetail(lookup[.claude]), symbol: "terminal",
                state: targetStageState(lookup[.claude])),
            SyncStage(
                id: "codex", title: "Codex", detail: targetStageDetail(lookup[.codex]), symbol: "apple.terminal",
                state: targetStageState(lookup[.codex])),
            SyncStage(
                id: "gemini", title: "Gemini", detail: targetStageDetail(lookup[.gemini]), symbol: "sparkles",
                state: targetStageState(lookup[.gemini])),
        ]
    }

    private static func targetStageDetail(_ observations: [TargetObservation]?) -> String {
        guard let observations, !observations.isEmpty else { return "Not scanned" }
        if observations.contains(where: \.isCommandAvailable) { return "Available" }
        return observations.contains(where: \.installed) ? "Configuration found; CLI unavailable" : "Not found"
    }

    private static func targetStageState(_ observations: [TargetObservation]?) -> SyncStageState {
        guard let observations, !observations.isEmpty else { return .waiting }
        return observations.contains(where: \.isCommandAvailable) ? .complete : .attention
    }

    // MARK: - Projects section (additive block — begin)
    //
    // Everything the Projects section needs lives between this marker and the
    // matching end marker so it can be merged as one unit. Pins and scan roots
    // are held in the workspace key-value store rather than in
    // `WorkspaceSnapshot`, so no shared model type changes shape.

    public private(set) var projects: [DiscoveredProject] = []
    public private(set) var projectScanRoots: [String] = []
    public private(set) var isDiscoveringProjects = false
    public private(set) var hasDiscoveredProjects = false
    private var pinnedProjectPaths: [String] = []
    private var hasLoadedProjectPreferences = false

    private static let pinnedProjectsKey = "projects.pinned"
    private static let projectScanRootsKey = "projects.scan-roots"
    nonisolated private static let maximumPinnedProjects = 128
    nonisolated private static let maximumProjectScanRoots = 12

    /// Projects are derived, not registered: Claude Code's own session index,
    /// any folder the user asked to scan, and any folder pinned by hand.
    public func discoverProjects(force: Bool = false) async {
        guard !isDiscoveringProjects else { return }
        guard force || !hasDiscoveredProjects else { return }
        loadProjectPreferencesIfNeeded()
        isDiscoveringProjects = true
        let home = homeURL
        let pinned = pinnedProjectPaths
        let roots = projectScanRoots
        let discovered = await Task.detached {
            Self.inspectProjects(homeURL: home, pinnedPaths: pinned, scanRoots: roots)
        }.value
        projects = discovered
        isDiscoveringProjects = false
        hasDiscoveredProjects = true
    }

    /// Adds a folder the user chose. Choosing it pins it, because a folder
    /// Claude Code has never run in has nothing else to keep it on the list.
    public func addProject(at url: URL) async {
        loadProjectPreferencesIfNeeded()
        let path = ProjectPath.canonical(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            presentError("That folder is no longer available.")
            return
        }
        guard ProjectDiscovery.isEligibleProjectRoot(url, homeURL: homeURL) else {
            presentError(
                "Your home folder is where this Mac's own skills, MCP servers, and plugins live. Choose a project folder inside it.")
            return
        }
        guard !pinnedProjectPaths.contains(path) else { return }
        guard pinnedProjectPaths.count < Self.maximumPinnedProjects else {
            presentError("Agent Tooling keeps at most \(Self.maximumPinnedProjects) pinned projects. Unpin one first.")
            return
        }
        guard persistProjectPreferences(pinned: (pinnedProjectPaths + [path]).sorted(), scanRoots: projectScanRoots) else { return }
        await discoverProjects(force: true)
    }

    public func setProjectPinned(_ path: String, pinned: Bool) {
        loadProjectPreferencesIfNeeded()
        let normalized = ProjectPath.canonical(path)
        var values = pinnedProjectPaths.filter { $0 != normalized }
        if pinned {
            guard values.count < Self.maximumPinnedProjects else {
                presentError("Agent Tooling keeps at most \(Self.maximumPinnedProjects) pinned projects. Unpin one first.")
                return
            }
            values.append(normalized)
        }
        guard persistProjectPreferences(pinned: values.sorted(), scanRoots: projectScanRoots) else { return }
        guard let index = projects.firstIndex(where: { $0.path == normalized }) else { return }
        if pinned {
            projects[index].origins.insert(.pinned)
        } else {
            projects[index].origins.remove(.pinned)
            if projects[index].origins.isEmpty { projects.remove(at: index) }
        }
        projects.sort(by: Self.projectOrder)
    }

    /// Unpins a project. One that is only on the list because it was pinned
    /// disappears; one Claude Code has run in stays, without the pin.
    public func forgetProject(_ path: String) {
        setProjectPinned(path, pinned: false)
    }

    public func addProjectScanRoot(at url: URL) async {
        loadProjectPreferencesIfNeeded()
        let path = ProjectPath.canonical(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            presentError("That folder is no longer available.")
            return
        }
        guard !projectScanRoots.contains(path) else { return }
        guard projectScanRoots.count < Self.maximumProjectScanRoots else {
            presentError("Agent Tooling scans at most \(Self.maximumProjectScanRoots) folders. Remove one first.")
            return
        }
        guard persistProjectPreferences(pinned: pinnedProjectPaths, scanRoots: (projectScanRoots + [path]).sorted()) else { return }
        await discoverProjects(force: true)
    }

    public func removeProjectScanRoot(_ path: String) async {
        loadProjectPreferencesIfNeeded()
        guard projectScanRoots.contains(path) else { return }
        guard persistProjectPreferences(pinned: pinnedProjectPaths, scanRoots: projectScanRoots.filter { $0 != path }) else { return }
        await discoverProjects(force: true)
    }

    /// A read-only preview of the `.gitignore` edit, safe to call while
    /// drawing. It never reports an error; the write does.
    public func projectIgnorePlan(for project: DiscoveredProject) -> ProjectIgnorePlan? {
        try? ProjectGitignore.plan(for: project)
    }

    /// Appends reviewed lines to a project's `.gitignore`. The plan shown in
    /// the sheet carries the exact text, and applying it twice changes
    /// nothing.
    @discardableResult
    public func applyProjectIgnorePlan(_ plan: ProjectIgnorePlan) -> Bool {
        do {
            let changed = try ProjectGitignore.apply(plan)
            guard changed else { return false }
            var candidate = currentSnapshot()
            candidate.activities.insert(
                ActivityReceipt(
                    kind: .configuration,
                    title: "Machine-local settings added to .gitignore",
                    detail:
                        "Appended \(plan.missingPatterns.count) line\(plan.missingPatterns.count == 1 ? "" : "s") so local agent settings are not shared with the repository.",
                    date: .now,
                    state: .healthy,
                    affectedPaths: [plan.gitignorePath]
                ), at: 0)
            _ = commit(candidate)
            refreshProject(at: plan.projectPath)
            return true
        } catch {
            presentError(error.localizedDescription)
            return false
        }
    }

    /// Re-reads one project after a change, without rescanning everything.
    public func refreshProject(at path: String) {
        let normalized = ProjectPath.canonical(path)
        guard let index = projects.firstIndex(where: { $0.path == normalized }) else { return }
        let origins = projects[index].origins
        guard let refreshed = ProjectDiscovery.inspect(root: URL(fileURLWithPath: normalized, isDirectory: true), origins: origins)
        else {
            projects.remove(at: index)
            return
        }
        projects[index] = refreshed
    }

    private func loadProjectPreferencesIfNeeded() {
        guard !hasLoadedProjectPreferences else { return }
        hasLoadedProjectPreferences = true
        pinnedProjectPaths = (try? store.load(Self.pinnedProjectsKey, as: [String].self)) ?? []
        projectScanRoots = (try? store.load(Self.projectScanRootsKey, as: [String].self)) ?? []
    }

    private func persistProjectPreferences(pinned: [String], scanRoots: [String]) -> Bool {
        do {
            try store.save(pinned, for: Self.pinnedProjectsKey)
            try store.save(scanRoots, for: Self.projectScanRootsKey)
            pinnedProjectPaths = pinned
            projectScanRoots = scanRoots
            return true
        } catch {
            presentError("The project list could not be saved: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated private static func inspectProjects(
        homeURL: URL,
        pinnedPaths: [String],
        scanRoots: [String]
    ) -> [DiscoveredProject] {
        var origins: [String: Set<ProjectDiscoveryOrigin>] = [:]
        var order: [String] = []

        func add(_ url: URL, _ origin: ProjectDiscoveryOrigin) {
            guard ProjectDiscovery.isEligibleProjectRoot(url, homeURL: homeURL) else { return }
            let key = ProjectPath.canonical(url)
            if origins[key] == nil { order.append(key) }
            origins[key, default: []].insert(origin)
        }

        for path in pinnedPaths.prefix(maximumPinnedProjects) {
            add(URL(fileURLWithPath: path, isDirectory: true), .pinned)
        }
        for root in scanRoots.prefix(maximumProjectScanRoots) {
            for url in ProjectDiscovery.scannedRoots(under: URL(fileURLWithPath: root, isDirectory: true)) {
                add(url, .scannedRoot)
            }
        }
        for url in ProjectDiscovery.sessionIndexRoots(homeURL: homeURL) {
            add(url, .sessionIndex)
        }

        return
            order
            .compactMap { path in
                ProjectDiscovery.inspect(root: URL(fileURLWithPath: path, isDirectory: true), origins: origins[path] ?? [])
            }
            .sorted(by: projectOrder)
    }

    /// Pinned first, then projects that carry configuration of their own, then
    /// the plain ones. Ordering is a configuration fact, never recency.
    nonisolated private static func projectOrder(_ left: DiscoveredProject, _ right: DiscoveredProject) -> Bool {
        if left.isPinned != right.isPinned { return left.isPinned }
        if left.isPlain != right.isPlain { return right.isPlain }
        let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return left.path < right.path
    }

    // MARK: - Projects section (additive block — end)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

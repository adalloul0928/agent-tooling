import Foundation
import Observation

@MainActor
@Observable
public final class AppModel {
    public internal(set) var skills: [Skill] {
        didSet {
            visibleInventoryCache.skills = nil
            if skills != oldValue { invalidateSkillAvailability() }
        }
    }
    public internal(set) var mcpServers: [MCPServer] {
        didSet {
            visibleInventoryCache.mcpServers = nil
        }
    }
    public internal(set) var plugins: [Plugin] {
        didSet {
            visibleInventoryCache.plugins = nil
        }
    }
    public internal(set) var profiles: [ToolingProfile]
    /// Reusable shelves. There is deliberately no "current" collection: being
    /// active belongs to a configuration, not to the material it is built from.
    public internal(set) var collections: [ToolingCollection]
    /// Tags filter. They never change what is installed.
    public internal(set) var tagAssignments: [TagAssignment]
    public internal(set) var activities: [ActivityReceipt] {
        didSet {
            visibleInventoryCache.activities = nil
        }
    }
    public internal(set) var syncStages: [SyncStage]
    public internal(set) var targetObservations: [TargetObservation] {
        didSet {
            visibleInventoryCache.targetObservations = nil
            if targetObservations != oldValue { invalidateSkillAvailability() }
        }
    }
    public internal(set) var sources: [ToolingSource] {
        didSet {
            visibleInventoryCache.sources = nil
        }
    }
    public internal(set) var marketplacePackages: [MarketplacePackage] {
        didSet {
            visibleInventoryCache.marketplacePackages = nil
        }
    }
    public internal(set) var accountSurfaces: [AccountSurface] {
        didSet {
            visibleInventoryCache.accountSurfaces = nil
        }
    }
    public internal(set) var connectors: [ConnectorRecord] {
        didSet {
            visibleInventoryCache.connectors = nil
        }
    }
    public internal(set) var operationReceipts: [OperationReceipt] {
        didSet {
            visibleInventoryCache.operationReceipts = nil
            visibleInventoryCache.activities = nil
        }
    }
    /// Installed copies compared against the fingerprint recorded when they
    /// were reviewed. Refreshed by `runDoctor()`.
    public internal(set) var installDrift: [InstalledPackageDrift] = []
    public internal(set) var mcpRuntimeStatuses: [MCPRuntimeStatus] = []
    public internal(set) var mcpRuntimeServers: [MCPRuntimeServer] = []
    public internal(set) var isRefreshingMCPRuntimes = false
    /// Legacy writes are held while an explicit versioned migration review is open.
    public internal(set) var isWorkspaceMigrationReviewActive = false
    public internal(set) var mcpRuntimeError: String?
    public internal(set) var pendingAgentRequests: [PendingAgentRequest] = []
    public internal(set) var pendingPlan: OperationPlan?
    public internal(set) var backupImportPreview: BackupImportPreview?
    public internal(set) var insightsReport: InsightsReport?

    public internal(set) var activeProfileID: String
    /// A Git repository can be imported as a source or backup. It is not the
    /// database or a prerequisite for using the app.
    public internal(set) var repositoryPath: String
    public internal(set) var enabledClients = Set(ClientKind.allCases) {
        didSet {
            visibleInventoryCache = VisibleInventoryCache()
            if enabledClients != oldValue { invalidateSkillAvailability() }
        }
    }
    public internal(set) var automaticallyCheckHealth = true
    public internal(set) var skillAvailabilityRevision = 0
    public internal(set) var isSyncing = false
    public internal(set) var isRunningDoctor = false
    public internal(set) var isExecutingPlan = false
    public internal(set) var isRefreshingMarketplace = false
    public internal(set) var isGeneratingSkill = false
    public internal(set) var isCheckingSkillRepository = false
    /// Detached safety reviews are still reading current package trees. Migration
    /// review begins only after every in-flight review has finished.
    var activeSafetyReviewCount = 0
    var isReviewingPlanSafety: Bool { activeSafetyReviewCount > 0 }
    /// Short-lived native plugin catalog probes are tracked so they cannot cross
    /// an exclusive migration-review boundary.
    var isInstallingSkillPlugin = false
    public internal(set) var isScanningInsights = false
    public internal(set) var lastError: String?
    public internal(set) var workspacePath: String
    public internal(set) var backupConfiguration: BackupConfiguration
    public internal(set) var encryptedSyncConfiguration: EncryptedSyncConfiguration
    public internal(set) var managedPolicies: [ManagedPolicy]

    /// Projections are rebuilt only when their source inventory or client
    /// selection changes, never for each row/body read. Getters still read the
    /// observed source so SwiftUI tracks the same dependencies on cache hits.
    @ObservationIgnored var visibleInventoryCache = VisibleInventoryCache()

    // Collaborators and persistence helpers are module-internal rather than
    // private so the per-feature extensions in the AppModel+*.swift files can
    // reach them. The module boundary, which is what public would widen, is
    // unchanged.
    let store: WorkspaceStore
    let library: WorkspaceLibrary
    let engine: OperationEngine
    let adapters: ClientAdapterRegistry
    let runner: any CommandRunning
    let homeURL: URL
    let marketplace: MarketplaceService
    let marketplaceProviders: [any MarketplaceProvider]
    let backupService: BackupService
    let encryptedSyncService: EncryptedSyncService
    let policyService: PolicyService
    let codexSkillDraftService: CodexSkillDraftService
    let toolingInsightsService: ToolingInsightsService
    @ObservationIgnored var skillAvailabilityCache = SkillAvailabilitySnapshot()
    @ObservationIgnored var skillAvailabilityGeneration = 0
    @ObservationIgnored var skillAvailabilityRequestedInputs: [SkillAvailabilityInput]?
    var pendingRestoreSnapshot: WorkspaceSnapshot?
    var pendingEncryptedSyncSnapshot: WorkspaceSnapshot?
    var pendingSkillAdoption: SkillAdoption?
    var pendingSkillRepositoryUpdate: SkillRepositoryUpdate?
    var pendingDiscoveredSkillInstall: DiscoveredSkillInstall?
    public internal(set) var onboardingCopyIssues: [SkillAdoptionRejection] = []
    /// Original discovery ID -> declared portable name, only after a reviewed
    /// copy has completed. Keep native discovery records untouched.
    public internal(set) var onboardingAdoptedSkillIDs: [String: String] = [:]
    var onboardingCopyIssuePreviewID: UUID?
    public internal(set) var encryptedSyncImportPreview: EncryptedSyncImportPreview?
    var hasBootstrapped = false

    // Projects section state. Stored properties cannot live in an extension,
    // so the section's behaviour is in AppModel+Projects.swift and its state
    // stays here with the rest of the model's state.
    public internal(set) var projects: [DiscoveredProject] = []
    public internal(set) var projectScanRoots: [String] = []
    public internal(set) var isDiscoveringProjects = false
    public internal(set) var hasDiscoveredProjects = false
    var pinnedProjectPaths: [String] = []
    var hasLoadedProjectPreferences = false

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
        self.enabledClients = snapshot.preferences.enabledClients
        self.automaticallyCheckHealth = snapshot.preferences.automaticallyCheckHealth
        self.managedPolicies = snapshot.managedPolicies
        self.syncStages = Self.syncStages(from: snapshot.targetObservations)
        self.pendingAgentRequests = (try? PendingRequestQueueService.pendingRequests(store: store)) ?? []
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

    public var activeProfile: ToolingProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    public var isBusy: Bool {
        isSyncing || isRunningDoctor || isExecutingPlan || isRefreshingMarketplace || isGeneratingSkill
            || isScanningInsights || isDiscoveringProjects || isCheckingSkillRepository
            || isRefreshingMCPRuntimes || isReviewingPlanSafety || isInstallingSkillPlugin
    }

    /// Disables competing commands while a change is running or awaiting
    /// review. A prepared plan is a snapshot of source and destination state;
    /// allowing another action to replace or invalidate it would make the
    /// review sheet misleading.
    public var isInteractionLocked: Bool {
        isWorkspaceMigrationReviewActive || isBusy || pendingPlan != nil
    }

    public var attentionCount: Int {
        let mcpAttention = visibleMCPServers.filter { $0.aggregateState == .attention || $0.aggregateState == .unavailable }.count
        let profileAttention = activeProfile?.checks.filter { $0.state == .attention || $0.state == .unavailable }.count ?? 0
        let clientAttention = visibleTargetObservations.filter { !$0.isCommandAvailable }.count
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
        refreshPendingRequests()
        if automaticallyCheckHealth {
            await runDoctor()
        } else {
            await refreshSkillAvailability()
        }
        await refreshMCPRuntimes()
        await refreshMarketplace()
    }

    /// Detects optional MCP runtime support without changing workloads. Direct
    /// native client configuration remains available even when ToolHive is not
    /// installed.
    public func refreshMCPRuntimes() async {
        guard !isWorkspaceMigrationReviewActive, !isRefreshingMCPRuntimes else { return }
        isRefreshingMCPRuntimes = true
        defer { isRefreshingMCPRuntimes = false }
        let direct = DirectMCPRuntimeProvider()
        let toolHive = ToolHiveMCPRuntimeProvider(runner: runner)
        async let directStatus = direct.status()
        async let toolHiveStatus = toolHive.status()
        let statuses = await (directStatus, toolHiveStatus)
        guard !Task.isCancelled else { return }
        mcpRuntimeStatuses = [statuses.0, statuses.1]
        do {
            let servers = try await toolHive.servers(after: statuses.1)
            try Task.checkCancellation()
            mcpRuntimeServers = servers
            mcpRuntimeError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            mcpRuntimeServers = []
            mcpRuntimeError = SensitiveValueRedactor.redact(error.localizedDescription)
        }
    }

    public func inspectToolHiveWorkload(_ name: String) async throws -> ToolHiveInspectionResult<ToolHiveWorkloadStatus> {
        try await ToolHiveRuntimeInspection(runner: runner).status(workloadName: name)
    }

    public func toolHiveLogs(_ name: String, proxy: Bool) async throws -> ToolHiveLogSnapshot {
        try await ToolHiveRuntimeInspection(runner: runner).logs(workloadName: name, proxy: proxy)
    }

    /// Reviews bounded, recent local conversation history on explicit request.
    /// Raw messages are tokenized and discarded inside the service; only the
    /// aggregate report is stored in this machine's local workspace database.
    public func runInsightsScan(options: InsightScanOptions) async {
        var options = options
        options.clients.formIntersection(enabledClients)
        guard ensureReadyForChange() else { return }
        guard !options.clients.intersection([.claude, .codex]).isEmpty else {
            presentError("Select Claude Code, Codex, or both before scanning recent work.")
            return
        }

        lastError = nil
        if options.includeMarketplaceRecommendations, !isRefreshingMarketplace {
            await refreshMarketplace()
        }
        guard !Task.isCancelled else { return }

        guard ensureReadyForChange() else { return }
        isScanningInsights = true
        defer { isScanningInsights = false }

        let report = await toolingInsightsService.scan(
            options: options,
            skills: visibleSkills,
            marketplacePackages: visibleMarketplacePackages,
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
        guard ensureReadyForChange() else { return }
        do {
            try store.removeInsightsReport()
            insightsReport = nil
        } catch {
            presentError("The insights report could not be removed: \(error.localizedDescription)")
        }
    }

    /// Reads real client state and never mutates a client configuration.
    @discardableResult
    public func runDoctor() async -> Bool {
        guard ensureReadyForChange() else { return false }
        isRunningDoctor = true
        defer { isRunningDoctor = false }
        let start = Date.now
        let scanned = await adapters.scanAll(homeURL: homeURL, runner: runner, clients: enabledClients)
        let observations = scanned + targetObservations.filter { !isClientEnabled($0.surface.client) }
        let scanHomeURL = homeURL
        var compiled = await Task.detached(priority: .userInitiated) {
            InventoryCompiler.compile(observations: scanned, homeURL: scanHomeURL)
        }.value
        compiled.skills = retainingExcludedClients(compiled.skills, existing: skills, clients: \.clients)
        compiled.mcpServers = retainingExcludedClients(compiled.mcpServers, existing: mcpServers, clients: \.clients)
        compiled.plugins = retainingExcludedClients(compiled.plugins, existing: plugins, clients: \.clients)
        let missing = scanned.filter { !$0.isCommandAvailable }.map { $0.surface.displayName }
        // Compare every install this app can prove it made against the
        // fingerprint recorded when the operator reviewed it. Drift is
        // reported as information; it never changes the setup-check state.
        installDrift = await InstalledPackageDriftInspector.inspect(store: store, clients: enabledClients)
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
                        ? enabledClients.isEmpty
                            ? "No clients selected."
                            : "Inspected \(availableClients.map(\.rawValue).joined(separator: ", ")) from local state."
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
        let persisted = commit(candidate)
        await refreshSkillAvailability()
        return persisted
    }

    /// Builds a reviewable plan. It does not perform changes until the user
    /// confirms the exact digest-bound plan through `executePendingPlan(_:)`.
    public func runSync() async {
        guard ensureReadyForChange() else { return }
        isSyncing = true
        defer { isSyncing = false }
        let installable = visibleSkills.filter { $0.owned && !$0.clients.isEmpty }
        var steps: [OperationStep] = []
        var selectedClients = Set<ClientKind>()
        var scopes = Set<ToolingScope>()
        for skill in installable {
            let configuredTargets =
                onboardingSyncTargets(for: skill)
                ?? Set(skill.clients.map(\.client)).intersection(enabledClients)
            guard !configuredTargets.isEmpty else { continue }
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
            if onboardingTargetBindings != nil {
                pendingPlan = OperationPlan(
                    kind: .installSkill, title: "Review setup",
                    summary: "No managed skill updates to apply for this configuration's recorded app assignments.",
                    steps: [
                        OperationStep(
                            kind: .manual, title: "Your setup is recorded",
                            detail:
                                "Native plugins and MCP servers remain tracked in your configuration. Review their native installation from Library when you want to change an app. Disabled or unverified skill assignments are excluded from sync.",
                            requiresUserAction: true
                        )
                    ], requiresConfirmation: false
                )
                return
            }
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
                            ? "Open a local skill, choose an enabled client, then sync again."
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

    @discardableResult
    public func executePendingPlan(_ reviewedPlan: ReviewedOperationPlan) async -> Bool {
        guard let pendingPlan, !isBusy else { return false }
        guard validateEnabledClients(in: pendingPlan) else { return false }
        do {
            try OperationPlanApproval.verify(
                pendingPlan,
                confirmedPlanID: reviewedPlan.plan.id,
                confirmedDigest: reviewedPlan.digest
            )
        } catch {
            presentError("The plan no longer matches what you reviewed: \(error.localizedDescription)")
            return false
        }
        let latestSafetyReview = await safetyReviewAsync(for: pendingPlan)
        guard !Task.isCancelled, !isWorkspaceMigrationReviewActive, self.pendingPlan?.id == pendingPlan.id else { return false }
        guard latestSafetyReview.planID == pendingPlan.id, !latestSafetyReview.hasBlockedSteps else {
            presentError(
                latestSafetyReview.blockedSteps.first?.blockReason
                    ?? "The plan's safety review is incomplete. Nothing was changed."
            )
            return false
        }
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
            return false
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
        completeSkillRepositoryUpdate(plan: pendingPlan, receipt: receipt)
        completeDiscoveredSkillInstall(plan: pendingPlan, receipt: receipt)
        isExecutingPlan = false
        if !Task.isCancelled {
            let postOperationScanPersisted = await runDoctor()
            if postOperationScanPersisted {
                reconcilePostOperationScan(receiptID: receipt.id, plan: pendingPlan)
            }
        }
        persist()
        return true
    }

    private func operationCompletedRequiredSteps(plan: OperationPlan, receipt: OperationReceipt) -> Bool {
        guard receipt.planID == plan.id else { return false }
        let results = Dictionary(uniqueKeysWithValues: receipt.results.map { ($0.stepID, $0.status) })
        return plan.steps.allSatisfy { step in
            guard let status = results[step.id] else { return false }
            if step.kind == .scan { return status == .pending || status == .succeeded }
            return step.requiresUserAction || step.kind == .manual || step.kind == .openURL
                ? status == .manual || status == .succeeded
                : status == .succeeded
        }
    }

    /// The engine records verification steps as pending because it cannot run
    /// the app-level inventory scan itself. Once `runDoctor()` returns, replace
    /// that provisional status in both the durable receipt and its activity.
    private func reconcilePostOperationScan(receiptID: UUID, plan: OperationPlan) {
        guard let receiptIndex = operationReceipts.firstIndex(where: { $0.id == receiptID }) else { return }
        let scanStepIDs = Set(plan.steps.filter { $0.kind == .scan }.map(\.id))
        guard !scanStepIDs.isEmpty else { return }

        var receipt = operationReceipts[receiptIndex]
        let finishedAt = Date.now
        for index in receipt.results.indices
        where scanStepIDs.contains(receipt.results[index].stepID) && receipt.results[index].status == .pending {
            receipt.results[index].status = .succeeded
            receipt.results[index].output = "Fresh local client state was inspected after the operation."
            receipt.results[index].finishedAt = finishedAt
        }
        for index in receipt.itemOutcomes.indices
        where scanStepIDs.contains(receipt.itemOutcomes[index].id) && receipt.itemOutcomes[index].status == .pending {
            receipt.itemOutcomes[index].status = .succeeded
            receipt.itemOutcomes[index].reason = "Fresh local client state was inspected after the operation."
        }
        receipt.state =
            receipt.results.contains(where: { $0.status == .failed })
            ? .attention
            : receipt.results.contains(where: { [.manual, .skipped, .pending].contains($0.status) }) ? .pending : .healthy
        receipt.verificationSummary =
            "\(receipt.outcomeTally). The post-operation setup check completed and the current client state is recorded."
        operationReceipts[receiptIndex] = receipt
        if let activityIndex = activities.firstIndex(where: { $0.operationReceiptID == receiptID }) {
            activities[activityIndex].state = receipt.state
            activities[activityIndex].detail = receipt.verificationSummary
        }
        do {
            try store.saveEntity(receipt, id: receipt.id.uuidString, domain: .receipts)
        } catch {
            presentError("The completed verification could not be added to its receipt: \(error.localizedDescription)")
        }
    }

    public func discardPendingPlan() {
        guard !isWorkspaceMigrationReviewActive, !isExecutingPlan else { return }
        pendingPlan = nil
        pendingRestoreSnapshot = nil
        pendingEncryptedSyncSnapshot = nil
        discardSkillRepositoryUpdate()
        discardDiscoveredSkillInstall()
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
        guard validateEnabledClients(in: plan) else { return false }
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

    /// Indexed in one pass. The Skills list asks for this on every layout pass
    /// with a few hundred rows on screen, so it must not be quadratic.
    public var adoptableSkillIDs: [String] {
        let sources = observedSkillSourcePaths()
        let bundledIDs = Set(
            targetObservations.flatMap { observation in
                observation.skillMetadata.compactMap { $0.value.providerPluginID == nil ? nil : $0.key }
            })
        return skills.filter { !$0.owned && !bundledIDs.contains($0.id) && sources[$0.id] != nil }.map(\.id)
    }

    public func planInstall(
        skillID: String,
        targets: Set<ClientKind>? = nil,
        includeFreshSessionCanary: Bool = false
    ) {
        guard ensureReadyForChange() else { return }
        if let targets, !requireEnabledClients(targets) { return }
        guard let skill = visibleSkills.first(where: { $0.id == skillID }) else {
            lastError = "The selected skill is no longer available."
            return
        }
        do {
            pendingPlan = try library.installPlan(
                for: skill,
                targets: targets ?? Set(skill.clients.map(\.client)).intersection(enabledClients),
                homeURL: homeURL,
                includeFreshSessionCanary: includeFreshSessionCanary
            )
        } catch {
            lastError = error.localizedDescription
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
        guard requireEnabledClients(selected) else { return nil }
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
        let selected = targets ?? Set(server.clients.map(\.client)).intersection(enabledClients)
        guard requireEnabledClients(selected) else { return }
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
        let operationScope = MCPClientCommand.scope(fromDisplayName: server.scope)
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
            guard MCPClientCommand.supportsScope(operationScope, client: client) else {
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
        guard requireEnabledClients([client]) else { return }
        guard ensureReadyForChange() else { return }
        if marketplacePackages.isEmpty { await refreshMarketplace() }
        guard ensureReadyForChange() else { return }
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
        result.enabledPlugins = enabledPlugins.filter { isItemVisible(.init(kind: .plugin, identifier: $0)) }.sorted()
        result.requiredMCPs = requiredMCPs.filter { isItemVisible(.init(kind: .mcpServer, identifier: $0)) }.sorted()
        result.requiredSkills = requiredSkills.filter { isItemVisible(.init(kind: .skill, identifier: $0)) }.sorted()
        result.includedCollections = includedCollections.sorted()
        result.checks = checks
        return result
    }

    /// Every item the named collections hold, de-duplicated across overlapping
    /// shelves so an item in two collections is still listed once.
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

    // MARK: - Tags

    public func tags(for item: ToolingItemReference) -> [String] {
        tagAssignments.first { $0.item == item }?.tags ?? []
    }

    /// Every tag in use, ordered for display. Filtering reads this; tagging
    /// never changes what is installed.
    public var allTags: [String] {
        ToolingTag.normalizedList(tagAssignments.flatMap(\.tags))
    }

    public func authenticate(serverID: String, client: ClientKind) {
        guard requireEnabledClients([client]) else { return }
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
        guard requireEnabledClients([client]) else { return }
        guard ensureReadyForChange() else { return }
        guard let server = mcpServers.first(where: { $0.id == serverID }) else {
            lastError = "The selected MCP server is no longer available."
            return
        }
        let operationScope = MCPClientCommand.scope(fromDisplayName: server.scope)
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
        // Asked the same way the configure path asks, so the app cannot add a
        // server through a route it will then refuse to remove it through.
        if !MCPClientCommand.supportsScope(operationScope, client: client) {
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
            scope: operationScope
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
        guard isClientEnabled(target.client) else { return false }
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
    func prepareInstallPlanAfterSaving(skill: Skill, draft: SkillDraft) {
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

    func ensureReadyForChange() -> Bool {
        guard !isWorkspaceMigrationReviewActive else {
            lastError = "Migration review is active. Finish or cancel it before changing this workspace."
            return false
        }
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

    func applyPersisted(_ snapshot: WorkspaceSnapshot) {
        if skills != snapshot.skills { skills = snapshot.skills }
        if mcpServers != snapshot.mcpServers { mcpServers = snapshot.mcpServers }
        if plugins != snapshot.plugins { plugins = snapshot.plugins }
        if profiles != snapshot.profiles { profiles = snapshot.profiles }
        if collections != snapshot.collections { collections = snapshot.collections }
        if tagAssignments != snapshot.tagAssignments { tagAssignments = snapshot.tagAssignments }
        if activities != snapshot.activities { activities = snapshot.activities }
        if operationReceipts != snapshot.operationReceipts { operationReceipts = snapshot.operationReceipts }
        if targetObservations != snapshot.targetObservations { targetObservations = snapshot.targetObservations }
        if sources != snapshot.sources { sources = snapshot.sources }
        if marketplacePackages != snapshot.marketplacePackages { marketplacePackages = snapshot.marketplacePackages }
        if accountSurfaces != snapshot.accountSurfaces { accountSurfaces = snapshot.accountSurfaces }
        if connectors != snapshot.connectors { connectors = snapshot.connectors }
        if activeProfileID != snapshot.activeProfileID { activeProfileID = snapshot.activeProfileID }
        let nextRepositoryPath = snapshot.importedRepositoryPath ?? workspacePath
        if repositoryPath != nextRepositoryPath { repositoryPath = nextRepositoryPath }
        if backupConfiguration != snapshot.backupConfiguration { backupConfiguration = snapshot.backupConfiguration }
        if encryptedSyncConfiguration != snapshot.encryptedSyncConfiguration { encryptedSyncConfiguration = snapshot.encryptedSyncConfiguration }
        if enabledClients != snapshot.preferences.enabledClients { enabledClients = snapshot.preferences.enabledClients }
        if automaticallyCheckHealth != snapshot.preferences.automaticallyCheckHealth { automaticallyCheckHealth = snapshot.preferences.automaticallyCheckHealth }
        if managedPolicies != snapshot.managedPolicies { managedPolicies = snapshot.managedPolicies }
        let nextSyncStages = Self.syncStages(from: snapshot.targetObservations)
        if syncStages != nextSyncStages { syncStages = nextSyncStages }
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

    /// Large package trees are reviewed away from the main actor so the plan
    /// sheet remains responsive while bounded filesystem and content checks
    /// run. The caller must still compare the result to its current plan.
    public func safetyReviewAsync(for plan: OperationPlan) async -> OperationPlanSafetyReview {
        guard !isWorkspaceMigrationReviewActive else {
            return OperationPlanSafetyReview(
                planID: plan.id,
                steps: plan.steps.map {
                    OperationStepSafetyReview(
                        stepID: $0.id,
                        stepTitle: $0.title,
                        ownership: .unprovable("Migration review is active. Finish or cancel it before running this safety review.")
                    )
                }
            )
        }
        activeSafetyReviewCount += 1
        defer { activeSafetyReviewCount -= 1 }
        let store = self.store
        let task = Task.detached(priority: .userInitiated) {
            OperationPlanSafetyReviewer.fromStore(store).review(plan)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
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

    func surface(for client: ClientKind) -> TargetSurface {
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

    func currentSnapshot() -> WorkspaceSnapshot {
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
                automaticallyCheckHealth: automaticallyCheckHealth, enabledClients: enabledClients
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

    func persistOrThrow() throws {
        try requireWorkspaceMigrationReviewInactive()
        let snapshot = currentSnapshot()
        try WorkspaceSnapshotValidator.validate(snapshot, mode: .localState)
        try store.saveWorkspaceSnapshot(snapshot)
        try store.pruneOperationHistory(keepingPlanIDs: Set(snapshot.operationReceipts.map(\.planID)))
    }

    @discardableResult
    func commit(_ candidate: WorkspaceSnapshot) -> Bool {
        do {
            try requireWorkspaceMigrationReviewInactive()
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

    func boundedActivityDetail(_ value: String) -> String {
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
                            id: "apps", name: "App status", detail: "Check setup to inspect your selected clients",
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

}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

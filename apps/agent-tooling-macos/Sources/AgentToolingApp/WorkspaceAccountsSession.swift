import AgentToolingCore
import AppKit
import Foundation
import Observation

/// The Accounts tab's state: what each hosted account puts in front of this
/// Mac's clients, the choices every Mac shares about it, and the reviewed plan
/// that makes this Mac follow those choices.
///
/// Three things are kept apart. Reading runs each client's own read-only
/// commands and changes nothing. Saving a choice writes the portable document,
/// which every Mac syncs, and changes no client. Applying is the one thing that
/// touches a client: it edits that client's own settings file through the
/// operation engine, after the person has seen the exact edits, and backs the
/// file up first.
@MainActor @Observable
final class WorkspaceAccountsSession {
    private(set) var observations: [AccountProvider: AccountObservation] = [:]
    private(set) var plans: [AccountProvider: AccountPreferencePlan] = [:]
    private(set) var readingProviders: Set<AccountProvider> = []
    private(set) var readingDepth: AccountSurfaceProbe.Depth?
    private(set) var isSaving = false
    private(set) var applyingProvider: AccountProvider?
    private(set) var errorMessage: String?
    private(set) var lastApplyMessage: String?
    private(set) var publishing = PublishingStatus()

    /// The plugins this repository's catalog publishes, and whether each is on
    /// the claude.ai account yet.
    struct PublishingStatus: Equatable {
        struct Plugin: Identifiable, Equatable {
            var name: String
            var isOnAccount: Bool
            /// Assigned to a project somewhere. On the account it would load in
            /// every project instead.
            var isProjectScoped: Bool
            var id: String { name }
        }

        /// The repository the agent-tooling marketplace was added from on this
        /// Mac, as `owner/repo` or a URL, when Claude Code recorded one.
        var marketplaceSource: String?
        var plugins: [Plugin] = []
    }

    @ObservationIgnored private let library: WorkspaceLibrarySession
    @ObservationIgnored private let device: WorkspaceDeviceSession
    @ObservationIgnored private let service: WorkspaceApplicationService
    @ObservationIgnored private let store: WorkspaceRevisionStore
    @ObservationIgnored private let sync: WorkspaceSyncSession?
    @ObservationIgnored private let homeRoot: URL
    @ObservationIgnored private let reader: any AccountSurfaceReading
    @ObservationIgnored private let openURL: @Sendable (URL) -> Void
    @ObservationIgnored private var generation: UInt64 = 0
    /// Callers waiting for every read in flight to finish.
    @ObservationIgnored private var readWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        library: WorkspaceLibrarySession, device: WorkspaceDeviceSession, service: WorkspaceApplicationService,
        store: WorkspaceRevisionStore, sync: WorkspaceSyncSession?, homeRoot: URL, reader: any AccountSurfaceReading,
        openURL: @escaping @Sendable (URL) -> Void = { url in
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
    ) {
        self.library = library
        self.device = device
        self.service = service
        self.store = store
        self.sync = sync
        self.homeRoot = homeRoot
        self.reader = reader
        self.openURL = openURL
    }

    // MARK: What there is

    /// The accounts whose client this Mac manages, in provider order.
    var providers: [AccountProvider] {
        device.managedClients.compactMap(AccountProvider.provider(for:)).sorted()
    }

    var isReading: Bool { !readingProviders.isEmpty }

    var preferences: AccountPreferences {
        library.state?.snapshot.document.accountPreferences ?? AccountPreferences()
    }

    var canWrite: Bool { library.access == .writable }

    func observation(_ provider: AccountProvider) -> AccountObservation? { observations[provider] }

    func plan(_ provider: AccountProvider) -> AccountPreferencePlan? { plans[provider] }

    func sharedValue(_ key: AccountPreferenceKey) -> AccountPreferenceValue? { preferences.value(for: key) }

    /// When the oldest of the current readings was taken.
    var lastReadAt: Date? { observations.values.map(\.observedAt).min() }

    /// Findings for Checkup and the counts for Home. The same facts, so the
    /// two can never disagree about what is wrong.
    var findings: [SetupFinding] {
        AccountAuditor.findings(
            observations: providers.compactMap { observations[$0] }, plans: plans, peers: peers,
            workspaceID: library.workspaceID)
    }

    var attentionFindings: [SetupFinding] { findings.filter { $0.severity >= .medium || $0.kind == .accountChoicesNotFollowed } }

    var peers: [AccountPeerReport] {
        (sync?.otherDeviceStatuses ?? []).map { AccountPeerReport(deviceName: $0.name, summaries: $0.accounts ?? []) }
    }

    /// What this Mac publishes about its accounts to the others.
    func publishedSummaries() -> [PublishedAccountSummary] {
        providers.compactMap { provider in
            guard let observation = observations[provider], observation.unavailableReason == nil else { return nil }
            return PublishedAccountSummary(
                observation: observation, workspaceID: library.workspaceID,
                switchesOutOfStep: plans[provider]?.outOfStep)
        }
    }

    // MARK: Reading

    /// Reads every managed account again. Reads only.
    func read(depth: AccountSurfaceProbe.Depth = .contents) async {
        await read(providers, depth: depth)
    }

    func read(_ wanted: [AccountProvider], depth: AccountSurfaceProbe.Depth) async {
        let fresh = wanted.filter { !readingProviders.contains($0) }
        guard !fresh.isEmpty else { return }
        readingProviders.formUnion(fresh)
        readingDepth = depth
        errorMessage = nil
        generation &+= 1
        let token = generation
        let reader = self.reader
        let read = await Task.detached(priority: .userInitiated) {
            await reader.read(fresh, depth: depth, now: .now)
        }.value
        readingProviders.subtract(fresh)
        for observation in read { observations[observation.provider] = observation }
        if readingProviders.isEmpty {
            readingDepth = nil
            let waiters = readWaiters
            readWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        if token == generation || readingProviders.isEmpty {
            await replan()
        }
    }

    /// Returns once no read is in flight.
    private func finishReads() async {
        while isReading {
            await withCheckedContinuation { readWaiters.append($0) }
        }
    }

    /// Reads once when nothing has been read, at the depth asked for. Used by
    /// Checkup, which only needs to know how each client signs in. A read
    /// already running is waited for, so its answer is used rather than lost.
    func readIfNeverRead(depth: AccountSurfaceProbe.Depth) async {
        await finishReads()
        let missing = providers.filter { observations[$0] == nil }
        guard !missing.isEmpty else {
            await replan()
            return
        }
        await read(missing, depth: depth)
    }

    /// Reads the contents of each account that has none yet: the tab's first
    /// visit. Checkup's lighter read, if one is running, is waited for and
    /// then followed by this one rather than taking its place.
    func readContentsIfMissing() async {
        await finishReads()
        let missing = providers.filter { observations[$0]?.contentsRead != true }
        guard !missing.isEmpty else {
            await replan()
            return
        }
        await read(missing, depth: .contents)
    }

    /// Recomputes what applying the shared choices would change here, against
    /// the settings files as they are now. Also refreshes the publishing card.
    func replan() async {
        let preferences = self.preferences
        let observations = self.observations
        let home = homeRoot
        let computed = await Task.detached(priority: .userInitiated) { () -> [AccountProvider: AccountPreferencePlan] in
            var plans: [AccountProvider: AccountPreferencePlan] = [:]
            for (provider, observation) in observations {
                let file = ClientConfigurationFile.settings(for: provider.client).url(homeURL: home)
                let text = try? String(contentsOf: file, encoding: .utf8)
                plans[provider] = AccountPreferencePlanner.plan(
                    preferences: preferences, observation: observation, configurationText: text)
            }
            return plans
        }.value
        plans = computed
        publishing = Self.publishingStatus(
            document: library.state?.snapshot.document, claude: observations[.claude], homeURL: homeRoot)
    }

    // MARK: Saving choices

    /// Records one choice for every Mac. Nil lets it go. Changes no client;
    /// the plan this leaves behind is what changes this Mac, once reviewed.
    @discardableResult
    func setChoice(_ key: AccountPreferenceKey, to value: AccountPreferenceValue?) async -> Bool {
        await save([.init(key: key, value: value)])
    }

    /// Records every switch this Mac's own settings file sets as a choice for
    /// every Mac, so the others can follow it.
    @discardableResult
    func shareThisMacsSettings(_ provider: AccountProvider) async -> Bool {
        let changes = shareableSettings(provider).map { SetAccountPreferencesCommand.Change(key: $0.key, value: $0.value) }
        guard !changes.isEmpty else { return false }
        return await save(changes)
    }

    /// What `shareThisMacsSettings` would record: the switches this Mac's file
    /// sets that every Mac does not already share with that value.
    func shareableSettings(_ provider: AccountProvider) -> [AccountPreference] {
        guard let observation = observations[provider] else { return [] }
        return observation.fileValues
            .filter { key, value in
                key.provider == provider && preferences.value(for: key) != value
                    && key.setting.acceptedValues.contains(value)
                    && key.subject.map { AccountPreferences.isValidSubject($0, for: key.setting) } ?? !key.setting.requiresSubject
            }
            .map { AccountPreference($0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
    }

    private func save(_ changes: [SetAccountPreferencesCommand.Change]) async -> Bool {
        guard canWrite, !isSaving, !changes.isEmpty else { return false }
        isSaving = true
        errorMessage = nil
        lastApplyMessage = nil
        defer { isSaving = false }
        do {
            guard let head = library.state?.snapshot.document.revision.id else {
                errorMessage = "This workspace could not be read. Nothing was saved."
                return false
            }
            _ = try await service.setAccountPreferences(.init(expectedRevisionID: head, changes: changes))
        } catch WorkspaceRevisionStoreError.staleRevision {
            errorMessage = "This workspace changed while you were choosing. Try again."
            return false
        } catch {
            errorMessage = "That choice could not be saved: \((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)"
            return false
        }
        await library.refresh()
        await replan()
        return true
    }

    // MARK: Applying

    /// The reviewed plan for one provider, ready for the review sheet.
    func operationPlan(_ provider: AccountProvider) -> OperationPlan? {
        guard let plan = plans[provider], !plan.isEmpty else { return nil }
        return try? plan.operationPlan(homeURL: homeRoot)
    }

    /// Makes this Mac follow the shared choices for one provider.
    ///
    /// The plan is computed again against the file as it is now, and refused
    /// if it no longer matches what the person reviewed, so what runs is what
    /// was shown. Returns a sentence about what happened.
    @discardableResult
    func apply(_ provider: AccountProvider, reviewed: AccountPreferencePlan? = nil) async -> String? {
        guard applyingProvider == nil, canWrite else { return nil }
        applyingProvider = provider
        errorMessage = nil
        lastApplyMessage = nil
        defer { applyingProvider = nil }
        let shown = reviewed ?? plans[provider]
        await replan()
        guard let plan = plans[provider], !plan.isEmpty else {
            lastApplyMessage = "\(provider.client.rawValue) already follows every shared \(provider.accountName) choice it can."
            return lastApplyMessage
        }
        if let shown, shown.changes.map(\.edits) != plan.changes.map(\.edits) {
            errorMessage = "\(plan.file.relativePath) changed since you reviewed it. Review the changes again."
            return nil
        }
        let operation: OperationPlan
        do { operation = try plan.operationPlan(homeURL: homeRoot) } catch {
            errorMessage = "The changes could not be prepared: \(error.localizedDescription)"
            return nil
        }
        let receipt = await OperationExecutor(store: store, homeURL: homeRoot).execute(operation)
        let failed = receipt.results.filter { $0.status == .failed }
        let depth: AccountSurfaceProbe.Depth = observations[provider]?.contentsRead == true ? .contents : .signInOnly
        await read([provider], depth: depth)
        await device.refresh()
        if let first = failed.first {
            errorMessage = "\(failed.count) of \(receipt.results.count) changes did not go through. First: \(first.output)"
            return nil
        }
        lastApplyMessage = "\(provider.client.rawValue) now follows \(plan.changes.count) shared choice\(plan.changes.count == 1 ? "" : "s"). Restart open \(provider.client.rawValue) sessions to pick them up."
        return lastApplyMessage
    }

    // MARK: Opening the vendor's pages

    func openSite(_ provider: AccountProvider, kind: AccountItemKind? = nil) {
        openURL(provider.manageURL(for: kind))
    }

    func open(_ item: AccountItem) {
        openURL(item.url ?? item.provider.manageURL(for: item.kind))
    }

    // MARK: Publishing

    static let ownMarketplace = "agent-tooling"

    /// Which plugins this repository's marketplace provides, from the
    /// library's own records, and which of them the claude.ai account carries.
    static func publishingStatus(
        document: PortableWorkspaceDocument?, claude: AccountObservation?, homeURL: URL
    ) -> PublishingStatus {
        var status = PublishingStatus(marketplaceSource: knownMarketplaceSource(named: ownMarketplace, homeURL: homeURL))
        guard let document else { return status }
        let synced = Set((claude?.items(.plugin) ?? []).map(\.key))
        var seen = Set<String>()
        for artifact in document.artifacts
        where artifact.identity.kind == .nativePlugin && artifact.identity.parentPackageID == nil {
            let names = artifact.nativeRoutes
                .filter { ClaudeAccountSync.origin(ofPluginID: $0.externalPluginID) == ownMarketplace }
                .map { ClaudeAccountSync.pluginName(ofPluginID: $0.externalPluginID) }
            guard let name = names.first, seen.insert(name).inserted else { continue }
            let projectScoped = document.assignments.contains {
                $0.artifactID == artifact.identity.id && [.project, .localProject].contains($0.destination.scope)
            }
            status.plugins.append(.init(name: name, isOnAccount: synced.contains(name), isProjectScoped: projectScoped))
        }
        status.plugins.sort { $0.name < $1.name }
        return status
    }

    /// The source Claude Code recorded for a marketplace, from its own
    /// `known_marketplaces.json`. Read only, and only the repository name.
    static func knownMarketplaceSource(named name: String, homeURL: URL) -> String? {
        let url = homeURL.appending(path: ".claude/plugins/known_marketplaces.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.utf8.count <= 4 * 1_024 * 1_024,
              let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[name] as? [String: Any],
              let source = entry["source"] as? [String: Any]
        else { return nil }
        let candidate = (source["repo"] as? String) ?? (source["url"] as? String)
        guard let candidate, !candidate.isEmpty, candidate.count <= 512,
              SensitiveValueRedactor.redact(candidate) == candidate
        else { return nil }
        return candidate
    }
}

import AgentToolingCore
import Foundation
import Observation

/// Everything Insights reaches for outside the app, behind one protocol.
///
/// The scan reads this Mac's own chat history and the report is kept in a file,
/// so both are injected rather than called: a test hands in a scan that returns
/// a canned report and a place to keep it that is only memory, and never reads
/// a real transcript or writes into a real support folder.
protocol InsightsServicing: Sendable {
    /// Reads local conversation history and returns aggregate findings only.
    /// Never installs, never writes to a client, and never keeps message text.
    func scan(options: InsightScanOptions, skills: [Skill], homeURL: URL) async -> InsightsReport
    /// The same pass, also handing back one redacted digest per conversation
    /// for the deep dive. The digests are not kept anywhere.
    func scanWithDigests(options: InsightScanOptions, skills: [Skill], homeURL: URL) async -> (
        report: InsightsReport, digests: [ConversationDigest]
    )
    /// Asks the person's own assistant to read the digests. Throws with the
    /// client's own words when it cannot.
    func deepDive(client: ClientKind, digests: [ConversationDigest], skills: [Skill], windowStart: Date) async throws -> InsightsDeepDive
    /// Reads the real SKILL.md description and file list for library-authored
    /// skills out of the content store, keyed by skill id.
    ///
    /// The projection can only report what a person asked for; this is how the
    /// scan learns what a skill's own captured tree actually says, so a health
    /// check does not fire "description too short" or "SKILL.md missing" against
    /// facts it never read. A build with no content store returns nothing, and
    /// every skill stays honestly unknown.
    func libraryContent(for requests: [SkillContentRequest]) async -> [String: SkillContentFacts]
    /// Whether there is a catalog to ask at all.
    ///
    /// The scan options offer catalog suggestions only when this is true, so
    /// the switch never promises a question this build cannot send anywhere.
    var canReachCatalog: Bool { get }
    /// The last report this Mac kept, if there is one.
    func lastReport() -> InsightsReport?
    func keep(_ report: InsightsReport) throws
    func forget() throws
}

/// One library-authored skill the scan wants the real content facts for: its
/// id, and the content-store digest of its captured tree to read them from.
struct SkillContentRequest: Sendable, Equatable {
    let skillID: String
    let digest: ContentDigest
}

extension InsightsServicing {
    /// Reaching no catalog is the safe answer: a scan that cannot ask one still
    /// works, and a screen told so offers nothing it cannot do.
    var canReachCatalog: Bool { false }

    /// A service with no digests to give runs the plain scan and hands back
    /// none, so a deep dive over it has nothing to read and says so.
    func scanWithDigests(options: InsightScanOptions, skills: [Skill], homeURL: URL) async -> (
        report: InsightsReport, digests: [ConversationDigest]
    ) {
        (await scan(options: options, skills: skills, homeURL: homeURL), [])
    }

    func deepDive(client: ClientKind, digests: [ConversationDigest], skills: [Skill], windowStart: Date) async throws -> InsightsDeepDive {
        throw InsightsDeepDiveError.nothingToRead
    }

    /// Reading no content is the safe answer: a build without a content store,
    /// or a test that hands in none, leaves every skill's description and files
    /// honestly unknown rather than inventing them.
    func libraryContent(for requests: [SkillContentRequest]) async -> [String: SkillContentFacts] { [:] }
}

/// The real scan, and the file the last report is kept in.
///
/// The report is aggregate counts and recommendations — `InsightsReport` says so
/// itself — so keeping it beside this Mac's workspace database keeps no message
/// text anywhere. It sits in the same device-local folder as this Mac's sync
/// enrollment and its linked presets, and travels to no other Mac.
struct LiveInsightsServices: InsightsServicing {
    /// A report is aggregate text. One that could not have been written by this
    /// app is not decoded at all rather than trusted because of its name.
    private static let maximumReportBytes = 8 * 1_024 * 1_024

    private let service = ToolingInsightsService()
    private let deepDiveService: InsightsDeepDiveService
    private let homeRoot: URL
    private let file: URL
    /// The workspace's content store directory. The scan opens a read handle on
    /// it to read a library skill's real SKILL.md; the objects there are
    /// immutable and content-addressed, so a second read handle is safe.
    private let contentDirectory: URL
    private let providers: [any MarketplaceProvider]
    private let cachedPackages: [MarketplacePackage]

    /// The catalogs default to the ones this build ships, so a scan that was
    /// asked for catalog suggestions has somewhere to ask. They are still a
    /// parameter: a test hands in none, and reaches no registry.
    init(
        container: URL,
        homeRoot: URL = FileManager.default.homeDirectoryForCurrentUser,
        providers: [any MarketplaceProvider] = MarketplaceProviderRegistry.builtIn(),
        cachedPackages: [MarketplacePackage] = []
    ) {
        file = container.appending(path: "insights-report.json")
        contentDirectory = container.appending(path: "content")
        self.homeRoot = homeRoot
        self.providers = providers
        self.cachedPackages = cachedPackages
        // The deep dive stages its schema file beside the skill drafts, inside
        // this workspace's own cache: the one place a request folder may be.
        deepDiveService = InsightsDeepDiveService(
            stagingRootURL: container.appending(path: "cache", directoryHint: .isDirectory)
                .appending(path: "insights-deep-dive", directoryHint: .isDirectory),
            homeURL: homeRoot)
    }

    /// Whether a catalog can be reached at all. The scan options offer catalog
    /// suggestions only when this is true, so the switch never promises a
    /// network call this build cannot make.
    var canReachCatalog: Bool { !providers.isEmpty }

    func scan(options: InsightScanOptions, skills: [Skill], homeURL: URL) async -> InsightsReport {
        await service.scan(
            options: options, skills: skills, marketplacePackages: cachedPackages, homeURL: homeURL,
            marketplaceProviders: providers)
    }

    func scanWithDigests(options: InsightScanOptions, skills: [Skill], homeURL: URL) async -> (
        report: InsightsReport, digests: [ConversationDigest]
    ) {
        await service.scanWithDigests(
            options: options, skills: skills, marketplacePackages: cachedPackages, homeURL: homeURL,
            marketplaceProviders: providers)
    }

    func deepDive(client: ClientKind, digests: [ConversationDigest], skills: [Skill], windowStart: Date) async throws -> InsightsDeepDive {
        try await deepDiveService.run(client: client, digests: digests, skills: skills, windowStart: windowStart)
    }

    /// Reads the real description and files for each requested library skill.
    ///
    /// The content store is opened read-only (`initializeIfEmpty: false`) so
    /// this never creates or mutates anything; a workspace with no content
    /// directory yet, or a digest with no stored object, simply drops out of
    /// the result and that skill stays honestly unknown. A read that throws is
    /// treated the same way — a failed read must not become a false finding.
    func libraryContent(for requests: [SkillContentRequest]) async -> [String: SkillContentFacts] {
        guard !requests.isEmpty,
            let store = try? CentralPackageContentStore(directory: contentDirectory, initializeIfEmpty: false)
        else { return [:] }
        var facts: [String: SkillContentFacts] = [:]
        for request in requests {
            guard let tree = try? await store.read(request.digest) else { continue }
            facts[request.skillID] = SkillContentFacts.read(from: tree)
        }
        return facts
    }

    func lastReport() -> InsightsReport? {
        guard let bytes = try? Data(contentsOf: file, options: [.mappedIfSafe]),
            bytes.count <= Self.maximumReportBytes
        else { return nil }
        return try? AgentToolingCoding.decoder().decode(InsightsReport.self, from: bytes)
    }

    func keep(_ report: InsightsReport) throws {
        try AgentToolingCoding.encoder().encode(report).write(to: file, options: .atomic)
    }

    func forget() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }
}

/// Shared read-only Insights state for Home and Insights. Background scans read
/// existing chat history; report actions navigate without writing. Cancelled or
/// superseded scans cannot replace or persist the current report.
@MainActor @Observable
final class WorkspaceInsightsSession {
    /// The last report on screen: this session's scan, or the one this Mac kept
    /// from a previous one.
    private(set) var report: InsightsReport?
    private(set) var isScanning = false
    /// True while the person's own assistant is reading the digests. The fast
    /// pass has already landed by then; this is the slow part, in the
    /// background, and the screen says so rather than blocking on it.
    private(set) var isDeepDiving = false
    private(set) var errorMessage: String?
    /// Why the last deep dive did not land, when it did not. Kept apart from
    /// `errorMessage` because the fast pass may have succeeded.
    private(set) var deepDiveMessage: String?
    /// When a scan in this session last finished. A restored report carries its
    /// own `generatedAt`, which is older and says so.
    private(set) var lastScannedAt: Date?

    /// How old the last deep dive may be before opening the app runs another.
    static let deepDiveStaleAfter: TimeInterval = 24 * 60 * 60

    @ObservationIgnored private let library: WorkspaceLibrarySession
    @ObservationIgnored private let services: any InsightsServicing
    @ObservationIgnored private let homeRoot: URL
    @ObservationIgnored private var scanTask: Task<InsightsReport, Never>?
    @ObservationIgnored private var deepDiveTask: Task<Void, Never>?
    /// Which scan the state on screen belongs to. A scan that is not the
    /// current one has been stopped or replaced, and its answer is dropped.
    @ObservationIgnored private var generation: UInt64 = 0
    /// The scan the launch started on its own, while it is the current one,
    /// and whether it hands its summaries to the assistant: turning the run
    /// it is off stops it, and never a scan a person started.
    @ObservationIgnored private var scheduledScan: (generation: UInt64, divesDeep: Bool)?
    /// The launch's own run, from its keyword pass to its deep dive's
    /// answer, while it runs: a main window opened again in the same launch
    /// waits for it rather than running beside it.
    @ObservationIgnored private var scheduledRun: Task<Void, Never>?

    /// One bounded read of the kept report, so opening the app shows the last
    /// scan rather than an empty screen somebody has to scan again to fill.
    init(
        library: WorkspaceLibrarySession,
        homeRoot: URL,
        services: any InsightsServicing
    ) {
        self.library = library
        self.homeRoot = homeRoot
        self.services = services
        report = services.lastReport()
    }

    /// Whether a scan can ask a catalog as well as read this Mac. The screen
    /// enables its catalog-suggestions switch on this and nothing else.
    var canReachCatalog: Bool { services.canReachCatalog }

    /// Which assistant the deep dive runs in: Claude Code when this Mac has it,
    /// else Codex, else none. Only the managed clients are considered.
    static func deepDiveClient(managed: [ClientKind]) -> ClientKind? {
        [ClientKind.claude, .codex].first(where: managed.contains)
    }

    /// Whether opening the app should run a deep dive now: the last one is
    /// older than a day, or there has never been one.
    var isDeepDiveStale: Bool {
        guard let last = report?.deepDive?.generatedAt else { return true }
        return Date.now.timeIntervalSince(last) > Self.deepDiveStaleAfter
    }

    /// Whether the kept report is older than a day, or there is none: when
    /// the local scan, run on its own, is due again.
    var isReportStale: Bool {
        guard let generated = report?.generatedAt else { return true }
        return Date.now.timeIntervalSince(generated) > Self.deepDiveStaleAfter
    }

    /// Runs due insights for managed clients under the current consent. Deep dives
    /// send keyword summaries to the assistant; local-only scans send nothing.
    /// `current` is rechecked before sending summaries. Existing scans or deep dives
    /// are awaited so the following weekly review cannot overlap them. A cancelled
    /// launch starts no new work; legacy consent preserves prior behavior.
    func runScheduledInsightsIfDue(
        consent: AssistantRunConsent, managedClients: [ClientKind], current: (@MainActor () -> AssistantRunConsent)? = nil
    ) async {
        if let running = scheduledRun {
            await running.value
            return
        }
        if isScanning || isDeepDiving {
            _ = await scanTask?.value
            await waitForDeepDive()
            return
        }
        guard !Task.isCancelled else { return }
        let options = InsightScanOptions(clients: Set(managedClients))
        let work: @MainActor () async -> Void
        if consent.dailyDeepDive, isDeepDiveStale, let client = Self.deepDiveClient(managed: managedClients) {
            work = {
                await self.run(
                    options: options, deepDiveWith: client, scheduled: true,
                    divesIf: { (current?() ?? consent).dailyDeepDive })
                await self.waitForDeepDive()
            }
        } else if consent.localInsights, isReportStale, !options.clients.isDisjoint(with: AssistantRunLimits.historyClients) {
            work = { await self.run(options: options, deepDiveWith: nil, scheduled: true) }
        } else {
            return
        }
        // Its own task, so a second launch lane can wait on the whole run.
        // Like the deep dive it ends in, it is not stopped by the window that
        // started it closing; turning it off does (`cancelScheduledRun`).
        let task = Task { await work() }
        scheduledRun = task
        await task.value
        if scheduledRun == task { scheduledRun = nil }
    }

    /// Returns once the deep dive running now has answered, failed or been
    /// stopped; at once when none is running.
    func waitForDeepDive() async {
        // Taken before waiting: the dive clears its own handle as it ends.
        let running = deepDiveTask
        await running?.value
    }

    /// Stops the run the launch started, while it is still the one running,
    /// unless `consent` allows it: a deep dive once the daily deep dive is
    /// off, a keyword scan on its own once local insights is. Left out,
    /// `consent` allows nothing, so the run stops whatever it is. A scan or
    /// deep dive a person started on Insights is left alone.
    func cancelScheduledRun(unlessAllowedBy consent: AssistantRunConsent = .off) {
        guard let scheduledScan, scheduledScan.generation == generation else { return }
        guard !(scheduledScan.divesDeep ? consent.dailyDeepDive : consent.localInsights) else { return }
        cancelScan()
    }

    /// Reviews recent work against the skills this workspace holds.
    ///
    /// The fast pass lands first and is shown; when `deepDiveWith` names a
    /// client, that client then reads the digests in the background and its
    /// conclusions are added to the same report when they arrive.
    ///
    /// Returns when the fast pass has finished, been stopped, or been replaced.
    func scan(options: InsightScanOptions, deepDiveWith deepDiveClient: ClientKind? = nil) async {
        await run(options: options, deepDiveWith: deepDiveClient, scheduled: false)
    }

    /// A scan, started by a person or by the launch (`scheduled`). The deep
    /// dive starts only while `divesIf` says it may, asked once the fast pass
    /// has landed.
    private func run(
        options: InsightScanOptions, deepDiveWith deepDiveClient: ClientKind?, scheduled: Bool,
        divesIf allowsDive: @MainActor () -> Bool = { true }
    ) async {
        guard !isScanning else { return }
        guard let state = library.state else {
            errorMessage =
                "This workspace's library has not been read yet, so there is nothing to compare recent work against."
            return
        }
        // The scan is under way from here, through reading the library's own
        // content, so stopping it (or turning a scheduled run off) holds from
        // the first moment, and a second scan does not start beside it.
        generation &+= 1
        let token = generation
        scheduledScan = scheduled ? (token, deepDiveClient != nil) : nil
        isScanning = true
        errorMessage = nil
        deepDiveTask?.cancel()
        deepDiveTask = nil
        isDeepDiving = false
        // The versioned library, in the shape the surviving scan already speaks.
        let projected = VersionedInventoryProjection.inventory(state.library).skills
        // The projection can only report requested intent, so a library-authored
        // skill's description and files arrive empty — unknown, not missing. Read
        // the real facts from each skill's own captured tree so the health checks
        // judge what the SKILL.md actually says instead of the placeholders.
        let requests = Self.libraryContentRequests(state.library)
        let facts = requests.isEmpty ? [:] : await services.libraryContent(for: requests)
        guard token == generation else { return }
        // Collapsed here as well as in the scan, so the deep dive is handed
        // the same one-per-skill list the fast pass judged.
        let skills = ToolCopyIdentity.collapsingCopies(
            projected.map { skill -> Skill in
                guard let fact = facts[skill.id] else { return skill }
                var enriched = skill
                if let description = fact.description { enriched.summary = description }
                enriched.files = fact.files
                // The facts came from reading this skill's own captured tree, so the
                // file list is now known — even when the tree genuinely holds none.
                enriched.filesKnown = true
                return enriched
            })
        let task = Task { [services, homeRoot] in
            await services.scanWithDigests(options: options, skills: skills, homeURL: homeRoot)
        }
        // Stopping the scan cancels the read itself, not only this handle on
        // it: a task that awaits another does not pass its cancellation on,
        // so without the handler a stopped scan ran to its end, and every
        // caller waiting on it waited too.
        scanTask = Task {
            await withTaskCancellationHandler {
                await task.value.report
            } onCancel: {
                task.cancel()
            }
        }
        let scanned = await task.value
        // A scan somebody stopped, or one a newer scan replaced, is no longer
        // this Mac's answer: it is dropped rather than written over what the
        // person is looking at.
        guard token == generation else { return }
        scanTask = nil
        isScanning = false
        // A fresh fast pass keeps the last deep dive until a new one lands:
        // the model's conclusions do not go stale because a keyword count did.
        var fresh = scanned.report
        fresh.deepDive = report?.deepDive
        report = fresh
        lastScannedAt = fresh.generatedAt
        keep(fresh)
        guard let deepDiveClient, allowsDive() else { return }
        startDeepDive(client: deepDiveClient, digests: scanned.digests, skills: skills, windowStart: fresh.windowStart, token: token)
    }

    /// Hands the digests to the assistant in the background. When its answer
    /// arrives and this is still the current scan, it joins the report on
    /// screen; a stopped or superseded run is dropped.
    private func startDeepDive(client: ClientKind, digests: [ConversationDigest], skills: [Skill], windowStart: Date, token: UInt64) {
        isDeepDiving = true
        deepDiveMessage = nil
        deepDiveTask = Task { [services] in
            let outcome: Result<InsightsDeepDive, any Error>
            do {
                outcome = .success(try await services.deepDive(client: client, digests: digests, skills: skills, windowStart: windowStart))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                guard token == self.generation else { return }
                self.isDeepDiving = false
                self.deepDiveTask = nil
                switch outcome {
                case .success(let dive):
                    guard var current = self.report else { return }
                    current.deepDive = dive
                    self.report = current
                    self.keep(current)
                case .failure(let error):
                    if error is CancellationError { return }
                    self.deepDiveMessage =
                        (error as? any LocalizedError)?.errorDescription ?? "\(client.rawValue) could not finish the deep dive."
                }
            }
        }
    }

    /// Fresh digests of recent work in `clients` for a setup review, read now
    /// and kept nowhere. The review passes the apps this Mac manages, so a
    /// summary never comes from an app it does not. Empty when the library is
    /// unread or none of `clients` has history to read.
    func digestsForReview(clients: Set<ClientKind>) async -> [ConversationDigest] {
        guard let state = library.state else { return [] }
        guard !clients.isDisjoint(with: AssistantRunLimits.historyClients) else { return [] }
        let skills = ToolCopyIdentity.collapsingCopies(VersionedInventoryProjection.inventory(state.library).skills)
        return await services.scanWithDigests(options: InsightScanOptions(clients: clients), skills: skills, homeURL: homeRoot).digests
    }

    private func keep(_ report: InsightsReport) {
        do {
            try services.keep(report)
        } catch {
            errorMessage = "This scan is on screen but could not be saved, so it will be gone when Agent Tooling closes."
        }
    }

    /// Stops the scan before it replaces the report on screen.
    ///
    /// The reading itself is a local pass that does not stop halfway; what this
    /// guarantees is that its result is never saved or shown.
    func cancelScan() {
        guard isScanning || scanTask != nil || deepDiveTask != nil else { return }
        generation &+= 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        deepDiveTask?.cancel()
        deepDiveTask = nil
        isDeepDiving = false
    }

    /// The library-authored skills worth reading real content for: the ones the
    /// workspace owns (its own or an upstream copy) that pin a captured tree by
    /// digest. A native-owned or tracked-only row is not the workspace's content
    /// to read, and a row with no digest has nothing stored to read.
    ///
    /// The projection derives a skill's id from its artifact id the same way, so
    /// these requests line up with the projected skills by id.
    private static func libraryContentRequests(_ library: WorkspaceLibraryReadModel) -> [SkillContentRequest] {
        var requests: [SkillContentRequest] = []
        for row in library.rows {
            if row.kind == .skill, isWorkspaceOwned(row.ownership), let digest = row.contentDigest {
                requests.append(.init(skillID: skillID(row.artifactID), digest: digest))
            }
            for child in row.includedChildren where child.kind == .skill {
                if isWorkspaceOwned(child.ownership), let digest = child.contentDigest {
                    requests.append(.init(skillID: skillID(child.artifactID), digest: digest))
                }
            }
        }
        return requests
    }

    private static func isWorkspaceOwned(_ ownership: WorkspaceLibraryOwnership) -> Bool {
        switch ownership {
        case .centralPersonal, .centralUpstream: true
        case .nativeOwned, .attachedAuthoring, .trackedOnly: false
        }
    }

    private static func skillID(_ id: ArtifactID) -> String {
        id.rawValue.uuidString.lowercased()
    }

    /// Forgets the saved aggregate report. Chat history is not touched.
    func clear() {
        report = nil
        lastScannedAt = nil
        errorMessage = nil
        deepDiveMessage = nil
        do {
            try services.forget()
        } catch {
            errorMessage = "The saved report could not be removed, so it may come back the next time Agent Tooling opens."
        }
    }
}

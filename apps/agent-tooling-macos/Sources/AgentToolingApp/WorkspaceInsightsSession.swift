import AgentToolingCore
import Foundation
import Observation
import SwiftUI

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

extension InsightsServicing {
    /// Reaching no catalog is the safe answer: a scan that cannot ask one still
    /// works, and a screen told so offers nothing it cannot do.
    var canReachCatalog: Bool { false }
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
    private let file: URL
    private let providers: [any MarketplaceProvider]
    private let cachedPackages: [MarketplacePackage]

    /// The catalogs default to the ones this build ships, so a scan that was
    /// asked for catalog suggestions has somewhere to ask. They are still a
    /// parameter: a test hands in none, and reaches no registry.
    init(
        container: URL,
        providers: [any MarketplaceProvider] = MarketplaceProviderRegistry.builtIn(),
        cachedPackages: [MarketplacePackage] = []
    ) {
        file = container.appending(path: "insights-report.json")
        self.providers = providers
        self.cachedPackages = cachedPackages
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

extension EnvironmentValues {
    /// How Insights gets its scan and its saved report, given this Mac's own
    /// workspace folder. A test replaces the whole factory.
    @Entry var insightsServices: (URL) -> any InsightsServicing = { LiveInsightsServices(container: $0) }
}

/// What this Mac's own recent work suggests, and nothing it does about it.
///
/// The scan is read-only in both directions: it reads chat history that already
/// exists and it installs nothing. The one thing this session can write is a
/// request for somebody to review later, which is not an install either.
///
/// Scanning never blocks the screen. The work runs off this actor, a scan can
/// be stopped before it replaces what is on screen, and a stopped or superseded
/// scan is dropped rather than saved.
@MainActor @Observable
final class WorkspaceInsightsSession {
    /// The last report on screen: this session's scan, or the one this Mac kept
    /// from a previous one.
    private(set) var report: InsightsReport?
    private(set) var isScanning = false
    private(set) var errorMessage: String?
    /// When a scan in this session last finished. A restored report carries its
    /// own `generatedAt`, which is older and says so.
    private(set) var lastScannedAt: Date?
    /// Recommendations this session has already asked somebody to review, so a
    /// row says it is waiting rather than offering to ask twice.
    private(set) var queuedDraftIDs: Set<String> = []

    @ObservationIgnored private let library: WorkspaceLibrarySession
    @ObservationIgnored private let store: WorkspaceRevisionStore
    @ObservationIgnored private let services: any InsightsServicing
    @ObservationIgnored private let homeRoot: URL
    @ObservationIgnored private var scanTask: Task<InsightsReport, Never>?
    /// Which scan the state on screen belongs to. A scan that is not the
    /// current one has been stopped or replaced, and its answer is dropped.
    @ObservationIgnored private var generation: UInt64 = 0

    /// One bounded read of the kept report, so opening the app shows the last
    /// scan rather than an empty screen somebody has to scan again to fill.
    init(
        library: WorkspaceLibrarySession,
        store: WorkspaceRevisionStore,
        homeRoot: URL,
        services: any InsightsServicing
    ) {
        self.library = library
        self.store = store
        self.homeRoot = homeRoot
        self.services = services
        report = services.lastReport()
    }

    /// Whether a scan can ask a catalog as well as read this Mac. The screen
    /// enables its catalog-suggestions switch on this and nothing else.
    var canReachCatalog: Bool { services.canReachCatalog }

    /// Reviews recent work against the skills this workspace holds.
    ///
    /// Returns when the scan has finished, been stopped, or been replaced.
    func scan(options: InsightScanOptions) async {
        guard !isScanning else { return }
        guard let state = library.state else {
            errorMessage =
                "This workspace's library has not been read yet, so there is nothing to compare recent work against."
            return
        }
        // The versioned library, in the shape the surviving scan already speaks.
        let skills = VersionedInventoryProjection.inventory(state.library).skills
        generation &+= 1
        let token = generation
        isScanning = true
        errorMessage = nil
        let task = Task { [services, homeRoot] in
            await services.scan(options: options, skills: skills, homeURL: homeRoot)
        }
        scanTask = task
        let scanned = await task.value
        // A scan somebody stopped, or one a newer scan replaced, is no longer
        // this Mac's answer: it is dropped rather than written over what the
        // person is looking at.
        guard token == generation else { return }
        scanTask = nil
        isScanning = false
        report = scanned
        lastScannedAt = scanned.generatedAt
        do {
            try services.keep(scanned)
        } catch {
            errorMessage = "This scan is on screen but could not be saved, so it will be gone when Agent Tooling closes."
        }
    }

    /// Stops the scan before it replaces the report on screen.
    ///
    /// The reading itself is a local pass that does not stop halfway; what this
    /// guarantees is that its result is never saved or shown.
    func cancelScan() {
        guard let scanTask else { return }
        generation &+= 1
        scanTask.cancel()
        self.scanTask = nil
        isScanning = false
    }

    /// Forgets the saved aggregate report. Chat history is not touched.
    func clear() {
        report = nil
        lastScannedAt = nil
        errorMessage = nil
        queuedDraftIDs.removeAll()
        do {
            try services.forget()
        } catch {
            errorMessage = "The saved report could not be removed, so it may come back the next time Agent Tooling opens."
        }
    }

    /// Asks for a skill to be drafted from one recommendation.
    ///
    /// This queues a request for review and does nothing else: no skill is
    /// created, nothing is written to a client, and the person still decides.
    /// The draft payload is kept beside the queued row, so the review can open
    /// what was actually asked for rather than a row with nothing behind it.
    func requestSkillDraft(from recommendation: ToolRecommendation, targets: [ClientKind]) async {
        guard recommendation.kind == .createCustomSkill, !queuedDraftIDs.contains(recommendation.id) else { return }
        let instruction = recommendation.draftInstruction ?? recommendation.summary
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        errorMessage = nil
        let store = self.store
        let requested = targets.isEmpty ? [ClientKind.codex] : targets
        do {
            try await Task.detached(priority: .userInitiated) {
                let outcome = try PendingRequestQueueService.enqueue(
                    kind: .createSkill,
                    title: "Create a skill for \(recommendation.title)",
                    summary: recommendation.summary,
                    componentID: nil,
                    scope: .user,
                    targets: requested,
                    reason: recommendation.rationale,
                    reviewDetails: PendingRequestReviewDetails(instruction: instruction),
                    fingerprintInputs: [recommendation.id, instruction],
                    clientLabel: "Insights",
                    store: store)
                // Bound to the queued row even when this collapsed into an
                // identical earlier ask, so a review can always be opened.
                let draft = CodexSkillDraftRequest(
                    id: outcome.request.id, instruction: instruction, scope: .user, targets: requested)
                do {
                    try store.saveRequestDraft(outcome.request.id, draft)
                } catch {
                    if !outcome.collapsed {
                        _ = try? PendingRequestQueueService.resolve(
                            id: outcome.request.id, expectedFingerprint: outcome.request.fingerprint, store: store)
                    }
                    throw error
                }
            }.value
            queuedDraftIDs.insert(recommendation.id)
        } catch let error as PendingRequestQueueError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "That request could not be queued for review. Nothing was changed."
        }
    }
}

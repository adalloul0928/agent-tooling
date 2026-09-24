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
        providers: [any MarketplaceProvider] = MarketplaceProviderRegistry.builtIn(),
        cachedPackages: [MarketplacePackage] = []
    ) {
        file = container.appending(path: "insights-report.json")
        contentDirectory = container.appending(path: "content")
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

/// What this Mac's own recent work suggests, and nothing it does about it.
///
/// The scan is read-only in both directions: it reads chat history that already
/// exists and it installs nothing. Every action a report offers opens a screen;
/// none of them writes anywhere.
///
/// There is one of these per launch, built by `WorkspaceLaunch` and handed to
/// both screens that read a report, so a scan started on Insights is the scan
/// Home reports and neither screen has its own idea of what was last found.
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

    @ObservationIgnored private let library: WorkspaceLibrarySession
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
        let projected = VersionedInventoryProjection.inventory(state.library).skills
        // The projection can only report requested intent, so a library-authored
        // skill's description and files arrive empty — unknown, not missing. Read
        // the real facts from each skill's own captured tree so the health checks
        // judge what the SKILL.md actually says instead of the placeholders.
        let requests = Self.libraryContentRequests(state.library)
        let facts = requests.isEmpty ? [:] : await services.libraryContent(for: requests)
        let skills = projected.map { skill -> Skill in
            guard let fact = facts[skill.id] else { return skill }
            var enriched = skill
            if let description = fact.description { enriched.summary = description }
            enriched.files = fact.files
            // The facts came from reading this skill's own captured tree, so the
            // file list is now known — even when the tree genuinely holds none.
            enriched.filesKnown = true
            return enriched
        }
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
        do {
            try services.forget()
        } catch {
            errorMessage = "The saved report could not be removed, so it may come back the next time Agent Tooling opens."
        }
    }
}

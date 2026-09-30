import AgentToolingCore
import Foundation
import Observation

/// Everything the setup, checkup, and client review reach outside the window:
/// the deterministic audit, the model pass, and the kept results. A test hands
/// in one that answers from memory; the app hands in the live one.
protocol SetupServicing: Sendable {
    /// Which folders a bare command is looked for in. Asks the login shell once.
    func searchPath(homeURL: URL) async -> [URL]
    /// The model pass. Throws in the client's words when it cannot run.
    func review(
        client: ClientKind, purpose: SetupReviewPrompt.Purpose, audit: SetupAuditReport, digests: [ConversationDigest],
        focus: ClientKind?, clientVersions: [ClientKind: String], releaseNotes: [String]
    ) async throws -> SetupReview
    func lastCheckup() -> SetupCheckup?
    func keep(_ checkup: SetupCheckup) throws
}

/// What a checkup left behind: the audit, the review if one ran, and the
/// findings the person has said to stop mentioning.
struct SetupCheckup: Codable, Equatable, Sendable {
    var audit: SetupAuditReport
    var review: SetupReview?
    var dismissedFindingIDs: Set<String>
    var dismissedRecommendationIDs: Set<String>
    /// When the last full checkup (audit and review) finished.
    var completedAt: Date

    init(audit: SetupAuditReport, review: SetupReview? = nil, dismissedFindingIDs: Set<String> = [], dismissedRecommendationIDs: Set<String> = [], completedAt: Date = .now) {
        self.audit = audit
        self.review = review
        self.dismissedFindingIDs = dismissedFindingIDs
        self.dismissedRecommendationIDs = dismissedRecommendationIDs
        self.completedAt = completedAt
    }

    var openFindings: [SetupFinding] { audit.findings.filter { !dismissedFindingIDs.contains($0.id) } }
    var openRecommendations: [SetupRecommendation] {
        (review?.recommendations ?? []).filter { !dismissedRecommendationIDs.contains($0.id) }
    }
}

struct LiveSetupServices: SetupServicing {
    private let file: URL
    private let reviewService: SetupReviewService
    private let homeRoot: URL

    init(container: URL, homeRoot: URL = FileManager.default.homeDirectoryForCurrentUser) {
        file = container.appending(path: "setup-checkup.json")
        self.homeRoot = homeRoot
        reviewService = SetupReviewService(
            stagingRootURL: container.appending(path: "cache", directoryHint: .isDirectory)
                .appending(path: "setup-review", directoryHint: .isDirectory),
            homeURL: homeRoot)
    }

    func searchPath(homeURL: URL) async -> [URL] {
        await SetupAuditor.searchPath(homeURL: homeURL, runner: ProcessCommandRunner(homeURL: homeURL))
    }

    func review(
        client: ClientKind, purpose: SetupReviewPrompt.Purpose, audit: SetupAuditReport, digests: [ConversationDigest],
        focus: ClientKind?, clientVersions: [ClientKind: String], releaseNotes: [String]
    ) async throws -> SetupReview {
        try await reviewService.run(
            client: client, purpose: purpose, audit: audit, digests: digests, focus: focus, clientVersions: clientVersions,
            releaseNotes: releaseNotes)
    }

    func lastCheckup() -> SetupCheckup? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SetupCheckup.self, from: data)
    }

    func keep(_ checkup: SetupCheckup) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(checkup).write(to: file, options: .atomic)
    }
}

/// The setup loop: audit this Mac, have the person's assistant read the audit,
/// and carry out what they choose, one reviewed action at a time.
///
/// Three rhythms share this one session. First-time setup runs it inside the
/// wizard; the weekly checkup runs it when the app opens and the last one is
/// old; a client review runs it for one app with the web allowed. None of them
/// changes anything until `apply` is called for one action.
@MainActor @Observable
final class WorkspaceSetupSession {
    private(set) var checkup: SetupCheckup?
    private(set) var isAuditing = false
    private(set) var isReviewing = false
    private(set) var isApplying = false
    private(set) var errorMessage: String?
    private(set) var reviewMessage: String?
    /// What the last apply did, in a sentence, for the screen to show.
    private(set) var lastApplyMessage: String?

    static let checkupStaleAfter: TimeInterval = 7 * 24 * 60 * 60

    @ObservationIgnored private let service: WorkspaceApplicationService
    @ObservationIgnored private let library: WorkspaceLibrarySession
    @ObservationIgnored private let device: WorkspaceDeviceSession
    @ObservationIgnored private let insights: WorkspaceInsightsSession
    @ObservationIgnored private let store: WorkspaceRevisionStore
    @ObservationIgnored private let homeRoot: URL
    @ObservationIgnored private let services: any SetupServicing
    @ObservationIgnored private var generation: UInt64 = 0

    init(
        service: WorkspaceApplicationService, library: WorkspaceLibrarySession, device: WorkspaceDeviceSession,
        insights: WorkspaceInsightsSession, store: WorkspaceRevisionStore, homeRoot: URL, services: any SetupServicing
    ) {
        self.service = service
        self.library = library
        self.device = device
        self.insights = insights
        self.store = store
        self.homeRoot = homeRoot
        self.services = services
        checkup = services.lastCheckup()
    }

    var isBusy: Bool { isAuditing || isReviewing || isApplying }

    var isStale: Bool {
        guard let completedAt = checkup?.completedAt else { return true }
        return Date.now.timeIntervalSince(completedAt) > Self.checkupStaleAfter
    }

    /// The assistant that reads the audit: Claude Code when this Mac has it,
    /// else Codex, else none.
    var reviewClient: ClientKind? {
        WorkspaceInsightsSession.deepDiveClient(managed: device.managedClients)
    }

    // MARK: Audit

    /// Reads what the last check saw and turns it into findings. Fast, local,
    /// and repeatable; runs a check first when there has never been one.
    func audit() async {
        guard !isAuditing else { return }
        generation &+= 1
        let token = generation
        isAuditing = true
        errorMessage = nil
        defer { if token == generation { isAuditing = false } }
        if device.observations.isEmpty { await device.refresh() }
        let observations = device.observations
        let managed = device.managedClients
        let managedNames = Set(
            (library.state?.snapshot.document.artifacts ?? [])
                .filter { $0.identity.kind == .skill && $0.authority != .trackedOnly }
                .compactMap(\.declaredName))
        let homeRoot = self.homeRoot
        let services = self.services
        let report = await Task.detached(priority: .userInitiated) {
            let searchPath = await services.searchPath(homeURL: homeRoot)
            return SetupAuditor(homeURL: homeRoot, searchPath: searchPath)
                .audit(observations: observations, managed: managed, library: .init(managedSkillNames: managedNames))
        }.value
        guard token == generation else { return }
        var next = checkup ?? SetupCheckup(audit: report)
        next.audit = report
        // A finding dismissed once stays dismissed while it persists; one that
        // is gone and comes back is new.
        next.dismissedFindingIDs = next.dismissedFindingIDs.intersection(report.findings.map(\.id))
        checkup = next
        keep()
    }

    // MARK: Review

    /// Hands the current audit to the assistant. The audit stays on screen
    /// while it reads; its answer joins the checkup when it lands.
    func review(purpose: SetupReviewPrompt.Purpose, focus: ClientKind? = nil, releaseNotes: [String] = []) async {
        guard !isReviewing, let audit = checkup?.audit else { return }
        guard let client = reviewClient else {
            reviewMessage = "A review needs Claude Code or Codex; this Mac is not managing either."
            return
        }
        generation &+= 1
        let token = generation
        isReviewing = true
        reviewMessage = nil
        defer { if token == generation { isReviewing = false } }
        let versions = Dictionary(
            device.observations.compactMap { observation -> (ClientKind, String)? in
                guard let client = observation.surface.client, let version = observation.version else { return nil }
                return (client, version)
            }, uniquingKeysWith: { first, _ in first })
        let digests = insights.report == nil ? [] : (await insights.digestsForReview())
        do {
            let review = try await services.review(
                client: client, purpose: purpose, audit: audit, digests: digests, focus: focus, clientVersions: versions,
                releaseNotes: releaseNotes)
            guard token == generation else { return }
            var next = checkup ?? SetupCheckup(audit: audit)
            next.review = review
            next.dismissedRecommendationIDs = next.dismissedRecommendationIDs.intersection(review.recommendations.map(\.id))
            next.completedAt = .now
            checkup = next
            keep()
        } catch {
            guard token == generation else { return }
            reviewMessage = (error as? any LocalizedError)?.errorDescription ?? "\(client.rawValue) could not finish the review."
        }
    }

    /// The weekly run: when the app opens and the last checkup is more than a
    /// week old, audit and review in the background.
    func runScheduledCheckupIfStale() async {
        guard isStale, !isBusy else { return }
        await audit()
        guard reviewClient != nil else { return }
        await review(purpose: .checkup)
    }

    // MARK: Dismissing

    func dismiss(_ finding: SetupFinding) {
        guard var next = checkup else { return }
        next.dismissedFindingIDs.insert(finding.id)
        checkup = next
        keep()
    }

    func undismiss(_ finding: SetupFinding) {
        guard var next = checkup else { return }
        next.dismissedFindingIDs.remove(finding.id)
        checkup = next
        keep()
    }

    func dismiss(_ recommendation: SetupRecommendation) {
        guard var next = checkup else { return }
        next.dismissedRecommendationIDs.insert(recommendation.id)
        checkup = next
        keep()
    }

    // MARK: Applying

    /// Carries out one action through the app's own reviewed paths, then
    /// re-audits so the screen shows what is true now. One action at a time:
    /// the person reads each before it runs.
    func apply(_ action: SetupAction) async {
        guard !isApplying else { return }
        isApplying = true
        errorMessage = nil
        lastApplyMessage = nil
        defer { isApplying = false }
        do {
            switch action {
            case .adoptSkill(let path, _):
                lastApplyMessage = try await adopt(path: path)
            case .removeSkillCopy(let path, let client), .removeBrokenLink(let path, let client):
                lastApplyMessage = try await remove(path: path, client: client)
            case .pruneStalePluginCache(let paths, let client):
                var removed = 0
                for path in paths { _ = try await removePluginCache(path: path, client: client); removed += 1 }
                lastApplyMessage = "Removed \(removed) old version\(removed == 1 ? "" : "s")."
            case .reinstallPlugin(let pluginID, let client):
                lastApplyMessage = try await reinstall(pluginID: pluginID, client: client)
            case .checkClient:
                await device.refresh()
                lastApplyMessage = "Checked."
            case .locateTool:
                await device.smartFindTools()
                lastApplyMessage = device.smartFindMessage ?? "Looked for the tool."
            case .inspectMCPServer, .manageMCPServer:
                // These open screens; the view handles them. Nothing to apply.
                return
            }
        } catch {
            errorMessage = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await library.refresh()
        await device.refresh()
        await audit()
    }

    func apply(_ action: SetupRecommendationAction) async {
        switch action {
        case .take(let setupAction):
            await apply(setupAction)
        case .installPlugin(let client, let pluginID):
            isApplying = true
            defer { isApplying = false }
            do { lastApplyMessage = try await reinstall(pluginID: pluginID, client: client) } catch {
                errorMessage = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            await device.refresh()
            await audit()
        case .setSetting, .disableMCPServer, .readOnly:
            // Settings and server toggles are shown with instructions; the
            // configuration screens own those writes.
            return
        }
    }

    private func adopt(path: String) async throws -> String {
        let prepared = try await WorkspaceSkillPreparation.capturePersonal(directory: URL(filePath: path, directoryHint: .isDirectory))
        guard let snapshot = library.state?.snapshot else { throw SetupApplyError.libraryUnread }
        guard
            let artifact = snapshot.document.artifacts.first(where: {
                $0.identity.kind == .skill && $0.authority == .trackedOnly && $0.declaredName == prepared.frontmatter.name
            })
        else { throw SetupApplyError.notTracked(prepared.frontmatter.name) }
        _ = try await service.adoptTrackedSkill(
            .init(expectedRevisionID: snapshot.document.revision.id, artifactID: artifact.identity.id, prepared: prepared), prepared: prepared)
        return "\(prepared.frontmatter.name) is in the library now. Choose where to use it from its details."
    }

    private func remove(path: String, client: ClientKind) async throws -> String {
        let plan = OperationPlan(
            kind: .installSkill, title: "Remove \(URL(filePath: path).lastPathComponent) from \(client.rawValue)",
            summary: "Moves the folder into this workspace's trash, or removes the link. The library's copy, if any, is untouched.",
            targetSurfaces: [client.userSurface].compactMap { $0 },
            steps: [.init(kind: .removeUnmanagedSkillCopy, title: "Remove the copy", detail: path, destinationPath: path, isReversible: true)])
        let receipt = await OperationExecutor(store: store, homeURL: homeRoot).execute(plan)
        guard let result = receipt.results.first else { throw SetupApplyError.nothingRan }
        guard result.status != .failed else { throw SetupApplyError.stepFailed(result.output) }
        return result.output
    }

    private func removePluginCache(path: String, client: ClientKind) async throws -> String {
        // An old plugin version folder is a client copy of a different shape:
        // it lives under the plugin cache, not a skills folder, so it goes
        // through the same step with the cache root as the permitted parent.
        let plan = OperationPlan(
            kind: .installPlugin, title: "Remove an old plugin version from \(client.rawValue)",
            summary: "Moves the unused version folder into this workspace's trash.",
            steps: [.init(kind: .removeUnmanagedPluginCache, title: "Remove the old version", detail: path, destinationPath: path, isReversible: true)])
        let receipt = await OperationExecutor(store: store, homeURL: homeRoot).execute(plan)
        guard let result = receipt.results.first else { throw SetupApplyError.nothingRan }
        guard result.status != .failed else { throw SetupApplyError.stepFailed(result.output) }
        return result.output
    }

    private func reinstall(pluginID: String, client: ClientKind) async throws -> String {
        let arguments: [String]
        switch client {
        case .claude: arguments = ["plugin", "install", pluginID, "--scope", "user"]
        case .codex: arguments = ["plugin", "add", pluginID]
        default: throw SetupApplyError.unsupported("\(client.rawValue) does not install plugins by command.")
        }
        let executable = ClientExecutableLocator.locate(client, homeURL: homeRoot)?.path(percentEncoded: false)
            ?? ClientExecutableLocator.executableName(for: client)
        let plan = OperationPlan(
            kind: .installPlugin, title: "Install \(pluginID) in \(client.rawValue)",
            summary: "Asks \(client.rawValue) to install the plugin with its own command.",
            targetSurfaces: [client.userSurface].compactMap { $0 },
            steps: [.init(kind: .command, title: "Install", detail: ([executable] + arguments).joined(separator: " "), executable: executable, arguments: arguments, stopsOnFailure: true)])
        let receipt = await OperationExecutor(store: store, homeURL: homeRoot).execute(plan)
        guard let result = receipt.results.first else { throw SetupApplyError.nothingRan }
        guard result.status != .failed else { throw SetupApplyError.stepFailed(result.output) }
        return "Installed \(pluginID)."
    }

    private func keep() {
        guard let checkup else { return }
        do { try services.keep(checkup) } catch {
            errorMessage = "This checkup is on screen but could not be saved, so it will be gone when Agent Tooling closes."
        }
    }
}

enum SetupApplyError: LocalizedError {
    case libraryUnread
    case notTracked(String)
    case nothingRan
    case stepFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .libraryUnread: "The library has not been read yet, so nothing was changed."
        case .notTracked(let name): "The library has no tracked record of \(name), so it cannot adopt it. Check the apps first."
        case .nothingRan: "Nothing ran."
        case .stepFailed(let output): output
        case .unsupported(let reason): reason
        }
    }
}

extension ClientKind {
    /// The user-level surface for a client, for a plan's target list.
    var userSurface: TargetSurface? {
        TargetSurface.allCases.first { $0.client == self && !$0.isCloud }
    }
}

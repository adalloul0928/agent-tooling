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
    /// What a client has published since the installed version. Reaches the
    /// network; throws in the fetcher's words when it cannot.
    func releaseNotes(for client: ClientKind, installedVersion: String?) async throws -> [ClientReleaseNote]
    func lastClientReviews() -> [ClientKind: ClientReview]
    func keep(clientReviews: [ClientKind: ClientReview]) throws
}

/// One app's review: what changed upstream since the installed version and
/// what the assistant recommends, with the notes it was handed.
struct ClientReview: Codable, Equatable, Sendable {
    var client: ClientKind
    var installedVersion: String?
    var latestVersion: String?
    var notes: [ClientReleaseNote]
    var review: SetupReview?
    var dismissedRecommendationIDs: Set<String>
    var completedAt: Date

    var openRecommendations: [SetupRecommendation] {
        (review?.recommendations ?? []).filter { !dismissedRecommendationIDs.contains($0.id) }
    }
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
    private let clientReviewsFile: URL
    private let reviewService: SetupReviewService
    private let releaseNotes: ClientReleaseNotesService
    private let homeRoot: URL

    init(container: URL, homeRoot: URL = FileManager.default.homeDirectoryForCurrentUser) {
        file = container.appending(path: "setup-checkup.json")
        clientReviewsFile = container.appending(path: "client-reviews.json")
        releaseNotes = ClientReleaseNotesService()
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

    func releaseNotes(for client: ClientKind, installedVersion: String?) async throws -> [ClientReleaseNote] {
        try await releaseNotes.notes(for: client, installedVersion: installedVersion)
    }

    func lastClientReviews() -> [ClientKind: ClientReview] {
        guard let data = try? Data(contentsOf: clientReviewsFile) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ClientReview].self, from: data)).map { Dictionary($0.map { ($0.client, $0) }, uniquingKeysWith: { first, _ in first }) } ?? [:]
    }

    func keep(clientReviews: [ClientKind: ClientReview]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(clientReviews.values.sorted { $0.client.rawValue < $1.client.rawValue }).write(to: clientReviewsFile, options: .atomic)
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
    /// How far a bulk apply has got: done of total. Nil when none is running.
    private(set) var applyProgress: (done: Int, total: Int)?
    /// One app's review, by app. Kept apart from the weekly checkup: it is
    /// asked for from that app's page and looks outward at what changed.
    private(set) var clientReviews: [ClientKind: ClientReview] = [:]
    private(set) var reviewingClient: ClientKind?
    private(set) var clientReviewMessage: String?

    static let checkupStaleAfter: TimeInterval = 7 * 24 * 60 * 60

    @ObservationIgnored private let service: WorkspaceApplicationService
    @ObservationIgnored private let library: WorkspaceLibrarySession
    @ObservationIgnored private let device: WorkspaceDeviceSession
    @ObservationIgnored private let insights: WorkspaceInsightsSession
    @ObservationIgnored private let store: WorkspaceRevisionStore
    @ObservationIgnored private let homeRoot: URL
    @ObservationIgnored private let services: any SetupServicing
    @ObservationIgnored private let accounts: WorkspaceAccountsSession?
    @ObservationIgnored private var generation: UInt64 = 0

    init(
        service: WorkspaceApplicationService, library: WorkspaceLibrarySession, device: WorkspaceDeviceSession,
        insights: WorkspaceInsightsSession, store: WorkspaceRevisionStore, homeRoot: URL, services: any SetupServicing,
        accounts: WorkspaceAccountsSession? = nil
    ) {
        self.service = service
        self.library = library
        self.device = device
        self.insights = insights
        self.store = store
        self.homeRoot = homeRoot
        self.services = services
        self.accounts = accounts
        checkup = services.lastCheckup()
        clientReviews = services.lastClientReviews()
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
        // An audit reports nothing of its own that could fail except keeping
        // the result, so it leaves any message an apply just set in place.
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
        let local = await Task.detached(priority: .userInitiated) {
            let searchPath = await services.searchPath(homeURL: homeRoot)
            return SetupAuditor(homeURL: homeRoot, searchPath: searchPath)
                .audit(observations: observations, managed: managed, library: .init(managedSkillNames: managedNames))
        }.value
        guard token == generation else { return }
        // How each client signs in to its hosted account, read lightly the
        // first time and reused after, joins the same report, so one Checkup
        // says everything this Mac has to look at.
        var report = local
        if let accounts {
            await accounts.readIfNeverRead(depth: .signInOnly)
            guard token == generation else { return }
            report = SetupAuditReport(
                generatedAt: local.generatedAt, clients: local.clients,
                findings: local.findings + accounts.findings, counts: local.counts)
        }
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

    /// The run on open. The audit is a second's work and reads only what the
    /// last check saw, so it runs every time and the list is always current;
    /// the assistant's review is the slow part and runs when the last one is
    /// more than a week old.
    func runScheduledCheckupIfStale() async {
        guard !isBusy else { return }
        let wasStale = isStale
        await audit()
        guard wasStale, reviewClient != nil else { return }
        await review(purpose: .checkup)
    }

    // MARK: Reviewing one app

    /// Fetches what the app has published since its installed version, then
    /// has the assistant read those notes, the audit's findings for the app,
    /// and (with the web allowed) the app's documentation, and say what to
    /// adopt. The assistant is Claude Code or Codex; the app under review can
    /// be any of them.
    func reviewClient(_ client: ClientKind) async {
        guard reviewingClient == nil else { return }
        guard let assistant = reviewClient else {
            clientReviewMessage = "A review needs Claude Code or Codex; this Mac is not managing either."
            return
        }
        reviewingClient = client
        clientReviewMessage = nil
        defer { reviewingClient = nil }
        if checkup == nil { await audit() }
        guard let audit = checkup?.audit else { return }
        let installed = device.observations.first { $0.surface.client == client && $0.version?.isEmpty == false }?.version
        var notes: [ClientReleaseNote] = []
        var noteFailure: String?
        do { notes = try await services.releaseNotes(for: client, installedVersion: installed) } catch {
            noteFailure = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        let versions = Dictionary(
            device.observations.compactMap { o -> (ClientKind, String)? in
                guard let c = o.surface.client, let v = o.version else { return nil }
                return (c, v)
            }, uniquingKeysWith: { first, _ in first })
        var next = ClientReview(
            client: client, installedVersion: installed, latestVersion: notes.first?.version, notes: notes, review: nil,
            dismissedRecommendationIDs: clientReviews[client]?.dismissedRecommendationIDs ?? [], completedAt: .now)
        do {
            let review = try await services.review(
                client: assistant, purpose: .clientReview, audit: audit, digests: [], focus: client, clientVersions: versions,
                releaseNotes: notes.map(\.rendered))
            next.review = review
            next.dismissedRecommendationIDs = next.dismissedRecommendationIDs.intersection(review.recommendations.map(\.id))
            if let noteFailure { clientReviewMessage = "The review ran without release notes: \(noteFailure)" }
        } catch {
            clientReviewMessage = (error as? any LocalizedError)?.errorDescription ?? "\(assistant.rawValue) could not finish the review."
            if let noteFailure { clientReviewMessage = (clientReviewMessage ?? "") + " \(noteFailure)" }
        }
        clientReviews[client] = next
        do { try services.keep(clientReviews: clientReviews) } catch {
            errorMessage = "This review is on screen but could not be saved."
        }
    }

    func dismiss(_ recommendation: SetupRecommendation, in client: ClientKind) {
        guard var review = clientReviews[client] else { return }
        review.dismissedRecommendationIDs.insert(recommendation.id)
        clientReviews[client] = review
        try? services.keep(clientReviews: clientReviews)
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
        // Opening the vendor's page changes nothing here, so it is not run
        // through the apply loop that re-checks the Mac afterwards.
        if case .openAccountSite(let provider, let kind) = action {
            accounts?.openSite(provider, kind: kind)
            return
        }
        await applyAll([action])
    }

    func apply(_ action: SetupRecommendationAction) async {
        switch action {
        case .take(let setupAction): await applyAll([setupAction])
        case .installPlugin(let client, let pluginID): await applyAll([.reinstallPlugin(pluginID: pluginID, client: client)])
        case .disableMCPServer(let client, let name): await applyAll([.disableMCPServer(name: name, client: client)])
        case .setSetting(let client, let key, let value): await applyAll([], settings: [(client, key, value)])
        case .readOnly: return
        }
    }

    /// Carries out several actions in order, each through the app's own
    /// reviewed paths, then re-audits once so the screen shows what is true
    /// now. One that fails does not stop the rest; the message says how many
    /// went through and quotes the first failure.
    func applyAll(_ actions: [SetupAction], settings: [(ClientKind, String, String)] = []) async {
        let work: [() async throws -> String] = actions.map { action in { try await self.perform(action) } }
            + settings.map { setting in { try await self.setSetting(client: setting.0, key: setting.1, value: setting.2) } }
        guard !isApplying, !work.isEmpty else { return }
        isApplying = true
        errorMessage = nil
        lastApplyMessage = nil
        applyProgress = (0, work.count)
        defer {
            isApplying = false
            applyProgress = nil
        }
        var done: [String] = []
        var failures: [String] = []
        for (index, step) in work.enumerated() {
            do { done.append(try await step()) } catch {
                failures.append((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            applyProgress = (index + 1, work.count)
        }
        if work.count == 1 {
            lastApplyMessage = done.first
            errorMessage = failures.first
        } else {
            lastApplyMessage = "\(done.count) of \(work.count) done."
            if let first = failures.first {
                errorMessage = "\(failures.count) did not go through. First: \(first)"
            }
        }
        await library.refresh()
        await device.refresh()
        await audit()
    }

    /// One action, in a sentence about what it did. Opening a screen is not
    /// an action here; the view does that.
    private func perform(_ action: SetupAction) async throws -> String {
        switch action {
        case .adoptSkill(let path, _):
            return try await adopt(path: path)
        case .removeSkillCopy(let path, let client), .removeBrokenLink(let path, let client):
            return try await remove(path: path, client: client)
        case .pruneStalePluginCache(let paths, let client):
            for path in paths { _ = try await removePluginCache(path: path, client: client) }
            return "Removed \(paths.count) old version\(paths.count == 1 ? "" : "s")."
        case .reinstallPlugin(let pluginID, let client):
            return try await reinstall(pluginID: pluginID, client: client)
        case .disableMCPServer(let name, let client):
            return try await disableMCPServer(name: name, client: client)
        case .checkClient:
            await device.refresh()
            return "Checked."
        case .locateTool:
            await device.smartFindTools()
            return device.smartFindMessage ?? "Looked for the tool."
        case .inspectMCPServer, .manageMCPServer, .openAccounts:
            return "Opened."
        case .openAccountSite(let provider, let kind):
            accounts?.openSite(provider, kind: kind)
            return "Opened \(provider.accountName)."
        case .applyAccountChoices(let provider):
            guard let accounts else { throw SetupApplyError.unsupported("Account choices are not available here.") }
            if let message = await accounts.apply(provider) { return message }
            throw SetupApplyError.stepFailed(accounts.errorMessage ?? "The shared \(provider.accountName) choices were not applied.")
        }
    }

    // MARK: Configuration writes

    /// Sets one documented key in the client's user-level settings file. The
    /// value is parsed, never run; the file is backed up first.
    private func setSetting(client: ClientKind, key: String, value: String) async throws -> String {
        let file = ClientConfigurationFile.settings(for: client)
        let edit = ClientConfigurationEdit(file: file, keyPath: key.split(separator: ".").map(String.init), value: .parsing(value))
        guard edit.isSafe else { throw SetupApplyError.unsupported("\(key) is not a key this app will write.") }
        return try await runEdits([edit], title: "Set \(key) in \(client.rawValue)", client: client)
    }

    /// Turns a server off where the client records that: Codex's
    /// `[mcp_servers.<name>] enabled = false`, Kiro's `disabled: true`, and for
    /// Claude Code the `disabledMcpServers` list of every project it knows,
    /// which is the only place Claude Code reads one.
    private func disableMCPServer(name: String, client: ClientKind) async throws -> String {
        guard ClientConfigurationEdit.isSafeKeyComponent(name), !name.contains("/"), !name.contains(" ") else {
            throw SetupApplyError.unsupported("\(name) is not a server name this app will write.")
        }
        let edits: [ClientConfigurationEdit]
        switch client {
        case .codex:
            edits = [.init(file: .codexConfig, keyPath: ["mcp_servers", name, "enabled"], value: .bool(false))]
        case .kiro:
            edits = [.init(file: .kiroMCP, keyPath: ["mcpServers", name, "disabled"], value: .bool(true))]
        case .claude:
            let home = homeRoot
            let projects = try await Task.detached(priority: .userInitiated) {
                try Self.claudeProjects(homeURL: home)
            }.value
            guard !projects.isEmpty else {
                throw SetupApplyError.unsupported("Claude Code turns servers off per project, and it has no projects recorded yet. Open a project in Claude Code and use /mcp there.")
            }
            edits = projects.map { .init(file: .claudeGlobal, keyPath: ["projects", $0, "disabledMcpServers"], value: .appendToList(name)) }
        case .gemini:
            throw SetupApplyError.unsupported("Gemini CLI has no switch for one server that this app knows how to write.")
        }
        let note = client == .claude ? " in \(edits.count) project\(edits.count == 1 ? "" : "s")" : ""
        _ = try await runEdits(edits, title: "Turn \(name) off in \(client.rawValue)", client: client)
        return "Turned \(name) off in \(client.rawValue)\(note). Its configuration is kept."
    }

    /// The projects Claude Code records in `~/.claude.json`, the file it reads
    /// each project's turned-off servers from. That file also keeps every
    /// project's history, so it is the client configuration most likely to be
    /// large: it is read bounded, off the main actor, and one over the limit
    /// or one that is not JSON turns nothing off rather than reading as a file
    /// with no projects.
    nonisolated static func claudeProjects(homeURL: URL) throws -> [String] {
        let file = ClientConfigurationFile.claudeGlobal
        guard let text = try file.readText(homeURL: homeURL), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw SetupApplyError.unsupported("\(file.relativePath) could not be read as JSON, so no server was turned off.")
        }
        return ((root["projects"] as? [String: Any]) ?? [:]).keys.sorted()
    }

    private func runEdits(_ edits: [ClientConfigurationEdit], title: String, client: ClientKind) async throws -> String {
        let plan = OperationPlan(
            kind: .configureMCP, title: title,
            summary: "Changes one key in \(client.rawValue)'s own configuration file. The file is copied into this workspace's trash first.",
            targetSurfaces: [client.userSurface].compactMap { $0 },
            steps: try edits.map { edit in
                OperationStep(
                    kind: .editClientConfiguration, title: edit.summary, detail: edit.file.relativePath,
                    destinationPath: edit.file.url(homeURL: homeRoot).path(percentEncoded: false), contents: try edit.encoded(), isReversible: true)
            })
        let receipt = await OperationExecutor(store: store, homeURL: homeRoot).execute(plan)
        if let failed = receipt.results.first(where: { $0.status == .failed }) { throw SetupApplyError.stepFailed(failed.output) }
        return receipt.results.map(\.output).joined(separator: " ")
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
        return "\(prepared.frontmatter.name) is in the library now. Install it from its details."
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

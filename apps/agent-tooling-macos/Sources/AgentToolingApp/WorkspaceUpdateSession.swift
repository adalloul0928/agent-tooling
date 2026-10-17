import AgentToolingCore
import Foundation

/// Updates to what this Mac manages: finding them, and installing them.
///
/// A check asks each source what it publishes now and compares it with what
/// the library approved. Followed skills are compared with their repository;
/// native plugins with the catalog this Mac kept from Discover; MCP servers
/// with the catalog entry of the same name, when one exists. Nothing changes
/// during a check.
///
/// Installing an update is the same two steps installing anything is: the
/// library takes the new content, then the planner replaces the copies this
/// app proved it installed. A native plugin is different: its app owns it, so
/// the update is the app's own `plugin update` command, run through the
/// executor's allowlist like every other command.
///
/// `UpdatePolicy` decides, per kind, whether a found update is installed at
/// once or waits for a press. The scheduled check reads that policy; the
/// buttons ignore it, because a press is the ask.
@MainActor @Observable
final class WorkspaceUpdateSession {
    struct Entry: Identifiable, Equatable {
        let id: ArtifactID
        let displayName: String
        let kind: ToolingItemKind
        var availability: UpdateAvailability
        /// Why the Update button would do nothing here, or `nil` when it can
        /// run. A plugin whose app has no recorded update command is updated
        /// in that app.
        var cannotUpdate: String?
    }

    /// How content a followed skill's repository publishes is fetched. A
    /// test answers from memory; the app runs the bounded Git fetch.
    typealias UpstreamFetcher = @Sendable (SkillRepositoryBinding, URL) async throws -> PreparedStandaloneSkill

    private(set) var entries: [ArtifactID: Entry] = [:]
    private(set) var isChecking = false
    private(set) var updating: Set<ArtifactID> = []
    private(set) var errorMessage: String?
    /// Updates installed by the last check, under the automatic policy.
    private(set) var installedAutomatically: [String] = []
    /// What the last update left alone, and where it can be dealt with.
    private(set) var notice: String?

    private let library: WorkspaceLibrarySession
    private let deployment: WorkspaceDeploymentSession
    private let device: WorkspaceDeviceSession
    private let marketplace: WorkspaceMarketplaceSession
    private let service: WorkspaceApplicationService
    private let store: WorkspaceRevisionStore
    private let homeRoot: URL
    private let cacheRoot: URL
    private let fetchUpstream: UpstreamFetcher
    /// What each followed skill's repository published at the last check,
    /// so applying installs exactly what was compared.
    private var fetched: [ArtifactID: PreparedStandaloneSkill] = [:]

    init(
        library: WorkspaceLibrarySession, deployment: WorkspaceDeploymentSession,
        device: WorkspaceDeviceSession, marketplace: WorkspaceMarketplaceSession,
        service: WorkspaceApplicationService, store: WorkspaceRevisionStore, homeRoot: URL,
        fetchUpstream: @escaping UpstreamFetcher = { try await WorkspaceSkillPreparation.fetchUpstream(binding: $0, cacheURL: $1) }
    ) {
        self.library = library
        self.deployment = deployment
        self.device = device
        self.marketplace = marketplace
        self.service = service
        self.store = store
        self.homeRoot = homeRoot
        self.cacheRoot = store.rootURL.appending(path: "cache/upstream-checks", directoryHint: .isDirectory)
        self.fetchUpstream = fetchUpstream
    }

    // MARK: Reading

    var available: [Entry] {
        entries.values.filter { $0.availability.hasUpdate }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func availability(for artifactID: ArtifactID) -> UpdateAvailability? { entries[artifactID]?.availability }

    var isBusy: Bool { isChecking || !updating.isEmpty }

    // MARK: Checking

    /// Runs a check when the policy's cadence says one is due. The shell calls
    /// this on open; a check that found nothing to compare is still a check.
    func checkIfDue(now: Date = .now) async {
        let policy = device.updatePolicy
        guard policy.cadence.isDue(lastChecked: device.lastUpdateCheck, now: now) else { return }
        await check(installingAutomatically: true)
    }

    /// Compares everything this Mac manages with its sources. With
    /// `installingAutomatically`, kinds the policy marks automatic are then
    /// updated without a press; a button's check leaves that to the person.
    func check(installingAutomatically: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil
        installedAutomatically = []
        defer { isChecking = false }

        if library.state == nil { await library.refresh() }
        guard let state = library.state else {
            errorMessage = library.errorMessage ?? "The library could not be read, so nothing was compared."
            return
        }
        var next: [ArtifactID: Entry] = [:]

        // Followed skills: what the repository publishes against what this
        // library approved. One fetch per skill, in turn; a repository that
        // cannot be reached is reported for that skill, and the rest go on.
        for (artifactID, binding, name, digest, approved) in followedSkills(in: state) {
            do {
                let prepared = try await fetchUpstream(binding, cacheRoot)
                fetched[artifactID] = prepared
                let same = prepared.review.contentDigest == digest
                let revision = prepared.review.upstream.map { Self.shortRevision($0.revision) } ?? "the repository's current content"
                next[artifactID] = .init(
                    id: artifactID, displayName: name, kind: .skill,
                    availability: same
                        ? .upToDate(revision: revision)
                        : .updateAvailable(installed: Self.shortRevision(approved), available: revision))
            } catch {
                fetched[artifactID] = nil
                next[artifactID] = .init(
                    id: artifactID, displayName: name, kind: .skill,
                    availability: .checkFailed(reason: "The repository could not be read. \(error.localizedDescription)"))
            }
        }

        // Native plugins and MCP servers: the catalog's word. Refreshed first,
        // so the comparison is with today's listing and not the one Discover
        // last happened to see.
        await marketplace.refresh()
        let evaluation = PluginUpdateEvaluation(
            state: state,
            packages: marketplace.packages.isEmpty ? nil : marketplace.packages,
            sources: marketplace.sources.isEmpty ? nil : marketplace.sources)
        for row in state.library.rows where row.kind == .nativePlugin || row.kind == .package {
            guard let availability = evaluation.availability[row.artifactID] else { continue }
            next[row.artifactID] = .init(
                id: row.artifactID, displayName: row.displayName, kind: .plugin,
                availability: availability, cannotUpdate: pluginUpdateRefusal(for: row))
        }
        for row in state.library.rows where row.kind == .mcpServer {
            guard
                let package = marketplace.packages.first(where: { package in
                    package.components.contains(.mcpServer)
                        && package.name.caseInsensitiveCompare(row.displayName) == .orderedSame
                }), let status = package.updateStatus
            else { continue }
            let availability: UpdateAvailability =
                switch status {
                case .updateAvailable:
                    .updateAvailable(installed: "the recorded connection", available: package.revision ?? "a newer listing")
                case .current: .upToDate(revision: package.revision ?? "the current listing")
                case .locallyModified, .conflict, .unknown:
                    .unknown(reason: "\(package.sourceName) could not say whether this connection changed.")
                }
            next[row.artifactID] = .init(
                id: row.artifactID, displayName: row.displayName, kind: .mcpServer, availability: availability,
                cannotUpdate:
                    "Connections are set up once; a changed listing is applied by removing and adding it again from the Connections screen."
            )
        }

        entries = next
        await device.recordUpdateCheck()

        guard installingAutomatically else { return }
        let policy = device.updatePolicy
        for entry in available where policy.policy(for: entry.kind) == .automatic && entry.cannotUpdate == nil {
            if await update(entry.id) { installedAutomatically.append(entry.displayName) }
        }
    }

    /// Records what a check would have found, for a caller that already knows.
    /// Tests use it to stand in for a catalog; the app never calls it.
    func record(_ entry: Entry) { entries[entry.id] = entry }

    // MARK: Updating

    /// Installs one found update. Returns whether it landed.
    @discardableResult
    func update(_ artifactID: ArtifactID) async -> Bool {
        guard let entry = entries[artifactID], entry.availability.hasUpdate, !updating.contains(artifactID),
            entry.cannotUpdate == nil
        else { return false }
        updating.insert(artifactID)
        errorMessage = nil
        notice = nil
        defer { updating.remove(artifactID) }
        let landed: Bool
        switch entry.kind {
        case .skill: landed = await updateSkill(entry)
        case .plugin: landed = await updatePlugin(entry)
        case .mcpServer: landed = false
        }
        if landed {
            entries[artifactID]?.availability = .upToDate(revision: "the content installed just now")
            fetched[artifactID] = nil
        }
        return landed
    }

    /// Installs every found update of one kind that can be installed from here.
    func updateAll(_ kind: ToolingItemKind? = nil) async {
        for entry in available where (kind == nil || entry.kind == kind) && entry.cannotUpdate == nil {
            await update(entry.id)
        }
    }

    /// The library takes the repository's content, then every copy this app
    /// proved it installed is replaced. Copies it cannot prove are left alone,
    /// as the installer leaves them.
    private func updateSkill(_ entry: Entry) async -> Bool {
        // The check itself moved the workspace on (it stamped the time), so
        // read the head again rather than apply against the one before.
        await library.refresh()
        guard let prepared = fetched[entry.id],
            let head = library.state?.snapshot.document.revision.id,
            let digest = library.state?.library.rows.first(where: { $0.artifactID == entry.id })?.contentDigest
        else {
            errorMessage = "Check for updates again before installing this one."
            return false
        }
        do {
            _ = try await service.updateStandaloneSkill(
                .init(expectedRevisionID: head, artifactID: entry.id, expectedContentDigest: digest, prepared: prepared),
                prepared: prepared)
        } catch {
            errorMessage = "\(entry.displayName) could not take the update. \(error.localizedDescription)"
            return false
        }
        await library.refresh()
        await deployment.prepare()
        let leftAlone = await deployment.replaceProvenCopies(of: [entry.id])
        if let message = deployment.errorMessage {
            errorMessage = message
            return false
        }
        if !leftAlone.isEmpty {
            let apps = leftAlone.map(\.surface.displayName).formatted(.list(type: .and))
            let them = leftAlone.count == 1 ? "it" : "them"
            // Points at the review without quoting its button. The button counts
            // the plan's changes, and the edited copies are in that plan, so a
            // title quoted here ("Review changes…") never matched the button
            // ("Review 1 change…") it sent a person to.
            notice =
                "\(apps) kept \(leftAlone.count == 1 ? "a copy" : "copies") of \(entry.displayName) that "
                + "\(leftAlone.count == 1 ? "was" : "were") edited after Agent Tooling installed \(them). "
                + "Review the changes on the Apps screen to replace \(them)."
        }
        return true
    }

    /// The app's own update command, through the executor. The register says
    /// which apps have one; the policy inside the executor checks it again.
    private func updatePlugin(_ entry: Entry) async -> Bool {
        guard let row = library.state?.library.rows.first(where: { $0.artifactID == entry.id }),
            let route = row.nativeRoutes.first,
            let command = NativePluginInstallRegister.command(for: route.client, externalPluginID: route.externalPluginID),
            let arguments = command.updateArguments,
            let executable = ClientExecutableLocator.locate(route.client, homeURL: homeRoot)
        else {
            errorMessage =
                pluginUpdateRefusal(for: library.state?.library.rows.first { $0.artifactID == entry.id })
                ?? "\(entry.displayName) cannot be updated from here."
            return false
        }
        let surface = route.client.userSurface
        let plan = OperationPlan(
            kind: .updatePlugin,
            title: "Update \(entry.displayName) in \(route.client.rawValue)",
            summary: "Asks the app to update its own plugin.",
            targetSurfaces: surface.map { [$0] } ?? [],
            steps: [
                .init(
                    kind: .command, title: "Update \(route.externalPluginID)",
                    detail: "Runs the app's own update command.",
                    executable: executable.path, arguments: arguments)
            ])
        let executor = OperationExecutor(store: store, homeURL: homeRoot)
        let receipt = await executor.execute(plan)
        if let failure = receipt.results.first(where: { $0.status == .failed }) {
            errorMessage = failure.output.isEmpty ? "\(route.client.rawValue) did not update \(entry.displayName)." : failure.output
            return false
        }
        await device.refresh()
        await library.refresh()
        return true
    }

    // MARK: Facts

    private static func shortRevision(_ revision: SourceRevision) -> String {
        switch revision.kind {
        case .gitCommitSHA1, .gitCommitSHA256: String(revision.value.prefix(12))
        case .semanticVersion, .opaquePublisherRevision: revision.value
        }
    }

    private func followedSkills(
        in state: WorkspaceLibraryState
    ) -> [(ArtifactID, SkillRepositoryBinding, String, ContentDigest?, SourceRevision)] {
        let document = state.snapshot.document
        let rows = Dictionary(state.library.rows.map { ($0.artifactID, $0) }, uniquingKeysWith: { first, _ in first })
        return document.subscriptions.compactMap { subscription in
            guard let row = rows[subscription.artifactID], row.kind == .skill,
                let source = document.sources.first(where: { $0.id == subscription.sourceID }),
                let repositoryURL = source.repositoryURL,
                let binding = try? SkillRepositoryBinding(
                    repositoryURL: repositoryURL, ref: subscription.lock.requestedRef,
                    subdirectory: subscription.lock.packageRelativePath == "." ? "" : subscription.lock.packageRelativePath)
            else { return nil }
            return (subscription.artifactID, binding, row.displayName, row.contentDigest, subscription.lock.approvedRevision)
        }
    }

    private func pluginUpdateRefusal(for row: WorkspaceLibraryReadModelRow?) -> String? {
        guard let row else { return nil }
        guard let route = row.nativeRoutes.first else {
            return "This plugin is not tied to an app on this Mac, so no app can be asked to update it."
        }
        guard NativePluginInstallRegister.command(for: route.client, externalPluginID: route.externalPluginID)?.updateArguments != nil
        else {
            return "\(route.client.rawValue) keeps its own plugins up to date; update it there."
        }
        return nil
    }
}

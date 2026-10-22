import AgentToolingCore
import Foundation
import Observation

/// Shared catalog state for Discover and Home. All providers are injected at
/// launch, so tests can replace every network, CLI and disk source.
/// Catalog claims never establish local installation; the library supplies it.
/// Refreshes cache results locally and report individual provider failures.
/// This session never writes client configuration.
@MainActor @Observable
final class WorkspaceMarketplaceSession {
    /// One entry per package a catalog published, most recent refresh wins.
    private(set) var packages: [MarketplacePackage] = []
    /// The catalogs and folders this workspace records, in the document's own
    /// order, joined with the ones every build knows about. Written through the
    /// catalog-source command rather than here, and re-read afterwards.
    private(set) var sources: [ToolingSource] = []
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    /// The catalogs whose last refresh could not be read, each with the plain
    /// words the Sources row shows for it. Discover reads this to explain an
    /// empty result honestly — a banner when nothing came back, a one-line note
    /// when some catalogs answered and others did not — and it is empty whenever
    /// nothing failed.
    private(set) var catalogFailures: [CatalogFailure] = []
    /// Marketplaces whose listings are on screen from the published catalog
    /// file while the client has not added the marketplace yet. Kept so the
    /// detail pane can warn before an Apply would fail at the client.
    private(set) var marketplacesNotAdded: [ClientKind: Set<String>] = [:]
    /// When the last refresh that reached a catalog finished. A refresh that
    /// only re-read this Mac's own record leaves it alone.
    private(set) var lastRefreshedAt: Date?

    /// Every native package already in the library, by the route that names it.
    /// Discover matches a catalog listing against this rather than against a
    /// name, so a namesake is never mistaken for the package you already have.
    private(set) var installedRoutes: [NativePackageRoute: LibraryMatch] = [:]
    /// The connections the library already holds, by the name the managed-MCP
    /// intake would give a listing, so an added server reads as held rather than
    /// as offered again.
    private(set) var heldConnections: [String: LibraryMatch] = [:]

    /// What adding the last listing did, or why it was refused.
    private(set) var adoption: AdoptionOutcome?
    private(set) var isAdopting = false
    /// The listing being added right now, so only its card shows the work.
    private(set) var adoptingPackageID: String?

    /// Skills this library follows from a repository, keyed the way a skills.sh
    /// listing is identified (`owner/repo/skill`), under both the folder's name
    /// and the name the skill declares for itself.
    private(set) var heldSkills: [String: LibraryMatch] = [:]

    /// The one command that would let `client` install this listing, when its
    /// marketplace has not been added to the client yet; nil when nothing
    /// stands in the way. Only the official Claude catalog is known well
    /// enough to name its add command.
    func marketplaceAddCommand(for package: MarketplacePackage, client: ClientKind) -> String? {
        guard client == .claude,
            package.catalogKind == .claudeMarketplace,
            let missing = marketplacesNotAdded[.claude],
            missing.contains(ClaudePluginsOfficialCatalogProvider.marketplaceName),
            package.id.hasSuffix("@\(ClaudePluginsOfficialCatalogProvider.marketplaceName)")
        else { return nil }
        return "claude plugin marketplace add anthropics/claude-plugins-official"
    }

    /// One library row a catalog listing turned out to be.
    struct LibraryMatch: Equatable {
        let artifactID: ArtifactID
        let displayName: String
        /// The form `AppNavigationState.openItem` and the palette both use.
        var itemID: String { artifactID.rawValue.uuidString.lowercased() }
    }

    /// A catalog that could not be read on the last refresh, named for a person
    /// with the same words its Sources row carries.
    struct CatalogFailure: Equatable, Identifiable {
        let name: String
        let reason: String
        var id: String { name }
    }

    /// What adding a listing does, and what it deliberately does not do.
    /// Stated once here so the button and the line under it cannot disagree.
    static let adoptionNote =
        "Install puts the listing in your library, then picks the apps and writes it."

    /// Said when the workspace itself cannot be written to, so a disabled
    /// control is never disabled without a reason. The words the rest of the
    /// app already uses for the same fact.
    static let readOnlyNote = "This workspace is open for reading only."

    /// The last refusal or result, and the listing it belongs to.
    ///
    /// Carrying the package's own identifier means a message about one listing
    /// is never left standing under another after the selection moves.
    struct AdoptionOutcome: Equatable {
        let packageID: String
        let message: String
    }

    /// Said wherever the screen would otherwise imply a catalog could be asked.
    static let noProviderNote =
        "No catalog provider is available in this build, so Discover shows only what this Mac already kept."

    /// The empty-Discover message when no filter is active, so the reason an
    /// unfiltered Discover is empty is told straight. When no provider can be
    /// reached, that is the whole story. When every catalog that was asked
    /// failed to read, the emptiness is the catalogs' fault, not the
    /// publisher's, so point at the sources rather than blaming them. Only when
    /// a catalog answered and still had nothing is it fair to say so.
    static func unfilteredEmptyMessage(canReachCatalog: Bool, hasCatalogFailures: Bool) -> String {
        if !canReachCatalog { return noProviderNote }
        if hasCatalogFailures { return "No catalog could be read. Check the sources and refresh." }
        return "Refresh the catalogs. Nothing this workspace records has published a package yet."
    }

    private static let pageLimit = 100

    private let providers: [any MarketplaceProvider]
    private let service: WorkspaceApplicationService
    private let library: WorkspaceLibrarySession
    private let store: WorkspaceRevisionStore

    /// Finds a registry skill's folder in its repository, and fetches it.
    /// Replaceable so tests can stand in for the network.
    typealias SkillLocator = @Sendable (_ skillID: String, _ repositoryURL: String, _ cacheURL: URL) async throws -> SkillRepositoryBinding
    typealias SkillFetcher = @Sendable (_ binding: SkillRepositoryBinding, _ cacheURL: URL) async throws -> PreparedStandaloneSkill
    private let locateSkill: SkillLocator
    private let fetchSkill: SkillFetcher

    /// Deliberately does no work. This is built while the workspace is being
    /// opened, so anything read here would be read before the window existed.
    /// The first `refresh()` reads the store instead.
    init(
        providers: [any MarketplaceProvider],
        service: WorkspaceApplicationService,
        library: WorkspaceLibrarySession,
        store: WorkspaceRevisionStore,
        locateSkill: @escaping SkillLocator = {
            try await WorkspaceSkillPreparation.locateUpstream(skillID: $0, repositoryURL: $1, cacheURL: $2)
        },
        fetchSkill: @escaping SkillFetcher = { try await WorkspaceSkillPreparation.fetchUpstream(binding: $0, cacheURL: $1) }
    ) {
        self.providers = providers
        self.service = service
        self.library = library
        self.store = store
        self.locateSkill = locateSkill
        self.fetchSkill = fetchSkill
    }

    /// True when there is a catalog to ask at all. A screen that cannot reach
    /// one still refreshes — it re-reads this Mac — but must not imply more.
    var canReachCatalog: Bool { !providers.isEmpty }

    /// Whether a catalog listing is already in the library, and which row it is.
    ///
    /// Matched on the exact catalog identity the native parsers preserved, not
    /// on a display name: `NativeCatalogPackageIdentity` refuses anything whose
    /// identifier, components, client and provenance do not all agree.
    func libraryMatch(for package: MarketplacePackage) -> LibraryMatch? {
        if let listing = Self.skillsShListing(package) {
            return heldSkills[Self.skillKey(repository: listing.repository, name: listing.skillID)]
        }
        if let identity = NativeCatalogPackageIdentity.recognize(package) {
            return installedRoutes[
                NativePackageRoute(client: identity.client, externalPluginID: identity.externalPluginID)]
        }
        // An MCP listing is held once a connection with the name its intake
        // would record exists, whichever screen recorded it.
        guard package.components.contains(.mcpServer),
            case .reviewed(let draft) = ReviewedMarketplaceMCPServer.availability(for: package)
        else { return nil }
        return heldConnections[Self.connectionKey(draft.name)]
    }

    private static func connectionKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Adding a listing to the library

    /// Whether this workspace may be written to at all.
    var canAdopt: Bool { library.access == .writable }

    /// Why this listing cannot be added for this client, or `nil` when it can.
    ///
    /// The command's own answer, asked before the control is offered, so a
    /// button that is offered is one the command will accept and a button that
    /// is not says why in the same words the command would have used.
    func adoptionRefusal(for package: MarketplacePackage, client: ClientKind) -> String? {
        NativePackageAdoptionCommand.refusal(adding: package, for: client)?.localizedDescription
    }

    /// Records the listing as a library item, and nothing else.
    ///
    /// This installs nothing, asks for nothing anywhere, and writes no file a
    /// client owns: it adds one row whose next step is assignment. Afterwards
    /// the library is read again so `libraryMatch(for:)` finds the new row and
    /// the screen shows it as held rather than as offered.
    func adopt(_ package: MarketplacePackage, client: ClientKind) async {
        guard canAdopt, !isAdopting else { return }
        isAdopting = true
        adoptingPackageID = package.id
        adoption = nil
        defer {
            isAdopting = false
            adoptingPackageID = nil
        }
        do {
            guard let head = try await service.snapshot()?.document.revision.id else {
                adoption = .init(
                    packageID: package.id,
                    message: "This workspace could not be read. Nothing was added.")
                return
            }
            _ = try await service.adoptNativePackage(
                .init(expectedRevisionID: head, package: package, client: client))
            adoption = .init(
                packageID: package.id,
                message: "Added to your library. Install picks the apps and writes it.")
        } catch {
            adoption = .init(packageID: package.id, message: Self.message(for: error))
        }
        await library.refresh()
        reload()
    }

    // MARK: - Adding an MCP server listing to the library

    /// What adding an MCP-server listing needs: a reviewed connection ready to
    /// record, or a manual setup this app cannot complete on its own. Asked by
    /// the screen so it can show one button or one sentence rather than four
    /// dead per-client buttons.
    ///
    /// Returns `nil` when the listing is not an MCP server at all, so a plugin
    /// listing keeps its per-client buttons.
    func mcpAvailability(for package: MarketplacePackage) -> ReviewedMarketplaceMCPServer.Availability? {
        ReviewedMarketplaceMCPServer.availability(for: package)
    }

    /// The sentence shown in place of buttons for an MCP-server listing with no
    /// reviewed route. Stated once so the screen and this session agree. The
    /// screen appends `mcpManualSetupCommandClause` only when the detail pane
    /// actually renders an install command for the listing; a credentials-only
    /// registry listing has no command row, so promising one below would be a
    /// sentence pointing at nothing.
    static let mcpManualSetupNote =
        "This listing needs credentials or a manual install, so Agent Tooling cannot add it here."

    /// Appended to `mcpManualSetupNote` only when a copyable install command is
    /// shown beneath the sentence.
    static let mcpManualSetupCommandClause = " Its install command is shown below."

    /// Records a reviewed MCP-server listing through the same managed-MCP intake
    /// the Paste sheet uses. The listing carries the reviewed transport, so this
    /// builds the definition from it, writes one connection, and nothing else:
    /// no server is started, contacted, or put in an app. On success the row
    /// shows as held, with the words Discover uses for every added package.
    /// A skills.sh listing: `owner/repo` and the skill's name, from the listing
    /// URL the provider built. Nil for any other kind of listing.
    static func skillsShListing(_ package: MarketplacePackage) -> (repository: String, skillID: String)? {
        guard package.catalogKind == .skillsShRegistry, let url = URL(string: package.location) else { return nil }
        let parts = url.path().split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }
        return ("\(parts[0])/\(parts[1])", parts[2])
    }

    static func skillKey(repository: String, name: String) -> String {
        repository.lowercased() + "/" + SkillRepositoryBinding.comparableSkillName(name)
    }

    /// Where fetched repositories are unpacked while a listing is added; each
    /// fetch works in its own folder under this one and removes it after.
    private var skillCacheRoot: URL {
        store.rootURL.appending(path: "cache/marketplace-skills", directoryHint: .isDirectory)
    }

    /// Brings a skills.sh listing into the library as a skill that follows its
    /// repository: finds the skill's folder on the repository's default branch,
    /// fetches that one folder, and records it with a source and subscription
    /// so Updates can check it later. Nothing is installed; the picker does
    /// that next. A second skill from the same repository reuses the source
    /// the first one recorded.
    func adoptSkill(_ package: MarketplacePackage) async {
        guard canAdopt, !isAdopting, let listing = Self.skillsShListing(package) else { return }
        isAdopting = true
        adoptingPackageID = package.id
        adoption = nil
        defer {
            isAdopting = false
            adoptingPackageID = nil
        }
        do {
            let repositoryURL = "https://github.com/\(listing.repository)"
            let binding = try await locateSkill(listing.skillID, repositoryURL, skillCacheRoot)
            let prepared = try await fetchSkill(binding, skillCacheRoot)
            guard let snapshot = try await service.snapshot() else {
                adoption = .init(packageID: package.id, message: "This workspace could not be read. Nothing was added.")
                return
            }
            let document = snapshot.document
            let existingSource = document.sources.first {
                $0.role == .publisherRepository && $0.repositoryURL == prepared.review.upstream?.repositoryURL
                    && $0.requestedRef == prepared.review.upstream?.requestedRef
            }
            _ = try await service.intakeStandaloneSkill(
                .init(
                    expectedRevisionID: document.revision.id, displayName: package.name, prepared: prepared,
                    upstreamIDs: .init(sourceID: existingSource?.id ?? WorkspaceObjectID())),
                prepared: prepared)
            adoption = .init(
                packageID: package.id,
                message: "Added to your library from \(listing.repository), following its \(binding.ref) branch.")
        } catch {
            adoption = .init(packageID: package.id, message: Self.message(for: error))
        }
        await library.refresh()
        reload()
    }

    func adoptMCPServer(_ package: MarketplacePackage) async {
        guard canAdopt, !isAdopting else { return }
        guard case .reviewed(let draft) = ReviewedMarketplaceMCPServer.availability(for: package) else {
            adoption = .init(packageID: package.id, message: Self.mcpManualSetupNote)
            return
        }
        isAdopting = true
        adoptingPackageID = package.id
        adoption = nil
        defer {
            isAdopting = false
            adoptingPackageID = nil
        }
        do {
            guard let head = try await service.snapshot()?.document.revision.id else {
                adoption = .init(
                    packageID: package.id,
                    message: "This workspace could not be read. Nothing was added.")
                return
            }
            let command = try ManagedMCPServerIntakeCommand(expectedRevisionID: head, draft: draft).refusingReservedName()
            _ = try await service.intakeManagedMCPServer(command)
            adoption = .init(
                packageID: package.id,
                message: "Added to your library. Install picks the apps and writes it.")
        } catch {
            adoption = .init(packageID: package.id, message: Self.message(for: error))
        }
        await library.refresh()
        reload()
    }

    /// A refusal carries the sentence it wants shown; anything else is named
    /// without pretending to know more about it than that it stopped the write.
    private static func message(for error: any Error) -> String {
        if let refusal = error as? NativePackageAdoptionError { return refusal.localizedDescription }
        if let refusal = error as? ManagedMCPServerIntakeError { return refusal.localizedDescription }
        if let repository = error as? SkillRepositoryError {
            if repository == .sourceMissing {
                return "The repository has no skill by that name on its default branch. Nothing was added."
            }
            return repository.localizedDescription + " Nothing was added."
        }
        if let preparation = error as? WorkspaceSkillPreparationError { return preparation.localizedDescription + " Nothing was added." }
        if let command = error as? WorkspaceSkillCommandError, command == .upstreamAlreadyManaged {
            return "This library already follows that skill."
        }
        if case WorkspaceRevisionStoreError.staleRevision = error {
            return "This workspace changed while you were reading. Try again."
        }
        return "That package could not be added to your library. Nothing was changed."
    }

    /// Re-reads this Mac's record, then asks every catalog it has.
    func refresh() async {
        await fetch(MarketplaceQuery(limit: Self.pageLimit))
    }

    /// Asks the catalogs for one term. Filtering the packages already on screen
    /// is the screen's own job; this is for the words a catalog knows and this
    /// Mac does not.
    func search(_ term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        await fetch(MarketplaceQuery(search: trimmed.isEmpty ? nil : trimmed, limit: Self.pageLimit))
    }

    // MARK: - Reading

    /// Combines portable source records, device-local bindings and built-in
    /// catalog references without network access. Recorded sources override
    /// built-in rows of the same kind.
    private func reload() {
        guard let snapshot = try? store.snapshot() else { return }
        let deviceSources = Dictionary(
            (snapshot.device.configurationState?.catalogSources ?? []).map { ($0.catalogSourceID, $0) },
            uniquingKeysWith: { first, _ in first })
        let recorded = (snapshot.document.configurationState?.catalogSources ?? []).map { record in
            let local = deviceSources[record.id]
            return ToolingSource(
                id: record.id.rawValue, name: record.name, kind: record.kind,
                location: local?.localLocation ?? record.remoteLocation ?? "",
                isOptionalBackup: record.isOptionalBackup, lastRefreshedAt: local?.lastRefreshedAt,
                lastRevision: local?.lastRevision, trustSummary: local?.trustSummary ?? "Not reviewed")
        }
        let recordedKinds = Set(recorded.map(\.kind))
        // What a refresh in this session already learned about a reference row
        // survives the redraw that follows it.
        let known = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let references = MarketplaceService().defaultSources()
            .filter { !recordedKinds.contains($0.kind) }
            .map { reference -> ToolingSource in
                var row = reference
                row.id = MarketplaceCatalogs.builtInSourceID(for: reference.kind)
                row.trustSummary = known[row.id]?.trustSummary ?? reference.trustSummary
                row.lastRefreshedAt = known[row.id]?.lastRefreshedAt
                return row
            }
        sources = references + recorded
        installedRoutes = Dictionary(
            snapshot.document.artifacts
                .filter { $0.identity.parentPackageID == nil }
                .flatMap { artifact in
                    artifact.nativeRoutes.map {
                        ($0, LibraryMatch(artifactID: artifact.identity.id, displayName: artifact.identity.displayName))
                    }
                },
            uniquingKeysWith: { first, _ in first })
        heldConnections = Dictionary(
            snapshot.document.artifacts
                .filter { $0.identity.kind == .mcpServer && $0.identity.parentPackageID == nil }
                .map {
                    (
                        Self.connectionKey($0.declaredName ?? $0.identity.displayName),
                        LibraryMatch(artifactID: $0.identity.id, displayName: $0.identity.displayName)
                    )
                },
            uniquingKeysWith: { first, _ in first })
        heldSkills = Self.heldSkills(in: snapshot.document)
        // Only on the first read: a refresh that reached a catalog must not be
        // overwritten by what this Mac kept from the one before it.
        if packages.isEmpty {
            packages = MarketplaceSorting.sorted(
                (snapshot.device.applicationState?.marketplacePackages ?? []).map(Self.unobserved), by: .name)
        }
    }

    /// Every followed skill, keyed as a skills.sh listing would name it: by the
    /// folder it lives in and by the name it declares, both under its
    /// repository. A GitHub source only; a registry lists nothing else.
    static func heldSkills(in document: PortableWorkspaceDocument) -> [String: LibraryMatch] {
        var held: [String: LibraryMatch] = [:]
        let rows = Dictionary(document.artifacts.map { ($0.identity.id, $0) }, uniquingKeysWith: { first, _ in first })
        for subscription in document.subscriptions {
            guard let row = rows[subscription.artifactID], row.identity.kind == .skill,
                let source = document.sources.first(where: { $0.id == subscription.sourceID }),
                let repositoryURL = source.repositoryURL,
                let components = URLComponents(string: repositoryURL), components.host?.lowercased() == "github.com"
            else { continue }
            let parts = components.path.split(separator: "/").map(String.init)
            guard parts.count == 2 else { continue }
            let repository = "\(parts[0])/\(parts[1])"
            let match = LibraryMatch(artifactID: row.identity.id, displayName: row.identity.displayName)
            let folder = subscription.lock.packageRelativePath.split(separator: "/").last.map(String.init) ?? ""
            for name in [folder, row.declaredName ?? "", row.identity.displayName] where !name.isEmpty && name != "." {
                held[Self.skillKey(repository: repository, name: name)] = held[Self.skillKey(repository: repository, name: name)] ?? match
            }
        }
        return held
    }

    /// Re-reads the recorded catalogs after a command changed which ones there
    /// are. No catalog is asked anything: what changed is where this app will
    /// look, and a date claiming a fresh answer would be an invention.
    func reloadSources() { reload() }

    /// The tools Start your library offers: the bundled starter shelf, filled
    /// in from what a catalog said when one was read, the page this Mac kept
    /// or a refresh in this launch. It re-reads this Mac's own record and the
    /// library, so `libraryMatch(for:)` answers for every listing, and it asks
    /// no catalog anything: no provider, no app's tool, no network.
    func starterShelf() -> [MarketplacePackage] {
        reload()
        return StarterShelf.packages(retained: packages)
    }

    private func fetch(_ query: MarketplaceQuery) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        errorMessage = nil
        reload()
        guard !providers.isEmpty else { return }

        let retained = packages
        var collected: [MarketplacePackage] = []
        var failures: [String] = []
        var structuredFailures: [CatalogFailure] = []
        var learned = MarketplaceSourceReport()
        var answered = 0

        for provider in providers {
            var refused: String?
            do {
                let page = try await provider.search(query)
                collected.append(contentsOf: page.packages.map(Self.unobserved))
                answered += 1
            } catch let partial as RecordedFolderCatalogError {
                // Some folders were read and some were not. Both halves count.
                collected.append(contentsOf: partial.packages.map(Self.unobserved))
                answered += 1
                refused = SensitiveValueRedactor.redact(partial.localizedDescription)
            } catch {
                // The catalog's own words, not this app's guess at them, with
                // anything that looks like a credential taken out first: a
                // provider that refused says why, and a name says which one.
                refused = SensitiveValueRedactor.redact(error.localizedDescription)
            }
            if let refused {
                failures.append("\(provider.displayName): \(refused)")
                structuredFailures.append(CatalogFailure(name: provider.displayName, reason: refused))
            }
            guard let reporting = provider as? any CatalogSourceReporting else { continue }
            let report = await reporting.lastReport()
            learned.summaries.merge(report.summaries) { _, latest in latest }
            learned.folderSummaries.merge(report.folderSummaries) { _, latest in latest }
            learned.refreshedKinds.formUnion(report.refreshedKinds)
            learned.refreshedFolders.formUnion(report.refreshedFolders)
            learned.incompletePackagePrefixes.formUnion(report.incompletePackagePrefixes)
            learned.marketplacesNotAdded.merge(report.marketplacesNotAdded) { $0.union($1) }
            // A catalog that refused outright says so on its own row, since its
            // report has nothing newer to put there.
            if let refused {
                for kind in reporting.sourceKinds where report.summaries[kind] == nil {
                    learned.summaries[kind] = "Unavailable: \(refused)"
                    learned.refreshedKinds.remove(kind)
                }
            }
        }

        // A refresh where every catalog failed keeps what was already on
        // screen. Replacing it with nothing would read as an empty catalog
        // rather than as a refresh that did not happen.
        if answered > 0 {
            packages = await Self.merged(
                collected, keeping: retained, whenIncomplete: learned.incompletePackagePrefixes)
            lastRefreshedAt = .now
            await retain(packages)
        }
        annotate(learned)
        catalogFailures = structuredFailures
        marketplacesNotAdded = learned.marketplacesNotAdded
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: " · ")
    }

    /// Writes what the refresh learned onto the rows it learned it about.
    ///
    /// Only a row whose catalog answered completely is dated. The date on a row
    /// is a claim that what it lists is current, and a refusal or a partial
    /// answer cannot support one — the clause still changes, so the row says
    /// what happened without pretending it was a successful read.
    private func annotate(_ report: MarketplaceSourceReport) {
        sources = sources.map { source in
            var row = source
            guard let summary = report.folderSummaries[source.id] ?? report.summaries[source.kind]
            else { return row }
            row.trustSummary = summary
            if report.refreshedFolders.contains(source.id) || report.refreshedKinds.contains(source.kind) {
                row.lastRefreshedAt = .now
            }
            return row
        }
    }

    /// Keeps the last page in this Mac's own record, so the next launch has
    /// something to show before any catalog is reachable.
    ///
    /// Best effort on purpose. This is a convenience, not the result the person
    /// asked for: a workspace that moved on underneath, or one that refuses the
    /// listing, leaves the packages on screen and says only that they were not
    /// kept. Nothing is written where there is no record to write into, so a
    /// workspace without one is left without one rather than given one here.
    private func retain(_ packages: [MarketplacePackage]) async {
        do {
            guard let snapshot = try store.snapshot(), snapshot.device.applicationState != nil else { return }
            let retained = packages
            _ = try await service.commitDeviceChange(expectedRevisionID: snapshot.document.revision.id) { device in
                device.applicationState?.marketplacePackages = retained
            }
        } catch {
            errorMessage = "The catalog is shown but could not be kept for next time."
            return
        }
        // Keeping it advanced the workspace, so the library is read again
        // rather than left holding an older head.
        await library.refresh()
    }

    // MARK: - Packages

    /// A catalog listing with every installation claim removed.
    ///
    /// Catalogs report installation, and this build observes none: nothing here
    /// runs a client's plugin list. Keeping the claim would put "Installed" on
    /// a row on the strength of a file written by a version of this app that
    /// could still check. The library answers that question instead.
    private static func unobserved(_ package: MarketplacePackage) -> MarketplacePackage {
        var value = package
        value.isInstalled = false
        value.nativeInstalls = value.nativeInstalls.map { route in
            var route = route
            route.isInstalled = false
            return route
        }
        return value
    }

    /// One row per catalog identity, in a stable order, off this actor.
    ///
    /// Merging is `MarketplaceService`'s own: two catalogs publishing the same
    /// server are folded into one row that keeps the richer half of each,
    /// rather than whichever happened to answer first. It sorts and compares
    /// every listing on this Mac, which is not work the window should wait on.
    ///
    /// Listings kept from an earlier refresh survive only where this one could
    /// not supersede them — a client catalog that answered partially — because
    /// a list that quietly shrank reads as a catalog that lost packages.
    private static func merged(
        _ collected: [MarketplacePackage],
        keeping retained: [MarketplacePackage],
        whenIncomplete incomplete: Set<String>
    ) async -> [MarketplacePackage] {
        await Task.detached(priority: .utility) {
            let listed = Set(collected.map(\.id))
            let kept = retained.filter { package in
                !listed.contains(package.id) && incomplete.contains { package.id.hasPrefix($0) }
            }
            return MarketplaceSorting.sorted(
                MarketplaceService().deduplicatedPackages(collected + kept), by: .name)
        }.value
    }
}

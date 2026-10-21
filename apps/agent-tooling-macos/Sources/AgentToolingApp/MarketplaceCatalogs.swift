import AgentToolingCore
import CryptoKit
import Foundation

/// The catalogs this Mac can actually be asked about, and what asking one means
/// for the rows on Discover's Sources list.
///
/// Everything here is a `MarketplaceProvider`, deliberately. Discover's session
/// takes a list of providers and nothing else, so a render test that hands it
/// one stub has replaced every catalog this build knows — there is no second
/// door through which a socket, a CLI or a folder read could still happen.

/// What a catalog needs to know about this Mac before it can be built: whose
/// home directory the client CLIs belong to, and where this workspace's own
/// record lives — which clients it manages and which catalog folders it has
/// been given are both read from that record, when a refresh happens rather
/// than when the screen was built.
struct MarketplaceCatalogContext {
    var homeRoot: URL
    var store: WorkspaceRevisionStore
}

/// A provider that also speaks for one or more rows on the Sources list.
///
/// Optional on purpose. A provider that is not one of this workspace's recorded
/// catalogs — a test's stub — reports nothing, and no row is annotated with an
/// answer it did not give.
protocol CatalogSourceReporting: MarketplaceProvider {
    /// The rows this provider answers for, known before it is asked, so a
    /// refusal can be attributed to the right row.
    var sourceKinds: Set<SourceKind> { get }
    /// What the last `search` means for those rows.
    func lastReport() async -> MarketplaceSourceReport
}

/// One provider's account of its own last answer.
struct MarketplaceSourceReport: Sendable {
    /// The one clause a built-in catalog row shows, by row kind.
    var summaries: [SourceKind: String] = [:]
    /// The same, for the folders and checkouts this workspace records itself.
    var folderSummaries: [UUID: String] = [:]
    /// The rows this answer was complete for, and only those. A date on a row
    /// is a claim that what it lists is current, which a partial or refused
    /// answer cannot support.
    var refreshedKinds: Set<SourceKind> = []
    var refreshedFolders: Set<UUID> = []
    /// Identifier prefixes whose catalog answered only partially. Listings kept
    /// from an earlier refresh under one of these are still the truest thing
    /// known, so they survive rather than reading as a catalog that shrank.
    var incompletePackagePrefixes: Set<String> = []
    /// Marketplaces a client has not added yet, though listings from them are
    /// on screen (read from the published catalog file). Installing one of
    /// those listings needs the marketplace added to the client first, and the
    /// detail pane says so with the command that does it.
    var marketplacesNotAdded: [ClientKind: Set<String>] = [:]
}

/// How a native client catalog names its listings, and which Sources row it is
/// shown as. Spelled once so a partial answer is attributed to the same row the
/// listing itself would be attributed to.
enum NativeCatalogRows {
    static let byClient: [ClientKind: SourceKind] = [
        .claude: .claudeMarketplace, .codex: .openAIPluginDirectory,
    ]
    static let prefixByClient: [ClientKind: String] = [.claude: "claude:", .codex: "codex:"]
}

/// Which catalogs a live build asks.
enum MarketplaceCatalogs {
    /// Every catalog this Mac can be asked about, in the order Discover has
    /// always listed them: the registries, then what the installed clients
    /// publish, then the folders somebody added themselves.
    ///
    /// The official Claude catalog and the Claude CLI answer for the same
    /// Sources row, so they are folded into one `ClaudeMarketplaceCatalog` that
    /// reads both and speaks for the row once. That leaves the generic native
    /// catalog to answer only for Codex, so no two providers annotate the same
    /// row and race to overwrite each other.
    static func live(in context: MarketplaceCatalogContext) -> [any MarketplaceProvider] {
        let store = context.store
        let httpsClaude = try? ClaudePluginsOfficialCatalogProvider()
        var providers = MarketplaceProviderRegistry.builtIn().compactMap(wrapped(_:))
        providers.append(
            ClaudeMarketplaceCatalog(
                httpsCatalog: httpsClaude,
                runner: ProcessCommandRunner(homeURL: context.homeRoot),
                claudeManaged: { managedClients(in: store).contains(.claude) }))
        providers.append(
            NativeClientCatalog(
                runner: ProcessCommandRunner(homeURL: context.homeRoot),
                clients: { managedClients(in: store).intersection([.codex]) }))
        providers.append(RecordedFolderCatalog(store: store))
        return providers
    }

    /// Each remote provider is paired with the Sources row it answers for, so a
    /// refusal or a count lands on the right row. The official Claude catalog is
    /// dropped here because `ClaudeMarketplaceCatalog` reads it directly and
    /// speaks for the Claude row itself; a provider this table does not know is
    /// passed through unannotated rather than attributed to a row it never
    /// spoke for.
    private static func wrapped(_ provider: any MarketplaceProvider) -> (any MarketplaceProvider)? {
        switch provider.id {
        case "skills-sh.registry": SkillsShCatalog(asking: provider)
        case "mcp.official-registry": MCPRegistryCatalog(asking: provider)
        case "claude.plugins-official": nil
        default: provider
        }
    }

    /// Which clients this workspace manages, read when a refresh asks rather
    /// than when the screen was built, so turning one off in the sidebar stops
    /// its catalog being read on the very next refresh.
    ///
    /// A workspace that has not recorded a choice manages all of them, which is
    /// the same answer `WorkspaceDeviceSession` gives from the same record.
    private static func managedClients(in store: WorkspaceRevisionStore) -> Set<ClientKind> {
        guard let device = (try? store.snapshot())?.device else { return Set(ClientKind.allCases) }
        return ClientVisibilityPolicy.effectiveEnabledClients(
            preferences: device.applicationState?.preferences,
            observations: device.observations)
    }

    /// A fixed identity per built-in catalog row.
    ///
    /// `defaultSources()` mints a new UUID every time it is called, which would
    /// make the row somebody selected on the Sources list a different row after
    /// the next refresh. Deriving the identity from the kind instead keeps a
    /// selection, and a restored one, pointing at the same catalog.
    static func builtInSourceID(for kind: SourceKind) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("agent-tooling.catalog-source.\(kind.rawValue)".utf8)).prefix(16))
        // Version 4, variant 1: a derived identifier that is still a well-formed
        // UUID rather than sixteen arbitrary bytes wearing the type.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}

/// The official MCP registry, named as the Sources row it answers for.
///
/// A thin wrapper rather than a change to the provider: which recorded row a
/// remote catalog belongs to is this app's presentation question, not something
/// the registry client should have an opinion about.
actor MCPRegistryCatalog: CatalogSourceReporting {
    nonisolated var id: String { asking.id }
    nonisolated var displayName: String { asking.displayName }
    nonisolated var sourceKinds: Set<SourceKind> { [.mcpRegistry] }

    private let asking: any MarketplaceProvider
    private var report = MarketplaceSourceReport()

    init(asking: any MarketplaceProvider) {
        self.asking = asking
    }

    func search(_ query: MarketplaceQuery) async throws -> MarketplacePage {
        let page = try await asking.search(query)
        report.summaries[.mcpRegistry] =
            "\(CountNoun("server").phrase(page.packages.count)) loaded from \(asking.displayName); "
            + "package execution still requires review"
        report.refreshedKinds = [.mcpRegistry]
        return page
    }

    func lastReport() -> MarketplaceSourceReport { report }
}

/// Supplies browsable skills.sh results using fixed public search seeds because
/// the registry has no browse endpoint. Results are merged, deduplicated, and
/// capped. An explicit query bypasses the seeds and makes one request; only a
/// queried or seeded response updates the source timestamp.
actor SkillsShCatalog: CatalogSourceReporting {
    nonisolated var id: String { asking.id }
    nonisolated var displayName: String { asking.displayName }
    nonisolated var sourceKinds: Set<SourceKind> { [.skillsShRegistry] }

    /// The starter vocabulary an unqueried refresh browses with. Fixed in code
    /// so it is the same on every Mac and can never carry a value read from a
    /// person's workspace. Chosen to cover the common reasons someone reaches
    /// for a skill.
    static let seedTerms = [
        "code review", "testing", "documentation", "git", "debugging", "refactoring", "planning", "writing",
    ]

    /// At most this many seed searches run at once, so a browse fans out without
    /// opening a request per term all at the same moment.
    private static let maxConcurrentSeedSearches = 8
    /// The most listings a browse keeps after merging every seed's answer.
    private static let browseListingCeiling = 100

    private let asking: any MarketplaceProvider
    private var report = MarketplaceSourceReport()

    init(asking: any MarketplaceProvider) {
        self.asking = asking
    }

    func search(_ query: MarketplaceQuery) async throws -> MarketplacePage {
        // A real search term asks the registry once, exactly as before.
        if let term = SkillsShRegistryProvider.searchTerm(from: query) {
            let page = try await asking.search(query)
            report.summaries[.skillsShRegistry] =
                "\(CountNoun.skill.phrase(page.packages.count)) matched “\(term)”; read the source repository before installing"
            report.refreshedKinds = [.skillsShRegistry]
            return page
        }
        // No search term: browse the shipped starter set instead of staying
        // silent, so Discover has skill listings before anyone types anything.
        return try await browseSeedTerms(limit: query.limit)
    }

    /// Fans the seed vocabulary out over the registry, bounded and cancellable,
    /// then merges the answers into one deduplicated, capped page.
    private func browseSeedTerms(limit: Int) async throws -> MarketplacePage {
        let terms = Self.seedTerms
        let asking = asking
        let collected: [MarketplacePackage] = try await withThrowingTaskGroup(
            of: [MarketplacePackage].self
        ) { group in
            var results: [MarketplacePackage] = []
            var running = 0
            var iterator = terms.makeIterator()

            func addNext() {
                guard let term = iterator.next() else { return }
                running += 1
                group.addTask {
                    // Cancellation propagates: if the refresh is torn down, a
                    // seed search in flight stops rather than finishing wasted.
                    try Task.checkCancellation()
                    return try await asking.search(MarketplaceQuery(search: term, limit: limit)).packages
                }
            }

            for _ in 0..<min(Self.maxConcurrentSeedSearches, terms.count) { addNext() }
            while running > 0 {
                let page = try await group.next() ?? []
                running -= 1
                results.append(contentsOf: page)
                addNext()
            }
            return results
        }

        let merged = MarketplaceService().deduplicatedPackages(collected)
        let capped = Array(merged.prefix(Self.browseListingCeiling))
        report.summaries[.skillsShRegistry] =
            "Browsing skills.sh starter set; type to search"
        report.refreshedKinds = [.skillsShRegistry]
        return MarketplacePage(packages: capped)
    }

    func lastReport() -> MarketplaceSourceReport { report }
}

/// What the Codex CLI already installed on this Mac publishes.
///
/// Only the documented, machine-readable local catalog Codex exposes. No hosted
/// web page is scraped, and nothing is installed: this is Codex's own
/// `plugin list --available --json`, read. The Claude row is handled by
/// `ClaudeMarketplaceCatalog`, which folds the Claude CLI together with the
/// official HTTPS catalog, so this catalog speaks only for the Codex row even
/// though the shared discovery it calls can read both clients.
actor NativeClientCatalog: CatalogSourceReporting {
    nonisolated let id = "device.native-catalogs"
    nonisolated let displayName = "Installed client catalogs"
    nonisolated var sourceKinds: Set<SourceKind> { [.openAIPluginDirectory] }

    private let runner: any CommandRunning
    /// Asked at refresh time, not captured when the screen opened.
    private let clients: @Sendable () -> Set<ClientKind>
    private var report = MarketplaceSourceReport()

    init(runner: any CommandRunning, clients: @escaping @Sendable () -> Set<ClientKind>) {
        self.runner = runner
        self.clients = clients
    }

    /// The search term is not passed to the client CLIs: their catalog commands
    /// list what they know and take no query. Filtering the answer is Discover's
    /// own job, over everything that came back.
    func search(_ query: MarketplaceQuery) async throws -> MarketplacePage {
        var built = MarketplaceSourceReport()
        let clients = clients()
        guard !clients.isEmpty else {
            for kind in sourceKinds {
                built.summaries[kind] = "This workspace is not managing this client, so its catalog was not read."
            }
            report = built
            return MarketplacePage(packages: [])
        }
        let discovery = await MarketplaceService.discoverNativeCatalogs(runner: runner, clients: clients)
        for (client, outcome) in discovery.outcomes {
            guard let kind = NativeCatalogRows.byClient[client], sourceKinds.contains(kind) else { continue }
            switch outcome {
            case .excluded:
                built.summaries[kind] = "This workspace is not managing \(client.rawValue), so its catalog was not read."
            case .complete:
                built.summaries[kind] = discovery.notes[client]
                built.refreshedKinds.insert(kind)
            case .incomplete:
                built.summaries[kind] = discovery.notes[client] ?? "\(client.rawValue)'s catalog answered only partially."
                if let prefix = NativeCatalogRows.prefixByClient[client] {
                    built.incompletePackagePrefixes.insert(prefix)
                }
            }
        }
        report = built
        return MarketplacePage(packages: discovery.packages)
    }

    func lastReport() -> MarketplaceSourceReport { report }
}

/// Combines Claude CLI install state with the public marketplace catalog.
/// Reports a source failure only when both listings are unavailable.
actor ClaudeMarketplaceCatalog: CatalogSourceReporting {
    nonisolated let id = "device.claude-marketplace"
    nonisolated let displayName = "Claude marketplaces"
    nonisolated var sourceKinds: Set<SourceKind> { [.claudeMarketplace] }

    private let httpsCatalog: (any MarketplaceProvider)?
    private let runner: any CommandRunning
    /// Asked at refresh time so turning Claude off in the sidebar takes effect
    /// on the next refresh rather than the next launch.
    private let claudeManaged: @Sendable () -> Bool
    private var report = MarketplaceSourceReport()

    init(
        httpsCatalog: (any MarketplaceProvider)?,
        runner: any CommandRunning,
        claudeManaged: @escaping @Sendable () -> Bool
    ) {
        self.httpsCatalog = httpsCatalog
        self.runner = runner
        self.claudeManaged = claudeManaged
    }

    func search(_ query: MarketplaceQuery) async throws -> MarketplacePage {
        var built = MarketplaceSourceReport()
        guard claudeManaged() else {
            built.summaries[.claudeMarketplace] =
                "This workspace is not managing Claude Code, so its catalog was not read."
            report = built
            return MarketplacePage(packages: [])
        }

        // The CLI, read the same way the generic native catalog reads it, so a
        // Claude row and a file row for one plugin carry the same identifier and
        // fold together.
        let cli = await MarketplaceService.discoverNativeCatalogs(runner: runner, clients: [.claude])
        let cliOutcome = cli.outcomes[.claude] ?? .incomplete
        let cliNote = cli.notes[.claude]

        // The official catalog file. It is only asked when there is one to ask;
        // a build that could not construct it (an unreachable configuration)
        // leaves the row to the CLI alone.
        var httpsPackages: [MarketplacePackage] = []
        var httpsFailure: String?
        if let httpsCatalog {
            do {
                httpsPackages = try await httpsCatalog.search(query).packages
            } catch {
                httpsFailure = SensitiveValueRedactor.redact(error.localizedDescription)
            }
        }
        let httpsAnswered = httpsFailure == nil && httpsCatalog != nil

        let merged = MarketplaceService().deduplicatedPackages(cli.packages + httpsPackages)

        switch cliOutcome {
        case .complete:
            // Claude Code answered, so what it knows leads: which marketplaces
            // are added and what is installed. The file fills in categories and
            // homepages, and — when no marketplace has been added yet, so the
            // CLI lists nothing — is the reason the row is not empty. The
            // wording keeps those two facts apart so a person can tell which
            // listings Claude Code can install today.
            built.summaries[.claudeMarketplace] = Self.completeSummary(
                cliCount: cli.packages.count, httpsCount: httpsPackages.count,
                httpsAnswered: httpsAnswered, httpsFailure: httpsFailure, cliNote: cliNote)
            built.refreshedKinds.insert(.claudeMarketplace)
            if cli.packages.isEmpty, !httpsPackages.isEmpty {
                built.marketplacesNotAdded[.claude] = [ClaudePluginsOfficialCatalogProvider.marketplaceName]
            }
        case .incomplete, .excluded:
            // Claude Code could not be asked, or answered only partially. If the
            // file answered, that is now the browsable source, and the row says
            // so and names why the CLI could not be asked.
            let reason = Self.shortReason(cliNote)
            if httpsAnswered {
                built.summaries[.claudeMarketplace] =
                    "\(CountNoun.plugin.phrase(httpsPackages.count)) read from the official catalog on GitHub. "
                    + "Claude Code itself could not be asked: \(reason)"
                built.refreshedKinds.insert(.claudeMarketplace)
            } else if let httpsFailure {
                built.summaries[.claudeMarketplace] =
                    "Neither Claude Code nor the official catalog on GitHub could be read. "
                    + "Claude Code: \(reason) Catalog: \(httpsFailure)"
            } else {
                built.summaries[.claudeMarketplace] = cliNote ?? "Claude Code's catalog could not be read: \(reason)"
            }
            // Anything the CLI kept from a previous complete refresh is still the
            // truest thing known, so its listings survive this partial answer.
            if cliOutcome == .incomplete {
                built.incompletePackagePrefixes.insert("claude:")
            }
        }
        report = built
        return MarketplacePage(packages: merged)
    }

    func lastReport() -> MarketplaceSourceReport { report }

    /// The row's wording when Claude Code answered in full.
    static func completeSummary(
        cliCount: Int, httpsCount: Int, httpsAnswered: Bool, httpsFailure: String?, cliNote: String?
    ) -> String {
        var sentences: [String] = []
        if cliCount == 0 {
            // Installing a file-sourced listing needs the marketplace to be
            // added to Claude Code first; the app does not add marketplaces
            // itself, so it names the one command that does.
            sentences.append(
                "Claude Code lists no plugins yet, because no marketplace has been added to it. "
                    + "Before a plugin from the official catalog can be installed, run: "
                    + "claude plugin marketplace add anthropics/claude-plugins-official")
        } else {
            sentences.append("\(CountNoun.plugin.phrase(cliCount)) listed by Claude Code from its added marketplaces.")
        }
        if httpsAnswered {
            sentences.append("\(CountNoun.plugin.phrase(httpsCount)) read from the official catalog on GitHub.")
        } else if let httpsFailure {
            sentences.append("The official catalog on GitHub could not be read: \(httpsFailure)")
        }
        if let cliNote, !cliNote.isEmpty { sentences.append(cliNote) }
        return sentences.joined(separator: " ")
    }

    /// The CLI's own diagnostic, trimmed to the clause that follows "could not
    /// be asked:". The discovery note reads "claude catalog unavailable:
    /// <reason>", so the prefix is stripped when present and the whole note is
    /// used otherwise.
    private static func shortReason(_ note: String?) -> String {
        guard let note else { return "Claude Code was not available on this Mac." }
        if let range = note.range(of: "unavailable: ") {
            let tail = note[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { return tail }
        }
        return note
    }
}

/// The catalog folders and Git checkouts this workspace records itself.
///
/// Read from the store on every refresh rather than captured once, so a folder
/// added since the screen opened is inspected on the next look at it. The
/// inspection is the same bounded, read-only walk the rest of the app uses:
/// nothing in a catalog folder is executed to find out what it contains.
actor RecordedFolderCatalog: CatalogSourceReporting {
    nonisolated let id = "workspace.recorded-folders"
    nonisolated let displayName = "Catalog folders"
    nonisolated var sourceKinds: Set<SourceKind> { [.localFolder, .gitRepository] }

    private let store: WorkspaceRevisionStore
    private var report = MarketplaceSourceReport()

    init(store: WorkspaceRevisionStore) {
        self.store = store
    }

    func search(_ query: MarketplaceQuery) async throws -> MarketplacePage {
        var built = MarketplaceSourceReport()
        var packages: [MarketplacePackage] = []
        var failures: [String] = []
        for source in Self.folders(in: store) {
            do {
                let inspected = try MarketplaceService().inspect(source)
                packages.append(contentsOf: inspected)
                built.folderSummaries[source.id] =
                    inspected.isEmpty
                    ? "No portable packages found"
                    : "\(CountNoun("package").phrase(inspected.count)) discovered; review before installing"
                built.refreshedFolders.insert(source.id)
            } catch {
                // The folder's own refusal, with anything that looks like a
                // credential taken out of it before it reaches a screen.
                let diagnostic = SensitiveValueRedactor.redact(error.localizedDescription)
                built.folderSummaries[source.id] = diagnostic
                failures.append("\(source.name): \(diagnostic)")
            }
        }
        report = built
        // One folder that cannot be read must not lose the folders that could,
        // so the packages are returned and the failure is named alongside them.
        guard failures.isEmpty else { throw RecordedFolderCatalogError.partial(packages, failures) }
        return MarketplacePage(packages: packages)
    }

    func lastReport() -> MarketplaceSourceReport { report }

    /// The recorded catalog sources that are actually folders on this Mac,
    /// paired with where this device last saw each one.
    private static func folders(in store: WorkspaceRevisionStore) -> [ToolingSource] {
        guard let snapshot = try? store.snapshot() else { return [] }
        let local = Dictionary(
            (snapshot.device.configurationState?.catalogSources ?? []).map { ($0.catalogSourceID, $0) },
            uniquingKeysWith: { first, _ in first })
        return (snapshot.document.configurationState?.catalogSources ?? [])
            .filter { [.localFolder, .gitRepository].contains($0.kind) }
            .compactMap { record in
                guard let location = local[record.id]?.localLocation ?? record.remoteLocation, !location.isEmpty
                else { return nil }
                return ToolingSource(
                    id: record.id.rawValue, name: record.name, kind: record.kind, location: location)
            }
    }
}

/// A folder read that partly succeeded. The packages travel with the failure so
/// nothing that was read is thrown away with the news that something was not.
enum RecordedFolderCatalogError: LocalizedError {
    case partial([MarketplacePackage], [String])

    var packages: [MarketplacePackage] {
        switch self {
        case .partial(let packages, _): packages
        }
    }

    var errorDescription: String? {
        switch self {
        case .partial(_, let failures): failures.joined(separator: " · ")
        }
    }
}

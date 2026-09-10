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
}

/// How a native client catalog names its listings, and which Sources row it is
/// shown as. Spelled once so a partial answer is attributed to the same row the
/// listing itself would be attributed to.
enum NativeCatalogRows {
    static let byClient: [ClientKind: SourceKind] = [
        .claude: .claudeMarketplace, .codex: .openAIPluginDirectory,
    ]
    static let byPrefix: [String: SourceKind] = [
        "claude:": .claudeMarketplace, "codex:": .openAIPluginDirectory,
    ]
    static let prefixByClient: [ClientKind: String] = [.claude: "claude:", .codex: "codex:"]
}

/// Which catalogs a live build asks.
enum MarketplaceCatalogs {
    /// Every catalog this Mac can be asked about, in the order Discover has
    /// always listed them: the registry, then what the installed clients
    /// publish, then the folders somebody added themselves.
    static func live(in context: MarketplaceCatalogContext) -> [any MarketplaceProvider] {
        let store = context.store
        return MarketplaceProviderRegistry.builtIn().map { MCPRegistryCatalog(asking: $0) }
            + [
                NativeClientCatalog(
                    runner: ProcessCommandRunner(homeURL: context.homeRoot),
                    clients: { managedClients(in: store) }),
                RecordedFolderCatalog(store: store),
            ]
    }

    /// Which clients this workspace manages, read when a refresh asks rather
    /// than when the screen was built, so turning one off in the sidebar stops
    /// its catalog being read on the very next refresh.
    ///
    /// A workspace that has not recorded a choice manages all of them, which is
    /// the same answer `WorkspaceDeviceSession` gives from the same record.
    private static func managedClients(in store: WorkspaceRevisionStore) -> Set<ClientKind> {
        guard let recorded = (try? store.snapshot())?.device.applicationState?.preferences.enabledClients
        else { return Set(ClientKind.allCases) }
        return Set(recorded)
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
        let count = page.packages.count
        report.summaries[.mcpRegistry] =
            "\(count) server\(count == 1 ? "" : "s") loaded from \(asking.displayName); "
            + "package execution still requires review"
        report.refreshedKinds = [.mcpRegistry]
        return page
    }

    func lastReport() -> MarketplaceSourceReport { report }
}

/// What the client CLIs already installed on this Mac publish.
///
/// Only the documented, machine-readable local catalogs each client exposes.
/// No hosted web page is scraped, and nothing is installed: this is `claude
/// plugin list --available` and its Codex equivalent, read.
actor NativeClientCatalog: CatalogSourceReporting {
    nonisolated let id = "device.native-catalogs"
    nonisolated let displayName = "Installed client catalogs"
    nonisolated var sourceKinds: Set<SourceKind> { [.claudeMarketplace, .openAIPluginDirectory] }

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
            guard let kind = NativeCatalogRows.byClient[client] else { continue }
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
                    : "\(inspected.count) package\(inspected.count == 1 ? "" : "s") discovered; review before installing"
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

import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The catalogs a live build asks, exercised without asking any of them for
/// real: the folder catalog reads a directory this test made, and the native
/// client catalog talks to a command runner that launches nothing.
///
/// Nothing here opens a socket. The one provider that would — the official MCP
/// registry — is only ever constructed, and constructing it is an offline check
/// of its base URL.
struct MarketplaceCatalogsTests {
    @Test func aBuiltInCatalogRowKeepsTheSameIdentityEveryTimeItIsBuilt() {
        let first = MarketplaceCatalogs.builtInSourceID(for: .mcpRegistry)

        #expect(first == MarketplaceCatalogs.builtInSourceID(for: .mcpRegistry))
        #expect(first != MarketplaceCatalogs.builtInSourceID(for: .claudeMarketplace))
        // A derived identifier that is still a well-formed version-4 UUID.
        #expect(first.uuidString.dropFirst(14).first == "4")
    }

    @Test func theLiveCatalogsAreTheRegistryTheClientCLIsAndTheRecordedFolders() throws {
        let workspace = try CatalogFixture()
        defer { workspace.remove() }

        let providers = MarketplaceCatalogs.live(
            in: MarketplaceCatalogContext(homeRoot: workspace.root, store: workspace.store))

        #expect(providers.map(\.id).contains("device.native-catalogs"))
        #expect(providers.map(\.id).contains("workspace.recorded-folders"))
    }

    /// The folder catalog reads the folders this workspace records, and reports
    /// what each one turned out to hold.
    @Test func theFolderCatalogReadsARecordedFolderAndSaysWhatWasInIt() async throws {
        let workspace = try CatalogFixture(withFolderCatalog: true)
        defer { workspace.remove() }
        let catalog = RecordedFolderCatalog(store: workspace.store)

        let page = try await catalog.search(MarketplaceQuery(limit: 10))

        #expect(page.packages.map(\.name) == ["reviewed-plugin"])
        let report = await catalog.lastReport()
        #expect(report.folderSummaries[workspace.folderSourceID.rawValue] == "1 package discovered; review before installing")
        #expect(report.refreshedFolders == [workspace.folderSourceID.rawValue])
    }

    /// A folder that has gone is named rather than silently dropped, and the
    /// row stays undated: nobody read it just now.
    @Test func aRecordedFolderThatIsNoLongerThereIsNamedAndLeavesTheRowUndated() async throws {
        let workspace = try CatalogFixture(withFolderCatalog: true)
        defer { workspace.remove() }
        try FileManager.default.removeItem(at: workspace.catalogFolder)
        let catalog = RecordedFolderCatalog(store: workspace.store)

        await #expect(throws: RecordedFolderCatalogError.self) {
            try await catalog.search(MarketplaceQuery(limit: 10))
        }
        let report = await catalog.lastReport()
        #expect(report.refreshedFolders.isEmpty)
        #expect(report.folderSummaries[workspace.folderSourceID.rawValue]?.isEmpty == false)
    }

    /// A client CLI that is not installed leaves its row saying so, and marks
    /// its listings as ones this refresh could not supersede. The generic native
    /// catalog now answers only for Codex — the Claude row is folded into
    /// `ClaudeMarketplaceCatalog` — so Codex is what it is asked about here.
    @Test func aClientCatalogThatCouldNotBeReadKeepsWhatWasKeptBefore() async throws {
        let catalog = NativeClientCatalog(runner: RefusingRunner(), clients: { [.codex] })

        let page = try await catalog.search(MarketplaceQuery(limit: 10))

        #expect(page.packages.isEmpty)
        let report = await catalog.lastReport()
        #expect(report.refreshedKinds.isEmpty)
        #expect(report.incompletePackagePrefixes == ["codex:"])
        #expect(report.summaries[.openAIPluginDirectory]?.isEmpty == false)
        // The Claude row is not this catalog's to speak for anymore.
        #expect(report.summaries[.claudeMarketplace] == nil)
    }

    /// A client this workspace does not manage is not asked at all. The generic
    /// native catalog speaks only for the Codex row now.
    @Test func aClientThisWorkspaceDoesNotManageIsNotAsked() async throws {
        let runner = CountingRunner()
        let catalog = NativeClientCatalog(runner: runner, clients: { [] })

        let page = try await catalog.search(MarketplaceQuery(limit: 10))

        #expect(page.packages.isEmpty)
        #expect(await runner.calls == 0)
        let report = await catalog.lastReport()
        #expect(report.summaries[.openAIPluginDirectory]?.contains("not managing") == true)
        #expect(report.summaries[.claudeMarketplace] == nil)
    }

    /// Which clients are asked is read when a refresh happens, not captured when
    /// the screen was built, so turning one off takes effect on the next look
    /// rather than the next launch.
    @Test func whichClientsAreAskedIsReadAtRefreshTimeAndNotCaptured() async throws {
        let managed = ManagedClients()
        let catalog = NativeClientCatalog(runner: RefusingRunner(), clients: { managed.value })

        _ = try await catalog.search(MarketplaceQuery(limit: 10))
        #expect(await catalog.lastReport().incompletePackagePrefixes == ["codex:"])

        managed.value = []
        _ = try await catalog.search(MarketplaceQuery(limit: 10))
        #expect(await catalog.lastReport().incompletePackagePrefixes.isEmpty)
    }

    // MARK: - The Claude marketplace row: CLI and the official catalog together

    /// Claude Code answered, but with an empty catalog because no marketplace
    /// has been added to it. The listings on screen come from the file, and the
    /// row and the detail pane say the marketplace must be added first, naming
    /// the command, rather than letting an install fail later at the client.
    @Test func theClaudeRowNamesTheMarketplaceAddCommandWhenTheCLIListsNothing() async throws {
        let https = StubOfficialCatalog(packages: [Self.officialListing(name: "review-buddy")])
        let catalog = ClaudeMarketplaceCatalog(
            httpsCatalog: https, runner: EmptyClaudeCatalogRunner(), claudeManaged: { true })

        let page = try await catalog.search(MarketplaceQuery(limit: 100))

        #expect(page.packages.map(\.id) == ["claude:review-buddy@claude-plugins-official"])
        let report = await catalog.lastReport()
        let summary = try #require(report.summaries[.claudeMarketplace])
        #expect(summary.contains("no marketplace has been added"))
        #expect(summary.contains("claude plugin marketplace add anthropics/claude-plugins-official"))
        #expect(summary.contains("1 plugin read from the official catalog on GitHub"))
        #expect(report.marketplacesNotAdded[.claude] == ["claude-plugins-official"])
        #expect(report.refreshedKinds.contains(.claudeMarketplace))
    }

    /// Claude Code answered with its own listings; the row keeps the two counts
    /// apart and nothing is said about adding a marketplace.
    @Test func theClaudeRowKeepsBothCountsApartWhenTheCLIAnswers() async throws {
        let summary = ClaudeMarketplaceCatalog.completeSummary(
            cliCount: 19, httpsCount: 314, httpsAnswered: true, httpsFailure: nil, cliNote: nil)
        #expect(summary == "19 plugins listed by Claude Code from its added marketplaces. 314 plugins read from the official catalog on GitHub.")
        let failed = ClaudeMarketplaceCatalog.completeSummary(
            cliCount: 1, httpsCount: 0, httpsAnswered: false, httpsFailure: "HTTP 503", cliNote: nil)
        #expect(failed == "1 plugin listed by Claude Code from its added marketplaces. The official catalog on GitHub could not be read: HTTP 503")
    }

    /// When Claude Code cannot be asked but the official catalog on GitHub
    /// answers, the row says the browsable listings came from the catalog and
    /// names, in plain words, why Claude Code itself could not be asked.
    @Test func theClaudeRowReadsTheOfficialCatalogWhenTheCLICannotBeAsked() async throws {
        let https = StubOfficialCatalog(
            packages: [Self.officialListing(name: "review-buddy"), Self.officialListing(name: "test-helper")])
        let catalog = ClaudeMarketplaceCatalog(
            httpsCatalog: https, runner: RefusingRunner(), claudeManaged: { true })

        let page = try await catalog.search(MarketplaceQuery(limit: 100))

        // Both official listings are browsable even though the CLI answered nothing.
        #expect(page.packages.map(\.id).sorted() == ["claude:review-buddy@claude-plugins-official", "claude:test-helper@claude-plugins-official"])
        let report = await catalog.lastReport()
        let summary = try #require(report.summaries[.claudeMarketplace])
        #expect(summary.contains("official catalog on GitHub"))
        #expect(summary.contains("Claude Code itself could not be asked"))
        // The catalog answered, so the row is dated.
        #expect(report.refreshedKinds.contains(.claudeMarketplace))
    }

    /// When both the CLI and the official catalog fail, the row keeps the
    /// failure rather than pretending a catalog answered.
    @Test func theClaudeRowKeepsTheFailureWhenBothTheCLIAndTheCatalogFail() async throws {
        let https = StubOfficialCatalog(packages: [], fails: true)
        let catalog = ClaudeMarketplaceCatalog(
            httpsCatalog: https, runner: RefusingRunner(), claudeManaged: { true })

        let page = try await catalog.search(MarketplaceQuery(limit: 100))

        #expect(page.packages.isEmpty)
        let report = await catalog.lastReport()
        let summary = try #require(report.summaries[.claudeMarketplace])
        #expect(summary.contains("Neither Claude Code nor the official catalog"))
        #expect(report.refreshedKinds.contains(.claudeMarketplace) == false)
    }

    /// A workspace not managing Claude never reads either source for the row.
    @Test func theClaudeRowIsNotReadWhenTheWorkspaceDoesNotManageClaude() async throws {
        let https = StubOfficialCatalog(packages: [Self.officialListing(name: "review-buddy")])
        let catalog = ClaudeMarketplaceCatalog(
            httpsCatalog: https, runner: RefusingRunner(), claudeManaged: { false })

        let page = try await catalog.search(MarketplaceQuery(limit: 100))

        #expect(page.packages.isEmpty)
        #expect(await https.calls == 0)
        #expect(await catalog.lastReport().summaries[.claudeMarketplace]?.contains("not managing Claude Code") == true)
    }

    // MARK: - skills.sh browsable starter set

    /// An unqueried refresh fans the shipped seed vocabulary out over the
    /// registry, requests every seed term, and returns the merged, deduplicated
    /// listings rather than staying silent.
    @Test func anUnqueriedRefreshBrowsesTheSeedVocabularyAndDedupes() async throws {
        let recorder = SeedRecordingProvider()
        let catalog = SkillsShCatalog(asking: recorder)

        let page = try await catalog.search(MarketplaceQuery(limit: 100))

        // Every shipped seed term was asked for, and only those.
        #expect(await recorder.terms.sorted() == SkillsShCatalog.seedTerms.sorted())
        // The same listing returned under two seeds is one row.
        #expect(page.packages.map(\.id) == ["skills-sh:owner/repo/shared"])
        let report = await catalog.lastReport()
        #expect(report.summaries[.skillsShRegistry] == "Browsing skills.sh starter set; type to search")
        #expect(report.refreshedKinds.contains(.skillsShRegistry))
    }

    /// A real search term bypasses the seeds and asks the registry once.
    @Test func aSearchTermAsksTheRegistryOnceAndNotTheSeeds() async throws {
        let recorder = SeedRecordingProvider()
        let catalog = SkillsShCatalog(asking: recorder)

        _ = try await catalog.search(MarketplaceQuery(search: "react performance", limit: 100))

        #expect(await recorder.terms == ["react performance"])
        #expect(await catalog.lastReport().summaries[.skillsShRegistry]?.contains("matched") == true)
    }

    /// One official-catalog listing shaped as the real provider emits one: a
    /// `claude:<name>@claude-plugins-official` identifier, one component, and a
    /// Claude route, so it merges with a CLI row of the same id.
    static func officialListing(name: String) -> MarketplacePackage {
        let externalPluginID = "\(name)@claude-plugins-official"
        return MarketplacePackage(
            id: "claude:\(externalPluginID)", name: name, publisher: "Anthropic marketplace",
            summary: "An official catalog listing.", sourceName: "claude-plugins-official",
            components: [.plugin], supportedClients: [.claude],
            location: "https://example.com/\(name)",
            nativeInstalls: [
                NativeInstall(
                    client: .claude, executable: "claude",
                    arguments: ["plugin", "install", externalPluginID, "--scope", "user"],
                    removalArguments: ["plugin", "uninstall", externalPluginID], scope: .user,
                    detail: "Recorded install command.")
            ],
            provenance: PackageProvenance(source: PackageSource(kind: .claudeMarketplace, location: "https://example.com/\(name)")),
            category: "development")
    }
}

/// The official Claude catalog, answering from memory. Constructing the real
/// provider is an offline HTTPS check; this stands in for the HTTP read so the
/// test never opens a socket.
private actor StubOfficialCatalog: MarketplaceProvider {
    nonisolated let id = "claude.plugins-official"
    nonisolated let displayName = "claude-plugins-official"
    private let packages: [MarketplacePackage]
    private let fails: Bool
    private(set) var calls = 0

    init(packages: [MarketplacePackage], fails: Bool = false) {
        self.packages = packages
        self.fails = fails
    }

    func search(_ query: MarketplaceQuery) async throws -> MarketplacePage {
        calls += 1
        if fails { throw StubCatalogFailure.unreachable }
        return MarketplacePage(packages: packages)
    }
}

private enum StubCatalogFailure: LocalizedError {
    case unreachable
    var errorDescription: String? { "The official catalog was unreachable." }
}

/// A skills.sh stand-in that records every term it was asked and answers each
/// with one listing under a shared id, so a browse's dedupe is observable.
private actor SeedRecordingProvider: MarketplaceProvider {
    nonisolated let id = "skills-sh.registry"
    nonisolated let displayName = "skills.sh"
    private(set) var terms: [String] = []

    func search(_ query: MarketplaceQuery) async throws -> MarketplacePage {
        if let term = query.search { terms.append(term) }
        return MarketplacePage(packages: [
            MarketplacePackage(
                id: "skills-sh:owner/repo/shared", name: "shared", publisher: "owner", summary: "s",
                sourceName: "skills.sh", components: [.skill], supportedClients: [.claude],
                location: "https://skills.sh/owner/repo/shared")
        ])
    }
}

/// A choice somebody changes between two refreshes.
private final class ManagedClients: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: Set<ClientKind> = [.codex]

    var value: Set<ClientKind> {
        get { lock.withLock { clients } }
        set { lock.withLock { clients = newValue } }
    }
}

/// A command runner that answers as an absent CLI does, without launching one.
private struct RefusingRunner: CommandRunning {
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        CommandOutput(status: 127, standardOutput: "", standardError: "command not found: \(executable)")
    }
}

/// Claude Code with no marketplace added: the catalog command succeeds and
/// lists nothing at all.
private struct EmptyClaudeCatalogRunner: CommandRunning {
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        CommandOutput(status: 0, standardOutput: #"{"installed": [], "available": []}"#, standardError: "")
    }
}

/// The same, but remembering whether it was asked at all.
private actor CountingRunner: CommandRunning {
    private(set) var calls = 0

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        calls += 1
        return CommandOutput(status: 127, standardOutput: "", standardError: "")
    }
}

/// A workspace that records one catalog folder, on a scratch path of its own.
private struct CatalogFixture {
    let root: URL
    let store: WorkspaceRevisionStore
    let folderSourceID = WorkspaceObjectID()
    var catalogFolder: URL { root.appending(path: "catalog", directoryHint: .isDirectory) }

    init(withFolderCatalog: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "marketplace-catalogs-\(UUID())")
        let container = root.appending(path: "store")
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = root.appending(path: "catalog", directoryHint: .isDirectory)
        var sources: [WorkspaceCatalogSourceRecord] = []
        if withFolderCatalog {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(
                #"{"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"reviewed-plugin"}"#
                    .utf8
            ).write(to: folder.appending(path: "plugin.json"))
            // Where the folder actually is belongs to this Mac, not to the
            // portable half: the document records that a catalog exists, and
            // this device records where it found it.
            sources = [.init(id: folderSourceID, name: "Catalog folder", kind: .localFolder)]
        }
        let writerID = WorkspaceObjectID()
        let document = try WorkspaceDocumentCoding.seal(
            .init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                configurationState: .init(
                    catalogSources: sources,
                    identityMap: sources.map { source in
                        .init(
                            legacy: .init(
                                domain: .catalogSource,
                                identifier: source.id.rawValue.uuidString.lowercased()),
                            objectID: source.id)
                    })))
        var device = DeviceWorkspaceState(workspaceID: document.workspaceID)
        device.configurationState = .init(
            catalogSources: sources.map {
                .init(
                    catalogSourceID: $0.id, localLocation: folder.standardizedFileURL.path,
                    trustSummary: "Not reviewed")
            })
        store = try WorkspaceRevisionStore(
            containerRoot: container, workspaceID: document.workspaceID, deviceID: device.deviceID)
        try store.initialize(document: document, device: device)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

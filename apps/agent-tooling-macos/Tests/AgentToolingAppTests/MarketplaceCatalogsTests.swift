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
    /// its listings as ones this refresh could not supersede.
    @Test func aClientCatalogThatCouldNotBeReadKeepsWhatWasKeptBefore() async throws {
        let catalog = NativeClientCatalog(runner: RefusingRunner(), clients: { [.claude] })

        let page = try await catalog.search(MarketplaceQuery(limit: 10))

        #expect(page.packages.isEmpty)
        let report = await catalog.lastReport()
        #expect(report.refreshedKinds.isEmpty)
        #expect(report.incompletePackagePrefixes == ["claude:"])
        #expect(report.summaries[.claudeMarketplace]?.isEmpty == false)
    }

    /// A client this workspace does not manage is not asked at all.
    @Test func aClientThisWorkspaceDoesNotManageIsNotAsked() async throws {
        let runner = CountingRunner()
        let catalog = NativeClientCatalog(runner: runner, clients: { [] })

        let page = try await catalog.search(MarketplaceQuery(limit: 10))

        #expect(page.packages.isEmpty)
        #expect(await runner.calls == 0)
        let report = await catalog.lastReport()
        #expect(report.summaries[.claudeMarketplace]?.contains("not managing") == true)
        #expect(report.summaries[.openAIPluginDirectory]?.contains("not managing") == true)
    }

    /// Which clients are asked is read when a refresh happens, not captured when
    /// the screen was built, so turning one off takes effect on the next look
    /// rather than the next launch.
    @Test func whichClientsAreAskedIsReadAtRefreshTimeAndNotCaptured() async throws {
        let managed = ManagedClients()
        let catalog = NativeClientCatalog(runner: RefusingRunner(), clients: { managed.value })

        _ = try await catalog.search(MarketplaceQuery(limit: 10))
        #expect(await catalog.lastReport().incompletePackagePrefixes == ["claude:"])

        managed.value = []
        _ = try await catalog.search(MarketplaceQuery(limit: 10))
        #expect(await catalog.lastReport().incompletePackagePrefixes.isEmpty)
    }
}

/// A choice somebody changes between two refreshes.
private final class ManagedClients: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: Set<ClientKind> = [.claude]

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

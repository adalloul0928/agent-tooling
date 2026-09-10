import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Reading a catalog is not observing this Mac.
///
/// Every test here is about one of the three claims the session is allowed to
/// make: what the catalogs published, where those catalogs came from, and
/// whether this workspace already holds a listing. It is never allowed to
/// repeat a catalog's claim that something is installed.
@MainActor
struct WorkspaceMarketplaceSessionTests {
    @Test func sourcesAreTheDocumentsHalfAndThisMacsHalfTogether() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let session = fixture.session()
        await session.refresh()

        let source = try #require(session.sources.first { $0.id == Fixture.sourceID.rawValue })
        // The portable half.
        #expect(source.name == "Vendor catalog")
        #expect(source.kind == .claudeMarketplace)
        // This Mac's half: where it actually is, and what the last look found.
        #expect(source.location == "/tmp/vendor-catalog")
        #expect(source.trustSummary == "3 packages discovered; review before installing")
        #expect(source.lastRefreshedAt != nil)
    }

    /// The catalogs every build reads join the ones this workspace recorded,
    /// and a recorded source is the authority over its own kind: the fixture
    /// records a Claude marketplace, so the built-in Claude row is not shown
    /// beside it claiming to be a second one.
    @Test func theCatalogsEveryBuildKnowsAreListedBesideTheRecordedOnes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let session = fixture.session()
        await session.refresh()

        #expect(session.sources.count { $0.kind == .claudeMarketplace } == 1)
        #expect(session.sources.first { $0.kind == .claudeMarketplace }?.name == "Vendor catalog")
        #expect(
            Set(session.sources.map(\.kind))
                == [.claudeMarketplace, .openAIPluginDirectory, .geminiExtensionGallery, .agentPlugins, .mcpRegistry])
        // A reference row keeps the same identity across refreshes, so
        // selecting one on the Sources list survives asking the catalogs again.
        let before = session.sources.first { $0.kind == .mcpRegistry }?.id
        await session.refresh()
        #expect(session.sources.first { $0.kind == .mcpRegistry }?.id == before)
    }

    /// A catalog that answers says so on its own row, so the grading that reads
    /// a row's freshness has something true to read.
    @Test func aCatalogThatAnsweredSaysSoOnItsOwnRow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let session = fixture.session(providers: [MCPRegistryCatalog(asking: StubMarketplaceProvider())])
        await session.refresh()

        let registry = try #require(session.sources.first { $0.kind == .mcpRegistry })
        #expect(registry.lastRefreshedAt != nil)
        #expect(registry.trustSummary.contains("2 servers loaded"))
    }

    /// A catalog that refuses says why on its own row rather than leaving the
    /// last successful summary standing as if it were still true.
    @Test func aCatalogThatRefusedSaysSoOnItsOwnRow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let session = fixture.session(providers: [MCPRegistryCatalog(asking: StubMarketplaceProvider(fails: true))])
        await session.refresh()

        let registry = try #require(session.sources.first { $0.kind == .mcpRegistry })
        #expect(registry.trustSummary.hasPrefix("Unavailable: "))
        #expect(registry.lastRefreshedAt == nil)
    }

    @Test func whatThisMacKeptIsShownWhenNoCatalogCanBeAsked() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        // No provider at all: nothing here can reach a catalog.
        let session = fixture.session(providers: [])
        await session.refresh()

        #expect(session.canReachCatalog == false)
        #expect(session.packages.map(\.id) == ["claude:example@vendor"])
        #expect(session.errorMessage == nil)
    }

    @Test func aCatalogNeverGetsToSayWhatIsInstalled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var claiming = ShellRenderFixture.unheldPackage
        claiming.isInstalled = true
        claiming.nativeInstalls = claiming.nativeInstalls.map { route in
            var route = route
            route.isInstalled = true
            return route
        }

        let session = fixture.session(providers: [StubMarketplaceProvider(packages: [claiming])])
        await session.refresh()

        let package = try #require(session.packages.first)
        #expect(package.isInstalled == false)
        #expect(package.nativeInstalls.allSatisfy { $0.isInstalled == false })
        #expect(package.installedClients.isEmpty)
    }

    @Test func aListingThisWorkspaceHoldsIsMatchedByItsRouteAndNotByItsName() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // A namesake: the same display name, a different catalog identity.
        let namesake = ShellRenderFixture.catalogPackage(
            id: "claude:example@other", name: "Example Plugin", summary: "A different vendor's plugin of the same name.")

        let session = fixture.session(
            providers: [StubMarketplaceProvider(packages: [ShellRenderFixture.heldPackage, namesake])])
        await session.refresh()

        let match = try #require(session.libraryMatch(for: ShellRenderFixture.heldPackage))
        #expect(match.artifactID == Fixture.plugin)
        #expect(match.displayName == "Example Plugin")
        #expect(match.itemID == Fixture.plugin.rawValue.uuidString.lowercased())
        #expect(session.libraryMatch(for: namesake) == nil)
    }

    @Test func aRefreshKeepsWhatAnsweredAndNamesWhatDidNot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let session = fixture.session(providers: [
            StubMarketplaceProvider(packages: [ShellRenderFixture.unheldPackage]),
            StubMarketplaceProvider(id: "stub.broken", displayName: "Broken catalog", fails: true),
        ])
        await session.refresh()

        #expect(session.packages.map(\.id) == ["claude:atlas@vendor"])
        let message = try #require(session.errorMessage)
        #expect(message.contains("Broken catalog"))
        #expect(message.contains("The stub catalog was unreachable."))
    }

    @Test func aRefreshWhereEveryCatalogFailsKeepsWhatWasAlreadyOnScreen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let session = fixture.session(
            providers: [StubMarketplaceProvider(displayName: "Broken catalog", fails: true)])
        await session.refresh()

        // The retained listing is still the truest thing known about the
        // catalog, so it stays rather than being replaced by nothing.
        #expect(session.packages.map(\.id) == ["claude:example@vendor"])
        #expect(session.lastRefreshedAt == nil)
        #expect(try #require(session.errorMessage).contains("Broken catalog"))
    }

    @Test func theLastPageIsKeptForTheNextLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let session = fixture.session(providers: [StubMarketplaceProvider()])
        await session.refresh()

        #expect(session.errorMessage == nil, "\(session.errorMessage ?? "")")
        let kept = try #require(try fixture.store.snapshot()).device.applicationState?.marketplacePackages
        #expect(Set(kept?.map(\.id) ?? []) == ["claude:example@vendor", "claude:atlas@vendor"])
        // A second session, with no catalog to ask, opens on what was kept.
        let reopened = fixture.session(providers: [])
        await reopened.refresh()
        #expect(reopened.packages.count == 2)
    }

    @Test func searchingAsksTheCatalogForTheTerm() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let provider = StubMarketplaceProvider()

        let session = fixture.session(providers: [provider])
        await session.search("  atlas  ")

        #expect(await provider.lastQuery?.search == "atlas")
        // An emptied field asks for the whole catalog rather than for "".
        await session.search("   ")
        #expect(await provider.lastQuery?.search == nil)
    }

    /// A workspace that already holds one native plugin, records one catalog
    /// source, and has kept one listing from the last time it could ask.
    @MainActor private struct Fixture {
        static let plugin = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1") ?? UUID())
        static let sourceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000d4") ?? UUID())
        let root: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let library: WorkspaceLibrarySession
        let writerID = WorkspaceObjectID()

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "marketplace-session-\(UUID())")
            let container = root.appending(path: "store")
            try FileManager.default.createDirectory(
                at: container, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let document = try WorkspaceDocumentCoding.seal(
                .init(
                    workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                    artifacts: [
                        .init(
                            identity: .init(id: Self.plugin, kind: .nativePlugin, displayName: "Example Plugin"),
                            authority: .nativeOwned,
                            nativeRoutes: [.init(client: .claude, externalPluginID: "example@vendor")])
                    ],
                    configurationState: .init(
                        catalogSources: [
                            .init(
                                id: Self.sourceID, name: "Vendor catalog", kind: .claudeMarketplace,
                                remoteLocation: "https://example.com/catalog")
                        ],
                        identityMap: [
                            .init(
                                legacy: .init(
                                    domain: .catalogSource, identifier: Self.sourceID.rawValue.uuidString.lowercased()),
                                objectID: Self.sourceID)
                        ])))
            var device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            device.configurationState = .init(catalogSources: [
                .init(
                    catalogSourceID: Self.sourceID, localLocation: "/tmp/vendor-catalog",
                    lastRefreshedAt: .now, trustSummary: "3 packages discovered; review before installing")
            ])
            // What a previous launch kept, so opening with no catalog to ask
            // still has something to show.
            device.applicationState = .init(marketplacePackages: [ShellRenderFixture.heldPackage])
            store = try WorkspaceRevisionStore(
                containerRoot: container, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
            library = WorkspaceLibrarySession(
                service: service, workspaceID: document.workspaceID, deviceID: device.deviceID,
                access: .writable)
        }

        func session(providers: [any MarketplaceProvider] = []) -> WorkspaceMarketplaceSession {
            WorkspaceMarketplaceSession(
                providers: providers, service: service, library: library, store: store)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

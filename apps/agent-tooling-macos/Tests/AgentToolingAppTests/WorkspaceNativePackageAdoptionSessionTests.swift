import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Discover's one write: putting a catalog listing in the library.
///
/// It adds a row and stops there. Nothing is asked for anywhere, no client is
/// run, and the screen never reports the result as an installation — after the
/// receipt the row's next step is assignment, on the Apps screen.
@Suite("Adding a catalog package")
@MainActor
struct WorkspaceNativePackageAdoptionSessionTests {
    @Test func addingAListingPutsItInTheLibraryAndDiscoverThenPointsAtTheRow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session(providers: [StubMarketplaceProvider()])
        await session.refresh()
        let listing = try #require(session.packages.first { $0.id == "claude:atlas@vendor" })
        #expect(session.libraryMatch(for: listing) == nil)

        await session.adopt(listing, client: .claude)

        let match = try #require(session.libraryMatch(for: listing))
        #expect(match.displayName == "Atlas")
        #expect(session.adoption?.packageID == listing.id)
        #expect(
            session.adoption?.message == "Added to your library. Choose where it goes on the Apps screen.")
        // One row, holding the route and nothing else.
        let snapshot = try #require(try fixture.store.snapshot())
        let added = try #require(snapshot.document.artifacts.first { $0.identity.id == match.artifactID })
        #expect(added.authority == .nativeOwned)
        #expect(added.nativeRoutes == [.init(client: .claude, externalPluginID: "atlas@vendor")])
    }

    @Test func addingToTheLibraryIsNotInstalling() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session(providers: [StubMarketplaceProvider()])
        await session.refresh()
        let listing = try #require(session.packages.first { $0.id == "claude:atlas@vendor" })

        await session.adopt(listing, client: .claude)

        // Nothing is asked for anywhere, so nothing can be installed from it.
        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.assignments.isEmpty)
        // And no catalog's claim about installation survives the round trip.
        let redrawn = try #require(session.packages.first { $0.id == listing.id })
        #expect(redrawn.isInstalled == false)
        #expect(redrawn.nativeInstalls.allSatisfy { $0.isInstalled == false })
    }

    @Test func aSecondAttemptIsRefusedInTheCommandsOwnWordsAndWritesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session(providers: [StubMarketplaceProvider()])
        await session.refresh()
        let listing = try #require(session.packages.first { $0.id == "claude:atlas@vendor" })
        await session.adopt(listing, client: .claude)

        await session.adopt(listing, client: .claude)

        #expect(session.adoption?.message == "Atlas is already in your library. Open it to choose where it goes.")
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.count == 2)
    }

    /// A refusal about one listing must not be left standing under another.
    @Test func aMessageBelongsToTheListingItWasAbout() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session(providers: [StubMarketplaceProvider()])
        await session.refresh()
        let held = try #require(session.packages.first { $0.id == "claude:example@vendor" })

        await session.adopt(held, client: .claude)

        #expect(session.adoption?.packageID == "claude:example@vendor")
        #expect(session.adoption?.packageID != "claude:atlas@vendor")
    }

    @Test func aRouteWithNoRecordedInstallCommandIsRefusedBeforeItIsOffered() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session(providers: [StubMarketplaceProvider()])
        await session.refresh()
        let listing = try #require(session.packages.first { $0.id == "claude:atlas@vendor" })

        // Asked before the control is offered, and answered in the same words
        // the command would have used, so a disabled button always says why.
        #expect(session.adoptionRefusal(for: listing, client: .claude) == nil)
        #expect(
            session.adoptionRefusal(for: listing, client: .gemini)
                == """
                Nothing has recorded how Gemini CLI installs a package, \
                so this would be a library item Install could never act on.
                """)
    }

    @Test func aWorkspaceOpenedReadOnlyAddsNothing() async throws {
        let fixture = try Fixture(access: .readOnly)
        defer { fixture.remove() }
        let session = fixture.session(providers: [StubMarketplaceProvider()])
        await session.refresh()
        let listing = try #require(session.packages.first { $0.id == "claude:atlas@vendor" })

        #expect(session.canAdopt == false)
        await session.adopt(listing, client: .claude)

        #expect(session.adoption == nil)
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.count == 1)
        // The listing itself is addable, so the reason the control is off is
        // the workspace, and that is the reason the button has to give.
        #expect(session.adoptionRefusal(for: listing, client: .claude) == nil)
        #expect(WorkspaceMarketplaceSession.readOnlyNote == "This workspace is open for reading only.")
    }

    /// The screen itself, with a live button on it.
    ///
    /// The render tests elsewhere draw Discover with every control disabled;
    /// this one draws it after the control this unit enables became reachable,
    /// and again once pressing it turned the listing into a library row.
    @Test func discoverDrawsTheListingBeforeAndAfterItIsAdded() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let session = fixture.workspace.marketplace
        await session.refresh()
        let listing = try #require(session.packages.first { $0.id == "claude:atlas@vendor" })
        #expect(session.adoptionRefusal(for: listing, client: .claude) == nil)
        #expect(session.canAdopt)

        try expectDrawn(
            MarketplaceView(workspace: fixture.workspace, session: session)
                .environment(AppNavigationState()))

        await session.adopt(listing, client: .claude)

        #expect(session.libraryMatch(for: listing) != nil)
        try expectDrawn(
            MarketplaceView(workspace: fixture.workspace, session: session)
                .environment(AppNavigationState()))
    }

    /// A workspace holding one native plugin and one recorded catalog, with a
    /// listing kept from the last time a catalog could be asked.
    @MainActor private struct Fixture {
        static let plugin = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000b1") ?? UUID())
        let root: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let library: WorkspaceLibrarySession

        init(access: WorkspaceLibraryAccess = .writable) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "package-adoption-session-\(UUID())")
            let container = root.appending(path: "store")
            try FileManager.default.createDirectory(
                at: container, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let writerID = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(
                .init(
                    workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                    artifacts: [
                        .init(
                            identity: .init(id: Self.plugin, kind: .nativePlugin, displayName: "Example Plugin"),
                            authority: .nativeOwned, declaredName: "example@vendor",
                            nativeRoutes: [.init(client: .claude, externalPluginID: "example@vendor")])
                    ]))
            var device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            device.applicationState = .init(marketplacePackages: [ShellRenderFixture.heldPackage])
            store = try WorkspaceRevisionStore(
                containerRoot: container, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
            library = WorkspaceLibrarySession(
                service: service, workspaceID: document.workspaceID, deviceID: device.deviceID,
                access: access)
        }

        func session(providers: [any MarketplaceProvider] = []) -> WorkspaceMarketplaceSession {
            WorkspaceMarketplaceSession(
                providers: providers, service: service, library: library, store: store)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

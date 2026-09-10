import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Adding a catalog to Discover's list, and taking one off it.
///
/// A catalog source is where this app looks, not what it holds. Nothing here
/// reaches a catalog: the session is handed no provider at all, so a screen
/// that fetched something on the way to recording a folder would be reaching
/// somewhere this suite deliberately does not go.
@Suite("Catalog sources on Discover")
@MainActor
struct WorkspaceCatalogSourceSessionTests {
    @Test func addingAFolderPutsItOnTheListWithoutAskingACatalogAnything() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalogs = fixture.catalogs()
        await catalogs.refresh()
        let before = catalogs.sources.count

        let added = await fixture.session(catalogs).add(
            .init(name: "Team packages", kind: .localFolder, remoteLocation: nil, localLocation: fixture.folder))

        #expect(added)
        #expect(catalogs.sources.count == before + 1)
        let row = try #require(catalogs.sources.first { $0.name == "Team packages" })
        #expect(row.kind == .localFolder)
        // Both halves on one row: the portable name and kind, and this Mac's
        // own path with the verdict nothing has earned yet.
        #expect(row.location == fixture.folder)
        #expect(row.trustSummary == "Not reviewed")
        // Recording where to look is not looking: no catalog was asked, so no
        // row may claim a fresh answer.
        #expect(catalogs.lastRefreshedAt == nil)
        // The path is a fact about this Mac and stays out of the portable bytes.
        let snapshot = try #require(try fixture.store.snapshot())
        let portable = try WorkspaceDocumentCoding.encode(snapshot.document)
        #expect(!String(decoding: portable, as: UTF8.self).contains(fixture.folder))
    }

    @Test func removingTakesTheRowOffTheList() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalogs = fixture.catalogs()
        await catalogs.refresh()
        let session = fixture.session(catalogs)
        _ = await session.add(
            .init(name: "Team packages", kind: .localFolder, remoteLocation: nil, localLocation: fixture.folder))
        let row = try #require(catalogs.sources.first { $0.name == "Team packages" })

        let removed = await session.remove(row.id)

        #expect(removed)
        #expect(session.errorMessage == nil)
        #expect(!catalogs.sources.contains { $0.name == "Team packages" })
        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.configurationState?.catalogSources.isEmpty == true)
        #expect(snapshot.device.configurationState?.catalogSources.isEmpty == true)
    }

    /// The catalogs every build lists are reference rows, not records. The
    /// screen keeps Remove off them, and the command refuses one anyway.
    @Test func aCatalogNobodyAddedCannotBeRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalogs = fixture.catalogs()
        await catalogs.refresh()
        let reference = try #require(catalogs.sources.first { $0.kind == .mcpRegistry })
        #expect(reference.id == MarketplaceCatalogs.builtInSourceID(for: .mcpRegistry))
        let session = fixture.session(catalogs)

        let removed = await session.remove(reference.id)

        #expect(!removed)
        #expect(
            session.errorMessage
                == "That catalog is not one this workspace recorded, so there is nothing to remove.")
        #expect(catalogs.sources.contains { $0.id == reference.id })
    }

    @Test func aRefusalIsShownInTheCommandsOwnWordsAndNothingChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalogs = fixture.catalogs()
        await catalogs.refresh()
        let session = fixture.session(catalogs)
        _ = await session.add(
            .init(name: "Team packages", kind: .localFolder, remoteLocation: nil, localLocation: fixture.folder))

        let again = await session.add(
            .init(name: "The same folder", kind: .localFolder, remoteLocation: nil, localLocation: fixture.folder))

        #expect(!again)
        #expect(session.errorMessage == "That catalog is already in your list, as Team packages.")
        #expect(catalogs.sources.count { $0.kind == .localFolder } == 1)
    }

    @Test func anAddressCarryingACredentialIsRefusedBeforeAnythingIsWritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalogs = fixture.catalogs()
        await catalogs.refresh()
        let session = fixture.session(catalogs)

        let added = await session.add(
            .init(
                name: "Team checkout", kind: .gitRepository,
                remoteLocation: "https://someone:secret@example.com/catalog", localLocation: fixture.folder))

        #expect(!added)
        #expect(
            session.errorMessage
                == "Enter a catalog address without a user name, password, query or fragment.")
        // The refusal must not carry the credential onto a screen.
        #expect(session.errorMessage?.contains("secret") != true)
        #expect(try #require(try fixture.store.snapshot()).document.configurationState?.catalogSources.isEmpty == true)
    }

    @Test func aWorkspaceOpenForReadingOnlyRecordsNothing() async throws {
        let fixture = try Fixture(access: .readOnly)
        defer { fixture.remove() }
        let catalogs = fixture.catalogs()
        await catalogs.refresh()
        let session = fixture.session(catalogs)

        #expect(!session.canWrite)
        #expect(
            await !session.add(
                .init(name: "Team packages", kind: .localFolder, remoteLocation: nil, localLocation: fixture.folder)))
        #expect(try #require(try fixture.store.snapshot()).document.configurationState?.catalogSources.isEmpty == true)
    }

    // MARK: - Drawing

    @Test func theAddCatalogSheetDraws() async throws {
        let render = try await ShellRenderFixture()
        defer { render.remove() }

        try expectDrawn(
            AddCatalogSourceSheet(workspace: render.workspace, catalogs: render.workspace.marketplace))
    }

    @Test func theRemoveConfirmationSaysWhatItDoesAndDraws() async throws {
        let render = try await ShellRenderFixture()
        defer { render.remove() }
        let session = WorkspaceCatalogSourceSession(
            workspace: render.workspace, catalogs: render.workspace.marketplace)
        let source = ToolingSource(name: "Team packages", kind: .localFolder, location: "/catalogs/packages")

        try expectControlDrawn(
            RemoveCatalogSourceConfirmation(session: session, source: source) {})
        // Removing a catalog is not removing what came from it, and the screen
        // has to be the thing that says so.
        #expect(RemoveCatalogSourceConfirmation.consequence.contains("Nothing installed from it is removed"))
    }

    /// Discover, with a live "Add source…" in its toolbar and a Sources list
    /// whose recorded rows carry a Remove.
    ///
    /// The button itself is not drawn alone: a glass control never finishes
    /// compositing at its own intrinsic size, and a screen is what a person
    /// actually opens. The catalog behind this is the stub the fixture hands
    /// launch, so nothing here reaches a registry, a client CLI or a folder.
    @Test func discoverStillDrawsWithTheSourceControlsLive() async throws {
        let render = try await ShellRenderFixture()
        defer { render.remove() }
        let catalogs = render.workspace.marketplace
        await catalogs.refresh()
        _ = await WorkspaceCatalogSourceSession(workspace: render.workspace, catalogs: catalogs)
            .add(.init(name: "Team packages", kind: .localFolder, remoteLocation: nil, localLocation: render.home.path))
        #expect(catalogs.sources.contains { $0.name == "Team packages" })

        try expectDrawn(
            MarketplaceView(workspace: render.workspace, session: catalogs)
                .environment(AppNavigationState()))
    }

    // MARK: - Fixtures

    /// A workspace with one native plugin, no catalogs of its own, and no
    /// provider to ask. The folder these tests record exists, because the
    /// command asks this Mac whether it does.
    @MainActor private struct Fixture {
        let root: URL
        let folder: String
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let library: WorkspaceLibrarySession

        init(access: WorkspaceLibraryAccess = .writable) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "catalog-source-session-\(UUID())")
            let container = root.appending(path: "store")
            let catalog = root.appending(path: "packages")
            for directory in [container, catalog] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            folder = catalog.standardizedFileURL.path
            let writerID = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(
                .init(
                    workspaceID: WorkspaceObjectID(), revision: .init(writerID: writerID),
                    artifacts: [
                        .init(
                            identity: .init(id: ArtifactID(), kind: .nativePlugin, displayName: "Example Plugin"),
                            authority: .nativeOwned,
                            nativeRoutes: [.init(client: .claude, externalPluginID: "example@vendor")])
                    ]))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(
                containerRoot: container, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
            library = WorkspaceLibrarySession(
                service: service, workspaceID: document.workspaceID, deviceID: device.deviceID, access: access)
        }

        /// No provider at all: this suite is about what the workspace records,
        /// and a catalog it could ask would only add noise it does not read.
        func catalogs() -> WorkspaceMarketplaceSession {
            .init(providers: [], service: service, library: library, store: store)
        }

        func session(_ catalogs: WorkspaceMarketplaceSession) -> WorkspaceCatalogSourceSession {
            .init(service: service, library: library, catalogs: catalogs)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

/// One control, drawn at its own size.
///
/// The shell harness lays a screen out at a real window's size, which is right
/// for a screen and wrong for a control: an eighteen-point button measured
/// against three-quarters of a million pixels of page background reads as a
/// blank frame whatever it drew. The window and its one run-loop turn stay,
/// because an enabled glass control never finishes compositing without them.
@MainActor
private func expectControlDrawn(
    _ view: some View, _ location: SourceLocation = #_sourceLocation
) throws {
    let host = NSHostingView(rootView: AnyView(view.fixedSize()))
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    #expect(size.width > 0, "the control laid out to no width", sourceLocation: location)
    #expect(size.height > 0, "the control laid out to no height", sourceLocation: location)
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(
        host.bitmapImageRepForCachingDisplay(in: host.bounds),
        "the control produced no drawable area", sourceLocation: location)
    host.cacheDisplay(in: host.bounds, to: bitmap)
    window.orderOut(nil)
    #expect(distinctColours(in: bitmap) >= 2, "the control drew a blank frame", sourceLocation: location)
}

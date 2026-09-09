import Foundation
import Testing

@testable import AgentToolingCore

/// Pointing a destination somewhere other than its default folder. One path is
/// only ever one role, and an apply-once destination never replaces what it
/// did not put there.
@Suite("Workspace linked destinations")
struct WorkspaceLinkedDestinationTests {
    @Test func aRegisteredFolderRedirectsThatDestinationAndNothingElse() throws {
        var device = DeviceWorkspaceState(workspaceID: Self.workspaceID)

        try WorkspaceLinkedDestinations.register(
            selector: Self.codexUser, path: "/Volumes/Work/agents",
            in: &device, managedLibraryRoot: Self.library)

        let found = try #require(WorkspaceLinkedDestinations.binding(for: Self.codexUser, in: device))
        #expect(found.resolvedPath == "/Volumes/Work/agents")
        #expect(found.writePolicy == .noClobberApplyOnce)
        // A different app's destination is untouched.
        #expect(WorkspaceLinkedDestinations.binding(
            for: .init(surface: .claudeCode, scope: .user), in: device) == nil)
    }

    @Test func whichDevicesWantAToolIsNotWhereThisMacPutsIt() throws {
        var device = DeviceWorkspaceState(workspaceID: Self.workspaceID)
        try WorkspaceLinkedDestinations.register(
            selector: Self.codexUser, path: "/Volumes/Work/agents",
            in: &device, managedLibraryRoot: Self.library)

        // The same destination, targeted at particular Macs.
        let targeted = PortableDestination(surface: .codexCLI, scope: .user,
                                           deviceIDs: [WorkspaceObjectID()])
        #expect(WorkspaceLinkedDestinations.binding(for: targeted, in: device) != nil)
    }

    @Test func aFolderThatBytesComeFromCannotAlsoBeWhereTheyGo() throws {
        var device = DeviceWorkspaceState(workspaceID: Self.workspaceID)
        device.sourceLocations = [.init(sourceRootID: WorkspaceObjectID(),
                                        checkoutPath: "/Users/me/my-repo")]

        // One folder being both roles is how a deployment quietly becomes an
        // edit to someone's repository.
        for path in ["/Users/me/my-repo", "/Users/me/my-repo/skills"] {
            #expect(throws: WorkspaceLinkedDestinationError.pathInUseAsSource) {
                try WorkspaceLinkedDestinations.register(
                    selector: Self.codexUser, path: path,
                    in: &device, managedLibraryRoot: Self.library)
            }
        }
        #expect(device.destinations.isEmpty)
    }

    @Test func thisAppsOwnLibraryIsNotSomewhereToPointADestination() throws {
        var device = DeviceWorkspaceState(workspaceID: Self.workspaceID)

        #expect(throws: WorkspaceLinkedDestinationError.pathInsideManagedLibrary) {
            try WorkspaceLinkedDestinations.register(
                selector: Self.codexUser, path: Self.library.path + "/packages",
                in: &device, managedLibraryRoot: Self.library)
        }
    }

    @Test func oneDestinationHasOnePlaceAndOnePlaceHasOneDestination() throws {
        var device = DeviceWorkspaceState(workspaceID: Self.workspaceID)
        try WorkspaceLinkedDestinations.register(
            selector: Self.codexUser, path: "/Volumes/Work/agents",
            in: &device, managedLibraryRoot: Self.library)

        #expect(throws: WorkspaceLinkedDestinationError.duplicateSelector) {
            try WorkspaceLinkedDestinations.register(
                selector: Self.codexUser, path: "/Volumes/Work/elsewhere",
                in: &device, managedLibraryRoot: Self.library)
        }
        #expect(throws: WorkspaceLinkedDestinationError.duplicatePath) {
            try WorkspaceLinkedDestinations.register(
                selector: .init(surface: .claudeCode, scope: .user), path: "/Volumes/Work/agents",
                in: &device, managedLibraryRoot: Self.library)
        }
        #expect(device.destinations.count == 1)
    }

    @Test func aPathThatIsNotOneIsRefused() throws {
        var device = DeviceWorkspaceState(workspaceID: Self.workspaceID)

        for path in ["relative/path", "/Volumes/../etc", "/Volumes/with\u{0}null", ""] {
            #expect(throws: WorkspaceLinkedDestinationError.invalidPath) {
                try WorkspaceLinkedDestinations.register(
                    selector: Self.codexUser, path: path,
                    in: &device, managedLibraryRoot: Self.library)
            }
        }
    }

    @Test func applyOnceWritesIntoAnEmptyPlaceAndNeverOverSomeoneElsesFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let occupied = fixture.root.appending(path: "occupied")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)

        #expect(WorkspaceLinkedDestinations.mayWrite(
            into: fixture.root.appending(path: "empty"),
            policy: .noClobberApplyOnce, provenInstall: false))
        #expect(!WorkspaceLinkedDestinations.mayWrite(
            into: occupied, policy: .noClobberApplyOnce, provenInstall: false))
        // Except where this app's own ledger proves it put that folder there,
        // which is what makes updating a linked destination possible at all.
        #expect(WorkspaceLinkedDestinations.mayWrite(
            into: occupied, policy: .noClobberApplyOnce, provenInstall: true))
        // A destination the person marked replaceable is a different promise.
        #expect(WorkspaceLinkedDestinations.mayWrite(
            into: occupied, policy: .reviewedReplacement, provenInstall: false))
    }

    @Test func forgettingABindingLeavesEverythingAtThatPathAlone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.root.appending(path: "linked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("theirs\n".utf8).write(to: folder.appending(path: "NOTES.md"))
        var device = DeviceWorkspaceState(workspaceID: Self.workspaceID)
        try WorkspaceLinkedDestinations.register(
            selector: Self.codexUser, path: folder.path,
            in: &device, managedLibraryRoot: Self.library)
        let id = try #require(device.destinations.first?.id)

        WorkspaceLinkedDestinations.unregister(id, in: &device)

        #expect(device.destinations.isEmpty)
        // Removing what this app installed is the reviewed removal path's job.
        #expect(try Data(contentsOf: folder.appending(path: "NOTES.md")) == Data("theirs\n".utf8))
    }

    @Test func aRegisteredDestinationStaysThisMacsOwnBusiness() throws {
        var device = DeviceWorkspaceState(workspaceID: Self.workspaceID)
        try WorkspaceLinkedDestinations.register(
            selector: Self.codexUser, path: "/Volumes/Work/agents",
            in: &device, managedLibraryRoot: Self.library)
        let document = try WorkspaceDocumentCoding.seal(.init(
            workspaceID: Self.workspaceID, revision: .init(writerID: WorkspaceObjectID())))

        // The portable side still says "Codex, user scope" everywhere.
        try device.validateStructure(against: document)
        let portable = try WorkspaceDocumentCoding.encode(document)
        #expect(!String(decoding: portable, as: UTF8.self).contains("/Volumes/Work/agents"))
    }

    private static let workspaceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000e5")!)
    private static let codexUser = PortableDestination(surface: .codexCLI, scope: .user)
    private static let library = URL(fileURLWithPath: "/Users/me/Library/Application Support/Agent Tooling/library")

    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "linked-destination-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

/// The executor's own rule: it writes into folders this device registered, and
/// naming one does not make it write anywhere else.
@Suite("Linked destination write bounds")
struct LinkedDestinationWriteBoundsTests {
    @Test func aRegisteredFolderIsWritableAndAnUnregisteredOneIsNot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let allowed = await fixture.install(into: fixture.linked, registering: [fixture.linked])
        #expect(allowed.failed == 0, "\(allowed.outputs)")
        #expect(try Data(contentsOf: fixture.linked.appending(path: "personal/SKILL.md"))
            == fixture.skillBytes)

        // The same folder, with nothing registered.
        let refused = await fixture.install(into: fixture.other, registering: [])
        #expect(refused.failed == 1)
        #expect(refused.outputs.first?.contains("refused to write outside") == true,
                "\(refused.outputs)")
        #expect(!FileManager.default.fileExists(atPath: fixture.other.appending(path: "personal").path))
    }

    @Test func registeringOneFolderDoesNotOpenTheOneBesideIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = await fixture.install(into: fixture.other, registering: [fixture.linked])

        #expect(result.failed == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.other.appending(path: "personal").path))
    }

    @Test func anItemStillCannotWalkOutOfTheFolderThatWasNamed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        // The item's own folder name is checked exactly as it is everywhere
        // else, so a name that climbs is refused rather than resolved.
        let result = await fixture.install(named: "../escaped", into: fixture.linked,
                                           registering: [fixture.linked])

        #expect(result.failed == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "escaped").path))
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let linked: URL
        let other: URL
        let store: WorkspaceRevisionStore
        let source: URL
        let skillBytes = Data("---\nname: personal\ndescription: Fixture\n---\n\n# Personal\n".utf8)

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "linked-write-bounds-\(UUID())")
            home = root.appending(path: "home")
            linked = root.appending(path: "linked")
            other = root.appending(path: "other")
            for url in [home, linked, other] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let document = try WorkspaceDocumentCoding.seal(.init(
                workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID())))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "workspace", directoryHint: .isDirectory),
                workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            try store.prepareManagedDirectories()
            // Staging inside the managed library, which is where the executor
            // insists reviewed content comes from.
            source = store.libraryURL.appending(path: "staged/personal")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try skillBytes.write(to: source.appending(path: "SKILL.md"))
        }

        func install(
            named name: String = "personal", into folder: URL, registering roots: [URL]
        ) async -> (failed: Int, outputs: [String]) {
            let executor = OperationExecutor(store: store, homeURL: home, linkedDestinationRoots: roots)
            let plan = OperationPlan(
                id: UUID(), kind: .installSkill, title: "Install", summary: "Fixture",
                targetSurfaces: [.codexCLI], scope: .user,
                steps: [.init(id: UUID(), kind: .copyDirectory, title: "Install \(name)",
                              detail: "Fixture", sourcePath: source.path,
                              sourceFingerprint: (try? DirectoryFingerprint.sha256(of: source)) ?? "",
                              destinationPath: folder.appending(path: name).path)])
            let receipt = await executor.execute(plan)
            return (receipt.results.filter { $0.status == .failed }.count,
                    receipt.results.map(\.output))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

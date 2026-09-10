import Foundation
import Testing

@testable import AgentToolingCore

/// Adding a catalog records where somebody said to look, and removing one
/// forgets it.
///
/// Two invariants run through every test here. A catalog source and its
/// identity-map allocation are one thing: neither can be written or withdrawn
/// without the other, because a document holding one without the other cannot
/// be opened. And a path is a fact about one Mac: it lives in device state, and
/// the portable bytes must not contain it.
@Suite("Workspace catalog sources")
struct WorkspaceCatalogSourceCommandTests {

    // MARK: - Adding

    @Test func addingRecordsTheCatalogAndItsAllocationTogether() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = WorkspaceObjectID()

        let receipt = try await fixture.service.changeCatalogSource(
            .init(
                expectedRevisionID: fixture.head(),
                adding: .init(
                    id: sourceID, name: "Team catalog", kind: .gitRepository,
                    remoteLocation: "https://example.com/catalog"),
                folders: Fixture.noFolders))

        let snapshot = try #require(try fixture.store.snapshot())
        let state = try #require(snapshot.document.configurationState)
        #expect(state.catalogSources.map(\.name) == ["Team catalog"])
        #expect(state.catalogSources.map(\.kind) == [.gitRepository])
        #expect(WorkspaceCatalogSourceIdentity.entry(for: sourceID, in: state)?.objectID == sourceID)
        // The document was validated inside the transaction, so a record
        // written without its allocation would never have reached the store.
        try snapshot.document.validateStructure()
        // A catalog source is a workspace object, not a library item, so the
        // receipt names no artifact and the library is untouched.
        #expect(receipt.affectedArtifactIDs.isEmpty)
        #expect(receipt.previousRevisionID != receipt.committedRevisionID)
        #expect(snapshot.document.revision.id == receipt.committedRevisionID)
        #expect(snapshot.document.artifacts.count == 1)
        // A remote catalog has no folder on this Mac, so nothing local is
        // claimed about it.
        #expect(snapshot.device.configurationState?.catalogSources.isEmpty == true)
    }

    /// The reason `WorkspaceCatalogSourceIdentity` exists at all: the two halves
    /// are not independently representable.
    @Test func aCatalogWithoutItsAllocationIsNotARepresentableDocument() throws {
        let sourceID = WorkspaceObjectID()
        var document = Fixture.emptyDocument()
        document.configurationState = .init(
            catalogSources: [.init(id: sourceID, name: "Team catalog", kind: .gitRepository)])

        #expect(throws: WorkspaceDomainValidationError.self) { try document.validateStructure() }

        document.configurationState?.identityMap = [WorkspaceCatalogSourceIdentity.entry(for: sourceID)]
        try document.validateStructure()
    }

    @Test func aLocalFolderCatalogKeepsItsPathOutOfThePortableBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = WorkspaceObjectID()

        _ = try await fixture.service.changeCatalogSource(
            .init(
                expectedRevisionID: fixture.head(),
                adding: .init(id: sourceID, name: "Packages", kind: .localFolder),
                localLocation: Fixture.folder,
                folders: Fixture.folders))

        let snapshot = try #require(try fixture.store.snapshot())
        let record = try #require(snapshot.document.configurationState?.catalogSources.first)
        #expect(record.kind == .localFolder)
        #expect(record.remoteLocation == nil)
        let local = try #require(snapshot.device.configurationState?.catalogSources.first)
        #expect(local.catalogSourceID == sourceID)
        #expect(local.localLocation == Fixture.folder)
        // Nothing has looked at the folder, so the row says exactly that
        // rather than carrying a verdict this command did not earn.
        #expect(local.trustSummary == "Not reviewed")
        let portable = try WorkspaceDocumentCoding.encode(snapshot.document)
        #expect(!String(decoding: portable, as: UTF8.self).contains(Fixture.folder))
    }

    @Test func aCatalogAlreadyInTheListIsRefusedByTheNameItAlreadyHas() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.service.changeCatalogSource(
            .init(
                expectedRevisionID: fixture.head(),
                adding: .init(
                    id: WorkspaceObjectID(), name: "Team catalog", kind: .gitRepository,
                    remoteLocation: "https://example.com/catalog"),
                folders: Fixture.noFolders))

        // The same catalog, spelled the way a person would spell it the second
        // time. Only the comparison is normalized; the record keeps its own.
        await #expect(throws: WorkspaceCatalogSourceError.alreadyRecorded("Team catalog")) {
            _ = try await fixture.service.changeCatalogSource(
                .init(
                    expectedRevisionID: fixture.head(),
                    adding: .init(
                        id: WorkspaceObjectID(), name: "Second try", kind: .gitRepository,
                        remoteLocation: "HTTPS://Example.com/catalog/"),
                    folders: Fixture.noFolders))
        }
        #expect(try #require(try fixture.store.snapshot()).document.configurationState?.catalogSources.count == 1)
    }

    @Test func aFolderAlreadyInTheListIsRefusedAndNothingIsWritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.service.changeCatalogSource(
            .init(
                expectedRevisionID: fixture.head(),
                adding: .init(id: WorkspaceObjectID(), name: "Packages", kind: .localFolder),
                localLocation: Fixture.folder, folders: Fixture.folders))
        let head = fixture.head()

        // The duplicate is only visible in this Mac's half, so the refusal
        // happens after the portable half was already staged. The transaction
        // rolls back: the second record must not survive it.
        await #expect(throws: WorkspaceCatalogSourceError.alreadyRecorded("Packages")) {
            _ = try await fixture.service.changeCatalogSource(
                .init(
                    expectedRevisionID: head,
                    adding: .init(id: WorkspaceObjectID(), name: "Same folder again", kind: .localFolder),
                    localLocation: Fixture.folder, folders: Fixture.folders))
        }
        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.revision.id == head)
        #expect(snapshot.document.configurationState?.catalogSources.count == 1)
        #expect(snapshot.device.configurationState?.catalogSources.count == 1)
    }

    @Test func anIdentityAlreadyUsedInThisWorkspaceIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        await #expect(throws: WorkspaceCatalogSourceError.identityCollision) {
            _ = try await fixture.service.changeCatalogSource(
                .init(
                    expectedRevisionID: fixture.head(),
                    adding: .init(
                        id: WorkspaceObjectID(Fixture.skill.rawValue), name: "Team catalog",
                        kind: .gitRepository, remoteLocation: "https://example.com/catalog"),
                    folders: Fixture.noFolders))
        }
        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.configurationState?.catalogSources.isEmpty == true)
        #expect(snapshot.document.revision.id == fixture.initialDocument.revision.id)
    }

    @Test func anAddressCarryingACredentialOrAQueryIsRefused() throws {
        for address in [
            "https://someone:secret@example.com/catalog",
            "https://example.com/catalog?token=abc",
            "https://example.com/catalog#fragment",
            "ftp://example.com/catalog",
            "not a url at all",
        ] {
            #expect(throws: WorkspaceCatalogSourceError.invalidLocation) {
                _ = try WorkspaceCatalogSourceCommand(
                    expectedRevisionID: WorkspaceObjectID(),
                    adding: .init(name: "Team catalog", kind: .gitRepository, remoteLocation: address),
                    folders: Fixture.noFolders)
            }
        }
    }

    @Test func aFolderThisMacCannotSeeIsRefused() throws {
        // A folder that is not there. Asked of an injected probe, so this suite
        // never depends on what happens to exist on the machine running it.
        #expect(throws: WorkspaceCatalogSourceError.invalidLocalFolder) {
            _ = try WorkspaceCatalogSourceCommand(
                expectedRevisionID: WorkspaceObjectID(),
                adding: .init(name: "Packages", kind: .localFolder),
                localLocation: "/nowhere/at/all", folders: Fixture.folders)
        }
        // Not an absolute, standardized path.
        #expect(throws: WorkspaceCatalogSourceError.invalidLocalFolder) {
            _ = try WorkspaceCatalogSourceCommand(
                expectedRevisionID: WorkspaceObjectID(),
                adding: .init(name: "Packages", kind: .localFolder),
                localLocation: "packages", folders: Fixture.folders)
        }
        // A local-folder catalog is read from a folder here and from nowhere
        // else, so one recorded without a folder could never list anything.
        #expect(throws: WorkspaceCatalogSourceError.invalidLocalFolder) {
            _ = try WorkspaceCatalogSourceCommand(
                expectedRevisionID: WorkspaceObjectID(),
                adding: .init(name: "Packages", kind: .localFolder, remoteLocation: "https://example.com/catalog"),
                folders: Fixture.folders)
        }
    }

    @Test func aCatalogThatNamesNowhereIsRefused() throws {
        #expect(throws: WorkspaceCatalogSourceError.invalidLocation) {
            _ = try WorkspaceCatalogSourceCommand(
                expectedRevisionID: WorkspaceObjectID(),
                adding: .init(name: "Registry", kind: .mcpRegistry), folders: Fixture.noFolders)
        }
    }

    /// A blank name is the document's own rule rather than this command's, so
    /// it is refused in the document's own words. Discover keeps it unreachable
    /// by leaving Add off until the field has something in it.
    @Test func aBlankNameIsRefusedInTheDocumentsOwnWords() throws {
        #expect(throws: WorkspaceDomainValidationError.invalidField("catalog source name")) {
            _ = try WorkspaceCatalogSourceCommand(
                expectedRevisionID: WorkspaceObjectID(),
                adding: .init(name: "", kind: .gitRepository, remoteLocation: "https://example.com/catalog"),
                folders: Fixture.noFolders)
        }
    }

    // MARK: - Removing

    @Test func removingTakesTheRecordTheAllocationAndThisMacsRow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = WorkspaceObjectID()
        _ = try await fixture.service.changeCatalogSource(
            .init(
                expectedRevisionID: fixture.head(),
                adding: .init(id: sourceID, name: "Packages", kind: .localFolder),
                localLocation: Fixture.folder, folders: Fixture.folders))

        let receipt = try await fixture.service.changeCatalogSource(
            .init(expectedRevisionID: fixture.head(), removing: sourceID))

        let snapshot = try #require(try fixture.store.snapshot())
        let state = try #require(snapshot.document.configurationState)
        #expect(state.catalogSources.isEmpty)
        #expect(state.identityMap.isEmpty)
        #expect(snapshot.device.configurationState?.catalogSources.isEmpty == true)
        // No tombstone: nothing scans catalogs into this document, so nothing
        // can silently bring one back, and typing the same one in again is
        // exactly what a person is meant to be able to do.
        #expect(snapshot.document.tombstones.isEmpty)
        #expect(receipt.affectedArtifactIDs.isEmpty)
        try snapshot.document.validateStructure()
        try snapshot.device.validateStructure(against: snapshot.document)
    }

    /// The five rows every build shows are reference rows, not records: nobody
    /// added them and nobody can remove them.
    @Test func aRowNobodyRecordedCannotBeRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        await #expect(throws: WorkspaceCatalogSourceError.missingSource) {
            _ = try await fixture.service.changeCatalogSource(
                .init(expectedRevisionID: fixture.head(), removing: WorkspaceObjectID()))
        }
    }

    /// A migrated source is named in this Mac's legacy record by the identifier
    /// it was allocated under. Leaving that behind would make the workspace
    /// point at a catalog the document no longer has, and the device validator
    /// would refuse the whole removal.
    @Test func removingAMigratedCatalogAlsoTakesThisMacsLegacyRecordOfIt() async throws {
        let legacyID = UUID()
        let sourceID = WorkspaceObjectID(legacyID)
        var document = Fixture.emptyDocument()
        document.configurationState = .init(
            catalogSources: [.init(id: sourceID, name: "Migrated", kind: .localFolder)],
            identityMap: [WorkspaceCatalogSourceIdentity.entry(for: sourceID)])
        let fixture = try Fixture(document: document) { device in
            device.applicationState?.catalogSourceIDs = [legacyID]
        }
        defer { fixture.remove() }

        _ = try await fixture.service.changeCatalogSource(
            .init(expectedRevisionID: fixture.head(), removing: sourceID))

        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.configurationState?.catalogSources.isEmpty == true)
        #expect(snapshot.device.applicationState?.catalogSourceIDs.isEmpty == true)
        try snapshot.device.validateStructure(against: snapshot.document)
    }

    // MARK: - Doing it twice, and against a workspace that moved

    @Test func replayingTheSameCommandReturnsItsOriginalReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try WorkspaceCatalogSourceCommand(
            expectedRevisionID: fixture.head(),
            adding: .init(
                name: "Team catalog", kind: .gitRepository, remoteLocation: "https://example.com/catalog"),
            folders: Fixture.noFolders)

        let first = try await fixture.service.changeCatalogSource(command)
        let second = try await fixture.service.changeCatalogSource(command)

        #expect(first == second)
        #expect(try #require(try fixture.store.snapshot()).document.configurationState?.catalogSources.count == 1)
    }

    @Test func askingAgainUnderANewKeyIsRefusedRatherThanDuplicated() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = WorkspaceObjectID()
        _ = try await fixture.service.changeCatalogSource(
            .init(
                expectedRevisionID: fixture.head(),
                adding: .init(id: sourceID, name: "Packages", kind: .localFolder),
                localLocation: Fixture.folder, folders: Fixture.folders))
        _ = try await fixture.service.changeCatalogSource(
            .init(expectedRevisionID: fixture.head(), removing: sourceID))

        // A second removal is a new act with a new key, and the catalog it
        // named is gone.
        await #expect(throws: WorkspaceCatalogSourceError.missingSource) {
            _ = try await fixture.service.changeCatalogSource(
                .init(expectedRevisionID: fixture.head(), removing: sourceID))
        }
        // Adding it back by hand is intended, and works: removal wrote no
        // tombstone to stand in the way.
        _ = try await fixture.service.changeCatalogSource(
            .init(
                expectedRevisionID: fixture.head(),
                adding: .init(id: WorkspaceObjectID(), name: "Packages", kind: .localFolder),
                localLocation: Fixture.folder, folders: Fixture.folders))
        #expect(try #require(try fixture.store.snapshot()).document.configurationState?.catalogSources.count == 1)
    }

    @Test func aCommandBuiltAgainstAWorkspaceThatMovedIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stale = fixture.head()
        _ = try await fixture.service.changeCatalogSource(
            .init(
                expectedRevisionID: stale,
                adding: .init(
                    name: "Team catalog", kind: .gitRepository, remoteLocation: "https://example.com/catalog"),
                folders: Fixture.noFolders))

        await #expect(throws: WorkspaceRevisionStoreError.self) {
            _ = try await fixture.service.changeCatalogSource(
                .init(
                    expectedRevisionID: stale,
                    adding: .init(
                        name: "Other catalog", kind: .gitRepository,
                        remoteLocation: "https://example.com/other"),
                    folders: Fixture.noFolders))
        }
    }

    // MARK: - Merge and sync

    /// A workspace synced from a Mac that never added a catalog carries an
    /// empty list. It must keep reading, encode to exactly the bytes it encoded
    /// to before, and merge to itself unchanged now that this part of the
    /// document is written rather than read-only.
    @Test func aDocumentWithNoCatalogOfItsOwnStillReadsAndMergesUnchanged() throws {
        let document = try WorkspaceDocumentCoding.seal(Fixture.emptyDocument())
        let bytes = try WorkspaceDocumentCoding.encode(document)

        let decoded = try WorkspaceDocumentCoding.decode(bytes)
        #expect(try WorkspaceDocumentCoding.encode(decoded) == bytes)
        #expect(decoded.configurationState?.catalogSources.isEmpty == true)
        try decoded.validateStructure()

        let merged = WorkspaceMergeEngine.merge(
            base: document, local: document, remote: document, writerID: WorkspaceObjectID())
        let result = try #require(merged.document)
        #expect(merged.conflicts.isEmpty)
        #expect(result.configurationState?.catalogSources.isEmpty == true)
        #expect(result.configurationState?.identityMap.isEmpty == true)
        #expect(result.artifacts == document.artifacts)
    }

    @Test func twoMacsEachAddingACatalogKeepBoth() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = try Fixture(document: fixture.initialDocument)
        defer { other.remove() }
        let base = try #require(try fixture.store.snapshot()).document

        _ = try await fixture.service.changeCatalogSource(
            .init(
                expectedRevisionID: fixture.head(),
                adding: .init(
                    name: "Mine", kind: .gitRepository, remoteLocation: "https://example.com/mine"),
                folders: Fixture.noFolders))
        _ = try await other.service.changeCatalogSource(
            .init(
                expectedRevisionID: other.head(),
                adding: .init(
                    name: "Theirs", kind: .gitRepository, remoteLocation: "https://example.com/theirs"),
                folders: Fixture.noFolders))

        let merged = WorkspaceMergeEngine.merge(
            base: base, local: try #require(try fixture.store.snapshot()).document,
            remote: try #require(try other.store.snapshot()).document, writerID: WorkspaceObjectID())
        let result = try #require(merged.document)
        #expect(merged.conflicts.isEmpty)
        #expect(result.configurationState?.catalogSources.map(\.name).sorted() == ["Mine", "Theirs"])
        // Both allocations travelled with their records; the result would not
        // have validated otherwise.
        #expect(result.configurationState?.identityMap.count == 2)
        try result.validateStructure()
    }

    @Test func aCatalogOneMacRemovedIsNotBroughtBackByTheOtherAddingOne() async throws {
        let shared = WorkspaceObjectID()
        var document = Fixture.emptyDocument()
        document.configurationState = .init(
            catalogSources: [
                .init(id: shared, name: "Shared", kind: .gitRepository, remoteLocation: "https://example.com/shared")
            ],
            identityMap: [WorkspaceCatalogSourceIdentity.entry(for: shared)])
        let fixture = try Fixture(document: document)
        defer { fixture.remove() }
        let other = try Fixture(document: fixture.initialDocument)
        defer { other.remove() }
        let base = try #require(try fixture.store.snapshot()).document

        _ = try await fixture.service.changeCatalogSource(
            .init(expectedRevisionID: fixture.head(), removing: shared))
        _ = try await other.service.changeCatalogSource(
            .init(
                expectedRevisionID: other.head(),
                adding: .init(
                    name: "New", kind: .gitRepository, remoteLocation: "https://example.com/new"),
                folders: Fixture.noFolders))

        let merged = WorkspaceMergeEngine.merge(
            base: base, local: try #require(try fixture.store.snapshot()).document,
            remote: try #require(try other.store.snapshot()).document, writerID: WorkspaceObjectID())
        let result = try #require(merged.document)
        #expect(merged.conflicts.isEmpty)
        #expect(result.configurationState?.catalogSources.map(\.name) == ["New"])
        #expect(result.configurationState?.identityMap.count == 1)
        try result.validateStructure()
    }

    /// A removal on one Mac against a change on the other is the person's
    /// decision, not a silent win for either side, and the resolver can apply
    /// it in both directions.
    @Test func removingACatalogTheOtherMacChangedIsAConflictTheResolverCanSettle() async throws {
        let shared = WorkspaceObjectID()
        var document = Fixture.emptyDocument()
        document.configurationState = .init(
            catalogSources: [
                .init(id: shared, name: "Shared", kind: .gitRepository, remoteLocation: "https://example.com/shared")
            ],
            identityMap: [WorkspaceCatalogSourceIdentity.entry(for: shared)])
        let fixture = try Fixture(document: document)
        defer { fixture.remove() }
        let base = try #require(try fixture.store.snapshot()).document

        _ = try await fixture.service.changeCatalogSource(
            .init(expectedRevisionID: fixture.head(), removing: shared))
        let local = try #require(try fixture.store.snapshot()).document
        var renamed = base
        renamed.configurationState?.catalogSources[0].name = "Renamed"
        let remote = try WorkspaceDocumentCoding.seal(renamed)

        let merged = WorkspaceMergeEngine.merge(
            base: base, local: local, remote: remote, writerID: WorkspaceObjectID())
        #expect(merged.conflicts.map(\.kind) == [.catalogSource])
        // Nothing is lost while the person decides.
        #expect(merged.document?.configurationState?.catalogSources.map(\.name) == ["Renamed"])

        let resolved = WorkspaceConflictResolver.resolve(
            base: base, local: local, remote: remote, conflicts: merged.conflicts,
            resolutions: [.init(kind: .catalogSource, objectID: shared, choice: .keepLocal)],
            writerID: WorkspaceObjectID())
        #expect(resolved.isResolved)
        #expect(resolved.document?.configurationState?.catalogSources.isEmpty == true)
        #expect(resolved.document?.configurationState?.identityMap.isEmpty == true)
    }

    // MARK: - Fixtures

    /// A store holding one skill, so identity collisions have something real to
    /// collide with, and no catalog until a test adds one.
    private struct Fixture {
        static let skill = ArtifactID(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1") ?? UUID())
        static let folder = "/catalogs/packages"
        /// A Mac where the one folder these tests use exists, and one where no
        /// folder does. Injected so nothing here reads a real filesystem.
        static let folders = StubFolders(paths: [folder])
        static let noFolders = StubFolders(paths: [])

        let root: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let initialDocument: PortableWorkspaceDocument

        init(
            document: PortableWorkspaceDocument = Fixture.emptyDocument(),
            device configure: (inout DeviceWorkspaceState) -> Void = { _ in }
        ) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "catalog-source-\(UUID())")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let sealed = try WorkspaceDocumentCoding.seal(document)
            initialDocument = sealed
            var device = DeviceWorkspaceState(workspaceID: sealed.workspaceID)
            configure(&device)
            store = try WorkspaceRevisionStore(
                containerRoot: root.appending(path: "store"), workspaceID: sealed.workspaceID,
                deviceID: device.deviceID)
            try store.initialize(document: sealed, device: device)
            service = WorkspaceApplicationService(store: store, writerID: sealed.revision.writerID)
        }

        /// One artifact and no catalogs. The identities are fixed so a test can
        /// name one without having to write a UUID string it must then unwrap.
        static func emptyDocument() -> PortableWorkspaceDocument {
            .init(
                workspaceID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000ff") ?? UUID()),
                revision: .init(
                    id: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000fe") ?? UUID()),
                    writerID: WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-0000000000fd") ?? UUID()),
                    createdAt: Date(timeIntervalSince1970: 1_767_323_045.678)),
                artifacts: [
                    .init(
                        identity: .init(id: skill, kind: .skill, displayName: "Personal"),
                        authority: .centralPersonal, declaredName: "personal")
                ])
        }

        func head() -> WorkspaceObjectID {
            (try? store.snapshot())?.document.revision.id ?? WorkspaceObjectID()
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// A Mac with a known set of folders on it.
    private struct StubFolders: CatalogSourceFolderProbing {
        let paths: Set<String>

        func isCatalogFolder(atPath path: String) -> Bool { paths.contains(path) }
    }
}

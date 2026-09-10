import Foundation
import Testing

@testable import AgentToolingCore

/// Adding a catalog listing to the library, and everything that must not
/// happen while it does.
///
/// One record lands, carrying provenance and nothing else: no assignment, no
/// content, no device state, no client file. The row is not installed and must
/// never read as installed — four independent things still have to hold before
/// anything is asked to install it, and the last test here is the one that
/// measures that.
@Suite("Native package adoption")
struct NativePackageAdoptionCommandTests {

    // MARK: - What one adoption writes

    @Test func adoptingWritesOneNativeOwnedRootAndNothingElse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let artifactID = ArtifactID()

        let receipt = try await fixture.service.adoptNativePackage(
            .init(
                expectedRevisionID: fixture.head(), artifactID: artifactID,
                package: Fixture.listing(), client: .claude))

        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.revision.id == receipt.committedRevisionID)
        #expect(receipt.affectedArtifactIDs == [artifactID])
        let artifact = try #require(snapshot.document.artifacts.first)
        #expect(snapshot.document.artifacts.count == 1)
        #expect(artifact.identity.id == artifactID)
        #expect(artifact.identity.kind == .nativePlugin)
        #expect(artifact.identity.displayName == "Atlas")
        #expect(artifact.identity.parentPackageID == nil)
        #expect(artifact.authority == .nativeOwned)
        #expect(artifact.declaredName == "atlas@vendor")
        #expect(artifact.nativeRoutes == [.init(client: .claude, externalPluginID: "atlas@vendor")])
        #expect(
            artifact.identity.aliases
                == [NativePackageAdoption.pluginAlias(client: .claude, externalPluginID: "atlas@vendor")])
        // The client owns these bytes; this workspace claims none of them.
        #expect(artifact.contentDigest == nil)
        #expect(artifact.packageRelativePath == nil)
        // Adding to the library is not asking for it anywhere, and it is not
        // installing it either.
        #expect(snapshot.document.assignments.isEmpty)
        #expect(snapshot.document.presets.isEmpty)
        // An artifact is not a configuration, policy, collection or catalog
        // source, so it needs no identity-map allocation and gets none.
        #expect(snapshot.document.configurationState?.identityMap.isEmpty != false)
        // Nothing about this Mac changed.
        #expect(snapshot.device == fixture.device)
    }

    @Test func theRecordedRowIsWhatDiscoverThenRecognizesAsHeld() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.service.adoptNativePackage(
            .init(expectedRevisionID: fixture.head(), package: Fixture.listing(), client: .claude))

        // The command and Discover ask one question in one place, so the button
        // that added the row is the button that now points at it.
        let snapshot = try #require(try fixture.store.snapshot())
        guard
            case .exact(let match) = NativePackageAdoption.recognize(
                client: .claude, externalPluginID: "atlas@vendor", in: snapshot.document)
        else {
            Issue.record("An adopted package is the package the library holds.")
            return
        }
        #expect(match.displayName == "Atlas")
        #expect(match.reason == .nativeRoute)
    }

    // MARK: - Being adopted twice

    @Test func replayingTheSameCommandReturnsItsOriginalReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try NativePackageAdoptionCommand(
            expectedRevisionID: fixture.head(), package: Fixture.listing(), client: .claude)

        let first = try await fixture.service.adoptNativePackage(command)
        let replayed = try await fixture.service.adoptNativePackage(command)

        #expect(first == replayed)
        // A replay is a repeated answer, never a second row.
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.count == 1)
    }

    @Test func addingTheSamePackageAgainIsRefusedByName() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.service.adoptNativePackage(
            .init(expectedRevisionID: fixture.head(), package: Fixture.listing(), client: .claude))

        // A new key, so this is a second request rather than a replay.
        let refusal = await fixture.refusal {
            try NativePackageAdoptionCommand(
                expectedRevisionID: fixture.head(), package: Fixture.listing(), client: .claude)
        }
        guard case .alreadyInLibrary(let match) = try #require(refusal) else {
            Issue.record("Expected the row it already holds to be named, got \(String(describing: refusal)).")
            return
        }
        #expect(match.displayName == "Atlas")
        #expect(
            refusal?.localizedDescription
                == "Atlas is already in your library. Open it to choose where it goes.")
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.count == 1)
    }

    @Test func aListingWhoseRouteIsAlreadyHeldIsRefused() async throws {
        // The ordinary case: a first-run scan recorded the package this catalog
        // is now listing, so there is nothing to add.
        let fixture = try Fixture(
            artifacts: [
                .init(
                    identity: .init(kind: .nativePlugin, displayName: "Atlas, already scanned"),
                    authority: .nativeOwned, declaredName: "atlas@vendor",
                    nativeRoutes: [.init(client: .claude, externalPluginID: "atlas@vendor")])
            ])
        defer { fixture.remove() }

        let refusal = await fixture.refusal {
            try NativePackageAdoptionCommand(
                expectedRevisionID: fixture.head(), package: Fixture.listing(), client: .claude)
        }
        guard case .alreadyInLibrary(let match) = try #require(refusal) else {
            Issue.record("A held route is identity, got \(String(describing: refusal)).")
            return
        }
        #expect(match.reason == .nativeRoute)
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.count == 1)
    }

    @Test func aTrackedPackageOfTheSameNameIsAnAmbiguityRatherThanASecondRecord() async throws {
        // How a first run records a package whose member files it could not
        // locate: the identifier, no route, and `trackedOnly`. It may be this
        // package seen through another app, or a different package of the same
        // name. Nothing here can tell, so nothing here decides.
        let fixture = try Fixture(
            artifacts: [
                .init(
                    identity: .init(kind: .nativePlugin, displayName: "Atlas, as this Mac found it"),
                    authority: .trackedOnly, declaredName: "atlas@vendor")
            ])
        defer { fixture.remove() }

        let refusal = await fixture.refusal {
            try NativePackageAdoptionCommand(
                expectedRevisionID: fixture.head(), package: Fixture.listing(), client: .claude)
        }
        guard case .ambiguousExistingRecord(let match, let identifier) = try #require(refusal) else {
            Issue.record("An equal identifier is an ambiguity, got \(String(describing: refusal)).")
            return
        }
        #expect(match.reason == .declaredName)
        #expect(identifier == "atlas@vendor")
        #expect(
            refusal?.localizedDescription
                == """
                Your library already has a package called atlas@vendor — Atlas, as this Mac found it — recorded from another app. \
                Open it rather than adding a second record of the same name.
                """)
        // Promoting a tracked record to native ownership is its own command.
        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.artifacts.count == 1)
        #expect(snapshot.document.artifacts[0].authority == .trackedOnly)
    }

    @Test func aNamesakeUnderAnotherClientIsNeverSilentlyMergedIntoOneRow() async throws {
        // The case the rule exists for: one identifier, two publishers. Codex's
        // "atlas@vendor" and Claude's may be one product or two, so the person
        // settles it rather than this build guessing.
        let fixture = try Fixture(
            artifacts: [
                .init(
                    identity: .init(kind: .nativePlugin, displayName: "Atlas from Codex"),
                    authority: .nativeOwned, declaredName: "atlas@vendor",
                    nativeRoutes: [.init(client: .codex, externalPluginID: "atlas@vendor")])
            ])
        defer { fixture.remove() }

        let refusal = await fixture.refusal {
            try NativePackageAdoptionCommand(
                expectedRevisionID: fixture.head(), package: Fixture.listing(), client: .claude)
        }
        guard case .ambiguousExistingRecord = try #require(refusal) else {
            Issue.record("Expected an ambiguity, got \(String(describing: refusal)).")
            return
        }
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.count == 1)
    }

    @Test func aPackageRemovedBeforeIsNotRecreatedByACatalogListing() async throws {
        let fixture = try Fixture(
            tombstoneAliases: [
                NativePackageAdoption.pluginAlias(client: .claude, externalPluginID: "atlas@vendor")
            ])
        defer { fixture.remove() }

        let refusal = await fixture.refusal {
            try NativePackageAdoptionCommand(
                expectedRevisionID: fixture.head(), package: Fixture.listing(), client: .claude)
        }
        #expect(refusal == .previouslyRemoved)
        #expect(
            refusal?.localizedDescription
                == """
                You removed this package from your library before. \
                Add it back from the library rather than from a catalog listing.
                """)
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.isEmpty)
    }

    // MARK: - Listings a command cannot be built from

    @Test func aClientWithNoRecordedInstallCommandIsRefusedWhenTheCommandIsBuilt() throws {
        // Two catalogs describing one package combine their routes, so a
        // listing can offer a Gemini route. Nothing has read Gemini's install
        // command, and writing a plausible one is the invention the register
        // exists to avoid — so this is a library item Install could never act
        // on, and it is refused rather than recorded.
        #expect(NativePluginInstallRegister.command(for: .gemini, externalPluginID: "atlas@vendor") == nil)

        let refusal = NativePackageAdoptionCommand.refusal(adding: Fixture.listing(), for: .gemini)
        #expect(refusal == .noRecordedInstallCommand(.gemini))
        #expect(
            refusal?.localizedDescription
                == """
                Nothing has recorded how Gemini CLI installs a package, \
                so this would be a library item Install could never act on.
                """)
        #expect(throws: NativePackageAdoptionError.noRecordedInstallCommand(.gemini)) {
            try NativePackageAdoptionCommand(
                expectedRevisionID: WorkspaceObjectID(), package: Fixture.listing(), client: .gemini)
        }
    }

    @Test func aListingWithoutItsCatalogsIdentityCannotBeAddedByName() throws {
        var unparsed = Fixture.listing()
        unparsed.id = "atlas@vendor"
        var multiComponent = Fixture.listing()
        multiComponent.components = [.plugin, .skill]

        for listing in [unparsed, multiComponent] {
            #expect(
                NativePackageAdoptionCommand.refusal(adding: listing, for: .claude) == .unrecognizedListing)
        }
        #expect(
            NativePackageAdoptionError.unrecognizedListing.localizedDescription
                == "This listing does not carry the package identity its catalog records, so it cannot be added by name.")
    }

    @Test func aPackageIsNeverRecordedUnderAnotherAppsNamespace() throws {
        // Codex has a recorded install command, so this gets past the register
        // and is refused on the only ground that matters: no catalog published
        // `atlas@vendor` as a Codex package.
        #expect(NativePluginInstallRegister.command(for: .codex, externalPluginID: "atlas@vendor") != nil)
        #expect(
            NativePackageAdoptionCommand.refusal(adding: Fixture.listing(), for: .codex) == .unrecognizedListing)
    }

    @Test func aListingThatCanBeAddedIsNotRefusedWhenTheScreenAsksFirst() throws {
        // The screen asks before offering the control, so a button that is
        // offered is one the command accepts.
        #expect(NativePackageAdoptionCommand.refusal(adding: Fixture.listing(), for: .claude) == nil)
    }

    // MARK: - Writing against a workspace that moved

    @Test func aStaleExpectedRevisionIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stale = fixture.head()
        _ = try await fixture.service.adoptNativePackage(
            .init(expectedRevisionID: stale, package: Fixture.listing(), client: .claude))

        // A second, different package, applied against the head that moved.
        await #expect(throws: (any Error).self) {
            _ = try await fixture.service.adoptNativePackage(
                .init(
                    expectedRevisionID: stale,
                    package: Fixture.listing(id: "claude:orbit@vendor", name: "Orbit"), client: .claude))
        }
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.count == 1)
    }

    @Test func anIdentityAlreadyUsedInThisWorkspaceIsRefused() async throws {
        let existing = ArtifactID()
        let fixture = try Fixture(
            artifacts: [
                .init(
                    identity: .init(id: existing, kind: .skill, displayName: "Something else"),
                    authority: .centralPersonal, declaredName: "something-else")
            ])
        defer { fixture.remove() }

        await #expect(throws: NativePackageAdoptionError.identityCollision) {
            _ = try await fixture.service.adoptNativePackage(
                .init(
                    expectedRevisionID: fixture.head(), artifactID: existing,
                    package: Fixture.listing(), client: .claude))
        }
        #expect(
            NativePackageAdoptionError.identityCollision.localizedDescription
                == "That identity is already used in this workspace.")
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.count == 1)
    }

    // MARK: - The row is not installed

    @Test func theAdoptedRowReachesDeploymentOnlyWithAnAssignmentAndAReviewedRoute() async throws {
        let fixture = try Fixture(capableOf: .claudeCode)
        defer { fixture.remove() }
        let artifactID = ArtifactID()
        _ = try await fixture.service.adoptNativePackage(
            .init(
                expectedRevisionID: fixture.head(), artifactID: artifactID,
                package: Fixture.listing(), client: .claude))
        let route = NativePackageRoute(client: .claude, externalPluginID: "atlas@vendor")
        let target = ResolvedAssignmentTarget(
            selector: .init(surface: .claudeCode, scope: .user, logicalProjectID: nil),
            physicalDestinationID: WorkspaceObjectID(), installedClientVersion: "1.0.0",
            adapterContractVersion: 1, componentContexts: [.init(component: .plugin)])

        // Adopted, and asked for nowhere: the plan proposes nothing at all.
        let unassigned = try await fixture.service.deploymentPlan(
            targets: [target], nativeInstallRoutes: [route])
        #expect(unassigned.items.isEmpty)
        #expect(unassigned.exclusions.isEmpty)

        _ = try await fixture.service.applyAssignmentBatch(
            .assign(
                document: try #require(try fixture.store.snapshot()).document, artifactIDs: [artifactID],
                destinations: [.init(surface: .claudeCode, scope: .user)]))

        // Asked for, but with no reviewed route for this Mac, it is excluded by
        // name rather than attempted.
        let unreviewed = try await fixture.service.deploymentPlan(targets: [target])
        #expect(unreviewed.items.isEmpty)
        #expect(unreviewed.exclusions.map(\.reason) == [.missingNativeRoute])

        let offered = try await fixture.service.deploymentPlan(
            targets: [target], nativeInstallRoutes: [route])
        #expect(offered.items.map(\.action) == [.installNativePackage(route: route)])
    }

    // MARK: - Two Macs

    @Test func adoptingOnOneMacAndNothingOnTheOtherFastForwards() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let base = try #require(try fixture.store.snapshot()).document
        _ = try await fixture.service.adoptNativePackage(
            .init(expectedRevisionID: fixture.head(), package: Fixture.listing(), client: .claude))
        let local = try #require(try fixture.store.snapshot()).document

        let merged = WorkspaceMergeEngine.merge(
            base: base, local: local, remote: base, writerID: WorkspaceObjectID())

        #expect(merged.conflicts.isEmpty)
        #expect(try #require(merged.document).artifacts.map(\.identity.id) == local.artifacts.map(\.identity.id))
    }

    @Test func bothMacsAddingTheSamePackageIsNamedRatherThanRefusedWhole() async throws {
        let here = try Fixture()
        defer { here.remove() }
        let there = try Fixture(workspaceID: here.workspaceID, base: here.baseDocument)
        defer { there.remove() }
        let base = here.baseDocument
        // Two Macs, one listing, two artifact IDs. The document's own rule says
        // one package is at most one live artifact, so this cannot merge.
        _ = try await here.service.adoptNativePackage(
            .init(expectedRevisionID: here.head(), package: Fixture.listing(), client: .claude))
        _ = try await there.service.adoptNativePackage(
            .init(expectedRevisionID: there.head(), package: Fixture.listing(), client: .claude))

        let local = try #require(try here.store.snapshot()).document
        let remote = try #require(try there.store.snapshot()).document
        let merged = WorkspaceMergeEngine.merge(
            base: base, local: local, remote: remote, writerID: WorkspaceObjectID())

        #expect(merged.document == nil)
        #expect(merged.conflicts.map(\.kind) == [.nativeRouteCollision])
        // Naming it is the point: a whole merge returned as "this did not pass
        // its own checks" is exactly what a person cannot act on.
        #expect(!merged.conflicts.contains { $0.kind == .invalidResult })

        // The fix is to remove one of the two rows, so this is not a
        // pick-a-side, and choosing one changes nothing.
        let resolved = WorkspaceConflictResolver.resolve(
            base: base, local: local, remote: remote, conflicts: merged.conflicts,
            resolutions: merged.conflicts.map {
                .init(kind: $0.kind, artifactID: $0.artifactID, objectID: $0.objectID, choice: .keepLocal)
            },
            writerID: WorkspaceObjectID())
        #expect(!resolved.isResolved)
        #expect(resolved.remaining.map(\.kind) == [.nativeRouteCollision])
    }

    @Test func aWorkspaceThatNeverUsedThisCommandReadsAndMergesUnchanged() throws {
        // A document synced from a Mac that has adopted nothing: no field this
        // command writes exists in it, and nothing about it may move.
        let scanned = try Fixture.scanned()
        try scanned.validateStructure()
        let device = DeviceWorkspaceState(workspaceID: scanned.workspaceID)
        try device.validateStructure(against: scanned)

        let encoded = try WorkspaceDocumentCoding.encode(scanned)
        #expect(try WorkspaceDocumentCoding.decode(encoded) == scanned)
        let merged = WorkspaceMergeEngine.merge(
            base: scanned, local: scanned, remote: scanned, writerID: WorkspaceObjectID())
        #expect(merged.conflicts.isEmpty)
        #expect(try #require(merged.document).artifacts == scanned.artifacts)
        // A listing this workspace has never seen is still recognized as new.
        #expect(
            NativePackageAdoption.recognize(client: .claude, externalPluginID: "atlas@vendor", in: scanned)
                == NativePackageAdoption.Recognition.none)
    }

    // MARK: - Fixture

    /// A real revision store, and the one catalog listing every test adds.
    private struct Fixture {
        let root: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService
        let workspaceID: WorkspaceObjectID
        let baseDocument: PortableWorkspaceDocument
        let device: DeviceWorkspaceState

        init(
            artifacts: [ArtifactRecord] = [],
            tombstoneAliases: [ExternalAlias] = [],
            capableOf surface: TargetSurface? = nil,
            workspaceID: WorkspaceObjectID = WorkspaceObjectID(),
            base: PortableWorkspaceDocument? = nil
        ) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "native-package-adoption-\(UUID())")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let writerID = WorkspaceObjectID()
            self.workspaceID = workspaceID
            let revisionID = WorkspaceObjectID()
            baseDocument =
                try base
                ?? WorkspaceDocumentCoding.seal(
                    .init(
                        workspaceID: workspaceID, revision: .init(id: revisionID, writerID: writerID),
                        artifacts: artifacts,
                        tombstones: tombstoneAliases.isEmpty
                            ? []
                            : [
                                .init(
                                    artifactID: ArtifactID(), aliases: tombstoneAliases,
                                    deletedInRevisionID: revisionID)
                            ]))
            var device = DeviceWorkspaceState(workspaceID: baseDocument.workspaceID)
            if let surface {
                device.capabilityEvidence = [
                    .init(
                        surface: surface, installedClientVersion: "1.0.0", adapterContractVersion: 1,
                        component: .plugin, scopes: [.user], support: .supported,
                        observedAt: Date(timeIntervalSince1970: 1_700_000_000))
                ]
                device.observations = [
                    .init(
                        surface: surface, installed: true, commandAvailable: true, version: "1.0.0",
                        capabilities: .init(
                            supportsPluginInstall: true, supportsProjectScope: true,
                            supportsLocalMarketplace: false, supportsMCPAuthentication: false,
                            supportsConnectorDiscovery: false, requiresNewSession: true,
                            requiresRestart: false, supportsMachineReadableOutput: true),
                        lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000))
                ]
            }
            self.device = device
            store = try WorkspaceRevisionStore(
                containerRoot: root.appending(path: "store"), workspaceID: baseDocument.workspaceID,
                deviceID: device.deviceID)
            try store.initialize(document: baseDocument, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
        }

        func head() -> WorkspaceObjectID {
            (try? store.snapshot())?.document.revision.id ?? WorkspaceObjectID()
        }

        /// The refusal building or applying this command produced, or `nil`.
        func refusal(
            _ build: () throws -> NativePackageAdoptionCommand
        ) async -> NativePackageAdoptionError? {
            do {
                _ = try await service.adoptNativePackage(try build())
                return nil
            } catch let error as NativePackageAdoptionError {
                return error
            } catch {
                Issue.record("Expected an adoption refusal, got \(error).")
                return nil
            }
        }

        /// One native-catalog plugin listing, shaped exactly as the Claude
        /// catalog parser leaves one: a `claude:` identifier, one component, and
        /// a client that agrees with it.
        static func listing(id: String = "claude:atlas@vendor", name: String = "Atlas") -> MarketplacePackage {
            MarketplacePackage(
                id: id, name: name, publisher: "vendor", summary: "A catalog listing.",
                sourceName: "vendor", revision: "1.4.0", components: [.plugin], supportedClients: [.claude],
                location: "https://example.com/atlas",
                nativeInstalls: [
                    NativeInstall(
                        client: .claude, executable: "claude",
                        arguments: ["plugin", "install", "atlas@vendor", "--scope", "user"],
                        removalArguments: ["plugin", "uninstall", "atlas@vendor"], scope: .user,
                        detail: "Installs through Claude Code's own plugin manager.")
                ])
        }

        /// A scan-built workspace that has never used this command.
        static func scanned() throws -> PortableWorkspaceDocument {
            let packageID = ArtifactID()
            return try WorkspaceDocumentCoding.seal(
                .init(
                    workspaceID: WorkspaceObjectID(), revision: .init(writerID: WorkspaceObjectID()),
                    artifacts: [
                        .init(
                            identity: .init(id: packageID, kind: .nativePlugin, displayName: "Pack"),
                            authority: .nativeOwned, declaredName: "pack",
                            nativeRoutes: [.init(client: .claude, externalPluginID: "pack")]),
                        .init(
                            identity: .init(
                                kind: .skill, displayName: "Bundled", parentPackageID: packageID),
                            authority: .nativeOwned, declaredName: "bundled",
                            packageRelativePath: "skills/bundled"),
                    ]))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

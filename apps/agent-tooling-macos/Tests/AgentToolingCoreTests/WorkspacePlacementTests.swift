import Foundation
import Testing

@testable import AgentToolingCore

/// Explicit placements: one item at one destination each, the way setup's
/// placement grid records them. Pairs something already asks for are passed
/// over and reported, setup's own earlier contributions are withdrawn only
/// where no placement still wants them, and the library session reviews them
/// even while it is busy.
@Suite("Workspace placement")
@MainActor
struct WorkspacePlacementTests {
    // MARK: - place(...)

    @Test func explicitPairsAreRecordedExactlyAsGiven() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let placements = [
            WorkspacePlacement(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI)),
            WorkspacePlacement(artifactID: fixture.plugin, destination: fixture.thisMacOnly(.claudeCode)),
        ]

        let placed = try WorkspaceAssignmentBatchCommand.place(document: fixture.document, placements: placements)

        #expect(placed.alreadyRequested.isEmpty)
        #expect(placed.command.removalIDs.isEmpty)
        #expect(placed.command.expectedRevisionID == fixture.document.revision.id)
        #expect(placed.command.additions.map { WorkspacePlacement(artifactID: $0.artifactID, destination: $0.destination) } == placements)
        #expect(placed.command.additions.allSatisfy { $0.reason == .manual && $0.desiredPresence && $0.desiredEnabled == nil })
    }

    /// Unlike `assign`, nothing is crossed: two items in two apps is two
    /// placements, not four.
    @Test func noPairIsCrossedWithAnother() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let placed = try WorkspaceAssignmentBatchCommand.place(
            document: fixture.document,
            placements: [
                .init(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI)),
                .init(artifactID: fixture.plugin, destination: fixture.everyMac(.claudeCode)),
            ])

        #expect(placed.command.additions.count == 2)
        #expect(!placed.command.additions.contains { $0.artifactID == fixture.skill && $0.destination.surface == .claudeCode })
    }

    @Test func aPairSomethingAlreadyAsksForIsPassedOverAndReported() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Asked for already, by a manual request at the same destination.
        let existing = AssignmentContribution(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI), reason: .manual)
        let document = try await fixture.commit(additions: [existing])
        let wanted = WorkspacePlacement(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI))
        let new = WorkspacePlacement(artifactID: fixture.skill, destination: fixture.everyMac(.claudeCode))

        let placed = try WorkspaceAssignmentBatchCommand.place(document: document, placements: [wanted, new])

        #expect(placed.alreadyRequested == [wanted])
        #expect(placed.command.additions.map(\.destination) == [fixture.everyMac(.claudeCode)])
        // The batch saves without the re-ask a cross product would refuse.
        _ = try await fixture.service.applyAssignmentBatch(placed.command)
        #expect(try await fixture.assignments().count == 2)
    }

    @Test func everythingAlreadyAskedForIsNothingToSave() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let document = try await fixture.commit(additions: [
            .init(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI), reason: .manual)
        ])

        #expect(throws: WorkspaceAssignmentCommandError.emptyBatch) {
            _ = try WorkspaceAssignmentBatchCommand.place(
                document: document, placements: [.init(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI))])
        }
    }

    /// Going back and changing one cell: the contribution still wanted is
    /// kept as it is, the one no longer wanted is withdrawn, and only the new
    /// cell is added.
    @Test func ownContributionsAreWithdrawnOnlyWhereNoPlacementWantsThem() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let kept = AssignmentContribution(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI), reason: .manual)
        let dropped = AssignmentContribution(artifactID: fixture.skill, destination: fixture.everyMac(.claudeCode), reason: .manual)
        let document = try await fixture.commit(additions: [kept, dropped])

        let placed = try WorkspaceAssignmentBatchCommand.place(
            document: document,
            placements: [
                .init(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI)),
                .init(artifactID: fixture.plugin, destination: fixture.everyMac(.claudeCode)),
            ],
            withdrawing: [kept.id, dropped.id, WorkspaceObjectID()])

        #expect(placed.alreadyRequested.isEmpty)
        #expect(placed.command.removalIDs == [dropped.id])
        #expect(placed.command.additions.map(\.artifactID) == [fixture.plugin])
        _ = try await fixture.service.applyAssignmentBatch(placed.command)
        let saved = try await fixture.assignments()
        #expect(Set(saved.map(\.id)) == Set([kept.id] + placed.command.additions.map(\.id)))
    }

    /// Withdrawing what this setup placed, with nothing placed now, removes
    /// it all: every cell turned off after going back.
    @Test func withdrawingEverythingIsARemovalOnlyBatch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let own = AssignmentContribution(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI), reason: .manual)
        let document = try await fixture.commit(additions: [own])

        let placed = try WorkspaceAssignmentBatchCommand.place(document: document, placements: [], withdrawing: [own.id])

        #expect(placed.command.additions.isEmpty)
        #expect(placed.command.removalIDs == [own.id])
    }

    /// Every Mac and This Mac only are different requests for the same app:
    /// both are recorded, neither is a re-ask of the other.
    @Test func everyMacAndThisMacOnlyAreDifferentPlacements() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let document = try await fixture.commit(additions: [
            .init(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI), reason: .manual)
        ])

        let placed = try WorkspaceAssignmentBatchCommand.place(
            document: document, placements: [.init(artifactID: fixture.skill, destination: fixture.thisMacOnly(.codexCLI))])

        #expect(placed.alreadyRequested.isEmpty)
        #expect(placed.command.additions.first?.destination.deviceIDs == [fixture.thisMac])
        _ = try await fixture.service.applyAssignmentBatch(placed.command)
        let saved = try await fixture.assignments()
        #expect(Set(saved.map(\.destination.deviceIDs)) == [nil, [fixture.thisMac]])
    }

    /// The same Macs named in another order are the same placement.
    @Test func devicesInAnotherOrderAreTheSamePlacement() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = WorkspaceObjectID()
        let both = [fixture.thisMac, other].sorted()
        let document = try await fixture.commit(additions: [
            .init(
                artifactID: fixture.skill, destination: .init(surface: .codexCLI, scope: .user, deviceIDs: both), reason: .manual)
        ])
        let reversed = WorkspacePlacement(
            artifactID: fixture.skill, destination: .init(surface: .codexCLI, scope: .user, deviceIDs: both.reversed()))

        #expect(throws: WorkspaceAssignmentCommandError.duplicateSelection) {
            _ = try WorkspaceAssignmentBatchCommand.place(
                document: document,
                placements: [
                    reversed, .init(artifactID: fixture.skill, destination: .init(surface: .codexCLI, scope: .user, deviceIDs: both)),
                ])
        }
        #expect(throws: WorkspaceAssignmentCommandError.emptyBatch) {
            _ = try WorkspaceAssignmentBatchCommand.place(document: document, placements: [reversed])
        }
    }

    @Test func aTrackedItemIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(throws: WorkspaceAssignmentCommandError.unsupportedArtifact) {
            _ = try WorkspaceAssignmentBatchCommand.place(
                document: fixture.document,
                placements: [
                    .init(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI)),
                    .init(artifactID: fixture.tracked, destination: fixture.everyMac(.codexCLI)),
                ])
        }
    }

    /// What `place` passes over, and what setup's what-if plan never asks
    /// for again: the same item at the same destination, its Macs named in
    /// any order, whatever the reason, whether or not it reaches this Mac.
    @Test func aPlacementIsAskedForByTheSameRequestWhateverItsReason() {
        let skill = ArtifactID()
        let thisMac = WorkspaceObjectID()
        let other = WorkspaceObjectID()
        let named = PortableDestination(surface: .codexCLI, scope: .user, deviceIDs: [thisMac, other])
        let placement = WorkspacePlacement(artifactID: skill, destination: named)
        func asking(_ artifact: ArtifactID, _ destination: PortableDestination, _ reason: AssignmentReason = .manual)
            -> AssignmentContribution
        {
            .init(artifactID: artifact, destination: destination, reason: reason)
        }

        #expect(placement.isAsked(by: asking(skill, .init(surface: .codexCLI, scope: .user, deviceIDs: [other, thisMac]))))
        #expect(placement.isAsked(by: asking(skill, named, .preset(presetID: ArtifactID()))))
        #expect(!placement.isAsked(by: asking(skill, .init(surface: .codexCLI, scope: .user))), "Every Mac is another request")
        #expect(!placement.isAsked(by: asking(skill, .init(surface: .claudeCode, scope: .user, deviceIDs: [thisMac, other]))))
        #expect(!placement.isAsked(by: asking(ArtifactID(), named)))
    }

    /// Every contribution in a document `place` accepts asks for its
    /// placement: one whose `desiredPresence` is false makes the document
    /// invalid, so it is refused before anything could be passed over as
    /// already asked for.
    @Test func aDocumentWithAContributionThatAsksForNothingIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var document = fixture.document
        document.assignments.append(
            .init(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI), reason: .manual, desiredPresence: false))

        #expect(throws: WorkspaceDomainValidationError.missingReference("assignment artifact")) {
            _ = try WorkspaceAssignmentBatchCommand.place(
                document: document, placements: [.init(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI))])
        }
    }

    @Test func aPlacementGivenTwiceIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let placement = WorkspacePlacement(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI))

        #expect(throws: WorkspaceAssignmentCommandError.duplicateSelection) {
            _ = try WorkspaceAssignmentBatchCommand.place(document: fixture.document, placements: [placement, placement])
        }
    }

    // MARK: - reviewPlacements

    @Test func reviewedPlacementsSaveAsOneRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        let placements = [
            WorkspacePlacement(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI)),
            WorkspacePlacement(artifactID: fixture.plugin, destination: fixture.everyMac(.claudeCode)),
        ]

        await session.reviewPlacements(placements)
        let review = try #require(session.review)
        #expect(review.preview.additions.count == 2)
        await session.applyReviewedAssignments()

        #expect(session.lastReceipt != nil)
        #expect(session.errorMessage == nil)
        let head = try #require(try fixture.store.snapshot()?.document)
        #expect(head.revision.parentIDs == [fixture.document.revision.id])
        #expect(Set(head.assignments.map { WorkspacePlacement(artifactID: $0.artifactID, destination: $0.destination) }) == Set(placements))
    }

    /// Nothing to save is not an error: there is no review and nothing to
    /// say.
    @Test func reviewingWhatIsAlreadyAskedForLeavesNoReviewAndNoError() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.commit(additions: [
            .init(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI), reason: .manual)
        ])
        let session = fixture.session()

        await session.reviewPlacements([.init(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI))])

        #expect(session.review == nil)
        #expect(session.errorMessage == nil)
        #expect(session.state != nil)
    }

    /// A session busy reading (the shell's read at launch) does not turn the
    /// stage's review into a silent no-op: it waits, then reviews.
    @Test(.timeLimit(.minutes(5)))
    func aBusySessionStillReviews() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = HeldLibraryReads(service: fixture.service)
        let session = WorkspaceLibrarySession(
            service: gate, workspaceID: fixture.document.workspaceID, deviceID: fixture.thisMac, access: .writable)
        let reading = Task { await session.refresh() }
        await gate.waitUntilHeld()
        #expect(session.isBusy)

        let reviewing = Task {
            await session.reviewPlacements([.init(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI))])
        }
        await Task.yield()
        gate.release()
        await reading.value
        await reviewing.value

        let review = try #require(session.review, "the review waited for the read instead of returning")
        #expect(review.preview.additions.map(\.artifactID) == [fixture.skill])
    }

    /// The read a review waits for can end with another caller starting work
    /// at once, ahead of it. The review waits that out too and lands; it
    /// never finds the session busy and returns with nothing saved, which a
    /// stage would read as nothing to save.
    @Test(.timeLimit(.minutes(5)))
    func aReviewWaitsOutWorkThatStartsAheadOfIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = HeldLibraryReads(service: fixture.service)
        let session = WorkspaceLibrarySession(
            service: gate, workspaceID: fixture.document.workspaceID, deviceID: fixture.thisMac, access: .writable)
        let reading = Task { await session.refresh() }
        await gate.waitUntilHeld()
        // Waiting first: a caller that reviews the plugin as soon as the read
        // lands, so its review is under way when the stage's turn comes.
        let ahead = Task {
            await session.refresh()
            await session.reviewAssignments(artifactIDs: [fixture.plugin], destinations: [fixture.everyMac(.claudeCode)])
        }
        let reviewing = Task {
            await session.reviewPlacements([.init(artifactID: fixture.skill, destination: fixture.everyMac(.codexCLI))])
        }
        // Both are now waiting for the read, in that order.
        await Task.yield()
        gate.release()
        await reading.value
        await ahead.value
        await reviewing.value

        let review = try #require(session.review)
        #expect(review.preview.additions.map(\.artifactID) == [fixture.skill], "the stage's review found the session busy")
        #expect(session.errorMessage == nil)
    }

    // MARK: - The shared skill folder

    /// Gemini CLI also reads Codex's folder: the folder `alsoReads` names is
    /// one the Gemini CLI adapter reads, and nothing else is claimed.
    @Test func geminiAlsoReadsTheFolderCodexInstallsInto() throws {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
        #expect(NativeSkillDestination.alsoReads(.gemini) == [.codex])
        for client in ClientKind.allCases where client != .gemini {
            #expect(NativeSkillDestination.alsoReads(client).isEmpty)
        }
        let codexFolder = try NativeSkillDestination.directory(client: .codex, homeURL: home, scope: .user, projectRoot: nil)
        let geminiRoots = GeminiCLIAdapter().readLocations(homeURL: home).skillRoots.map(\.standardizedFileURL)
        #expect(geminiRoots.contains(codexFolder.standardizedFileURL))
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let writerID = WorkspaceObjectID()
        let skill = ArtifactID()
        let plugin = ArtifactID()
        let tracked = ArtifactID()
        let document: PortableWorkspaceDocument
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService

        var thisMac: WorkspaceObjectID { store.deviceID }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "workspace-placement-\(UUID())")
            document = try WorkspaceDocumentCoding.seal(
                .init(
                    revision: .init(writerID: writerID),
                    artifacts: [
                        .init(
                            identity: .init(id: skill, kind: .skill, displayName: "Release Notes"), authority: .centralPersonal,
                            declaredName: "release-notes"),
                        .init(
                            identity: .init(id: plugin, kind: .nativePlugin, displayName: "Supabase"), authority: .nativeOwned,
                            declaredName: "supabase@claude-plugins-official",
                            nativeRoutes: [.init(client: .claude, externalPluginID: "supabase@claude-plugins-official")]),
                        .init(
                            identity: .init(id: tracked, kind: .skill, displayName: "Webapp Testing"), authority: .trackedOnly,
                            declaredName: "webapp-testing"),
                    ]))
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
        }

        func everyMac(_ surface: TargetSurface) -> PortableDestination {
            .init(surface: surface, scope: .user)
        }

        func thisMacOnly(_ surface: TargetSurface) -> PortableDestination {
            .init(surface: surface, scope: .user, deviceIDs: [thisMac])
        }

        @MainActor func session() -> WorkspaceLibrarySession {
            WorkspaceLibrarySession(service: service, workspaceID: document.workspaceID, deviceID: thisMac, access: .writable)
        }

        /// Saves `additions` and returns the document they were saved in.
        func commit(additions: [AssignmentContribution]) async throws -> PortableWorkspaceDocument {
            let head = try #require(try store.snapshot()).document.revision.id
            _ = try await service.applyAssignmentBatch(.init(expectedRevisionID: head, additions: additions))
            return try #require(try store.snapshot()).document
        }

        func assignments() async throws -> [AssignmentContribution] {
            try #require(try store.snapshot()).document.assignments
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

/// The library service, with its reads held until released, so a test can
/// see a session busy reading.
private final class HeldLibraryReads: WorkspaceLibraryServing, @unchecked Sendable {
    private let service: WorkspaceApplicationService
    private let lock = NSLock()
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(service: WorkspaceApplicationService) {
        self.service = service
    }

    func libraryState() async throws -> WorkspaceLibraryState {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                held.append(continuation)
                let waiting = watchers
                watchers = []
                for watcher in waiting { watcher.resume() }
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return try await service.libraryState()
    }

    func previewAssignmentBatch(_ command: WorkspaceAssignmentBatchCommand) async throws -> WorkspaceAssignmentBatchPreview {
        try await service.previewAssignmentBatch(command)
    }

    func applyAssignmentBatch(_ command: WorkspaceAssignmentBatchCommand) async throws -> WorkspaceCommandReceipt {
        try await service.applyAssignmentBatch(command)
    }

    /// Returns once a read is being held.
    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if !held.isEmpty { return true }
                watchers.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Lets every held read, and every later one, through.
    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            let waiting = held
            held = []
            return waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

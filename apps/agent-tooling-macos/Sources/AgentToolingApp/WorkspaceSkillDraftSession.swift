import AgentToolingCore
import Foundation
import Observation
import SwiftUI

/// Running Codex to produce a reviewable skill package, behind a protocol.
///
/// Every call here starts a signed-in local process in a staging directory, so a
/// render test has to be able to hand in something that runs nothing. Nothing on
/// this protocol writes to the library or to a client: it stages files, and it
/// puts staged files away again.
protocol CodexSkillDrafting: Sendable {
    func createDraft(_ request: CodexSkillDraftRequest) async throws -> CodexSkillDraftResult
    func discardDraft(_ result: CodexSkillDraftResult) async throws
    func discardRequest(id: UUID) async throws
}

/// The real one. Every rule about what Codex may write, how large a package may
/// be and where it may be staged lives in the core actor; this only carries the
/// calls across.
struct LiveCodexSkillDrafting: CodexSkillDrafting {
    private let service: CodexSkillDraftService

    init(stagingRoot: URL) {
        service = CodexSkillDraftService(stagingRootURL: stagingRoot)
    }

    func createDraft(_ request: CodexSkillDraftRequest) async throws -> CodexSkillDraftResult {
        try await service.createDraft(request)
    }

    func discardDraft(_ result: CodexSkillDraftResult) async throws {
        try await service.discardDraft(result)
    }

    func discardRequest(id: UUID) async throws {
        try await service.discardRequest(id: id)
    }
}

extension EnvironmentValues {
    /// How the creator reaches Codex, given the folder its drafts may be staged
    /// in. A test replaces the whole factory, so no render can start a process.
    @Entry var codexSkillDrafting: (URL) -> any CodexSkillDrafting = { LiveCodexSkillDrafting(stagingRoot: $0) }
}

extension WorkspaceLaunch.Workspace {
    /// The one folder Codex may stage a draft in: inside this workspace's own
    /// container, beside its cache, and nowhere a client would ever read.
    var skillDraftStagingRoot: URL {
        store.databaseURL.deletingLastPathComponent()
            .appending(path: "cache", directoryHint: .isDirectory)
            .appending(path: "skill-drafts", directoryHint: .isDirectory)
    }
}

/// Handing the creator an instruction somebody is looking at right now.
///
/// A screen that already knows what should be drafted writes the request down
/// and routes to the creator, rather than queueing a review of its own: the
/// person who asked is present, and the reviewed step is the draft itself.
enum WorkspaceSkillDraftSeed {
    /// Writes one draft request beside this Mac's workspace so the creator can
    /// open it. Nothing is queued, nothing is generated, and nothing is
    /// installed. Returns false when this Mac could not record it.
    static func save(_ request: CodexSkillDraftRequest, in store: WorkspaceRevisionStore) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            (try? store.saveRequestDraft(request.id, request)) != nil
        }.value
    }
}

/// One Codex-authored skill, from the instruction to the reviewed package, and
/// the single moment it becomes something this library holds.
///
/// Generation writes only into an isolated staging directory: until somebody has
/// opened every generated file and accepted the draft, this library contains
/// nothing new, no client has been written to, and closing the sheet leaves the
/// Mac exactly as it was. Accepting admits the package and nothing more — where
/// the skill is used stays the separate, reviewed choice the Apps screen asks
/// for.
@MainActor @Observable
final class WorkspaceSkillDraftSession {
    /// The staged package waiting to be reviewed, or nothing when no draft has
    /// been produced yet.
    private(set) var result: CodexSkillDraftResult?
    /// True while Codex is running or a reviewed draft is being saved. The sheet
    /// blocks its own actions on this; nothing else in the window waits for it.
    private(set) var isBusy = false
    private(set) var isGenerating = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: WorkspaceApplicationService
    @ObservationIgnored private let library: WorkspaceLibrarySession
    @ObservationIgnored private let store: WorkspaceRevisionStore
    @ObservationIgnored private let drafting: any CodexSkillDrafting
    @ObservationIgnored private let queue: any PendingRequestQueuing

    init(
        service: WorkspaceApplicationService,
        library: WorkspaceLibrarySession,
        store: WorkspaceRevisionStore,
        drafting: any CodexSkillDrafting,
        queue: any PendingRequestQueuing = LivePendingRequestQueue()
    ) {
        self.service = service
        self.library = library
        self.store = store
        self.drafting = drafting
        self.queue = queue
    }

    var canWrite: Bool { library.access == .writable }

    func dismissError() {
        errorMessage = nil
    }

    /// Reads the draft payload a queued request carries.
    ///
    /// A review row whose payload is missing can never be opened, so saying so
    /// is the honest answer rather than opening an empty creator that would
    /// generate something nobody asked for.
    func loadRequest(id: UUID) async -> CodexSkillDraftRequest? {
        let store = self.store
        let loaded = await Task.detached(priority: .userInitiated) {
            try? store.requestDraft(id, as: CodexSkillDraftRequest.self)
        }.value
        if loaded == nil {
            errorMessage = "That skill request is no longer available. Nothing was changed."
        }
        return loaded
    }

    /// Runs Codex over one instruction and keeps the package it staged.
    ///
    /// Nothing is written to the library here, and a failed run leaves nothing
    /// behind: the service removes its own stage before it throws.
    func generate(_ request: CodexSkillDraftRequest) async {
        guard !isBusy else { return }
        isBusy = true
        isGenerating = true
        errorMessage = nil
        defer {
            isBusy = false
            isGenerating = false
        }
        do {
            result = try await drafting.createDraft(request)
        } catch is CancellationError {
            // Somebody closed the sheet. Saying nothing is the right answer:
            // the stage is put away by the caller that cancelled.
            result = nil
        } catch {
            result = nil
            errorMessage = Self.message(for: error)
        }
    }

    /// Throws away the staged package so the same request can be described
    /// again. The request itself is kept, so a queued row stays openable.
    func startOver() async {
        guard !isBusy, let result else { return }
        isBusy = true
        defer { isBusy = false }
        try? await drafting.discardDraft(result)
        self.result = nil
        errorMessage = nil
    }

    /// Puts away everything one unaccepted draft left on this Mac.
    ///
    /// The staged package goes, and so does a payload nothing in the review
    /// queue owns — a request this app seeded for its own creator and nobody
    /// accepted. A payload a queued row *does* own is kept: deleting it would
    /// leave a review row that can never be opened again.
    func abandon(requestID: UUID) async {
        if let result {
            try? await drafting.discardDraft(result)
            self.result = nil
        } else {
            try? await drafting.discardRequest(id: requestID)
        }
        guard await !isQueued(requestID) else { return }
        let store = self.store
        await Task.detached(priority: .utility) { try? store.deleteRequestDraft(requestID) }.value
    }

    /// Admits the reviewed package into the library, and nothing else.
    ///
    /// This is the only call in the creator that changes anything durable. It
    /// runs after the package has been shown file by file, it installs nothing,
    /// and it assigns nothing: the returned item has no destination until
    /// somebody chooses one. The staged copy and the request that asked for it
    /// are put away only once the library holds the skill.
    func adopt(resolving queuedRequestID: UUID?) async -> ArtifactID? {
        guard !isBusy, canWrite, let result,
            let head = library.state?.snapshot.document.revision.id
        else { return nil }
        isBusy = true
        isSaving = true
        errorMessage = nil
        defer {
            isBusy = false
            isSaving = false
        }
        let artifactID = ArtifactID()
        do {
            let prepared = try await WorkspaceSkillPreparation.capturePersonal(directory: result.skillURL)
            // The reviewed files are the ones that get saved. A package whose
            // definition names something other than what was on screen is
            // refused rather than admitted under the reviewed name.
            guard prepared.frontmatter.name == result.skillName else {
                errorMessage = "The generated files no longer match the draft that was reviewed. Nothing was saved."
                return nil
            }
            _ = try await service.intakeStandaloneSkill(
                .init(
                    expectedRevisionID: head, artifactID: artifactID,
                    displayName: SkillTemplate.displayName(for: result.skillName), prepared: prepared),
                prepared: prepared)
        } catch {
            errorMessage = Self.message(for: error)
            return nil
        }
        try? await drafting.discardDraft(result)
        self.result = nil
        if let queuedRequestID { await resolveQueuedRequest(queuedRequestID) }
        await library.refresh()
        return artifactID
    }

    // MARK: - The review queue

    /// Takes the row this draft came from out of the queue and drops its
    /// payload, so an accepted request is not offered for review a second time.
    private func resolveQueuedRequest(_ id: UUID) async {
        let store = self.store
        let queue = self.queue
        await Task.detached(priority: .userInitiated) {
            guard let row = try? queue.pendingRequests(store: store).first(where: { $0.id == id }) else {
                try? store.deleteRequestDraft(id)
                return
            }
            _ = try? queue.resolve(id: id, expectedFingerprint: row.fingerprint, store: store)
            try? store.deleteRequestDraft(id)
        }.value
    }

    private func isQueued(_ id: UUID) async -> Bool {
        let store = self.store
        let queue = self.queue
        return await Task.detached(priority: .utility) {
            (try? queue.pendingRequests(store: store).contains { $0.id == id }) ?? false
        }.value
    }

    // MARK: - Messages

    private static func message(for error: any Error) -> String {
        switch error {
        case WorkspaceSkillCommandError.identityCollision:
            return "Your library already has something with that name. Ask for a different name and generate the draft again."
        case WorkspaceSkillCommandError.contentStoreUnavailable:
            return "This workspace cannot reach its stored content, so the reviewed skill could not be saved."
        case WorkspaceSkillCommandError.reviewMismatch, WorkspaceRevisionStoreError.staleRevision:
            return "This workspace changed while the draft was being reviewed. Nothing was saved — review the draft again."
        case WorkspaceSkillPreparationError.missingSkillDefinition,
            WorkspaceSkillPreparationError.invalidSkillDefinition:
            return "The generated package does not contain a readable SKILL.md. Nothing was saved."
        default:
            // The draft service says exactly what Codex refused to do, and
            // those sentences are written for the person reading this sheet.
            if let described = (error as? any LocalizedError)?.errorDescription, !described.isEmpty {
                return described
            }
            return "Codex did not return a reviewable skill package. Nothing was changed."
        }
    }
}

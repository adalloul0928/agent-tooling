import AgentToolingCore
import Foundation
import Observation
import SwiftUI

/// Talking to a client's skill creator, behind a protocol.
///
/// Every turn starts the person's signed-in Claude Code or Codex in a staging
/// directory, so a render test has to be able to hand in something that runs
/// nothing. Nothing on this protocol writes to the library or to a client: it
/// stages files, reads them back, and puts staged files away again.
protocol SkillDrafting: Sendable {
    /// Whether `client` can run its skill creator on this Mac right now.
    func skillCreatorAvailability(for client: ClientKind) async -> SkillCreatorAvailability
    /// Opens the conversation with the person's first message and returns the
    /// first reply, with whatever draft the client wrote.
    func startConversation(_ request: SkillDraftRequest) async throws -> SkillDraftTurn
    /// Sends the person's next message and returns the reply and the draft as
    /// it stands afterwards.
    func continueConversation(requestID: UUID, reply: String) async throws -> SkillDraftTurn
    /// The exchange a previous run of this app kept for a request, or nil when
    /// none was started. Read without running anything.
    func existingConversation(for requestID: UUID) async throws -> SkillDraftConversation?
    /// The draft a previous turn left, read again without running anything.
    func currentDraft(for requestID: UUID) async throws -> SkillDraftResult?
    func discardDraft(_ result: SkillDraftResult) async throws
    func discardRequest(id: UUID) async throws
}

/// The real one. Every rule about what a client may write, how large a package
/// may be and where it may be staged lives in the core actor; this only
/// carries the calls across.
struct LiveSkillDrafting: SkillDrafting {
    private let service: SkillDraftService

    init(stagingRoot: URL) {
        service = SkillDraftService(stagingRootURL: stagingRoot)
    }

    func skillCreatorAvailability(for client: ClientKind) async -> SkillCreatorAvailability {
        await service.skillCreatorAvailability(for: client)
    }

    func startConversation(_ request: SkillDraftRequest) async throws -> SkillDraftTurn {
        try await service.startConversation(request)
    }

    func continueConversation(requestID: UUID, reply: String) async throws -> SkillDraftTurn {
        try await service.continueConversation(requestID: requestID, reply: reply)
    }

    func existingConversation(for requestID: UUID) async throws -> SkillDraftConversation? {
        try await service.conversation(for: requestID)
    }

    func currentDraft(for requestID: UUID) async throws -> SkillDraftResult? {
        try await service.currentDraft(for: requestID)
    }

    func discardDraft(_ result: SkillDraftResult) async throws {
        try await service.discardDraft(result)
    }

    func discardRequest(id: UUID) async throws {
        try await service.discardRequest(id: id)
    }
}

/// Installing a client's skill creator, behind a protocol for the same reason.
///
/// The live one runs the install as an operation: the executable is the one
/// the locator found, every argument list is checked by the operation policy
/// before it runs, and a receipt is recorded like any other install this app
/// performs. A test hands in one that records what it was asked to run.
protocol SkillCreatorInstalling: Sendable {
    /// Runs `commands` in order and returns what the client printed. Throws
    /// with the client's own words when a step fails.
    func install(_ commands: [SkillCreatorInstallCommand], for client: ClientKind) async throws -> String
}

struct LiveSkillCreatorInstalling: SkillCreatorInstalling {
    let store: WorkspaceRevisionStore
    let homeRoot: URL

    func install(_ commands: [SkillCreatorInstallCommand], for client: ClientKind) async throws -> String {
        let surface = client.defaultSurface
        let plan = OperationPlan(
            kind: .installPlugin,
            title: "Install the skill creator in \(client.rawValue)",
            summary: "Asks \(client.rawValue) to install its own skill creator. Nothing else changes.",
            targetSurfaces: [surface], scope: .user,
            steps: commands.map { command in
                // The located tool, so an app launched outside a login shell
                // still reaches it; the bare name when the locator finds
                // nothing, which the policy also accepts.
                let executable =
                    ClientExecutableLocator.locate(client, homeURL: homeRoot)?.path(percentEncoded: false)
                    ?? command.executable
                return OperationStep(
                    kind: .command, title: command.title,
                    detail: "Runs \(command.executable) \(command.arguments.joined(separator: " "))",
                    executable: executable, arguments: command.arguments, stopsOnFailure: true)
            })
        let receipt = await OperationExecutor(store: store, homeURL: homeRoot).execute(plan)
        if let failed = receipt.results.first(where: { $0.status == .failed }) {
            throw SkillCreatorInstallError.stepFailed(failed.output)
        }
        return receipt.results.map(\.output).joined(separator: "\n")
    }
}

enum SkillCreatorInstallError: LocalizedError {
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .stepFailed(let output): output
        }
    }
}

extension EnvironmentValues {
    /// How the creator reaches a client, given the folder its drafts may be
    /// staged in. A test replaces the whole factory, so no render can start a
    /// process.
    @Entry var skillDrafting: (URL) -> any SkillDrafting = { LiveSkillDrafting(stagingRoot: $0) }
    /// How the creator installs a missing skill creator. Replaced by tests for
    /// the same reason.
    @Entry var skillCreatorInstalling: (WorkspaceLaunch.Workspace) -> any SkillCreatorInstalling = {
        LiveSkillCreatorInstalling(store: $0.store, homeRoot: $0.homeRoot)
    }
}

extension WorkspaceLaunch.Workspace {
    /// The one folder a client may stage a draft in: inside this workspace's
    /// own container, beside its cache, and nowhere a client would ever read.
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
    static func save(_ request: SkillDraftRequest, in store: WorkspaceRevisionStore) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            (try? store.saveRequestDraft(request.id, request)) != nil
        }.value
    }
}

/// One skill written in conversation with Claude Code or Codex, from the first
/// message to the reviewed package, and the single moment it becomes something
/// this library holds.
///
/// Every turn writes only into an isolated staging directory: until somebody
/// has opened every generated file and accepted the draft, this library
/// contains nothing new, no client has been written to, and closing the sheet
/// leaves the Mac exactly as it was. Accepting admits the package and nothing
/// more — where the skill is used stays the separate, reviewed choice the Apps
/// screen asks for.
@MainActor @Observable
final class WorkspaceSkillDraftSession {
    /// Whether the chosen client can run its skill creator. Nil until checked.
    private(set) var availability: SkillCreatorAvailability?
    /// The exchange so far: what the person said, what the client replied,
    /// and what this app had to note between them.
    private(set) var messages: [SkillDraftMessage] = []
    /// True once the client has answered at least once, so later messages
    /// continue the conversation rather than starting one.
    private(set) var hasConversation = false
    /// The staged package as it stands after the latest turn, or nothing when
    /// the client has written no complete package yet.
    private(set) var result: SkillDraftResult?
    /// Why a package that is on disk cannot be shown yet. A half-written draft
    /// reads as "not ready" rather than as failure.
    private(set) var draftIssue: String?
    /// True while a client is running, an install is running, or a reviewed
    /// draft is being saved. The sheet blocks its own actions on this; nothing
    /// else in the window waits for it.
    private(set) var isBusy = false
    private(set) var isThinking = false
    private(set) var isInstalling = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: WorkspaceApplicationService
    @ObservationIgnored private let library: WorkspaceLibrarySession
    @ObservationIgnored private let store: WorkspaceRevisionStore
    @ObservationIgnored private let drafting: any SkillDrafting
    @ObservationIgnored private let installing: any SkillCreatorInstalling
    @ObservationIgnored private let queue: any PendingRequestQueuing
    @ObservationIgnored private var requestID: UUID?

    init(
        service: WorkspaceApplicationService,
        library: WorkspaceLibrarySession,
        store: WorkspaceRevisionStore,
        drafting: any SkillDrafting,
        installing: any SkillCreatorInstalling = UnavailableSkillCreatorInstalling(),
        queue: any PendingRequestQueuing = LivePendingRequestQueue()
    ) {
        self.service = service
        self.library = library
        self.store = store
        self.drafting = drafting
        self.installing = installing
        self.queue = queue
    }

    var canWrite: Bool { library.access == .writable }

    // MARK: - The skill creator

    /// Asks whether `client` can run its skill creator. A file read on the
    /// client's side, so it is safe to repeat.
    func checkAvailability(for client: ClientKind) async {
        availability = await drafting.skillCreatorAvailability(for: client)
    }

    /// Installs the missing skill creator with the client's own commands and
    /// checks again. Nothing about the skill or the library changes; only the
    /// client gains its plugin, and a receipt says so.
    func installSkillCreator(for client: ClientKind) async {
        guard !isBusy, case .missing(_, let commands) = availability, !commands.isEmpty else { return }
        isBusy = true
        isInstalling = true
        errorMessage = nil
        defer {
            isBusy = false
            isInstalling = false
        }
        do {
            _ = try await installing.install(commands, for: client)
        } catch {
            errorMessage = "The skill creator could not be installed. \(error.localizedDescription)"
        }
        availability = await drafting.skillCreatorAvailability(for: client)
    }

    // MARK: - The conversation

    /// Reads the draft payload a queued request carries.
    ///
    /// A review row whose payload is missing can never be opened, so saying so
    /// is the honest answer rather than opening an empty creator that would
    /// generate something nobody asked for.
    func loadRequest(id: UUID) async -> SkillDraftRequest? {
        let store = self.store
        let loaded = await Task.detached(priority: .userInitiated) {
            try? store.requestDraft(id, as: SkillDraftRequest.self)
        }.value
        if loaded == nil {
            errorMessage = "That skill request is no longer available. Nothing was changed."
        }
        return loaded
    }

    /// Opens the conversation with the person's first message.
    ///
    /// A conversation an earlier run of this app kept for the same request —
    /// the app was quit mid-exchange, or the request is being reopened from
    /// the queue — is picked up where it stopped instead of started again.
    /// Otherwise nothing is written to the library here, and a failed first
    /// turn leaves nothing behind: the service removes its own stage before it
    /// throws.
    func start(_ request: SkillDraftRequest) async {
        guard !isBusy, !hasConversation else { return }
        requestID = request.id
        if await resumeExistingConversation(for: request.id) { return }
        messages = [SkillDraftMessage(role: .person, text: request.instruction.trimmingCharacters(in: .whitespacesAndNewlines))]
        await runTurn(client: request.client) {
            try await self.drafting.startConversation(request)
        } onFailure: {
            // The stage is gone, so the next message starts over rather than
            // continuing a conversation nobody is holding.
            self.hasConversation = false
        }
    }

    /// Restores a kept exchange and whatever draft it left. Runs nothing; a
    /// draft that cannot be shown reads as "not ready", as it would after a
    /// turn.
    private func resumeExistingConversation(for requestID: UUID) async -> Bool {
        guard let kept = try? await drafting.existingConversation(for: requestID), kept.sessionID != nil else {
            return false
        }
        messages = kept.messages
        hasConversation = true
        do {
            result = try await drafting.currentDraft(for: requestID)
            draftIssue = nil
        } catch {
            result = nil
            draftIssue = (error as? any LocalizedError)?.errorDescription ?? "The draft could not be read yet."
        }
        return true
    }

    /// Sends the person's next message in the open conversation.
    func send(_ reply: String, client: ClientKind) async {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, hasConversation, let requestID, !text.isEmpty else { return }
        messages.append(SkillDraftMessage(role: .person, text: text))
        await runTurn(client: client) {
            try await self.drafting.continueConversation(requestID: requestID, reply: text)
        } onFailure: {
        }
    }

    private func runTurn(
        client: ClientKind, _ turn: () async throws -> SkillDraftTurn, onFailure: () -> Void
    ) async {
        isBusy = true
        isThinking = true
        errorMessage = nil
        defer {
            isBusy = false
            isThinking = false
        }
        do {
            let completed = try await turn()
            hasConversation = true
            messages.append(completed.reply)
            for note in completed.notes {
                messages.append(SkillDraftMessage(role: .note, text: note))
            }
            result = completed.draft
            draftIssue = completed.draftIssue
        } catch is CancellationError {
            // Somebody stopped the turn. Saying nothing more is the right
            // answer: the sheet that cancelled decides what happens next.
            messages.append(SkillDraftMessage(role: .note, text: "Stopped before \(client.rawValue) answered."))
            onFailure()
        } catch {
            let message = Self.message(for: error, client: client)
            errorMessage = message
            messages.append(SkillDraftMessage(role: .note, text: message))
            onFailure()
        }
    }

    /// Throws away the staged package and the conversation so the same
    /// request can be described again. The request itself is kept, so a
    /// queued row stays openable.
    func startOver() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        if let result {
            try? await drafting.discardDraft(result)
        } else if let requestID {
            try? await drafting.discardRequest(id: requestID)
        }
        result = nil
        draftIssue = nil
        messages = []
        hasConversation = false
        errorMessage = nil
    }

    /// Puts away everything one unaccepted draft left on this Mac.
    ///
    /// The staged package and conversation go, and so does a payload nothing
    /// in the review queue owns — a request this app seeded for its own
    /// creator and nobody accepted. A payload a queued row *does* own is kept:
    /// deleting it would leave a review row that can never be opened again.
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
            errorMessage = Self.message(for: error, client: result.request.client)
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

    private static func message(for error: any Error, client: ClientKind) -> String {
        switch error {
        case WorkspaceSkillCommandError.identityCollision:
            return "Your library already has something with that name. Ask for a different name and try again."
        case WorkspaceSkillCommandError.contentStoreUnavailable:
            return "This workspace cannot reach its stored content, so the reviewed skill could not be saved."
        case WorkspaceSkillCommandError.reviewMismatch, WorkspaceRevisionStoreError.staleRevision:
            return "This workspace changed while the draft was being reviewed. Nothing was saved — review the draft again."
        case WorkspaceSkillPreparationError.missingSkillDefinition,
            WorkspaceSkillPreparationError.invalidSkillDefinition:
            return "The generated package does not contain a readable SKILL.md. Nothing was saved."
        default:
            // The draft service says exactly what the client refused to do, and
            // those sentences are written for the person reading this sheet.
            if let described = (error as? any LocalizedError)?.errorDescription, !described.isEmpty {
                return described
            }
            return "\(client.rawValue) did not answer. Nothing was changed."
        }
    }
}

/// The installer a session gets when nobody supplied one: it refuses, so a
/// caller that forgot to wire the real one cannot run a command by accident.
struct UnavailableSkillCreatorInstalling: SkillCreatorInstalling {
    func install(_ commands: [SkillCreatorInstallCommand], for client: ClientKind) async throws -> String {
        throw SkillCreatorInstallError.stepFailed("Installing is not available from here.")
    }
}

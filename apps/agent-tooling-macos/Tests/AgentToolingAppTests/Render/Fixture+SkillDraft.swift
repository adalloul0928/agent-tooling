import Foundation

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The shapes the skill creator reaches for: a staged draft package on disk, an
/// assistant that never runs, an installer that records what it was asked, and
/// a review queue that answers from memory.
///
/// A real turn starts a signed-in `claude` or `codex` process and stages a
/// package under this Mac's support folder. Neither belongs in a test, so the
/// package is written into the fixture's own temporary folder and the turns are
/// scripted.
extension ShellRenderFixture {
    func skillDraftSession(
        _ drafting: any SkillDrafting,
        installing: any SkillCreatorInstalling = RecordingSkillCreatorInstalling(),
        queue: any PendingRequestQueuing = RecordingPendingRequestQueue(),
        in workspace: WorkspaceLaunch.Workspace? = nil
    ) -> WorkspaceSkillDraftSession {
        let target = workspace ?? self.workspace
        return WorkspaceSkillDraftSession(
            service: target.service, library: target.library, store: store,
            drafting: drafting, installing: installing, queue: queue)
    }

    /// The same store, over sessions that can actually publish a package's
    /// bytes.
    ///
    /// `WorkspaceLaunch` builds its content store at `content` inside the
    /// workspace folder but nothing ever creates that folder, so every
    /// workspace it opens — this fixture's and a real Mac's — has none, and
    /// admitting a skill fails with "cannot reach its stored content". Creating
    /// it here is what lets these tests exercise adoption at all; the launch
    /// wiring needs the same directory.
    func workspaceHoldingContent() async throws -> WorkspaceLaunch.Workspace {
        try FileManager.default.createDirectory(
            at: store.databaseURL.deletingLastPathComponent()
                .appending(path: "content", directoryHint: .isDirectory),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let opened = WorkspaceLaunch.sessions(
            store: store, homeRoot: home, isFirstRun: false, deviceObserver: StubDeviceObserver(),
            accountReader: { _ in StubAccountReader() })
        await opened.library.refresh()
        return opened
    }

    /// Writes the package a finished turn would have staged, and returns the
    /// result the creator would have been handed for review.
    func stageSkillDraft(
        request: SkillDraftRequest,
        name: String = "codex-release-readiness",
        description: String = "Review release readiness and report blocking evidence."
    ) throws -> SkillDraftResult {
        let drafts = root.appending(path: "drafts", directoryHint: .isDirectory)
        let requestURL = drafts.appending(
            path: "request-\(request.id.uuidString.lowercased())", directoryHint: .isDirectory)
        let packageURL = requestURL.appending(path: "draft", directoryHint: .isDirectory)
        let skillURL = packageURL.appending(path: "skills/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: skillURL, withIntermediateDirectories: true)

        let manifest = try AgentPluginManifest(name: name, description: description)
        let manifestBytes = try AgentToolingCoding.encoder().encode(manifest)
        try manifestBytes.write(to: packageURL.appending(path: "plugin.json"), options: .atomic)
        let markdown = """
            ---
            name: \(name)
            description: \(description)
            ---

            # Generated Skill

            ## When to use this skill

            - When a release has to be checked before it ships
            """
        try Data(markdown.utf8).write(to: skillURL.appending(path: "SKILL.md"), options: .atomic)

        return SkillDraftResult(
            request: request, skillName: name, description: description,
            packageURL: packageURL, skillURL: skillURL, manifest: manifest, skillMarkdown: markdown,
            files: [
                .init(
                    relativePath: "plugin.json", byteCount: manifestBytes.count, isExecutable: false,
                    textContent: String(decoding: manifestBytes, as: UTF8.self)),
                .init(
                    relativePath: "skills/\(name)/SKILL.md", byteCount: markdown.utf8.count,
                    isExecutable: false, textContent: markdown),
            ],
            fingerprint: String(repeating: "a", count: 64), createdAt: .now)
    }

    /// One request in the shape the MCP server and the CLI write, with its
    /// draft payload beside it, so the creator opens what was actually asked
    /// for rather than a row with nothing behind it.
    @discardableResult
    func queueSkillDraftRequest(
        client: ClientKind = .codex,
        instruction: String = "Write a skill that reviews release readiness.",
        targets: [ClientKind] = [.codex]
    ) throws -> (request: PendingAgentRequest, draft: SkillDraftRequest) {
        let outcome = try PendingRequestQueueService.enqueue(
            kind: .createSkill, title: "Create the skill 'release-readiness'",
            summary: "\(client.rawValue) is asking to create a skill named 'release-readiness'.",
            componentID: nil, scope: .user, targets: targets, reason: nil,
            reviewDetails: PendingRequestReviewDetails(instruction: instruction),
            fingerprintInputs: ["", instruction, ""], clientLabel: client.rawValue, store: store)
        let draft = SkillDraftRequest(
            id: outcome.request.id, client: client, instruction: instruction, scope: .user, targets: targets)
        try store.saveRequestDraft(draft.id, draft)
        return (outcome.request, draft)
    }

    func savedDraftRequest(_ id: UUID) -> SkillDraftRequest? {
        try? store.requestDraft(id, as: SkillDraftRequest.self)
    }
}

/// A scripted assistant. It answers each turn from a queue a test filled, never
/// starts a process, and records what it was asked so a test can prove that an
/// accepted draft leaves nothing behind and an abandoned one leaves the request
/// it came from alone.
final class StubSkillDrafting: SkillDrafting, @unchecked Sendable {
    /// What one scripted turn does.
    enum Step {
        /// The assistant replies, and the draft folder holds `draft` afterwards
        /// (nil when it wrote nothing complete).
        case reply(String, draft: SkillDraftResult? = nil, notes: [String] = [], draftIssue: String? = nil)
        /// The turn fails the way the service reports it.
        case fail(any Error)
    }

    private let lock = NSLock()
    private var script: [Step]
    private var availability: [ClientKind: SkillCreatorAvailability]
    private var started: [SkillDraftRequest] = []
    private var continued: [(requestID: UUID, reply: String)] = []
    private var discardedDrafts: [UUID] = []
    private var discardedRequests: [UUID] = []
    private var latestDraft: SkillDraftResult?
    private var keptConversations: [UUID: SkillDraftConversation] = [:]

    /// `answer` is the one-turn shorthand: the first turn writes that draft
    /// and replies briefly. `failure` makes the first turn fail.
    init(
        answer: SkillDraftResult? = nil,
        failure: (any Error)? = nil,
        script: [Step] = [],
        availability: [ClientKind: SkillCreatorAvailability] = [.claude: .available, .codex: .available]
    ) {
        var steps = script
        if let failure {
            steps.insert(.fail(failure), at: 0)
        } else if let answer {
            steps.insert(.reply("I wrote the draft. Review the files on the right.", draft: answer), at: 0)
        }
        self.script = steps
        self.availability = availability
    }

    var startedRequests: [SkillDraftRequest] { lock.withLock { started } }
    var createCount: Int { lock.withLock { started.count } }
    var continuedReplies: [String] { lock.withLock { continued.map(\.reply) } }
    var discardedDraftIDs: [UUID] { lock.withLock { discardedDrafts } }
    var discardedRequestIDs: [UUID] { lock.withLock { discardedRequests } }

    /// Changes what the stub says about a client, as installing would.
    func setAvailability(_ value: SkillCreatorAvailability, for client: ClientKind) {
        lock.withLock { availability[client] = value }
    }

    /// Plants the exchange and draft an earlier run would have left on disk.
    func keep(_ conversation: SkillDraftConversation, draft: SkillDraftResult? = nil) {
        lock.withLock {
            keptConversations[conversation.request.id] = conversation
            if let draft { latestDraft = draft }
        }
    }

    func existingConversation(for requestID: UUID) async throws -> SkillDraftConversation? {
        lock.withLock { keptConversations[requestID] }
    }

    func skillCreatorAvailability(for client: ClientKind) async -> SkillCreatorAvailability {
        lock.withLock { availability[client] ?? .unsupportedClient }
    }

    func startConversation(_ request: SkillDraftRequest) async throws -> SkillDraftTurn {
        try takeTurn { started.append(request) }
    }

    func continueConversation(requestID: UUID, reply: String) async throws -> SkillDraftTurn {
        try takeTurn { continued.append((requestID, reply)) }
    }

    private func takeTurn(_ record: () -> Void) throws -> SkillDraftTurn {
        try lock.withLock {
            record()
            guard !script.isEmpty else { throw StubDraftFailure.nothingStaged }
            switch script.removeFirst() {
            case .fail(let error):
                throw error
            case .reply(let text, let draft, let notes, let draftIssue):
                latestDraft = draft
                return SkillDraftTurn(
                    reply: SkillDraftMessage(role: .assistant, text: text), notes: notes, draft: draft,
                    draftIssue: draftIssue)
            }
        }
    }

    func currentDraft(for requestID: UUID) async throws -> SkillDraftResult? {
        lock.withLock { latestDraft?.id == requestID ? latestDraft : nil }
    }

    func discardDraft(_ result: SkillDraftResult) async throws {
        lock.withLock {
            discardedDrafts.append(result.id)
            if latestDraft?.id == result.id { latestDraft = nil }
        }
    }

    func discardRequest(id: UUID) async throws {
        lock.withLock { discardedRequests.append(id) }
    }
}

/// An installer that runs nothing and remembers what it was asked to run.
final class RecordingSkillCreatorInstalling: SkillCreatorInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: [(client: ClientKind, commands: [SkillCreatorInstallCommand])] = []
    private let failure: (any Error)?
    /// Called on a successful install, so a test can flip the stub's
    /// availability the way a real install flips the client's.
    private let onInstall: (@Sendable () -> Void)?

    init(failure: (any Error)? = nil, onInstall: (@Sendable () -> Void)? = nil) {
        self.failure = failure
        self.onInstall = onInstall
    }

    var installedCommands: [[SkillCreatorInstallCommand]] { lock.withLock { installed.map(\.commands) } }
    var installedClients: [ClientKind] { lock.withLock { installed.map(\.client) } }

    func install(_ commands: [SkillCreatorInstallCommand], for client: ClientKind) async throws -> String {
        try lock.withLock {
            installed.append((client, commands))
            if let failure { throw failure }
        }
        onInstall?()
        return "Installed."
    }
}

/// What a scripted assistant refuses with, in the shape a person would read.
enum StubDraftFailure: LocalizedError {
    case nothingStaged
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .nothingStaged: "No draft was staged for this test."
        case .refused(let reason): reason
        }
    }
}

/// The review queue, in memory. It records the rows a decision took out, so a
/// test can tell an accepted request from one that is still waiting.
final class RecordingPendingRequestQueue: PendingRequestQueuing, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [PendingAgentRequest]
    private var resolved: [UUID] = []

    init(requests: [PendingAgentRequest] = []) {
        self.requests = requests
    }

    var resolvedIDs: [UUID] { lock.withLock { resolved } }
    var pending: [PendingAgentRequest] { lock.withLock { requests } }

    func pendingRequests(store: WorkspaceRevisionStore) throws -> [PendingAgentRequest] {
        lock.withLock { requests }
    }

    func resolve(id: UUID, expectedFingerprint: String, store: WorkspaceRevisionStore) throws
        -> PendingAgentRequest?
    {
        lock.withLock {
            guard let index = requests.firstIndex(where: { $0.id == id }),
                requests[index].fingerprint == expectedFingerprint
            else { return nil }
            resolved.append(id)
            return requests.remove(at: index)
        }
    }

    func restore(_ request: PendingAgentRequest, store: WorkspaceRevisionStore) throws {
        lock.withLock { requests.append(request) }
    }
}

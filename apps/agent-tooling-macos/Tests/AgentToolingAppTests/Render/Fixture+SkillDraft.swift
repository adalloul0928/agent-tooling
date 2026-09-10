import Foundation

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The shapes the Codex skill creator reaches for: a staged draft package on
/// disk, a Codex that never runs, and a review queue that answers from memory.
///
/// A real draft starts a signed-in `codex` process and stages a package under
/// this Mac's support folder. Neither belongs in a test, so the package is
/// written into the fixture's own temporary folder and the run is scripted.
extension ShellRenderFixture {
    func skillDraftSession(
        _ drafting: any CodexSkillDrafting,
        queue: any PendingRequestQueuing = RecordingPendingRequestQueue(),
        in workspace: WorkspaceLaunch.Workspace? = nil
    ) -> WorkspaceSkillDraftSession {
        let target = workspace ?? self.workspace
        return WorkspaceSkillDraftSession(
            service: target.service, library: target.library, store: store,
            drafting: drafting, queue: queue)
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
            store: store, homeRoot: home, isFirstRun: false, deviceObserver: StubDeviceObserver())
        await opened.library.refresh()
        return opened
    }

    /// Writes the package a finished Codex run would have staged, and returns
    /// the result the creator would have been handed for review.
    func stageSkillDraft(
        request: CodexSkillDraftRequest,
        name: String = "codex-release-readiness",
        description: String = "Review release readiness and report blocking evidence."
    ) throws -> CodexSkillDraftResult {
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

        return CodexSkillDraftResult(
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
        instruction: String = "Write a skill that reviews release readiness.",
        targets: [ClientKind] = [.codex]
    ) throws -> (request: PendingAgentRequest, draft: CodexSkillDraftRequest) {
        let outcome = try PendingRequestQueueService.enqueue(
            kind: .createSkill, title: "Create the skill 'release-readiness'",
            summary: "Codex is asking to create a skill named 'release-readiness'.",
            componentID: nil, scope: .user, targets: targets, reason: nil,
            reviewDetails: PendingRequestReviewDetails(instruction: instruction),
            fingerprintInputs: ["", instruction, ""], clientLabel: "Codex", store: store)
        let draft = CodexSkillDraftRequest(
            id: outcome.request.id, instruction: instruction, scope: .user, targets: targets)
        try store.saveRequestDraft(draft.id, draft)
        return (outcome.request, draft)
    }

    func savedDraftRequest(_ id: UUID) -> CodexSkillDraftRequest? {
        try? store.requestDraft(id, as: CodexSkillDraftRequest.self)
    }
}

/// A Codex run that answers with what a test staged, and never starts a
/// process. It records what it was asked to put away, so a test can prove that
/// an accepted draft leaves nothing behind and an abandoned one leaves the
/// request it came from alone.
final class StubCodexSkillDrafting: CodexSkillDrafting, @unchecked Sendable {
    private let lock = NSLock()
    private var answer: CodexSkillDraftResult?
    private var failure: (any Error)?
    private var created: [UUID] = []
    private var discardedDrafts: [UUID] = []
    private var discardedRequests: [UUID] = []

    init(answer: CodexSkillDraftResult? = nil, failure: (any Error)? = nil) {
        self.answer = answer
        self.failure = failure
    }

    var createCount: Int { lock.withLock { created.count } }
    var discardedDraftIDs: [UUID] { lock.withLock { discardedDrafts } }
    var discardedRequestIDs: [UUID] { lock.withLock { discardedRequests } }

    func answer(with result: CodexSkillDraftResult) {
        lock.withLock {
            answer = result
            failure = nil
        }
    }

    func createDraft(_ request: CodexSkillDraftRequest) async throws -> CodexSkillDraftResult {
        let staged: CodexSkillDraftResult? = try lock.withLock {
            created.append(request.id)
            if let failure { throw failure }
            return answer
        }
        guard let staged else { throw StubDraftFailure.nothingStaged }
        return staged
    }

    func discardDraft(_ result: CodexSkillDraftResult) async throws {
        lock.withLock { discardedDrafts.append(result.id) }
    }

    func discardRequest(id: UUID) async throws {
        lock.withLock { discardedRequests.append(id) }
    }
}

/// What a scripted Codex refuses with, in the shape a person would read.
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

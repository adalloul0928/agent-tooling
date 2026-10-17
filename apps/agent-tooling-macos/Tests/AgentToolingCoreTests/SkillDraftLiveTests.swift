import Foundation
import Testing

@testable import AgentToolingCore

/// Real-client smoke tests. They start the person's own signed-in `claude` or
/// `codex`, so they run only when asked for by name; a CI machine and a fresh
/// Mac both have every reason to say no.
///
/// Turn one on with the client's environment variable and the skill creator
/// installed for that client:
///
///     AGENT_TOOLING_RUN_LIVE_CLAUDE_SMOKE=1 swift test --filter SkillDraftLiveTests
///     AGENT_TOOLING_RUN_LIVE_CODEX_SMOKE=1 swift test --filter SkillDraftLiveTests
private let runsLiveClaudeSmoke = ProcessInfo.processInfo.environment["AGENT_TOOLING_RUN_LIVE_CLAUDE_SMOKE"] == "1"
private let runsLiveCodexSmoke = ProcessInfo.processInfo.environment["AGENT_TOOLING_RUN_LIVE_CODEX_SMOKE"] == "1"

private let liveInstruction = """
    Create a small portable skill that reviews a release checklist. It should trigger when a user asks whether a software release is ready, verify that tests, documentation, rollback notes, and version metadata are present, and return a concise list of unresolved blockers. Keep the skill self-contained and do not add scripts or assets. You have everything you need; write the package now rather than asking questions.
    """

@Test(
    "Authenticated Claude Code writes a disposable skill draft in conversation",
    .enabled(if: runsLiveClaudeSmoke)
)
func authenticatedClaudeWritesDisposableSkillDraft() async throws {
    try await liveConversation(client: .claude)
}

@Test(
    "Authenticated Codex writes a disposable skill draft in conversation",
    .enabled(if: runsLiveCodexSmoke)
)
func authenticatedCodexWritesDisposableSkillDraft() async throws {
    try await liveConversation(client: .codex)
}

/// Starts a conversation, asks for one change, and puts the stage away. The
/// staging root sits under the real home directory because the policy admits
/// a Codex start only there.
private func liveConversation(client: ClientKind) async throws {
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Caches/AgentToolingLiveSmoke-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let service = SkillDraftService(stagingRootURL: root)
    #expect(await service.skillCreatorAvailability(for: client) == .available, "\(client.rawValue) has no skill creator here")
    let request = SkillDraftRequest(
        client: client, instruction: liveInstruction, proposedName: "release-readiness-review", targets: [client])

    let first = try await service.startConversation(request)
    #expect(!first.reply.text.isEmpty)
    var afterFirst = first.draft
    if afterFirst == nil { afterFirst = try await service.currentDraft(for: request.id) }
    let draft = try #require(afterFirst, "no package after the first turn: \(first.draftIssue ?? first.reply.text)")
    #expect(draft.skillName == "release-readiness-review")
    #expect(draft.manifest.name == "release-readiness-review")
    #expect(draft.files.contains { $0.relativePath == "skills/release-readiness-review/SKILL.md" })

    let second = try await service.continueConversation(
        requestID: request.id, reply: "Add one sentence to SKILL.md saying the skill never edits files itself. Change nothing else.")
    #expect(!second.reply.text.isEmpty)
    let revised = try #require(second.draft, "no package after the second turn: \(second.draftIssue ?? second.reply.text)")
    #expect(revised.skillName == "release-readiness-review")
    #expect(revised.fingerprint != draft.fingerprint, "the second turn changed nothing")

    let conversation = try #require(try await service.conversation(for: request.id))
    #expect(conversation.sessionID != nil)
    #expect(conversation.messages.filter { $0.role == .person }.count == 2)

    try await service.discardDraft(revised)
    #expect(!FileManager.default.fileExists(atPath: revised.packageURL.path(percentEncoded: false)))
}

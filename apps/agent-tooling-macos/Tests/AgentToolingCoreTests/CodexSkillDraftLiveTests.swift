import Foundation
import Testing

@testable import AgentToolingCore

private let runsLiveCodexSkillDraftSmoke =
    ProcessInfo.processInfo.environment["AGENT_TOOLING_RUN_LIVE_CODEX_SMOKE"] == "1"

@Test(
    "Authenticated Codex creates and validates a disposable skill draft",
    .enabled(if: runsLiveCodexSkillDraftSmoke)
)
func authenticatedCodexCreatesDisposableSkillDraft() async throws {
    let root =
        FileManager.default.temporaryDirectory
        .appending(path: "AgentToolingLiveCodexSmoke-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let service = CodexSkillDraftService(stagingRootURL: root)
    let request = CodexSkillDraftRequest(
        instruction: """
            Create a small portable skill that reviews a release checklist. It should trigger when a user asks whether a software release is ready, verify that tests, documentation, rollback notes, and version metadata are present, and return a concise list of unresolved blockers. Keep the skill self-contained and do not add scripts or assets.
            """,
        proposedName: "release-readiness-review",
        targets: [.codex]
    )

    let result = try await service.createDraft(request)
    #expect(result.skillName == "release-readiness-review")
    #expect(result.request.targets == [.codex])
    #expect(result.files.contains { $0.relativePath == "skills/release-readiness-review/SKILL.md" })
    #expect(result.manifest.name == "release-readiness-review")

    try await service.discardDraft(result)
    #expect(!FileManager.default.fileExists(atPath: result.packageURL.path(percentEncoded: false)))
}

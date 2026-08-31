import Foundation

public extension WorkspaceStore {
    func saveCodexSkillDraftRequest(_ request: CodexSkillDraftRequest) throws {
        try save(request, for: Self.codexSkillDraftRequestKey(request.id))
    }

    func loadCodexSkillDraftRequest(id: UUID) throws -> CodexSkillDraftRequest? {
        try load(Self.codexSkillDraftRequestKey(id), as: CodexSkillDraftRequest.self)
    }

    func deleteCodexSkillDraftRequest(id: UUID) throws {
        try remove(Self.codexSkillDraftRequestKey(id))
    }

    private static func codexSkillDraftRequestKey(_ id: UUID) -> String {
        "codex-skill-draft.request.\(id.uuidString.lowercased())"
    }
}

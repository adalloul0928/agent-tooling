import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Skill authoring origin")
struct SkillAuthoringOriginTests {
    @Test func olderSkillRecordsRemainDecodable() throws {
        let data = Data(
            #"""
            {
              "id": "legacy",
              "name": "legacy",
              "displayName": "Legacy",
              "summary": "Legacy skill",
              "bundle": "local-legacy",
              "scope": "This Mac",
              "owned": true,
              "triggers": [],
              "negativeTrigger": "",
              "files": ["SKILL.md"],
              "clients": [],
              "validationCount": 1
            }
            """#.utf8
        )

        let skill = try AgentToolingCoding.decoder().decode(Skill.self, from: data)

        #expect(skill.authoringOrigin == nil)
    }

    @Test func templateEditorCannotRewriteCodexGeneratedPackages() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SkillAuthoringOriginTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(rootURL: root)
        let library = WorkspaceLibrary(store: store)
        let skill = Skill(
            id: "generated-skill",
            name: "generated-skill",
            displayName: "Generated Skill",
            summary: "Generated",
            bundle: "local-generated-skill",
            scope: "This Mac",
            owned: true,
            triggers: [],
            negativeTrigger: "",
            files: ["SKILL.md", "references/guide.md"],
            clients: [],
            validationCount: 1,
            authoringOrigin: .codexGenerated
        )

        do {
            _ = try library.updateSkill(skill, from: SkillDraft())
            Issue.record("Expected the template editor to reject a Codex-generated package.")
        } catch WorkspaceLibraryError.generatedSkillRequiresSourceEdit(let identifier) {
            #expect(identifier == skill.id)
        }
    }
}

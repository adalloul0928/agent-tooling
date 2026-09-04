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

    @Test func completeSourceEditorPreservesAuxiliaryFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SkillSourcePreservationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(rootURL: root)
        let library = WorkspaceLibrary(store: store)
        var draft = SkillDraft()
        draft.name = "source-preservation"
        draft.purpose = "Preserve rich package source while editing its definition."
        draft.triggers = ["Edit this complete source", "", ""]
        draft.negativeTrigger = "Editing an unrelated file"
        draft.includeReference = true
        draft.selectedTargets = [.claude]
        let created = try library.createSkill(from: draft)
        var richSkill = created.skill
        richSkill.authoringOrigin = .externalAdopted
        let reference = created.skillURL.appending(path: "references/reference.md")
        let originalReference = try Data(contentsOf: reference)
        let originalSource = try library.skillSource(for: richSkill)
        let editedSource = originalSource.replacingOccurrences(
            of: "Preserve rich package source while editing its definition.",
            with: "Preserve every rich package file while editing the complete definition."
        )

        let updated = try library.updateSkillSource(richSkill, markdown: editedSource)
        defer { _ = library.commitUpdate(updated) }

        #expect(try library.skillSource(for: updated.skill) == editedSource)
        #expect(try Data(contentsOf: reference) == originalReference)
        #expect(updated.skill.files.contains("references/reference.md"))
        #expect(updated.skill.authoringOrigin == .externalAdopted)
    }
}

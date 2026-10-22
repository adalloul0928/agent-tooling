import Foundation
import Testing

@testable import AgentToolingCore

struct SkillInventoryFrontmatterTests {
    @Test(arguments: [true, false])
    func inventoryReadsWrappedDescriptionWithoutChangingDiscoveredIdentity(observedPath: Bool) throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "skill-inventory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let id = observedPath ? "example:folder-name" : "folder-name"
        let root = home.appending(path: observedPath ? "plugin/skills/folder-name" : ".agents/skills/folder-name")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let markdown = """
            ---
            name: 'declared-skill'
            description: >-
              Read the complete description
              across both lines.
            metadata:
              owner: Example
            ---
            # Body
            """
        let skillFile = root.appending(path: "SKILL.md")
        try markdown.write(to: skillFile, atomically: true, encoding: .utf8)
        let observation = TargetObservation(
            surface: .codexCLI,
            installed: true,
            commandAvailable: true,
            discoveredSkills: [id],
            skillMetadata: observedPath ? [id: .init(path: root.path, source: "Plugin", providerPluginID: "example")] : [:],
            capabilities: CodexAdapter().capabilities
        )

        let inventory = InventoryCompiler.compile(observations: [observation], homeURL: home)
        let skill = try #require(inventory.skills.first)
        #expect(skill.id == id)
        #expect(skill.name == id)
        #expect(skill.displayName == "Declared Skill")
        #expect(skill.summary == "Read the complete description across both lines.")
        #expect(try Data(contentsOf: skillFile) == Data(markdown.utf8))
    }

    @Test func malformedFrontmatterUsesSafeInventoryFallback() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "skill-inventory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appending(path: ".agents/skills/folder-name")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "---\nname: declared\ndescription: [malformed\n---".write(
            to: root.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let observation = TargetObservation(
            surface: .codexCLI, installed: true, discoveredSkills: ["folder-name"], capabilities: CodexAdapter().capabilities)
        let inventory = InventoryCompiler.compile(observations: [observation], homeURL: home)
        let skill = try #require(inventory.skills.first)
        #expect(skill.id == "folder-name")
        #expect(skill.displayName == "Folder Name")
        #expect(skill.summary == "Portable agent skill")
    }
}

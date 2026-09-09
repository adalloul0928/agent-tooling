import Foundation
import Testing

@testable import AgentToolingCore

/// Names shown for discovered tools are derived from the identifier the vendor
/// recorded. Deriving must stay readable without inventing a name the vendor
/// never used, because the identifier is what a person searches for.
@Suite("Inventory display names")
struct InventoryDisplayNameTests {
    @Test func anOpaqueIdentifierKeepsItsOwnCharactersInsteadOfGrowingInternalCapitals() throws {
        // `String.capitalized` starts a new word at each digit-to-letter
        // boundary, which turned Codex's own
        // `app-68de829bf7648191acd70a907364c67c` into
        // `App 68De829Bf7648191Acd70A907364C67C` in the library.
        let inventory = try inventory(forSkillFolder: "app-68de829bf7648191acd70a907364c67c")
        let skill = try #require(inventory.skills.first)

        #expect(skill.displayName == "App 68de829bf7648191acd70a907364c67c")
    }

    @Test func casingAnAuthorChoseInsideAWordSurvives() throws {
        let inventory = try inventory(forSkillFolder: "pumpd-iOS-buildKit")
        let skill = try #require(inventory.skills.first)

        #expect(skill.displayName == "Pumpd iOS BuildKit")
    }

    @Test func ordinaryLowercaseIdentifiersStillReadAsTitles() throws {
        let inventory = try inventory(forSkillFolder: "template-creator")
        let skill = try #require(inventory.skills.first)

        #expect(skill.displayName == "Template Creator")
    }

    private func inventory(forSkillFolder folder: String) throws -> ScannedInventory {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "inventory-display-name-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appending(path: ".agents/skills/\(folder)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // No frontmatter name, so the folder identifier is all there is to go on.
        try "# Body".write(to: root.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let observation = TargetObservation(
            surface: .codexCLI, installed: true, discoveredSkills: [folder], capabilities: CodexAdapter().capabilities)
        return InventoryCompiler.compile(observations: [observation], homeURL: home)
    }
}

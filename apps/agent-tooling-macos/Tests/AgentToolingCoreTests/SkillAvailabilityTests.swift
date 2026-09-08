import Foundation
import Testing

@testable import AgentToolingCore

struct SkillAvailabilityTests {
    @Test func codexTogglePreservesOtherServersAndSkillsAndReenables() throws {
        let original = """
            model = "example"
            [mcp_servers.docs]
            url = "https://example.com/mcp"
            [[skills.config]]
            path = "/other/SKILL.md"
            enabled = false
            """
        let disabled = try SkillAvailability.codex(original, path: "/my skill/SKILL.md", enabled: false).1
        #expect(disabled.contains(original))
        #expect(try SkillAvailability.codex(disabled, path: "/my skill/SKILL.md", enabled: nil).0 == false)
        let enabled = try SkillAvailability.codex(disabled, path: "/my skill/SKILL.md", enabled: true).1
        #expect(try SkillAvailability.codex(enabled, path: "/my skill/SKILL.md", enabled: nil).0)
        #expect(try SkillAvailability.codex(enabled, path: "/other/SKILL.md", enabled: nil).0 == false)
        #expect(enabled.components(separatedBy: "[[skills.config]]").count == 3)
    }
    @Test func claudePluginAndStandaloneSettingsAreIndependent() throws {
        let data = Data(#"{"permissions":{"deny":["Bash(rm *)"]},"enabledPlugins":{"other@source":false}}"#.utf8)
        let changed = try SkillAvailability.json(data, key: "enabledPlugins", identifier: "mine@source", enabled: false).1
        let standalone = try SkillAvailability.json(changed, key: "skillOverrides", identifier: "daily", enabled: false).1
        let root = try #require(JSONSerialization.jsonObject(with: standalone) as? [String: Any])
        #expect((root["permissions"] as? [String: [String]])?["deny"] == ["Bash(rm *)"])
        #expect((root["enabledPlugins"] as? [String: Bool])?["other@source"] == false)
        #expect(try SkillAvailability.json(standalone, key: "skillOverrides", identifier: "daily", enabled: nil).0 == false)
        #expect(try SkillAvailability.json(standalone, key: "enabledPlugins", identifier: "mine@source", enabled: nil).0 == false)
    }
    @Test func refusesAmbiguousOrInvalidNativeConfiguration() {
        #expect(throws: (any Error).self) {
            try SkillAvailability.json(Data("not json".utf8), key: "enabledPlugins", identifier: "x", enabled: false)
        }
        #expect(throws: (any Error).self) { try SkillAvailability.codex("[skills]\nconfig = []", path: "/x/SKILL.md", enabled: false) }
        #expect(throws: (any Error).self) {
            try SkillAvailability.codex("[[skills.config]]\npath = '/x/SKILL.md'", path: "/x/SKILL.md", enabled: false)
        }
    }
}

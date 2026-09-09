import Foundation
import Testing

@testable import AgentToolingCore

@MainActor
struct SkillAvailabilityCacheTests {
    @Test func cachedReadsRefreshAfterExternalChangesAndSetupScan() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = try fixture.model()
        #expect(await model.runDoctor())
        #expect(model.isSkillEnabled("review", client: .claude) == false)
        let revision = model.skillAvailabilityRevision
        await model.refreshSkillAvailability()
        #expect(model.skillAvailabilityRevision == revision, "Unchanged settings do not invalidate inspectors")

        try "not valid JSON".write(to: fixture.settings, atomically: true, encoding: .utf8)
        let skillIndex = try #require(model.skills.firstIndex { $0.id == "review" })
        model.skills[skillIndex].summary = "Updated description"
        #expect(model.skillAvailabilityRevision == revision, "Description edits keep verified native availability")
        #expect(model.isSkillEnabled("review", client: .claude) == false)
        await Task.yield()
        #expect(model.skillAvailabilityRevision == revision, "Description edits do not schedule a settings reread")
        #expect(model.isSkillEnabled("review", client: .claude) == false, "Rendering uses the last verified snapshot without reading files")
        await model.refreshSkillAvailability()
        #expect(model.isSkillEnabled("review", client: .claude) == nil)

        try #"{"skillOverrides":{"review":"on"}}"#.write(to: fixture.settings, atomically: true, encoding: .utf8)
        #expect(await model.runDoctor())
        #expect(model.isSkillEnabled("review", client: .claude) == true)
        let observation = try #require(model.targetObservations.firstIndex { $0.skillMetadata["review"] != nil })
        var metadata = try #require(model.targetObservations[observation].skillMetadata["review"])
        metadata.path += "-moved"
        model.targetObservations[observation].skillMetadata["review"] = metadata
        #expect(model.isSkillEnabled("review", client: .claude) == nil, "Changing the installed source invalidates verified preferences")
        try FileManager.default.removeItem(at: fixture.skill)
        #expect(await model.runDoctor())
        #expect(model.isSkillEnabled("review", client: .claude) == nil)
    }

    @Test func successfulNativeTogglePublishesImmediatelyAndSurvivesRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = try fixture.model()
        #expect(await model.runDoctor())
        model.setSkillEnabled("review", client: .claude, enabled: true)
        #expect(model.lastError == nil)
        #expect(model.isSkillEnabled("review", client: .claude) == true)
        await model.refreshSkillAvailability()
        #expect(model.isSkillEnabled("review", client: .claude) == true)
        let persisted = try Data(contentsOf: fixture.settings)
        #expect(try SkillAvailability.json(persisted, key: "skillOverrides", identifier: "review", enabled: nil).0)
        #expect(model.setClientEnabled(.claude, enabled: false))
        #expect(model.isSkillEnabled("review", client: .claude) == nil)
        await model.refreshSkillAvailability()
        #expect(model.isSkillEnabled("review", client: .claude) == nil)
        #expect(model.setClientEnabled(.claude, enabled: true))
        await model.refreshSkillAvailability()
        #expect(model.isSkillEnabled("review", client: .claude) == true)
    }

    @Test func pluginToggleRefreshesEveryChildSharingTheNativePreference() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = try fixture.model()
        #expect(await model.runDoctor())
        let original = try #require(model.skills.first { $0.id == "review" })
        let sibling = Skill(
            id: "sibling", name: "sibling", displayName: "Sibling", summary: original.summary,
            bundle: original.bundle, scope: original.scope, owned: false, triggers: [], negativeTrigger: "",
            files: original.files, clients: original.clients, validationCount: 0)
        model.skills.append(sibling)
        let index = try #require(model.targetObservations.firstIndex { $0.surface == .claudeCode })
        var metadata = try #require(model.targetObservations[index].skillMetadata["review"])
        metadata.providerPluginID = "bundle@catalog"
        model.targetObservations[index].skillMetadata["review"] = metadata
        model.targetObservations[index].skillMetadata["sibling"] = metadata
        await model.refreshSkillAvailability()
        #expect(model.isSkillEnabled("review", client: .claude) == true)
        #expect(model.isSkillEnabled("sibling", client: .claude) == true)
        model.setSkillEnabled("review", client: .claude, enabled: false)
        #expect(model.isSkillEnabled("review", client: .claude) == false)
        #expect(model.isSkillEnabled("sibling", client: .claude) == false)
        await model.refreshSkillAvailability()
        #expect(model.isSkillEnabled("sibling", client: .claude) == false)
    }

    @Test func nativeDocumentsPreserveReadBytesAndResolveIndependentInvalidSettings() throws {
        let json = Data("{ \"skillOverrides\": { \"review\": \"off\" }, \"enabledPlugins\": [] }\n".utf8)
        #expect(try SkillAvailability.json(json, key: "skillOverrides", identifier: "review", enabled: nil).1 == json)
        let document = try SkillAvailability.JSONDocument(json)
        #expect(try document.isEnabled(key: "skillOverrides", identifier: "review") == false)
        #expect(throws: (any Error).self) { try document.isEnabled(key: "enabledPlugins", identifier: "bundle@catalog") }
        let toml = """
            # Existing preferences
            [[skills.config]]
            path = "/good/SKILL.md"
            enabled = false
            [[skills.config]]
            path = "/other/SKILL.md"
            enabled = "unsupported"
            """
        #expect(try SkillAvailability.codex(toml, path: "/good/SKILL.md", enabled: nil).1 == toml)
        let codex = try SkillAvailability.CodexDocument(toml)
        #expect(try codex.isEnabled(path: "/good/SKILL.md") == false)
        #expect(throws: (any Error).self) { try codex.isEnabled(path: "/other/SKILL.md") }
    }

    @Test func onboardingRechecksNativePreferencesBeforeAcceptingAReview() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try #"{"skillOverrides":{"review":"on"}}"#.write(to: fixture.settings, atomically: true, encoding: .utf8)
        let model = try fixture.model()
        #expect(await model.runDoctor())
        #expect(model.isSkillEnabled("review", client: .claude) == true)
        let selection = OnboardingSelection(itemIDs: ["skill:review"])
        let preview = try #require(model.previewOnboarding(selection))
        #expect(preview.targetBindings.first?.enabled == true)

        try #"{"skillOverrides":{"review":"off"}}"#.write(to: fixture.settings, atomically: true, encoding: .utf8)
        #expect(model.isSkillEnabled("review", client: .claude) == true, "No render-time disk refresh has happened")
        #expect(model.finishOnboarding(preview) == nil, "An old review must not preserve an assignment that was disabled externally")
        #expect(!model.profiles.contains { $0.id == preview.configurationID })
        let revised = try #require(model.previewOnboarding(selection))
        #expect(revised.targetBindings.first?.enabled == false)
        #expect(model.finishOnboarding(revised) != nil)
        #expect(model.activeProfile?.targetBindings?.first?.enabled == false)
        #expect(
            try SkillAvailability.json(Data(contentsOf: fixture.settings), key: "skillOverrides", identifier: "review", enabled: nil).0
                == false)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "availability-cache-\(UUID())")
        var home: URL { root.appending(path: "home") }
        var skill: URL { home.appending(path: ".claude/skills/review") }
        var settings: URL { home.appending(path: ".claude/settings.json") }
        init() throws {
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try "---\nname: review\ndescription: Review changes.\n---\nCheck the change.\n".write(
                to: skill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            try #"{"skillOverrides":{"review":"off"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        }
        @MainActor func model() throws -> AppModel {
            try AppModel(store: WorkspaceStore(rootURL: root.appending(path: "store")), runner: Runner(), homeURL: home)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private struct Runner: CommandRunning {
        func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
            CommandOutput(status: 0, standardOutput: arguments == ["--version"] ? "1.0.0\n" : "", standardError: "")
        }
    }
}

import Foundation
import Testing

@testable import AgentToolingCore

private struct OnboardingRunner: CommandRunning {
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        CommandOutput(status: 0, standardOutput: arguments == ["--version"] ? "1.0.0\n" : "", standardError: "")
    }
}

@MainActor
struct OnboardingTests {
    @Test func selectingAndSelectingAllTracksWithoutChoosingPersonalCopies() throws {
        let fixture = try fixture()
        let model = fixture.model
        model.skills = [skill("standalone"), skill("bundle:child"), skill("unknown"), skill("managed", owned: true)]
        model.plugins = [plugin()]
        model.mcpServers = [server()]
        model.targetObservations = [
            observation(skills: [
                "standalone": .init(path: "/example/standalone", source: "Standalone"),
                "bundle:child": .init(path: "/example/bundle/child", source: "Plugin", providerPluginID: "bundle@catalog"),
            ])
        ]
        let inventory = model.onboardingInventory
        let standalone = try #require(inventory.standaloneSkills.first { $0.itemID == "standalone" })
        var selection = OnboardingSelection()
        selection.setTracked(standalone, selected: true)
        #expect(selection.itemIDs == ["skill:standalone"])
        #expect(selection.copySkillIDs.isEmpty)
        for candidate in inventory.candidates { selection.setTracked(candidate, selected: true) }
        #expect(selection.copySkillIDs.isEmpty, "Select all never changes file ownership")
        #expect(selection.itemIDs.contains("skill:unknown"), "An unknown source can still be tracked")
        #expect(!selection.itemIDs.contains("skill:bundle:child"), "Bundled children are selected through their plugin")
        let preview = try #require(model.previewOnboarding(selection))
        #expect(preview.copySkillIDs.isEmpty)
        #expect(preview.candidates.contains { $0.itemID == "bundle:child" })
        #expect(model.pendingPlan == nil)
        #expect(model.skills.first { $0.id == "unknown" }?.owned == false)
    }

    @Test func personalCopyRequiresItsOwnExplicitSelectionAndCanReturnToSourceTracking() throws {
        let fixture = try fixture()
        let model = fixture.model
        model.skills = [skill("standalone"), skill("bundle:child"), skill("unknown")]
        model.targetObservations = [
            observation(skills: [
                "standalone": .init(path: "/example/standalone", source: "Standalone"),
                "bundle:child": .init(path: "/example/bundle/child", source: "Plugin", providerPluginID: "bundle@catalog"),
            ])
        ]
        let candidates = Dictionary(uniqueKeysWithValues: model.onboardingCandidates.map { ($0.itemID, $0) })
        let standalone = try #require(candidates["standalone"])
        var selection = OnboardingSelection()
        selection.setPersonalCopy(try #require(candidates["bundle:child"]), enabled: true)
        selection.setPersonalCopy(try #require(candidates["unknown"]), enabled: true)
        #expect(selection.itemIDs.isEmpty && selection.copySkillIDs.isEmpty)
        selection.setPersonalCopy(standalone, enabled: true)
        #expect(selection.itemIDs == ["skill:standalone"])
        #expect(selection.copySkillIDs == ["standalone"])
        selection.setTracked(standalone, selected: true)
        #expect(selection.copySkillIDs == ["standalone"], "Selecting again preserves the separate explicit copy choice")
        selection.setPersonalCopy(standalone, enabled: false)
        #expect(selection.itemIDs == ["skill:standalone"])
        #expect(selection.copySkillIDs.isEmpty)
        selection.setPersonalCopy(standalone, enabled: true)
        selection.setTracked(standalone, selected: false)
        #expect(selection.itemIDs.isEmpty && selection.copySkillIDs.isEmpty)
    }

    @Test func defaultTrackingSavesSetupWithoutCopyingOrRewritingExistingSkill() async throws {
        let fixture = try fixture()
        let model = fixture.model
        let source = fixture.home.appending(path: ".claude/skills/source-managed")
        // Tracking does not require the original to pass personal-copy checks.
        let original = "---\nname: source-managed\n---\n# Existing instructions\n"
        try write(original, to: source.appending(path: "SKILL.md"))
        try write("Keep this reference unchanged.", to: source.appending(path: "references/notes.md"))
        #expect(await model.runDoctor())
        let skillIndex = try #require(model.skills.firstIndex { $0.id == "source-managed" })
        let binding = try SkillRepositoryBinding(
            repositoryURL: "https://github.com/example/source-managed", ref: "stable", subdirectory: "skills/source-managed")
        model.skills[skillIndex].repositoryBinding = binding
        let discovered = try #require(model.onboardingInventory.standaloneSkills.first { $0.itemID == "source-managed" })
        #expect(discovered.repositoryBinding == binding)
        var selection = OnboardingSelection(configurationName: "Tracked setup")
        selection.setTracked(discovered, selected: true)
        let preview = try #require(model.previewOnboarding(selection))
        let completion = try #require(model.finishOnboarding(preview))
        #expect(completion.copiedSkillCount == 0 && completion.trackedItemCount == 1)
        #expect(model.activeProfile?.requiredSkills == ["source-managed"])
        #expect(model.skills.first { $0.id == "source-managed" }?.owned == false)
        #expect(model.skills.first { $0.id == "source-managed" }?.repositoryBinding == binding)
        #expect(model.operationReceipts.isEmpty && model.pendingPlan == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.libraryURL.appending(path: "packages/local-source-managed").path))
        #expect(try String(contentsOf: source.appending(path: "SKILL.md"), encoding: .utf8) == original)
        #expect(try String(contentsOf: source.appending(path: "references/notes.md"), encoding: .utf8) == "Keep this reference unchanged.")
        let reopened = try AppModel(store: fixture.store, runner: OnboardingRunner(), homeURL: fixture.home)
        #expect(reopened.skills.first { $0.id == "source-managed" }?.repositoryBinding == binding)
        await model.runSync()
        #expect(model.pendingPlan?.steps.allSatisfy { $0.kind == .manual } == true)
        model.discardPendingPlan()
    }

    @Test func discoveryDistinguishesStandaloneCopiesFromWholePluginOwnership() throws {
        let fixture = try fixture()
        let model = fixture.model
        model.skills = [skill("standalone"), skill("bundle:child"), skill("unknown"), skill("managed", owned: true)]
        model.targetObservations = [
            observation(skills: [
                "standalone": .init(path: "/example/standalone", source: "Standalone"),
                "bundle:child": .init(path: "/example/bundle/child", source: "Plugin", providerPluginID: "bundle@catalog"),
            ])
        ]

        let candidates = Dictionary(uniqueKeysWithValues: model.onboardingCandidates.map { ($0.itemID, $0) })
        #expect(candidates["standalone"]?.canCopy == true)
        #expect(candidates["bundle:child"]?.disposition == .nativePlugin)
        #expect(candidates["bundle:child"]?.canCopy == false)
        #expect(candidates["bundle:child"]?.providerPluginID == "bundle@catalog")
        #expect(candidates["unknown"]?.disposition == .unavailable)
        #expect(candidates["managed"]?.disposition == .managed)
    }

    @Test func previewAndCompletionRetainNativeTargetsWithoutChangingClientFiles() throws {
        let fixture = try fixture()
        let model = fixture.model
        let nativeConfiguration = fixture.home.appending(path: ".claude/settings.json")
        let original = "{\"enabledPlugins\":{\"bundle@catalog\":false}}"
        try write(original, to: nativeConfiguration)
        model.plugins = [plugin()]
        model.mcpServers = [server()]
        model.targetObservations = [
            observation(plugins: [
                "bundle@catalog": .init(
                    name: "Bundle", source: "catalog", scope: "This Mac", enabled: false
                )
            ])
        ]
        let selection = OnboardingSelection(configurationName: "Work setup", itemIDs: ["plugin:bundle@catalog", "mcpServer:docs"])
        let profileCount = model.profiles.count
        let preview = try #require(model.previewOnboarding(selection))

        #expect(model.profiles.count == profileCount)
        #expect(model.pendingPlan == nil)
        #expect(preview.targetBindings.count == 2)
        #expect(preview.targetBindings.allSatisfy { $0.client == .claude })
        #expect(preview.targetBindings.first { $0.item.kind == .plugin }?.enabled == false)
        #expect(preview.nativeItemCount == 2)

        let completion = try #require(model.finishOnboarding(preview))
        let saved = try #require(model.profiles.first { $0.id == completion.configurationID })
        #expect(saved.enabledPlugins.isEmpty)
        #expect(saved.requiredMCPs == ["docs"])
        #expect(saved.targetBindings == preview.targetBindings)
        #expect(model.activeProfileID == saved.id)
        #expect(try String(contentsOf: nativeConfiguration, encoding: .utf8) == original)
        #expect(model.mcpServers.first?.isManagedDefinition == false)
        #expect(model.operationReceipts.isEmpty)
        let reopened = try AppModel(store: fixture.store, runner: OnboardingRunner(), homeURL: fixture.home)
        #expect(reopened.profiles.first { $0.id == saved.id }?.targetBindings == preview.targetBindings)
    }

    @Test func wizardCopiesWholeSkillAndOnlySyncsItsExistingSelectedClient() async throws {
        let fixture = try fixture()
        let model = fixture.model
        let source = fixture.home.appending(path: ".claude/skills/doc-review")
        try write(definition("doc-review"), to: source.appending(path: "SKILL.md"))
        try write("Reference material", to: source.appending(path: "references/checklist.md"))
        try write("print('helper')", to: source.appending(path: "scripts/helper.py"))
        try write("another", to: source.appending(path: "assets/template.txt"))
        #expect(await model.runDoctor())
        let preview = try #require(
            model.previewOnboarding(
                .init(
                    itemIDs: ["skill:doc-review"], copySkillIDs: ["doc-review"]
                )))
        #expect(model.enabledClients.contains(.claude) && model.enabledClients.contains(.codex))
        #expect(preview.targetBindings.map(\.client) == [.claude])
        #expect(model.planOnboardingSkillAdoption(preview))
        let plan = try #require(model.pendingPlan)
        #expect(plan.steps.allSatisfy { $0.kind == .copyDirectory })
        #expect(model.skills.first { $0.id == "doc-review" }?.owned == false)
        #expect(await model.executePendingPlan(try OperationPlanApproval.review(plan)))
        let completion = try #require(model.finishOnboarding(preview))
        #expect(completion.copiedSkillCount == 1)
        #expect(completion.managedSkillCount == 1)
        #expect(completion.trackedItemCount == 0)
        for name in ["SKILL.md", "references/checklist.md", "scripts/helper.py", "assets/template.txt"] {
            let managed = fixture.store.libraryURL.appending(path: "packages/local-doc-review/skills/doc-review/\(name)")
            #expect(try Data(contentsOf: managed) == Data(contentsOf: source.appending(path: name)))
        }
        var extra = SkillDraft()
        extra.name = "unselected"
        extra.purpose = "Leave this unrelated library skill alone."
        extra.triggers = ["one", "two", "three"]
        extra.negativeTrigger = "Other work."
        extra.selectedTargets = [.codex]
        extra.syncClients = false
        #expect(model.createSkill(from: extra) != nil)

        await model.runSync()
        let sync = try #require(model.pendingPlan)
        #expect(sync.targetSurfaces == [.claudeCode])
        #expect(sync.steps.filter { $0.kind == .copyDirectory }.count == 1)
        #expect(
            sync.steps.filter { $0.kind == .copyDirectory }.allSatisfy { $0.destinationPath?.contains(".claude/skills/doc-review") == true }
        )
        #expect(
            !sync.steps.contains { $0.destinationPath?.contains(".agents/") == true || $0.destinationPath?.contains("unselected") == true })
        model.discardPendingPlan()
        let child = try #require(
            model.createProfile(
                name: "Child setup", summary: "Inherited setup", scope: .user, projectRoot: nil, inheritedFrom: completion.configurationID))
        model.applyProfile(id: child.id)
        await model.runSync()
        let inheritedSync = try #require(model.pendingPlan)
        #expect(inheritedSync.targetSurfaces == [.claudeCode])
        #expect(inheritedSync.steps.filter { $0.kind == .copyDirectory }.count == 1)
        #expect(!inheritedSync.steps.contains { $0.destinationPath?.contains("unselected") == true })
        model.discardPendingPlan()
        #expect(try String(contentsOf: source.appending(path: "SKILL.md"), encoding: .utf8) == definition("doc-review"))
    }

    @Test(arguments: [false, true])
    func disabledOrUnknownCodexSkillIsNotCopiedIntoAnotherActivePath(unsupportedSyntax: Bool) async throws {
        let fixture = try fixture()
        let source = fixture.home.appending(path: ".codex/skills/disabled-review/SKILL.md")
        try write(definition("disabled-review"), to: source)
        let quote = unsupportedSyntax ? "'" : "\""
        let configuration = "[[skills.config]]\npath = \(quote)\(source.path)\(quote)\nenabled = false\n"
        let configURL = fixture.home.appending(path: ".codex/config.toml")
        try write(configuration, to: configURL)
        #expect(await fixture.model.runDoctor())
        let preview = try #require(
            fixture.model.previewOnboarding(.init(itemIDs: ["skill:disabled-review"], copySkillIDs: ["disabled-review"])))
        #expect(preview.targetBindings.map(\.client) == [.codex])
        if unsupportedSyntax {
            #expect(preview.targetBindings.first?.enabled == nil)
            #expect(preview.warnings.contains { $0.contains("excluded from sync") })
        } else {
            #expect(preview.targetBindings.first?.enabled == false)
        }
        #expect(fixture.model.planOnboardingSkillAdoption(preview))
        #expect(await fixture.model.executePendingPlan(try OperationPlanApproval.review(try #require(fixture.model.pendingPlan))))
        #expect(fixture.model.finishOnboarding(preview) != nil)
        await fixture.model.runSync()
        let sync = try #require(fixture.model.pendingPlan)
        #expect(!sync.steps.contains { $0.kind == .copyDirectory })
        #expect(try String(contentsOf: configURL, encoding: .utf8) == configuration)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appending(path: ".agents/skills/disabled-review").path))
        fixture.model.discardPendingPlan()
    }

    @Test func cancelledCopyCannotBeReportedAsCompletedSetup() async throws {
        let fixture = try fixture()
        try write(definition("doc-review"), to: fixture.home.appending(path: ".claude/skills/doc-review/SKILL.md"))
        #expect(await fixture.model.runDoctor())
        let preview = try #require(fixture.model.previewOnboarding(.init(itemIDs: ["skill:doc-review"], copySkillIDs: ["doc-review"])))
        #expect(fixture.model.planOnboardingSkillAdoption(preview))
        fixture.model.discardPendingPlan()
        #expect(fixture.model.finishOnboarding(preview) == nil)
        #expect(!fixture.model.profiles.contains { $0.id == preview.configurationID })
        #expect(fixture.model.skills.first { $0.id == "doc-review" }?.owned == false)
    }

    @Test func copyingBundledSkillsIsRefusedWithoutAnAdoptionPlan() throws {
        let fixture = try fixture()
        fixture.model.skills = [skill("bundle:child")]
        fixture.model.targetObservations = [
            observation(skills: [
                "bundle:child": .init(path: "/example/bundle/child", source: "Plugin", providerPluginID: "bundle@catalog")
            ])
        ]
        #expect(fixture.model.previewOnboarding(.init(itemIDs: ["skill:bundle:child"], copySkillIDs: ["bundle:child"])) == nil)
        #expect(fixture.model.pendingPlan == nil)
        #expect(fixture.model.lastError?.contains("bundled") == true)
    }

    @Test func sourceThatVanishesAfterScanRejectsEntireBatch() async throws {
        let fixture = try fixture()
        for name in ["present", "vanished"] {
            try write(definition(name), to: fixture.home.appending(path: ".claude/skills/\(name)/SKILL.md"))
        }
        #expect(await fixture.model.runDoctor())
        let preview = try #require(
            fixture.model.previewOnboarding(
                .init(
                    itemIDs: ["skill:present", "skill:vanished"], copySkillIDs: ["present", "vanished"]
                )))
        try FileManager.default.removeItem(at: fixture.home.appending(path: ".claude/skills/vanished"))
        #expect(!fixture.model.planOnboardingSkillAdoption(preview))
        #expect(fixture.model.pendingPlan == nil)
        #expect(!fixture.model.skills.contains { $0.owned })
        #expect(fixture.model.onboardingCopyIssues.map(\.id) == ["vanished"])
        #expect(fixture.model.lastError == nil, "Copy issues use the inline review instead of a duplicate alert")
    }

    @Test func staleAssignmentsRequireAnotherReview() throws {
        let fixture = try fixture()
        fixture.model.skills = [skill("managed", owned: true)]
        let preview = try #require(fixture.model.previewOnboarding(.init(itemIDs: ["skill:managed"])))
        fixture.model.skills[0].clients.append(.init(client: .codex, state: .healthy, detail: "Found", isInstalled: true))
        #expect(fixture.model.finishOnboarding(preview) == nil)
        #expect(fixture.model.lastError?.contains("assignments changed") == true)
        #expect(!fixture.model.profiles.contains { $0.id == preview.configurationID })
    }

    @Test func unknownSelectionsAndDuplicateNamesCannotCreateAConfiguration() throws {
        let fixture = try fixture()
        #expect(fixture.model.previewOnboarding(.init(itemIDs: ["plugin:missing"])) == nil)
        #expect(fixture.model.previewOnboarding(.init(configurationName: "Local Library")) == nil)
        #expect(fixture.model.profiles.count == 1)
    }

    @Test func emptySetupIsExplicitAndDoesNotEnrollAllDiscoveredTools() throws {
        let fixture = try fixture()
        fixture.model.plugins = [plugin()]
        let preview = try #require(fixture.model.previewOnboarding(.init()))
        #expect(preview.candidates.isEmpty)
        #expect(preview.warnings.contains { $0.contains("empty configuration") })
        let completion = try #require(fixture.model.finishOnboarding(preview))
        let profile = try #require(fixture.model.profiles.first { $0.id == completion.configurationID })
        #expect(profile.enabledPlugins.isEmpty && profile.requiredMCPs.isEmpty && profile.requiredSkills.isEmpty)
        #expect(profile.targetBindings == [])
        #expect(fixture.model.plugins.count == 1)
    }

    @Test func clientSelectionIsAtomicAndRetainsExcludedInventory() throws {
        let fixture = try fixture()
        fixture.model.skills = [skill("existing")]
        #expect(fixture.model.setOnboardingClients([.codex]))
        #expect(fixture.model.enabledClients == [.codex])
        #expect(fixture.model.skills.map(\.id) == ["existing"])
        #expect(fixture.model.visibleSkills.isEmpty)
        let reopened = try AppModel(store: fixture.store, runner: OnboardingRunner(), homeURL: fixture.home)
        #expect(reopened.enabledClients == [.codex])
        #expect(reopened.skills.map(\.id) == ["existing"])
    }

    @Test func olderConfigurationsDoNotAcquireAnEmptyTargetRestriction() throws {
        let legacy = Data(
            """
            {"id":"legacy","name":"Legacy","summary":"Existing configuration"}
            """.utf8)
        let profile = try JSONDecoder().decode(ToolingProfile.self, from: legacy)
        #expect(profile.targetBindings == nil)
    }

    @Test func wholePluginIncludesSkillsAndServersOnlyInTheirObservedApp() throws {
        let model = try fixture().model
        var bundledSkill = skill("bundle:child")
        bundledSkill.clients.append(.init(client: .codex, state: .healthy, detail: "Independent copy", isInstalled: true))
        var bundledServer = server()
        bundledServer.clients.append(.init(client: .codex, state: .healthy, detail: "Independent server", isInstalled: true))
        model.skills = [bundledSkill, skill("standalone")]
        model.mcpServers = [bundledServer]
        var bundle = plugin()
        bundle.skills = ["bundle:child"]
        bundle.clients.append(.init(client: .codex, state: .healthy, detail: "Found", isInstalled: true))
        model.plugins = [bundle]
        model.targetObservations = [
            observation(
                skills: ["bundle:child": .init(path: "/bundle/child", source: "Plugin", providerPluginID: "bundle@catalog")],
                plugins: [
                    "bundle@catalog": .init(
                        name: "Bundle", source: "catalog", scope: "User", enabled: true,
                        skillIDs: ["bundle:child"], mcpServerIDs: ["docs"])
                ],
                servers: ["docs": .init(transport: "HTTP", authentication: "OAuth", source: "bundle@catalog")]),
            observation(
                surface: .codexCLI,
                skills: ["bundle:child": .init(path: "/independent/child", source: "Standalone")],
                plugins: ["bundle@catalog": .init(name: "Bundle", source: "catalog", scope: "User", enabled: true)],
                servers: ["docs": .init(transport: "HTTP", authentication: "OAuth", source: "Codex configuration")]),
        ]

        let inventory = model.onboardingInventory
        #expect(inventory.standaloneSkills.map(\.itemID) == ["standalone"])
        #expect(inventory.standaloneServers.isEmpty)
        #expect(Set(inventory.childrenByPluginID["bundle@catalog", default: []].map(\.id)) == ["skill:bundle:child", "mcpServer:docs"])
        let preview = try #require(model.previewOnboarding(.init(itemIDs: ["plugin:bundle@catalog"])))
        #expect(Set(preview.candidates.map(\.id)) == ["plugin:bundle@catalog", "skill:bundle:child", "mcpServer:docs"])
        #expect(preview.targetBindings.count == 4)
        #expect(preview.targetBindings.filter { $0.item.kind != .plugin }.allSatisfy { $0.client == .claude })
        #expect(preview.copySkillIDs.isEmpty)
        let completion = try #require(model.finishOnboarding(preview))
        let saved = try #require(model.profiles.first { $0.id == completion.configurationID })
        #expect(saved.requiredSkills == ["bundle:child"])
        #expect(saved.requiredMCPs == ["docs"])
    }

    @Test func sameNamedPluginsKeepExactIdentityAndUnionPerClientContents() throws {
        let model = try fixture().model
        var first = plugin()
        first.clients.append(.init(client: .codex, state: .healthy, detail: "Found", isInstalled: true))
        var second = plugin("bundle@other")
        second.skills = ["bundle:other"]
        var codexChild = skill("bundle:codex-child")
        codexChild.clients = [.init(client: .codex, state: .healthy, detail: "Found", isInstalled: true)]
        model.skills = [skill("bundle:child"), codexChild, skill("bundle:other")]
        model.plugins = [first, second]
        model.targetObservations = [
            observation(
                skills: ["bundle:child": .init(path: "/catalog/child", source: "Plugin", providerPluginID: "bundle@catalog")],
                plugins: [
                    "bundle@catalog": .init(
                        name: "Bundle", source: "catalog", scope: "User", enabled: true, skillIDs: ["bundle:child"])
                ]),
            observation(
                surface: .codexCLI,
                skills: ["bundle:codex-child": .init(path: "/catalog/codex-child", source: "Plugin", providerPluginID: "bundle@catalog")],
                plugins: [
                    "bundle@catalog": .init(
                        name: "Bundle", source: "catalog", scope: "User", enabled: true, skillIDs: ["bundle:codex-child"])
                ]),
        ]
        let inventory = model.onboardingInventory
        #expect(Set(inventory.childrenByPluginID["bundle@catalog", default: []].map(\.itemID)) == ["bundle:child", "bundle:codex-child"])
        #expect(inventory.childrenByPluginID["bundle@other"]?.map(\.itemID) == ["bundle:other"])
        let preview = try #require(model.previewOnboarding(.init(itemIDs: ["plugin:bundle@catalog"])))
        #expect(!preview.candidates.contains { $0.itemID == "bundle:other" })
        #expect(preview.targetBindings.filter { $0.item.identifier == "bundle:codex-child" }.map(\.client) == [.codex])
        #expect(preview.targetBindings.filter { $0.item.identifier == "bundle:child" }.map(\.client) == [.claude])
    }

    @Test func removingPluginRecomputesBundledContentsAndKeepsOtherChoices() throws {
        let model = try fixture().model
        var first = plugin()
        var second = plugin("second@catalog")
        first.skills = ["shared"]
        second.skills = ["shared"]
        model.plugins = [first, second]
        model.skills = [skill("shared"), skill("standalone")]
        let inventory = model.onboardingInventory
        var selection = OnboardingSelection(itemIDs: ["plugin:bundle@catalog", "plugin:second@catalog", "skill:standalone"])
        selection = inventory.expandedSelection(selection)
        #expect(selection.itemIDs.contains("skill:shared"))
        selection.itemIDs.remove("plugin:bundle@catalog")
        selection = inventory.expandedSelection(selection)
        #expect(selection.itemIDs.contains("skill:shared"))
        selection.itemIDs.remove("plugin:second@catalog")
        selection = inventory.expandedSelection(selection)
        #expect(selection.itemIDs == ["skill:standalone"])
        #expect(inventory.selectedCandidates(for: selection).map(\.itemID) == ["standalone"])
    }

    @Test func disabledPluginKeepsItsContentsDisabledAndNeverSyncsAnOwnedBundledCopy() async throws {
        let model = try fixture().model
        model.skills = [skill("child", owned: true)]
        model.plugins = [plugin()]
        model.mcpServers = [server()]
        model.targetObservations = [
            observation(
                skills: ["child": .init(path: "/bundle/child", source: "Plugin", providerPluginID: "bundle@catalog")],
                plugins: [
                    "bundle@catalog": .init(
                        name: "Bundle", source: "catalog", scope: "User", enabled: false,
                        skillIDs: ["child"], mcpServerIDs: ["docs"])
                ],
                servers: ["docs": .init(transport: "HTTP", authentication: "OAuth", source: "bundle@catalog", enabled: true)])
        ]
        let preview = try #require(model.previewOnboarding(.init(itemIDs: ["plugin:bundle@catalog"])))
        #expect(preview.targetBindings.count == 3)
        #expect(preview.targetBindings.allSatisfy { $0.enabled == false })
        #expect(model.finishOnboarding(preview) != nil, "\(model.lastError ?? "No error")")
        #expect(model.activeProfile?.enabledPlugins.isEmpty == true)
        #expect(model.activeProfile?.requiredMCPs.isEmpty == true)
        #expect(model.onboardingSyncTargets(for: model.skills[0]) == [])
        #expect(
            model.previewOnboarding(.init(configurationName: "Other", itemIDs: ["plugin:bundle@catalog"], copySkillIDs: ["child"])) == nil)
        #expect(model.pendingPlan == nil)
    }

    @Test func changingPluginContentsInvalidatesReviewAndUnrelatedMCPSourceStaysStandalone() throws {
        let model = try fixture().model
        model.plugins = [plugin()]
        model.mcpServers = [server()]
        model.targetObservations = [
            observation(servers: [
                "docs": .init(transport: "HTTP", authentication: "OAuth", source: "bundle")
            ])
        ]
        #expect(model.onboardingInventory.standaloneServers.map(\.itemID) == ["docs"])
        let preview = try #require(model.previewOnboarding(.init(itemIDs: ["plugin:bundle@catalog"])))
        model.skills = [skill("new-child")]
        model.plugins[0].skills = ["new-child"]
        #expect(model.renameOnboardingPreview(preview, to: "Renamed setup") == nil)
        #expect(model.finishOnboarding(preview) == nil)
        #expect(!model.profiles.contains { $0.id == preview.configurationID })
    }

    @Test func renamingAReviewedSetupPreservesItsSelectionAndTargets() throws {
        let model = try fixture().model
        model.plugins = [plugin()]
        let preview = try #require(model.previewOnboarding(.init(itemIDs: ["plugin:bundle@catalog"])))
        let renamed = try #require(model.renameOnboardingPreview(preview, to: "Daily setup"))
        #expect(renamed.selection.configurationName == "Daily setup")
        #expect(renamed.selection.itemIDs == preview.selection.itemIDs)
        #expect(renamed.copySkillIDs == preview.copySkillIDs)
        #expect(renamed.targetBindings == preview.targetBindings)
        #expect(renamed.candidates == preview.candidates)
        #expect(model.profiles.count == 1)
    }

    @Test func snapshotDeduplicatesKindQualifiedIDsWithoutMergingDifferentToolKinds() throws {
        let model = try fixture().model
        model.skills = [skill("docs")]
        model.mcpServers = [server()]
        let candidates = model.onboardingCandidates
        let inventory = OnboardingInventory(candidates: candidates + candidates)
        #expect(inventory.candidates.count == 2)
        #expect(inventory.standaloneSkills.map(\.id) == ["skill:docs"])
        #expect(inventory.standaloneServers.map(\.id) == ["mcpServer:docs"])
    }

    @Test(arguments: [false, true])
    func renamedSkillCopiesPreserveMetadataAndDisabledAssignments(refreshAfterCopy: Bool) async throws {
        let fixture = try fixture()
        let model = fixture.model
        let source = fixture.home.appending(path: ".codex/skills/js-server-sdk/SKILL.md")
        let markdown =
            "---\nname: 'fishjam-js-server-sdk'\ndescription: >-\n  Use the server SDK\n  to manage rooms.\n---\n\n# Original instructions\n"
        try write(markdown, to: source)
        let configuration = "[[skills.config]]\npath = \"\(source.path)\"\nenabled = false\n"
        let configURL = fixture.home.appending(path: ".codex/config.toml")
        try write(configuration, to: configURL)
        #expect(await model.runDoctor())
        var preview = try #require(model.previewOnboarding(.init(itemIDs: ["skill:js-server-sdk"], copySkillIDs: ["js-server-sdk"])))
        #expect(preview.targetBindings.first?.enabled == false)
        #expect(model.planOnboardingSkillAdoption(preview), "\(model.lastError ?? "No error")")
        #expect(model.onboardingAdoptedSkillIDs.isEmpty, "Preparing a copy is not completion")
        #expect(await model.executePendingPlan(try OperationPlanApproval.review(try #require(model.pendingPlan))))
        #expect(model.onboardingAdoptedSkillIDs["js-server-sdk"] == "fishjam-js-server-sdk")
        #expect(
            model.previewOnboarding(
                .init(
                    itemIDs: ["skill:js-server-sdk", "skill:fishjam-js-server-sdk"], copySkillIDs: ["js-server-sdk"])) == nil)
        model.lastError = nil
        if refreshAfterCopy {
            preview = try #require(model.previewOnboarding(.init(itemIDs: ["skill:fishjam-js-server-sdk"])))
            #expect(preview.targetBindings.first?.enabled == false)
        }
        let completion = try #require(model.finishOnboarding(preview), "\(model.lastError ?? "No error")")
        let profile = try #require(model.profiles.first { $0.id == completion.configurationID })
        #expect(profile.requiredSkills == ["fishjam-js-server-sdk"])
        #expect(profile.targetBindings?.map(\.item.identifier) == ["fishjam-js-server-sdk"])
        #expect(profile.targetBindings?.map(\.enabled) == [false])
        #expect(profile.targetBindings?.map(\.client) == [.codex])
        let copied = fixture.store.libraryURL.appending(path: "packages/local-fishjam-js-server-sdk/skills/fishjam-js-server-sdk/SKILL.md")
        #expect(try String(contentsOf: copied, encoding: .utf8) == markdown)
        #expect(try String(contentsOf: source, encoding: .utf8) == markdown)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == configuration)
        await model.runSync()
        let sync = try #require(model.pendingPlan)
        #expect(!sync.steps.contains { $0.kind == .copyDirectory })
        model.discardPendingPlan()
    }

    @Test func installedCanonicalSkillUsesItsOwnAvailabilityAfterAdoption() async throws {
        let fixture = try fixture()
        let model = fixture.model
        let original = fixture.home.appending(path: ".codex/skills/short-name/SKILL.md")
        let canonical = fixture.home.appending(path: ".codex/skills/declared-name/SKILL.md")
        try write(definition("declared-name"), to: original)
        try write(definition("declared-name"), to: canonical)
        try write(
            "[[skills.config]]\npath = \"\(original.path)\"\nenabled = false\n"
                + "[[skills.config]]\npath = \"\(canonical.path)\"\nenabled = true\n",
            to: fixture.home.appending(path: ".codex/config.toml"))
        #expect(await model.runDoctor())
        model.onboardingAdoptedSkillIDs = ["short-name": "declared-name"]
        let preview = try #require(model.previewOnboarding(.init(itemIDs: ["skill:declared-name"])))
        #expect(preview.targetBindings.map(\.enabled) == [true])
        #expect(preview.targetBindings.map(\.client) == [.codex])
    }

    @Test(arguments: [false, true])
    func rejectedCopiesCanOnlyBeSkippedExplicitlyAndNeverChangeClientFiles(allRejected: Bool) async throws {
        let fixture = try fixture()
        let model = fixture.model
        let invalid = fixture.home.appending(path: ".claude/skills/incomplete/SKILL.md")
        let invalidMarkdown = "---\nname: incomplete\n---\n# No description yet\n"
        try write(invalidMarkdown, to: invalid)
        let valid = fixture.home.appending(path: ".claude/skills/valid/SKILL.md")
        try write(definition("valid"), to: valid)
        #expect(await model.runDoctor())
        let ids: Set<String> = allRejected ? ["incomplete"] : ["incomplete", "valid"]
        let selection = OnboardingSelection(itemIDs: Set(ids.map { "skill:\($0)" }), copySkillIDs: ids)
        let preview = try #require(model.previewOnboarding(selection))
        #expect(!model.planOnboardingSkillAdoption(preview))
        #expect(model.pendingPlan == nil)
        #expect(model.onboardingCopyIssues.map(\.id) == ["incomplete"])
        #expect(model.onboardingCopyIssues.first?.reason.contains("description") == true)
        #expect(model.skills.allSatisfy { !$0.owned })
        #expect(preview.selection == selection, "A failed plan does not silently drop a choice")
        let otherReview = try #require(model.previewOnboarding(selection))
        #expect(model.skippingOnboardingCopyIssues(otherReview) == nil, "Issues are bound to the review that produced them")
        let remaining = try #require(model.skippingOnboardingCopyIssues(preview))
        #expect(remaining.selection.itemIDs.contains("skill:incomplete"), "Declining a copy keeps its source version tracked")
        #expect(!remaining.copySkillIDs.contains("incomplete"))
        #expect(model.onboardingCopyIssues.isEmpty)
        #expect(model.pendingPlan == nil, "Skipping returns to review; it does not approve a copy")
        if !allRejected {
            #expect(remaining.copySkillIDs == ["valid"])
            #expect(model.planOnboardingSkillAdoption(remaining))
            #expect(await model.executePendingPlan(try OperationPlanApproval.review(try #require(model.pendingPlan))))
        }
        #expect(model.finishOnboarding(remaining) != nil)
        #expect(model.activeProfile?.requiredSkills == (allRejected ? ["incomplete"] : ["incomplete", "valid"]))
        #expect(try String(contentsOf: invalid, encoding: .utf8) == invalidMarkdown)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.libraryURL.appending(path: "packages/local-incomplete").path))
    }

    @Test func blockedContentChecksReturnToExplicitSkipWithoutChangingReviewPolicy() async throws {
        let fixture = try fixture()
        let model = fixture.model
        for name in ["first", "second"] {
            try write(definition(name), to: fixture.home.appending(path: ".claude/skills/\(name)/SKILL.md"))
        }
        #expect(await model.runDoctor())
        let preview = try #require(
            model.previewOnboarding(
                .init(
                    itemIDs: ["skill:first", "skill:second"], copySkillIDs: ["first", "second"])))
        #expect(model.planOnboardingSkillAdoption(preview))
        let plan = try #require(model.pendingPlan)
        let blockedStep = try #require(
            plan.steps.first { URL(fileURLWithPath: $0.destinationPath ?? "").lastPathComponent == "local-first" })
        let blocked = OperationStepSafetyReview(
            stepID: blockedStep.id, stepTitle: blockedStep.title, ownership: .absent,
            contentRisk: .init(coverageNotes: ["assets/large.txt exceeds the file review limit."], reachedScanLimit: true))
        let review = OperationPlanSafetyReview(planID: plan.id, steps: [blocked])
        #expect(review.hasBlockedSteps)
        #expect(!model.recordOnboardingBlockedCopies(.init(planID: UUID(), steps: [blocked]), for: preview))
        #expect(model.recordOnboardingBlockedCopies(review, for: preview))
        #expect(model.onboardingCopyIssues.map(\.id) == ["first"])
        #expect(model.onboardingCopyIssues.first?.reason.contains("assets/large.txt") == true)
        #expect(model.pendingPlan?.id == plan.id, "Recording an issue never applies or approves a plan")
        model.discardPendingPlan()
        let remaining = try #require(model.skippingOnboardingCopyIssues(preview))
        #expect(remaining.copySkillIDs == ["second"])
        #expect(model.planOnboardingSkillAdoption(remaining))
        #expect(model.pendingPlan?.steps.count == 1)
        #expect(review.hasBlockedSteps, "The rejected review remains blocked")
        model.discardPendingPlan()
        #expect(model.skills.allSatisfy { !$0.owned })
    }

    private func fixture() throws -> (model: AppModel, store: WorkspaceStore, home: URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "onboarding-tests-\(UUID().uuidString)")
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try WorkspaceStore(rootURL: root.appending(path: "workspace"))
        return (try AppModel(store: store, runner: OnboardingRunner(), homeURL: home), store, home)
    }

    private func skill(_ id: String, owned: Bool = false) -> Skill {
        Skill(
            id: id, name: id, displayName: id, summary: "A useful skill.", bundle: owned ? "local-\(id)" : "Existing",
            scope: "This Mac", owned: owned, triggers: [], negativeTrigger: "", files: ["SKILL.md"],
            clients: [.init(client: .claude, state: .healthy, detail: "Found", isInstalled: true)], validationCount: 0)
    }

    private func plugin(_ id: String = "bundle@catalog") -> Plugin {
        Plugin(
            id: id, name: "Bundle", summary: "Existing native plugin.", source: "catalog", scope: "This Mac",
            revision: "1", skills: [], profiles: [], clients: [.init(client: .claude, state: .healthy, detail: "Found", isInstalled: true)],
            installed: true)
    }

    private func server() -> MCPServer {
        MCPServer(
            id: "docs", name: "Docs", summary: "Existing server.", endpoint: "https://example.com/mcp", transport: .http,
            authentication: "OAuth", scope: "This Mac",
            clients: [.init(client: .claude, state: .healthy, detail: "Found", isInstalled: true)])
    }

    private func observation(
        surface: TargetSurface = .claudeCode, skills: [String: ObservedSkillMetadata] = [:],
        plugins: [String: ObservedPluginMetadata] = [:], servers: [String: ObservedMCPMetadata] = [:]
    )
        -> TargetObservation
    {
        TargetObservation(
            surface: surface, installed: true, commandAvailable: true, discoveredSkills: Array(skills.keys),
            discoveredPlugins: Array(plugins.keys), discoveredMCPServers: Array(servers.keys),
            skillMetadata: skills, pluginMetadata: plugins, mcpMetadata: servers,
            capabilities: .init(
                supportsPluginInstall: true, supportsProjectScope: true, supportsLocalMarketplace: true,
                supportsMCPAuthentication: true, supportsConnectorDiscovery: false, requiresNewSession: true,
                requiresRestart: false, supportsMachineReadableOutput: true))
    }

    private func definition(_ name: String) -> String {
        "---\nname: \(name)\ndescription: Review a document before it is published.\n---\n\n# \(name)\n\nReview it.\n"
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

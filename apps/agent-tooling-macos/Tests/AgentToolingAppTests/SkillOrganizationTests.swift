import AgentToolingCore
import Testing

@testable import AgentToolingApp

@Suite("Skill ownership classification")
struct SkillOrganizationTests {
    @Test func standaloneSkillsDoNotShareOwnership() {
        #expect(
            SkillOrganization.ownershipKey(skillID: "custom", pluginID: nil)
                != SkillOrganization.ownershipKey(skillID: "downloaded", pluginID: nil))
    }

    @Test func pluginSkillsShareAnExplicitSourceClassification() {
        #expect(
            SkillOrganization.ownershipKey(skillID: "one", pluginID: "workflows@personal")
                == SkillOrganization.ownershipKey(skillID: "two", pluginID: "workflows@personal"))
        #expect(
            SkillOrganization.ownershipKey(skillID: "one", pluginID: "workflows@personal")
                != SkillOrganization.ownershipKey(skillID: "one", pluginID: "workflows@vendor"))
    }
}

@Suite("Automatic skill provenance")
struct AutomaticSkillProvenanceTests {
    @Test func personalAndIndependentPublishersAreRecognizedWithoutAdoption() {
        #expect(owner("cyrus-workflows@agent-tooling") == "mine")
        #expect(owner("react-native@callstack-agent-skills") == "thirdParty")
        #expect(owner("simview@toolingtools") == "thirdParty")
    }

    @Test func directlySuppliedSkillsHaveTheirOwnCategory() {
        for id in [
            "documents@openai-bundled", "pdf@openai-primary-runtime", "codex:imagegen@openai-bundled",
            "document-skills@anthropic-agent-skills", "example-skills@anthropic-agent-skills",
            "frontend-design@claude-plugins-official",
        ] {
            #expect(owner(id) == "provider")
            #expect(SkillScope.provider.matches(owner: owner(id)))
            #expect(!SkillScope.thirdParty.matches(owner: owner(id)))
        }
    }

    @Test func officialMarketplaceDoesNotEstablishVendorAuthorship() {
        for id in [
            "third-party-api@claude-plugins-official", "frontend-design@another-marketplace",
            "github@openai-curated-remote", "unrecognized@anthropic-agent-skills", "x@not-openai-bundled",
            "documents@openai-bundled@other", "https://example.com/documents@openai-bundled",
        ] {
            #expect(owner(id) == "unknown")
            #expect(!SkillScope.provider.matches(owner: owner(id)))
            #expect(!SkillScope.thirdParty.matches(owner: owner(id)))
            #expect(SkillScope.all.matches(owner: owner(id)))
        }
    }

    @Test func manualOverridesAndManagedCopiesKeepTheirMeaning() {
        #expect(
            SkillOrganization.classify(maintainedHere: false, pluginID: "personal@agent-tooling", override: "thirdParty").owner
                == "thirdParty")
        #expect(SkillOrganization.classify(maintainedHere: false, pluginID: "pdf@openai-bundled", override: "mine").owner == "mine")
        #expect(SkillOrganization.classify(maintainedHere: false, pluginID: "pdf@openai-bundled", override: "unknown").owner == "unknown")
        #expect(SkillOrganization.classify(maintainedHere: true, pluginID: "pdf@openai-bundled", override: nil).owner == "mine")
        #expect(SkillOrganization.classify(maintainedHere: false, pluginID: nil, override: nil).owner == "unknown")
        #expect(owner("personal@unrecognized") == "unknown")
    }

    private func owner(_ pluginID: String) -> String {
        SkillOrganization.classify(maintainedHere: false, pluginID: pluginID, override: nil).owner
    }
}

@Suite("Skill list presentation")
struct SkillListPresentationTests {
    @Test func pluginAndMarketplaceHaveSeparateHumanLabels() {
        let origin = SkillPresentation(pluginID: "cyrus-workflows@agent-tooling")
        #expect(origin.pluginID == "cyrus-workflows@agent-tooling")
        #expect(origin.pluginName == "Cyrus Workflows")
        #expect(origin.marketplaceID == "agent-tooling")
        #expect(origin.marketplaceName == "Agent Tooling")
        #expect(origin.compactDescription == "Cyrus Workflows · Agent Tooling")
        #expect(origin.compactDescription?.contains("@") == false)
        #expect(SkillPresentation(pluginID: nil).pluginName == nil)
        #expect(SkillPresentation(pluginID: nil).marketplaceName == nil)
    }

    @Test func declaredDisplayNameIsPreservedWithoutRepeatingTheCatalogSuffix() {
        #expect(SkillPresentation(pluginID: "ios-tools@agent-tooling", pluginDisplayName: "iOS Tools").pluginName == "iOS Tools")
        #expect(
            SkillPresentation(pluginID: "cyrus-workflows@agent-tooling", pluginDisplayName: "Cyrus Workflows@Agent Tooling").pluginName
                == "Cyrus Workflows")
    }

    @Test func marketplaceAndPluginFiltersAreIndependentAndIntersect() {
        let cyrus = SkillPresentation(pluginID: "cyrus-workflows@agent-tooling")
        let personal = SkillPresentation(pluginID: "personal@agent-tooling")
        let external = SkillPresentation(pluginID: "cyrus-workflows@another-marketplace")
        #expect(cyrus.matches(marketplace: "agent-tooling", plugin: ""))
        #expect(personal.matches(marketplace: "agent-tooling", plugin: ""))
        #expect(!external.matches(marketplace: "agent-tooling", plugin: ""))
        #expect(cyrus.matches(marketplace: "", plugin: "cyrus-workflows@agent-tooling"))
        #expect(!external.matches(marketplace: "", plugin: "cyrus-workflows@agent-tooling"))
        #expect(!cyrus.matches(marketplace: "another-marketplace", plugin: "cyrus-workflows@agent-tooling"))
        #expect(!SkillPresentation(pluginID: nil).matches(marketplace: "agent-tooling", plugin: ""))
    }

    @Test func legacyDefaultBecomesFlatAndNewChoicesSurviveRestoration() {
        #expect(SkillGrouping.migratedValue("Source") == .none)
        #expect(SkillGrouping.migratedValue("") == .none)
        for choice in SkillGrouping.allCases {
            #expect(SkillGrouping.migratedValue(choice.rawValue) == choice)
        }
    }

    @Test func flatListIsAlphabeticalAndDoesNotExposeGroupHeaders() {
        let groups = SkillListPresentation.groups(skills: fixture, grouping: .none, presentation: origin)
        #expect(groups.count == 1)
        #expect(groups.first?.title == "")
        #expect(groups.first?.skills.map(\.id) == ["alpha", "beta", "gamma", "standalone"])
    }

    @Test func pluginGroupsKeepSameNamedPluginsFromDifferentMarketplacesDistinct() {
        let groups = SkillListPresentation.groups(skills: fixture, grouping: .plugin, presentation: origin)
        let matching = groups.filter { $0.title == "Workflow" }
        #expect(matching.count == 2)
        #expect(Set(matching.map(\.id)).count == 2)
        #expect(Set(matching.compactMap(\.subtitle)) == ["Agent Tooling", "Other"])
        #expect(groups.contains { $0.title == "Standalone" && $0.skills.map(\.id) == ["standalone"] })
    }

    @Test func marketplaceGroupsCombinePackagesAndMaintenanceRemainsSeparate() {
        let marketplaces = SkillListPresentation.groups(skills: fixture, grouping: .marketplace, presentation: origin)
        #expect(marketplaces.first { $0.title == "Agent Tooling" }?.skills.map(\.id) == ["alpha", "beta"])
        #expect(marketplaces.first { $0.title == "No marketplace" }?.skills.map(\.id) == ["standalone"])
        let maintenance = SkillListPresentation.groups(skills: fixture, grouping: .maintenance, presentation: origin)
        #expect(maintenance.first { $0.title == "Maintained here" }?.skills.map(\.id) == ["standalone"])
        #expect(maintenance.first { $0.title == "Maintained elsewhere" }?.skills.count == 3)
    }

    private var fixture: [Skill] {
        [("gamma", "workflow@other"), ("standalone", ""), ("beta", "personal@agent-tooling"), ("alpha", "workflow@agent-tooling")].map {
            id, bundle in
            Skill(
                id: id, name: id, displayName: id.capitalized, summary: "", bundle: bundle, scope: "User",
                owned: bundle.isEmpty, triggers: [], negativeTrigger: "", files: [], clients: [], validationCount: 0)
        }
    }

    private func origin(_ skill: Skill) -> SkillPresentation {
        SkillPresentation(pluginID: skill.bundle.isEmpty ? nil : skill.bundle)
    }
}

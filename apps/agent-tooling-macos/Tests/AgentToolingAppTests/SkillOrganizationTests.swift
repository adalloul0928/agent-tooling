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
    @Test func personalAndExternalPluginsAreRecognizedWithoutAdoption() {
        #expect(SkillOrganization.classify(maintainedHere: false, pluginID: "cyrus-workflows@agent-tooling", override: nil).owner == "mine")
        #expect(
            SkillOrganization.classify(maintainedHere: false, pluginID: "frontend-design@claude-plugins-official", override: nil).owner
                == "thirdParty")
        #expect(
            SkillOrganization.classify(maintainedHere: false, pluginID: "react-native@callstack-agent-skills", override: nil).owner
                == "thirdParty")
    }
    @Test func manualOverridesWinAndUnknownSourcesAreNotGuessed() {
        #expect(
            SkillOrganization.classify(maintainedHere: false, pluginID: "personal@agent-tooling", override: "thirdParty").owner
                == "thirdParty")
        #expect(SkillOrganization.classify(maintainedHere: false, pluginID: "personal@unrecognized", override: nil).owner == "unknown")
        #expect(SkillOrganization.classify(maintainedHere: false, pluginID: nil, override: nil).owner == "unknown")
        #expect(SkillOrganization.classify(maintainedHere: false, pluginID: "x@not-agent-tooling", override: nil).owner == "unknown")
    }
}

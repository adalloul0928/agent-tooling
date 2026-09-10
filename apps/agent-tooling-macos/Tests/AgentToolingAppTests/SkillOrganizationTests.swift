import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

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
        #expect(groups.first?.skills.map(\.displayName) == ["Alpha", "Beta", "Gamma", "Standalone"])
    }

    @Test func pluginGroupsKeepSameNamedPluginsFromDifferentMarketplacesDistinct() {
        let groups = SkillListPresentation.groups(skills: fixture, grouping: .plugin, presentation: origin)
        let matching = groups.filter { $0.title == "Workflow" }
        #expect(matching.count == 2)
        #expect(Set(matching.map(\.id)).count == 2)
        #expect(Set(matching.compactMap(\.subtitle)) == ["Agent Tooling", "Other"])
        #expect(groups.contains { $0.title == "Standalone" && $0.skills.map(\.displayName) == ["Standalone"] })
    }

    @Test func marketplaceGroupsCombinePackagesAndMaintenanceRemainsSeparate() {
        let marketplaces = SkillListPresentation.groups(skills: fixture, grouping: .marketplace, presentation: origin)
        #expect(marketplaces.first { $0.title == "Agent Tooling" }?.skills.map(\.displayName) == ["Alpha", "Beta"])
        #expect(marketplaces.first { $0.title == "No marketplace" }?.skills.map(\.displayName) == ["Standalone"])
        let maintenance = SkillListPresentation.groups(skills: fixture, grouping: .maintenance, presentation: origin)
        #expect(maintenance.first { $0.title == "Maintained here" }?.skills.map(\.displayName) == ["Standalone"])
        #expect(maintenance.first { $0.title == "Maintained elsewhere" }?.skills.count == 3)
    }

    private var fixture: [SkillEntry] {
        [("Gamma", "workflow@other"), ("Standalone", ""), ("Beta", "personal@agent-tooling"), ("Alpha", "workflow@agent-tooling")]
            .map { name, plugin in
                SkillEntry(
                    id: ArtifactID(), displayName: name, declaredName: name.lowercased(), summary: "",
                    ownership: plugin.isEmpty ? .centralPersonal : .nativeOwned, authority: nil, contentDigest: nil,
                    parentID: plugin.isEmpty ? nil : ArtifactID(), parentPluginLabel: nil,
                    providerPluginID: plugin.isEmpty ? nil : plugin, sourceLabel: nil,
                    requestedAssignments: [], isAssignable: true, assignmentExplanation: nil)
            }
    }

    private func origin(_ skill: SkillEntry) -> SkillPresentation {
        SkillPresentation(pluginID: skill.providerPluginID)
    }
}

/// The index reads the library, and reads nothing into it.
@Suite("Skill inventory index")
@MainActor
struct SkillInventoryIndexTests {
    @Test func pluginMembersAreListedAndInheritTheirPackagesAuthority() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let state = try #require(fixture.workspace.library.state)
        let index = SkillInventoryIndex(
            library: state.library, snapshot: state.snapshot, observations: [], ownershipJSON: "{}")

        #expect(index.skills.map(\.displayName) == ["Bundled Skill", "Standalone Skill"])
        let bundled = try #require(index.skills.first { $0.displayName == "Bundled Skill" })
        #expect(bundled.parentPluginLabel == "Example Plugin")
        #expect(bundled.installation == "Plugin")
        #expect(!bundled.isMaintainedHere)
        let standalone = try #require(index.skills.first { $0.displayName == "Standalone Skill" })
        #expect(standalone.installation == "Standalone")
        #expect(standalone.isMaintainedHere)
        // The fixture's personal skill holds no content object, so nothing may
        // offer to show or replace bytes this workspace does not have.
        #expect(!standalone.hasCentralContent)
    }

    /// A row is joined to a scan by the name it declares. A skill that declares
    /// nothing is joined to nothing, so it never wears another one's marks and
    /// never claims a place on this Mac it was not found in.
    @Test func marksFollowTheDeclaredNameAndNothingElse() throws {
        let named = ArtifactID()
        let anonymous = ArtifactID()
        let snapshot = try Self.snapshot(artifacts: [
            .init(
                identity: .init(id: named, kind: .skill, displayName: "Release Readiness"),
                authority: .trackedOnly, declaredName: "release-readiness"),
            .init(
                identity: .init(id: anonymous, kind: .skill, displayName: "Release Readiness"),
                authority: .trackedOnly),
        ])
        var scripted = ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true)
        scripted.discoveredSkills = ["release-readiness"]
        scripted.skillMetadata = [
            "release-readiness": .init(path: "/tmp/skills/release-readiness", source: "Standalone skill")
        ]

        let index = try SkillInventoryIndex(
            library: WorkspaceLibraryReadModel(snapshot: snapshot), snapshot: snapshot,
            observations: [scripted], ownershipJSON: "{}")
        #expect(index.observedClients[named] == [.claude])
        #expect(index.observedClients[anonymous] == nil)
        #expect(index.observedPaths[named] == "/tmp/skills/release-readiness")
    }

    /// The scan and the request are two claims, and the index keeps them apart:
    /// a place somebody asked for is never reported as a place it was found.
    @Test func askingForASkillDoesNotMarkItAsFound() throws {
        let skill = ArtifactID()
        var snapshot = try Self.snapshot(artifacts: [
            .init(
                identity: .init(id: skill, kind: .skill, displayName: "Release Readiness"),
                authority: .centralPersonal, declaredName: "release-readiness")
        ])
        var document = snapshot.document
        document.assignments = [
            .init(artifactID: skill, destination: .init(surface: .claudeCode, scope: .user), reason: .manual)
        ]
        snapshot = .init(document: try WorkspaceDocumentCoding.seal(document), device: snapshot.device)

        let index = try SkillInventoryIndex(
            library: WorkspaceLibraryReadModel(snapshot: snapshot), snapshot: snapshot,
            observations: [], ownershipJSON: "{}")
        let row = try #require(index.skills.first)
        #expect(row.requestedClients == [.claude])
        #expect(index.observedClients[skill] == nil)
    }

    private static func snapshot(artifacts: [ArtifactRecord]) throws -> WorkspaceApplicationSnapshot {
        let workspaceID = WorkspaceObjectID()
        let document = try WorkspaceDocumentCoding.seal(
            .init(workspaceID: workspaceID, revision: .init(writerID: WorkspaceObjectID()), artifacts: artifacts))
        return .init(document: document, device: DeviceWorkspaceState(workspaceID: workspaceID))
    }

    @Test func aSavedClassificationOverridesTheAutomaticOne() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let state = try #require(fixture.workspace.library.state)
        let plain = SkillInventoryIndex(
            library: state.library, snapshot: state.snapshot, observations: [], ownershipJSON: "{}")
        let bundled = try #require(plain.skills.first { $0.displayName == "Bundled Skill" })
        #expect(plain.owner(of: bundled) == "unknown")

        let key = plain.ownershipKey(for: bundled)
        let overridden = SkillInventoryIndex(
            library: state.library, snapshot: state.snapshot, observations: [],
            ownershipJSON: #"{"\#(key)":"thirdParty"}"#)
        let same = try #require(overridden.skills.first { $0.displayName == "Bundled Skill" })
        #expect(overridden.owner(of: same) == "thirdParty")
    }

    @Test func anUnreadWorkspaceIndexesToNothing() {
        let index = SkillInventoryIndex(library: nil, snapshot: nil, observations: [], ownershipJSON: "{}")
        #expect(index.skills.isEmpty)
        #expect(index.marketplaces.isEmpty)
        #expect(index.mineCount == 0)
    }
}

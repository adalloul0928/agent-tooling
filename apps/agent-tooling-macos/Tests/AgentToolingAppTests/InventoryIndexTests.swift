import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

@Suite("Inventory presentation indexes")
struct InventoryIndexTests {
    @Test func skillIndexKeepsSourcePrecedenceClassificationAndKindScopedMetadata() {
        let shared = skill("shared")
        let independent = skill("independent")
        let provider = plugin("docs@openai-bundled", name: "Documents")
        let earlier = observation(
            .claudeCode,
            metadata: [
                shared.id: .init(path: "/fixture/first", source: "fixture", providerPluginID: provider.id)
            ])
        let later = observation(
            .codexCLI,
            metadata: [
                shared.id: .init(path: "/fixture/second", source: "fixture", providerPluginID: "other@vendor")
            ])
        let index = SkillInventoryIndex(
            skills: [shared, independent], plugins: [provider], observations: [later, earlier],
            tagAssignments: [
                .init(item: .init(kind: .plugin, identifier: shared.id), tags: ["wrong kind"]),
                .init(item: .init(kind: .skill, identifier: shared.id), tags: ["Docs"]),
            ],
            collections: [
                .init(id: "z", name: "Zebra", items: [.init(kind: .skill, identifier: shared.id)]),
                .init(id: "a", name: "Alpha", items: [.init(kind: .skill, identifier: shared.id)]),
                .init(id: "p", name: "Plugins", items: [.init(kind: .plugin, identifier: shared.id)]),
            ],
            ownershipJSON: #"{"skill:independent":"mine"}"#, adoptableIDs: [independent.id]
        )
        #expect(index.metadata[shared.id]?.path == "/fixture/first")
        #expect(index.presentations[shared.id]?.pluginName == "Documents")
        #expect(index.presentations[shared.id]?.marketplaceName == "OpenAI Bundled")
        #expect(index.classifications[shared.id]?.owner == "provider")
        #expect(index.classifications[independent.id]?.owner == "mine")
        #expect(index.mineCount == 1 && index.unknownCount == 0)
        #expect(index.tags[shared.id] == ["Docs"])
        #expect(index.skillTags == ["Docs"])
        #expect(index.untaggedCount == 1)
        #expect(index.collectionNames[shared.id] == ["Alpha", "Zebra"])
        #expect(index.adoptableIDs == [independent.id])
        #expect(index.plugins.map(\.id) == [provider.id])
        #expect(index.marketplaces.map(\.id) == ["openai-bundled"])
    }

    @Test func unrelatedTagsAndBrokenPreferencesDoNotChangeClassification() {
        let index = SkillInventoryIndex(
            skills: [skill("visible")], plugins: [], observations: [],
            tagAssignments: [.init(item: .init(kind: .skill, identifier: "hidden"), tags: ["Hidden"])],
            collections: [], ownershipJSON: "invalid", adoptableIDs: []
        )
        #expect(index.classifications["visible"]?.owner == "unknown")
        #expect(index.unknownCount == 1)
        #expect(index.skillTags.isEmpty)
        #expect(index.marketplaces.isEmpty && index.plugins.isEmpty)
    }

    @Test func flatAndMaintenanceListsDoNotResolveUnusedProvenance() {
        var lookups = 0
        for grouping in [SkillGrouping.none, .maintenance] {
            let groups = SkillListPresentation.groups(skills: [skill("beta"), skill("alpha")], grouping: grouping) { _ in
                lookups += 1
                return SkillPresentation(pluginID: nil)
            }
            #expect(groups.first?.skills.map(\.id) == ["alpha", "beta"])
        }
        #expect(lookups == 0)
    }

    @Test func pluginIndexUsesExactIdentityAndRefreshesRevisionWithoutChangingNativeClients() {
        let value = plugin("tools@vendor", name: "Native tools")
        let firstConnector = DiscoveredConnectorRow(
            id: "a", name: "Friendly tools", summary: "Connector summary", pluginID: value.id, clients: []
        )
        let package = MarketplacePackage(
            id: "claude:tools@vendor", name: "Native tools", publisher: "vendor", summary: "",
            sourceName: "Catalog", revision: "1.1.0", components: [.plugin], supportedClients: [.claude], location: ""
        )
        let index = PluginInventoryIndex(plugins: [value], connectors: [firstConnector], sources: [], packages: [package])
        #expect(index.plugins.first?.name == "Friendly tools")
        #expect(index.plugins.first?.summary == "Connector summary")
        #expect(index.plugins.first?.clients == value.clients)
        #expect(index.availability[value.id] == .updateAvailable(installed: "1.0.0", available: "1.1.0"))
        var changed = package
        changed.revision = "1.0.0"
        let refreshed = PluginInventoryIndex(plugins: [value], connectors: [], sources: [], packages: [changed])
        #expect(refreshed.availability[value.id] == .upToDate(revision: "1.0.0"))
        changed.id = "claude:unrelated@vendor"
        let unrelated = PluginInventoryIndex(plugins: [value], connectors: [], sources: [], packages: [changed])
        #expect(unrelated.availability[value.id]?.isUnverified == true)
    }

    private func skill(_ id: String) -> Skill {
        Skill(
            id: id, name: id, displayName: id, summary: "", bundle: "", scope: "User", owned: false,
            triggers: [], negativeTrigger: "", files: [], clients: [], validationCount: 0
        )
    }

    private func plugin(_ id: String, name: String) -> Plugin {
        Plugin(
            id: id, name: name, summary: "", source: "fixture", scope: "User", revision: "1.0.0", skills: [], profiles: [],
            clients: [.init(client: .claude, state: .healthy, detail: "Installed", isInstalled: true)], installed: true
        )
    }

    private func observation(_ surface: TargetSurface, metadata: [String: ObservedSkillMetadata]) -> TargetObservation {
        TargetObservation(
            surface: surface, installed: true, skillMetadata: metadata,
            capabilities: .init(
                supportsPluginInstall: false, supportsProjectScope: false, supportsLocalMarketplace: false,
                supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: false,
                requiresRestart: false, supportsMachineReadableOutput: false
            )
        )
    }
}

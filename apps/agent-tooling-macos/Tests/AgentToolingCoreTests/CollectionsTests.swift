import Foundation
import Testing

@testable import AgentToolingCore

private struct SilentRunner: CommandRunning {
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        CommandOutput(status: 127, standardOutput: "", standardError: "command not found")
    }
}

@MainActor
struct CollectionsTests {
    // MARK: - Persistence

    @Test func collectionsAndTagsSurviveAWorkspaceReopen() throws {
        let root = try temporaryDirectory()
        let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        let skill = ToolingItemReference(kind: .skill, identifier: "release-readiness")
        let server = ToolingItemReference(kind: .mcpServer, identifier: "linear")

        do {
            let model = try makeModel(at: workspace, home: root)
            #expect(model.createCollection(name: "Release Kit", summary: "Everything a release needs") != nil)
            #expect(model.setCollectionMembership(id: "release-kit", items: [skill, server]))
            #expect(model.setTags(["Release", "Daily"], for: [skill]))
        }

        let reopened = try makeModel(at: workspace, home: root)
        #expect(reopened.collections.count == 1)
        #expect(reopened.collection(id: "release-kit")?.name == "Release Kit")
        #expect(Set(reopened.collection(id: "release-kit")?.items ?? []) == [skill, server])
        #expect(reopened.tags(for: skill) == ["Daily", "Release"])
    }

    /// The fields shipped after the first snapshot format, so a workspace
    /// written by an earlier build has to keep opening.
    @Test func snapshotWrittenBeforeCollectionsExistedStillDecodes() throws {
        let legacy = """
            {
              "activeProfileID": "local-library",
              "profiles": [
                {
                  "id": "local-library",
                  "name": "Local Library",
                  "summary": "Fixture",
                  "checks": [],
                  "enabledPlugins": ["legacy-plugin"],
                  "requiredMCPs": ["legacy-mcp"]
                }
              ]
            }
            """

        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(legacy.utf8))

        #expect(snapshot.collections.isEmpty)
        #expect(snapshot.tagAssignments.isEmpty)
        #expect(snapshot.profiles.first?.includedCollections.isEmpty == true)
        #expect(snapshot.profiles.first?.requiredSkills.isEmpty == true)
        #expect(snapshot.profiles.first?.enabledPlugins == ["legacy-plugin"])
        try WorkspaceSnapshotValidator.validate(snapshot, mode: .localState)
    }

    @Test func legacyWorkspaceDatabaseOpensAndGainsCollections() throws {
        let root = try temporaryDirectory()
        let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        let legacyProfile = ToolingProfile(
            id: "local-library", name: "Local Library", summary: "Fixture", checks: [], enabledPlugins: ["legacy-plugin"],
            requiredMCPs: [])

        // Written the way a build without collections would have written it.
        do {
            let store = try WorkspaceStore(rootURL: workspace)
            try store.saveWorkspaceSnapshot(WorkspaceSnapshot(profiles: [legacyProfile]))
        }

        let model = try makeModel(at: workspace, home: root)
        #expect(model.collections.isEmpty)
        #expect(model.profiles.first?.enabledPlugins == ["legacy-plugin"])
        #expect(model.createCollection(name: "Review Kit") != nil)

        let reopened = try makeModel(at: workspace, home: root)
        #expect(reopened.collection(id: "review-kit") != nil)
        #expect(reopened.profiles.first?.enabledPlugins == ["legacy-plugin"])
    }

    @Test func portableProjectionCarriesCollectionsAndTags() throws {
        let item = ToolingItemReference(kind: .plugin, identifier: "developer-workflows")
        let snapshot = WorkspaceSnapshot(
            collections: [ToolingCollection(id: "review-kit", name: "Review Kit", items: [item])],
            tagAssignments: [TagAssignment(item: item, tags: ["Review"])]
        )

        let portable = snapshot.portableDesiredState()

        #expect(portable.collections.first?.items == [item])
        #expect(portable.tagAssignments.first?.tags == ["Review"])
    }

    // MARK: - Overlap

    @Test func oneItemBelongsToAsManyCollectionsAsItLikes() throws {
        let model = try makeModel()
        let skill = ToolingItemReference(kind: .skill, identifier: "release-readiness")
        for name in ["Release Kit", "Daily Drivers", "Shared With Team"] {
            #expect(model.createCollection(name: name) != nil)
        }
        for id in ["release-kit", "daily-drivers", "shared-with-team"] {
            #expect(model.setCollectionMembership(true, of: id, for: skill))
        }

        let owners = model.collections(containing: skill).map(\.id)

        // No one-group-per-item rule: overlap is modeled directly rather than
        // by duplicating the item.
        #expect(owners.sorted() == ["daily-drivers", "release-kit", "shared-with-team"])
        #expect(model.collections.allSatisfy { $0.items.count == 1 })
    }

    @Test func removingACollectionDetachesItFromEveryConfiguration() throws {
        let model = try makeModel()
        #expect(model.createCollection(name: "Release Kit") != nil)
        #expect(model.setCollectionInclusion(true, of: "release-kit", inProfile: "local-library"))
        #expect(model.profiles.first?.includedCollections == ["release-kit"])

        #expect(model.deleteCollection(id: "release-kit"))

        #expect(model.collections.isEmpty)
        #expect(model.profiles.first?.includedCollections.isEmpty == true)
        // A dangling reference would fail validation on the next save.
        #expect(model.createCollection(name: "Another Kit") != nil)
    }

    // MARK: - Resolution

    @Test func configurationResolvesOwnItemsInheritanceAndCollectionsWithoutDuplicates() throws {
        let model = try makeModel()
        #expect(model.createCollection(name: "Shared Kit") != nil)
        #expect(model.createCollection(name: "Extra Kit") != nil)
        #expect(
            model.setCollectionMembership(
                id: "shared-kit",
                items: [
                    ToolingItemReference(kind: .plugin, identifier: "shared-plugin"),
                    ToolingItemReference(kind: .mcpServer, identifier: "shared-mcp"),
                    // Also required directly by the parent, so resolution has
                    // a genuine duplicate to collapse.
                    ToolingItemReference(kind: .plugin, identifier: "parent-plugin"),
                    ToolingItemReference(kind: .skill, identifier: "shared-skill"),
                ]))
        #expect(
            model.setCollectionMembership(
                id: "extra-kit",
                items: [
                    ToolingItemReference(kind: .plugin, identifier: "shared-plugin"),
                    ToolingItemReference(kind: .mcpServer, identifier: "extra-mcp"),
                ]))

        #expect(
            model.updateProfile(
                id: "local-library", name: "Local Library", summary: "Parent", scope: .user, projectRoot: nil,
                enabledPlugins: ["parent-plugin"], requiredMCPs: ["parent-mcp"]))
        #expect(model.createProfile(name: "Child", summary: "Child", scope: .user, projectRoot: nil, inheritedFrom: "local-library") != nil)
        #expect(
            model.updateProfile(
                id: "child", name: "Child", summary: "Child", scope: .user, projectRoot: nil,
                enabledPlugins: ["child-plugin"], requiredMCPs: []))
        // The child includes one shelf; the parent includes the other, so the
        // inheritance chain has to carry inclusions too.
        #expect(model.setCollectionInclusion(true, of: "shared-kit", inProfile: "child"))
        #expect(model.setCollectionInclusion(true, of: "extra-kit", inProfile: "local-library"))

        let resolved = try #require(model.effectiveProfile(for: "child"))

        #expect(resolved.enabledPlugins == ["child-plugin", "parent-plugin", "shared-plugin"])
        #expect(resolved.requiredMCPs == ["extra-mcp", "parent-mcp", "shared-mcp"])
        #expect(resolved.requiredSkills == ["shared-skill"])
        #expect(resolved.includedCollections == ["extra-kit", "shared-kit"])
        #expect(Set(resolved.enabledPlugins).count == resolved.enabledPlugins.count)
        // The stored record is untouched; only the resolved view is unioned.
        #expect(model.profiles.first { $0.id == "child" }?.enabledPlugins == ["child-plugin"])
    }

    @Test func inclusionIsDesiredStateAndNeverWritesToAClient() throws {
        let model = try makeModel()
        #expect(model.createCollection(name: "Release Kit") != nil)
        #expect(
            model.setCollectionMembership(
                id: "release-kit", items: [ToolingItemReference(kind: .mcpServer, identifier: "linear")]))

        #expect(model.setCollectionInclusion(true, of: "release-kit", inProfile: "local-library"))

        // Desired state moved; no plan was queued and no operation ran.
        #expect(model.effectiveProfile(for: "local-library")?.requiredMCPs == ["linear"])
        #expect(model.pendingPlan == nil)
        #expect(model.operationReceipts.isEmpty)
        #expect(model.activities.contains { $0.title.contains("Release Kit") })
    }

    @Test func partialCoverageIsReportedInsteadOfAFalseCheckmark() throws {
        let model = try makeModel()
        #expect(model.createCollection(name: "Release Kit") != nil)
        #expect(
            model.setCollectionMembership(
                id: "release-kit",
                items: [
                    ToolingItemReference(kind: .plugin, identifier: "one"),
                    ToolingItemReference(kind: .plugin, identifier: "two"),
                    ToolingItemReference(kind: .plugin, identifier: "three"),
                ]))
        #expect(
            model.updateProfile(
                id: "local-library", name: "Local Library", summary: "Fixture", scope: .user, projectRoot: nil,
                enabledPlugins: ["one"], requiredMCPs: []))

        #expect(model.isCollectionIncluded("release-kit", inProfile: "local-library") == false)
        let coverage = model.collectionCoverage("release-kit", inProfile: "local-library")
        #expect(coverage.covered == 1)
        #expect(coverage.total == 3)
    }

    // MARK: - Tags

    @Test func tagsFilterWithoutChangingAnyDesiredState() throws {
        let model = try makeModel()
        let plugin = ToolingItemReference(kind: .plugin, identifier: "developer-workflows")
        let server = ToolingItemReference(kind: .mcpServer, identifier: "linear")
        #expect(model.createCollection(name: "Release Kit") != nil)
        #expect(model.setCollectionMembership(id: "release-kit", items: [plugin, server]))
        #expect(model.setCollectionInclusion(true, of: "release-kit", inProfile: "local-library"))
        let before = try #require(model.effectiveProfile(for: "local-library"))

        #expect(model.setTags(["Release", "release", "  Release  "], for: [plugin]))

        // Same word three ways is one tag, and tagging moved nothing.
        #expect(model.tags(for: plugin) == ["Release"])
        #expect(model.itemsTagged("RELEASE") == [plugin])
        #expect(model.allTags == ["Release"])
        let after = try #require(model.effectiveProfile(for: "local-library"))
        #expect(after.enabledPlugins == before.enabledPlugins)
        #expect(after.requiredMCPs == before.requiredMCPs)
        #expect(after.includedCollections == before.includedCollections)
        #expect(Set(model.collection(id: "release-kit")?.items ?? []) == [plugin, server])
        #expect(model.pendingPlan == nil)
    }

    @Test func untaggedIsAnAnswerableQuestion() throws {
        let model = try makeModel()
        let tagged = ToolingItemReference(kind: .skill, identifier: "tagged-skill")
        let untagged = ToolingItemReference(kind: .skill, identifier: "untagged-skill")
        #expect(model.setTags(["Review"], for: [tagged]))

        #expect(model.tags(for: tagged) == ["Review"])
        #expect(model.tags(for: untagged).isEmpty)
        #expect(model.itemsTagged("Review") == [tagged])
    }

    @Test func bulkTagEditingLeavesUnrelatedTagsAlone() throws {
        let model = try makeModel()
        let first = ToolingItemReference(kind: .plugin, identifier: "first")
        let second = ToolingItemReference(kind: .plugin, identifier: "second")
        #expect(model.setTags(["Keep", "Drop"], for: [first]))
        #expect(model.setTags(["Drop"], for: [second]))

        #expect(model.applyTagEdits(adding: ["Added"], removing: ["Drop"], to: [first, second]))

        #expect(model.tags(for: first) == ["Added", "Keep"])
        #expect(model.tags(for: second) == ["Added"])
    }

    @Test func clearingEveryTagRemovesTheAssignmentRatherThanLeavingAnEmptyOne() throws {
        let model = try makeModel()
        let item = ToolingItemReference(kind: .skill, identifier: "release-readiness")
        #expect(model.setTags(["Release"], for: [item]))

        #expect(model.setTags([], for: [item]))

        #expect(model.tagAssignments.isEmpty)
        #expect(model.allTags.isEmpty)
    }

    // MARK: - Export

    /// The workspace validator already refuses to store a credential-bearing
    /// endpoint, so this feeds the exporter hostile input directly rather than
    /// through the store — the exporter must not rely on that upstream guard.
    @Test func exportedCollectionCarriesNoSecretValue() throws {
        let server = MCPServer(
            id: "linear",
            name: "Linear",
            summary: "Issue tracking",
            endpoint: "https://deploy:hunter2@linear.example.com/mcp?api_key=REALLYSECRETVALUE",
            transport: .http,
            authentication: "Bearer sk-live-0123456789abcdefghij",
            scope: ToolingScope.user.displayName,
            clients: [],
            repairCommand: "claude mcp add linear --token sk-live-0123456789abcdefghij",
            secretNames: ["LINEAR_API_KEY"]
        )
        let reference = ToolingItemReference(kind: .mcpServer, identifier: "linear")
        let collection = ToolingCollection(id: "release-kit", name: "Release Kit", items: [reference])

        let document = CollectionExporter.document(
            for: collection, skills: [], plugins: [], mcpServers: [server], tags: [reference: ["Release"]])
        let data = try CollectionExporter.encode(document)
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(!text.contains("REALLYSECRETVALUE"))
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("sk-live-0123456789abcdefghij"))
        #expect(!SensitiveValueRedactor.containsCredentialValue(in: text))
        // The repair command could carry a token, so it never leaves at all.
        #expect(!text.contains("claude mcp add"))
        // The name of the credential still travels, because the recipient has
        // to know what they need to go and set up themselves.
        #expect(text.contains("LINEAR_API_KEY"))
        #expect(text.contains("Credentials are not included in shared collections for security reasons."))

        let decoded = try JSONDecoder.iso8601.decode(CollectionExportDocument.self, from: data)
        #expect(decoded.items.count == 1)
        #expect(decoded.items.first?.requiredCredentialNames == ["LINEAR_API_KEY"])
        #expect(decoded.items.first?.destination?.contains("REALLYSECRETVALUE") == false)
        #expect(decoded.items.first?.tags == ["Release"])
    }

    @Test func exportedCollectionCarriesNoMachineLocalLocations() throws {
        let skill = Skill(
            id: "portable-skill",
            name: "Portable Skill",
            displayName: "Portable Skill",
            summary: "Generated from /Users/alice/Secret Project/notes.md",
            bundle: "/Users/alice/Library/Application Support/Agent Tooling/package",
            scope: ToolingScope.project.displayName,
            owned: true,
            triggers: [],
            negativeTrigger: "",
            files: ["SKILL.md"],
            clients: [],
            validationCount: 0,
            projectRoot: "/Users/alice/Secret Project"
        )
        let plugin = Plugin(
            id: "portable-plugin",
            name: "Portable Plugin",
            summary: "Loaded from file:///Users/alice/private/plugin.json",
            source: "/Applications/Private Tool.app/Contents/Resources/plugin",
            scope: ToolingScope.user.displayName,
            revision: "local",
            skills: [],
            profiles: [],
            clients: [],
            installed: true
        )
        let stdio = MCPServer(
            id: "local-stdio",
            name: "Local stdio",
            summary: "Uses ~/.config/private.json",
            endpoint: "/Users/alice/bin/private-server --config /Users/alice/.config/private.json",
            transport: .stdio,
            authentication: "none",
            scope: ToolingScope.project.displayName,
            projectRoot: "/Users/alice/Secret Project",
            clients: []
        )
        let references = [
            ToolingItemReference(kind: .skill, identifier: skill.id),
            ToolingItemReference(kind: .plugin, identifier: plugin.id),
            ToolingItemReference(kind: .mcpServer, identifier: stdio.id),
        ]
        let document = CollectionExporter.document(
            for: ToolingCollection(
                id: "portable-kit",
                name: "Portable Kit",
                summary: "Do not reveal path:/Users/alice/Secret Project",
                items: references
            ),
            skills: [skill],
            plugins: [plugin],
            mcpServers: [stdio]
        )
        let data = try CollectionExporter.encode(document)
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(!text.contains("/Users/alice"))
        #expect(!text.contains("file://"))
        #expect(!text.contains("~/.config"))
        #expect(!text.contains("/Applications/Private Tool.app"))
        #expect(!text.contains("Secret Project"))
        #expect(!text.contains("notes.md"))
        #expect(!text.contains("private/plugin.json"))
        #expect(text.contains("[local location omitted]"))
        #expect(document.items.first(where: { $0.kind == .plugin })?.source == nil)
        #expect(document.items.first(where: { $0.kind == .mcpServer })?.destination == nil)
        #expect(Set(document.items.map(\.identifier)) == Set(["portable-skill", "portable-plugin", "local-stdio"]))
    }

    @Test func exportKeepsSanitizedPublicRemoteIdentitiesAndOmitsLocalHTTP() throws {
        let plugin = Plugin(
            id: "remote-plugin",
            name: "Remote Plugin",
            summary: "Public package",
            source: "https://github.com/acme/agent-plugin?access_token=secret",
            scope: ToolingScope.user.displayName,
            revision: "main",
            skills: [],
            profiles: [],
            clients: [],
            installed: true
        )
        let remote = MCPServer(
            id: "remote-mcp", name: "Remote", summary: "Remote endpoint",
            endpoint: "https://user:pass@mcp.example.com/v1/tools?api_key=secret#private", transport: .http,
            authentication: "OAuth", scope: ToolingScope.user.displayName, clients: [])
        let local = MCPServer(
            id: "loopback-mcp", name: "Loopback", summary: "Local endpoint",
            endpoint: "http://127.0.0.1:8765/mcp", transport: .http,
            authentication: "none", scope: ToolingScope.user.displayName, clients: [])
        let localIPv6 = MCPServer(
            id: "loopback-ipv6-mcp", name: "IPv6 Loopback", summary: "Local endpoint",
            endpoint: "http://[::1]:8765/mcp", transport: .http,
            authentication: "none", scope: ToolingScope.user.displayName, clients: [])
        let localTrailingDot = MCPServer(
            id: "localhost-dot-mcp", name: "Localhost", summary: "Local endpoint",
            endpoint: "http://localhost.:8765/mcp", transport: .http,
            authentication: "none", scope: ToolingScope.user.displayName, clients: [])
        let abbreviatedLoopback = MCPServer(
            id: "abbreviated-loopback-mcp", name: "Abbreviated loopback", summary: "Local endpoint",
            endpoint: "http://127.1:8765/mcp", transport: .http,
            authentication: "none", scope: ToolingScope.user.displayName, clients: [])
        let publicIPv6 = MCPServer(
            id: "public-ipv6-mcp", name: "Public IPv6", summary: "Remote endpoint",
            endpoint: "https://[2606:4700:4700::1111]/mcp", transport: .http,
            authentication: "none", scope: ToolingScope.user.displayName, clients: [])
        let portablePlugin = Plugin(
            id: "personal@agent-tooling", name: "Personal", summary: "Portable package",
            source: "personal@agent-tooling", scope: ToolingScope.user.displayName,
            revision: "main", skills: [], profiles: [], clients: [], installed: true)
        let relativePlugin = Plugin(
            id: "relative-plugin", name: "Relative", summary: "Local relative package",
            source: "plugins/private-package", scope: ToolingScope.user.displayName,
            revision: "local", skills: [], profiles: [], clients: [], installed: true)
        let references = [
            ToolingItemReference(kind: .plugin, identifier: plugin.id),
            ToolingItemReference(kind: .plugin, identifier: portablePlugin.id),
            ToolingItemReference(kind: .plugin, identifier: relativePlugin.id),
            ToolingItemReference(kind: .mcpServer, identifier: remote.id),
            ToolingItemReference(kind: .mcpServer, identifier: local.id),
            ToolingItemReference(kind: .mcpServer, identifier: localIPv6.id),
            ToolingItemReference(kind: .mcpServer, identifier: localTrailingDot.id),
            ToolingItemReference(kind: .mcpServer, identifier: abbreviatedLoopback.id),
            ToolingItemReference(kind: .mcpServer, identifier: publicIPv6.id),
        ]
        let document = CollectionExporter.document(
            for: ToolingCollection(id: "remote-kit", name: "Remote Kit", items: references),
            skills: [], plugins: [plugin, portablePlugin, relativePlugin],
            mcpServers: [remote, local, localIPv6, localTrailingDot, abbreviatedLoopback, publicIPv6])

        #expect(document.items.first(where: { $0.identifier == plugin.id })?.source == "https://github.com/acme/agent-plugin")
        #expect(document.items.first(where: { $0.identifier == portablePlugin.id })?.source == "personal@agent-tooling")
        #expect(document.items.first(where: { $0.identifier == relativePlugin.id })?.source == nil)
        #expect(document.items.first(where: { $0.identifier == remote.id })?.destination == "https://mcp.example.com/v1/tools")
        #expect(document.items.first(where: { $0.identifier == local.id })?.destination == nil)
        #expect(document.items.first(where: { $0.identifier == localIPv6.id })?.destination == nil)
        #expect(document.items.first(where: { $0.identifier == localTrailingDot.id })?.destination == nil)
        #expect(document.items.first(where: { $0.identifier == abbreviatedLoopback.id })?.destination == nil)
        #expect(document.items.first(where: { $0.identifier == publicIPv6.id })?.destination == "https://[2606:4700:4700::1111]/mcp")
        _ = try CollectionExporter.encode(document)
    }

    @Test func exportFileNameDoesNotEchoALocalCollectionName() {
        let collection = ToolingCollection(
            id: "/Users/alice/private-kit",
            name: "/Users/alice/Secret Project"
        )
        let name = CollectionExporter.suggestedFileName(for: collection)

        #expect(!name.contains("alice"))
        #expect(!name.contains("Secret"))
        #expect(name.hasSuffix("-collection.json"))
    }

    @Test func legacyExportShapeStillDecodesButCannotBeResharedWithLocalPaths() throws {
        let legacy = CollectionExportDocument(
            exportedAt: Date(timeIntervalSince1970: 0),
            name: "Legacy",
            items: [
                ExportedToolingItem(
                    kind: .plugin,
                    identifier: "legacy-plugin",
                    name: "Legacy Plugin",
                    source: "/Users/alice/legacy/plugin"
                )
            ]
        )
        let legacyData = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(CollectionExportDocument.self, from: legacyData)

        #expect(decoded.items.first?.source == "/Users/alice/legacy/plugin")
        #expect(throws: CollectionExportError.self) {
            try CollectionExporter.encode(decoded)
        }
    }

    @Test func exportThroughTheModelKeepsTheSameGuarantee() throws {
        let root = try temporaryDirectory()
        let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        let server = MCPServer(
            id: "linear", name: "Linear", summary: "Issue tracking", endpoint: "https://linear.example.com/mcp", transport: .http,
            authentication: "OAuth", scope: ToolingScope.user.displayName, clients: [], secretNames: ["LINEAR_API_KEY"])
        let store = try WorkspaceStore(rootURL: workspace)
        try store.saveWorkspaceSnapshot(WorkspaceSnapshot(mcpServers: [server]))
        let model = try makeModel(at: workspace, home: root)
        #expect(model.createCollection(name: "Release Kit") != nil)
        #expect(
            model.setCollectionMembership(
                id: "release-kit", items: [ToolingItemReference(kind: .mcpServer, identifier: "linear")]))

        let text = try #require(String(data: try model.collectionExportData(id: "release-kit"), encoding: .utf8))

        #expect(!SensitiveValueRedactor.containsCredentialValue(in: text))
        #expect(text.contains(CollectionExportDocument.securityNote))
        #expect(text.contains("LINEAR_API_KEY"))
    }

    @Test func exportWritesAFileAndNamesItInActivity() throws {
        let root = try temporaryDirectory()
        let model = try makeModel(at: root.appending(path: "workspace", directoryHint: .isDirectory), home: root)
        #expect(model.createCollection(name: "Release Kit") != nil)
        let destination = root.appending(path: "release-kit-collection.json", directoryHint: .notDirectory)

        #expect(model.exportCollection(id: "release-kit", to: destination))

        #expect(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        #expect(model.activities.contains { $0.title == "Release Kit collection exported" })
        #expect(
            CollectionExporter.suggestedFileName(for: ToolingCollection(id: "release-kit", name: "Release Kit"))
                == "release-kit-collection.json")
    }

    @Test func aMissingItemIsNamedRatherThanSilentlyDropped() throws {
        let collection = ToolingCollection(
            id: "release-kit",
            name: "Release Kit",
            items: [ToolingItemReference(kind: .plugin, identifier: "not-installed")]
        )

        let document = CollectionExporter.document(for: collection, skills: [], plugins: [], mcpServers: [])

        #expect(document.items.isEmpty)
        #expect(document.unresolvedItems.map(\.identifier) == ["not-installed"])
    }

    // MARK: - Validation

    @Test func aConfigurationCannotIncludeACollectionThatDoesNotExist() throws {
        let profile = ToolingProfile(
            id: "team", name: "Team", summary: "Fixture", checks: [], enabledPlugins: [], requiredMCPs: [],
            includedCollections: ["missing-kit"])
        let snapshot = WorkspaceSnapshot(profiles: [profile], activeProfileID: "team")

        #expect(throws: WorkspaceSnapshotValidationError.self) {
            try WorkspaceSnapshotValidator.validate(snapshot, mode: .localState)
        }
    }

    @Test func aCollectionCannotListTheSameItemTwice() throws {
        let item = ToolingItemReference(kind: .skill, identifier: "release-readiness")
        let snapshot = WorkspaceSnapshot(collections: [ToolingCollection(id: "kit", name: "Kit", items: [item, item])])

        #expect(throws: WorkspaceSnapshotValidationError.self) {
            try WorkspaceSnapshotValidator.validate(snapshot, mode: .localState)
        }
    }

    @Test func tagNormalizationRejectsUnusableInput() {
        #expect(ToolingTag.normalized("  Release  Kit ") == "Release Kit")
        #expect(ToolingTag.normalized("   ") == nil)
        #expect(ToolingTag.normalized(String(repeating: "a", count: ToolingTag.maximumLength + 1)) == nil)
        #expect(ToolingTag.normalizedList(["b", "A", "a", " B "]) == ["A", "b"])
        #expect(ToolingTag.matches("release", "RELEASE"))
    }

    // MARK: - Helpers

    private func makeModel() throws -> AppModel {
        let root = try temporaryDirectory()
        return try makeModel(at: root.appending(path: "workspace", directoryHint: .isDirectory), home: root)
    }

    private func makeModel(at workspace: URL, home: URL) throws -> AppModel {
        try AppModel(store: try WorkspaceStore(rootURL: workspace), runner: SilentRunner(), homeURL: home)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "agent-tooling-collections-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

extension JSONDecoder {
    fileprivate static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

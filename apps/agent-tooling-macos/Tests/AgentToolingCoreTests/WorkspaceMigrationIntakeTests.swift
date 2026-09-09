import Foundation
import Testing
@testable import AgentToolingCore

struct WorkspaceMigrationIntakeTests {
    @Test func recommendsOneWholeNativePackageAndNeverExtractsItsChild() async throws {
        let snapshot = WorkspaceSnapshot(
            skills: [skill("browser-search", owned: true)],
            plugins: [plugin("browser", skills: ["browser-search"])],
            targetObservations: [observation(
                client: .codex,
                pluginID: "browser",
                packageRoot: "/private/browser-package",
                skills: ["browser-search"]
            )]
        )

        let intake = try await review(snapshot)

        #expect(intake.issues.isEmpty)
        #expect(intake.choices.count == 1)
        let choice = try #require(intake.choices.first)
        #expect(choice.legacy == key(.plugin, "browser"))
        guard case let .nativePackage(routes, children) = choice.strategy else {
            Issue.record("The plugin should retain native-package ownership.")
            return
        }
        #expect(routes == [.init(client: .codex, externalPluginID: "browser")])
        #expect(children.map(\.legacy) == [key(.skill, "browser-search")])
        #expect(children.map(\.packageRelativePath) == ["skills/browser-search"])
        #expect(!intake.choices.contains { $0.legacy == key(.skill, "browser-search") })
    }

    @Test func keepsObservedNativeMCPAsOneWholePluginChildAcrossClients() async throws {
        let snapshot = WorkspaceSnapshot(
            mcpServers: [mcp("browser-mcp")],
            plugins: [plugin("browser", skills: [])],
            targetObservations: [
                observation(client: .claude, pluginID: "browser", packageRoot: "/private/claude-browser", skills: [], mcpServerIDs: ["browser-mcp"]),
                observation(client: .codex, pluginID: "browser", packageRoot: "/private/codex-browser", skills: [], mcpServerIDs: ["browser-mcp"]),
            ]
        )

        let intake = try await review(snapshot)

        #expect(intake.issues.isEmpty)
        let choice = try #require(intake.choices.first)
        guard case let .nativePackage(routes, children) = choice.strategy else {
            Issue.record("The native MCP must remain inside its plugin package.")
            return
        }
        #expect(Set(routes.map(\.client)) == [.claude, .codex])
        let child = try #require(children.first { $0.legacy == key(.mcpServer, "browser-mcp") })
        #expect(child.packageRelativePath == nil)
        #expect(!intake.choices.contains { $0.legacy == key(.mcpServer, "browser-mcp") })
    }

    @Test func nativeMCPChildBindingDoesNotCreateAStandalonePlacement() async throws {
        let snapshot = WorkspaceSnapshot(
            mcpServers: [mcp("browser-mcp")],
            plugins: [plugin("browser", skills: [])],
            profiles: [profile("active", targetBindings: [
                .init(item: .init(kind: .mcpServer, identifier: "browser-mcp"), client: .codex, enabled: true),
            ])],
            targetObservations: [observation(
                client: .codex, pluginID: "browser", packageRoot: "/private/browser", skills: [], mcpServerIDs: ["browser-mcp"]
            )],
            activeProfileID: "active",
            preferences: .init(enabledClients: [.codex])
        )

        let intake = try await review(snapshot)

        #expect(intake.issues.isEmpty)
        #expect(try intake.nativePlacements(workspaceID: workspaceID).isEmpty)
        #expect(!intake.choices.contains { $0.legacy == key(.mcpServer, "browser-mcp") })
    }

    @Test func missingNativeMCPRecordBlocksTheWholePlugin() async throws {
        let snapshot = WorkspaceSnapshot(
            plugins: [plugin("browser", skills: [])],
            targetObservations: [observation(
                client: .codex, pluginID: "browser", packageRoot: "/private/browser", skills: [], mcpServerIDs: ["missing-mcp"]
            )]
        )

        let intake = try await review(snapshot)

        #expect(intake.choices.isEmpty)
        #expect(intake.issues == [.init(
            legacy: key(.plugin, "browser"), displayName: "Browser", reason: .pluginContents
        )])
    }

    @Test func nativeMCPClaimedByTwoPluginsLeavesBothPackagesUnresolved() async throws {
        let snapshot = WorkspaceSnapshot(
            mcpServers: [mcp("shared-mcp")],
            plugins: [plugin("one", skills: []), plugin("two", skills: [])],
            targetObservations: [
                observation(client: .codex, pluginID: "one", packageRoot: "/private/one", skills: [], mcpServerIDs: ["shared-mcp"]),
                observation(client: .claude, pluginID: "two", packageRoot: "/private/two", skills: [], mcpServerIDs: ["shared-mcp"]),
            ]
        )

        let intake = try await review(snapshot)

        #expect(intake.choices.isEmpty)
        #expect(Set(intake.issues.map(\.legacy)) == [key(.plugin, "one"), key(.plugin, "two")])
        #expect(intake.issues.allSatisfy { $0.reason == .pluginContents })
    }

    @Test func conflictingClientRelativePathsKeepTheWholePluginUnresolved() async throws {
        let snapshot = WorkspaceSnapshot(
            skills: [skill("child")],
            plugins: [plugin("native", skills: ["child"])],
            targetObservations: [
                observation(client: .claude, pluginID: "native", packageRoot: "/private/claude-package", skills: ["child"]),
                observation(client: .codex, pluginID: "native", packageRoot: "/private/codex-package", skills: ["child"], relativePath: "different/child"),
            ]
        )

        let intake = try await review(snapshot)

        #expect(intake.choices.isEmpty)
        #expect(intake.issues == [.init(
            legacy: key(.plugin, "native"), displayName: "Native", reason: .pluginContents
        )])
    }

    @Test func displayAndPublisherLabelsDoNotCreateOwnership() async throws {
        let standalone = skill("official-looking", owned: false, displayName: "OpenAI Official Skill", bundle: "OpenAI Marketplace")
        let intake = try await review(.init(skills: [standalone]))

        #expect(intake.issues.isEmpty)
        let choice = try #require(intake.choices.first)
        #expect(choice.legacy == key(.skill, "official-looking"))
        #expect(choice.strategy.kind == .trackedOnly)
    }

    @Test func exactSingleUpstreamInstallationGetsARecommendationButAmbiguityDoesNot() async throws {
        var exact = skill("exact")
        exact.repositoryBinding = try binding(paths: ["/private/exact": hash("a")])
        let exactIntake = try await review(.init(skills: [exact]))
        let exactChoice = try #require(exactIntake.choices.first)
        guard case let .centralUpstream(directory, _, _) = exactChoice.strategy else {
            Issue.record("One fingerprinted directory should be proposed as upstream.")
            return
        }
        #expect(directory.path == "/private/exact")

        var ambiguous = skill("ambiguous")
        ambiguous.repositoryBinding = try binding(paths: [
            "/private/one": hash("b"), "/private/two": hash("c"),
        ])
        let ambiguousIntake = try await review(.init(skills: [ambiguous]))
        #expect(ambiguousIntake.choices.isEmpty)
        #expect(ambiguousIntake.issues == [.init(
            legacy: key(.skill, "ambiguous"), displayName: "Ambiguous", reason: .upstreamInstallation
        )])
    }

    @Test func upstreamRecommendationsAreStableForTheSameWorkspaceAndCheckpoint() async throws {
        var upstream = skill("stable-upstream")
        upstream.repositoryBinding = try binding(paths: ["/private/stable": hash("a")])
        let snapshot = WorkspaceSnapshot(skills: [upstream])

        let first = try await review(snapshot)
        let second = try await review(snapshot)

        let firstIDs = try #require(upstreamIDs(first))
        let secondIDs = try #require(upstreamIDs(second))
        #expect(firstIDs.0 == secondIDs.0)
        #expect(firstIDs.1 == secondIDs.1)
    }

    @Test func explicitEnabledAndDisabledNativeBindingsBothReceiveObservedUserPlacements() async throws {
        let bindings: [OnboardingTargetBinding] = [
            .init(item: .init(kind: .plugin, identifier: "native"), client: .claude, enabled: true),
            .init(item: .init(kind: .plugin, identifier: "native"), client: .codex, enabled: false),
        ]
        let snapshot = WorkspaceSnapshot(
            skills: [skill("child")],
            plugins: [plugin("native", skills: ["child"])],
            profiles: [profile("active", targetBindings: bindings)],
            targetObservations: [
                observation(client: .claude, pluginID: "native", packageRoot: "/private/claude", skills: ["child"]),
                observation(client: .codex, pluginID: "native", packageRoot: "/private/codex", skills: ["child"]),
            ],
            activeProfileID: "active",
            preferences: .init(enabledClients: [.claude, .codex])
        )

        let intake = try await review(snapshot)
        let placements = try intake.nativePlacements(workspaceID: workspaceID)
        let nativeIdentity = try #require(try WorkspaceMigrationIdentity.mapping(
            keys: [key(.plugin, "native")], workspaceID: workspaceID
        ).first)
        let nativeID = ArtifactID(nativeIdentity.objectID.rawValue)

        #expect(Set(placements) == Set([
            .init(artifactID: nativeID, client: .claude, scope: .user),
            .init(artifactID: nativeID, client: .codex, scope: .user),
        ]))
    }

    @Test func noExplicitBindingCreatesNoNativePlacement() async throws {
        let snapshot = WorkspaceSnapshot(
            skills: [skill("child")],
            plugins: [plugin("native", skills: ["child"])],
            profiles: [profile("active", targetBindings: nil)],
            targetObservations: [observation(
                client: .codex, pluginID: "native", packageRoot: "/private/native", skills: ["child"]
            )],
            activeProfileID: "active"
        )

        let intake = try await review(snapshot)
        #expect(try intake.nativePlacements(workspaceID: workspaceID).isEmpty)
    }

    @Test func unknownOfficialStandaloneRemainsTracked() async throws {
        let standalone = skill("unknown", owned: false, displayName: "Official catalog skill", bundle: "Official publisher")
        let intake = try await review(.init(skills: [standalone]))

        #expect(intake.issues.isEmpty)
        #expect(intake.choices.count == 1)
        #expect(intake.choices[0].strategy.kind == .trackedOnly)
    }

    @Test func malformedAndDuplicateInventoryIsRejectedWithoutCrashing() async throws {
        let duplicate = WorkspaceSnapshot(skills: [skill("same"), skill("same", displayName: "Same again")])

        await #expect(throws: WorkspaceSnapshotValidationError.self) {
            try await review(duplicate, persistNormalized: false)
        }
    }

    private let workspaceID = WorkspaceObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000abc")!)

    private func upstreamIDs(_ intake: WorkspaceMigrationIntake) -> (WorkspaceObjectID, WorkspaceObjectID)? {
        guard let choice = intake.choices.first,
              case let .centralUpstream(_, sourceID, subscriptionID) = choice.strategy else { return nil }
        return (sourceID, subscriptionID)
    }

    private func profile(_ id: String, targetBindings: [OnboardingTargetBinding]?) -> ToolingProfile {
        .init(
            id: id, name: id.capitalized, summary: "Fixture configuration",
            checks: [], enabledPlugins: [], requiredMCPs: [], targetBindings: targetBindings
        )
    }

    private func review(_ snapshot: WorkspaceSnapshot, persistNormalized: Bool = true) async throws -> WorkspaceMigrationIntake {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "migration-intake-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(rootURL: root)
        if persistNormalized {
            try store.saveWorkspaceSnapshot(snapshot)
        } else {
            // The checkpoint reader intentionally retains legacy raw rows before
            // later candidate validation decides whether the graph is usable.
            try store.save(snapshot, for: "workspace.snapshot")
        }
        let checkpoint = try await WorkspaceLegacyCheckpoint.capture(databaseURL: store.databaseURL)
        return try WorkspaceMigrationIntake.review(checkpoint: checkpoint, workspaceID: workspaceID)
    }

    private func skill(
        _ id: String,
        owned: Bool = false,
        displayName: String? = nil,
        bundle: String = "standalone"
    ) -> Skill {
        .init(
            id: id,
            name: id,
            displayName: displayName ?? id.capitalized,
            summary: "Fixture skill",
            bundle: bundle,
            scope: "This Mac",
            owned: owned,
            triggers: [],
            negativeTrigger: "",
            files: ["SKILL.md"],
            clients: [],
            validationCount: 0
        )
    }

    private func mcp(_ id: String) -> MCPServer {
        .init(
            id: id,
            name: id.capitalized,
            summary: "Observed through a native plugin",
            endpoint: "https://example.invalid/\(id)",
            transport: .http,
            authentication: "None",
            scope: "This Mac",
            clients: [],
            definitionOrigin: .observed
        )
    }

    private func plugin(_ id: String, skills: [String]) -> Plugin {
        .init(
            id: id,
            name: id.capitalized,
            summary: "Fixture native package",
            source: "Catalog label only",
            scope: "This Mac",
            revision: "current",
            skills: skills,
            profiles: [],
            clients: [],
            installed: true
        )
    }

    private func observation(
        client: ClientKind,
        pluginID: String,
        packageRoot: String,
        skills: [String],
        relativePath: String? = nil,
        mcpServerIDs: [String] = []
    ) -> TargetObservation {
        let metadata = Dictionary(uniqueKeysWithValues: skills.map { id in
            let relative = relativePath ?? "skills/\(id)"
            return (id, ObservedSkillMetadata(
                path: "\(packageRoot)/\(relative)/SKILL.md",
                source: "Display label only",
                providerPluginID: pluginID
            ))
        })
        return .init(
            surface: client == .claude ? .claudeCode : .codexCLI,
            installed: true,
            commandAvailable: true,
            discoveredSkills: skills,
            discoveredPlugins: [pluginID],
            skillMetadata: metadata,
            pluginMetadata: [pluginID: .init(
                name: "Publisher display label",
                source: packageRoot,
                scope: "This Mac",
                enabled: true,
                skillIDs: skills,
                mcpServerIDs: mcpServerIDs
            )],
            capabilities: .init(
                supportsPluginInstall: true,
                supportsProjectScope: true,
                supportsLocalMarketplace: true,
                supportsMCPAuthentication: false,
                supportsConnectorDiscovery: false,
                requiresNewSession: false,
                requiresRestart: false,
                supportsMachineReadableOutput: true
            ),
            lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func binding(paths: [String: String]) throws -> SkillRepositoryBinding {
        var binding = try SkillRepositoryBinding(
            repositoryURL: "https://github.com/example/repository",
            ref: "main",
            subdirectory: "skills/example",
            installedFingerprints: paths
        )
        binding.installedRevision = String(repeating: "d", count: 40)
        return binding
    }

    private func hash(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func key(_ domain: LegacyReferenceDomain, _ identifier: String) -> LegacyReferenceKey {
        .init(domain: domain, identifier: identifier)
    }
}

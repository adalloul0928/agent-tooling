import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingCore

/// A later check of this Mac catches the library up with what a client gained
/// since the first run, by the first run's own rules — and never by taking
/// anything away or changing a row that was already here.
@Suite("Observation reconciliation")
struct WorkspaceObservationReconciliationTests {
    // MARK: - What a check adds

    @Test func aPackagesNewMembersJoinItAsItsOwnWithTheirPlacesInside() throws {
        // The package landed on the first run; its skills did not, because the
        // client's tool could not be reached then and disk reading names a
        // package but not what is inside it.
        let packageID = ArtifactID()
        let document = try Fixture.document(artifacts: [
            .init(
                identity: .init(id: packageID, kind: .nativePlugin, displayName: "Core"),
                authority: .nativeOwned, declaredName: "core@aim",
                nativeRoutes: [.init(client: .claude, externalPluginID: "core@aim")])
        ])
        let observation = Fixture.observation(
            .claudeCode, skills: ["core:brazil", "core:wiki-edit"], plugins: ["core@aim"],
            memberships: ["core:brazil": "core@aim", "core:wiki-edit": "core@aim"])
        let inventory = ScannedInventory(
            skills: [Fixture.skill("core:brazil"), Fixture.skill("core:wiki-edit")], mcpServers: [],
            plugins: [Fixture.plugin("core@aim", members: ["core:brazil", "core:wiki-edit"])])

        let plan = WorkspaceObservationReconciliation.plan(
            document: document, observations: [observation], inventory: inventory)

        #expect(plan.additions.count == 2)
        #expect(plan.skipped.isEmpty, "\(plan.skipped)")
        for member in plan.additions {
            #expect(member.identity.kind == .skill)
            #expect(member.identity.parentPackageID == packageID)
            // The package owns it, so the member is the package's, and says
            // where it lives inside it.
            #expect(member.authority == .nativeOwned)
            #expect(member.nativeRoutes.isEmpty)
        }
        #expect(plan.additions.map(\.packageRelativePath) == ["skills/brazil", "skills/wiki-edit"])
        #expect(plan.additions.map(\.declaredName) == ["core:brazil", "core:wiki-edit"])
        // The document the plan lands in is valid: a member has its parent and
        // its path.
        var applied = document
        _ = try WorkspaceObservationReconciliationCommand(expectedRevisionID: document.revision.id, plan: plan)
            .apply(to: &applied)
        try applied.validateStructure()
    }

    @Test func aNewPackageAndAStandaloneSkillAreRecordedTheWayAFirstRunWould() throws {
        let document = try Fixture.document(artifacts: [])
        let observation = Fixture.observation(
            .codexCLI, skills: ["browse", "reviewer"], plugins: ["browser"], memberships: ["browse": "browser"])
        let inventory = ScannedInventory(
            skills: [Fixture.skill("browse"), Fixture.skill("reviewer")], mcpServers: [Fixture.server("git")],
            plugins: [Fixture.plugin("browser", members: ["browse"])])

        let plan = WorkspaceObservationReconciliation.plan(
            document: document, observations: [observation], inventory: inventory)

        let package = try #require(plan.additions.first { $0.identity.kind == .nativePlugin })
        let member = try #require(plan.additions.first { $0.declaredName == "browse" })
        let standalone = try #require(plan.additions.first { $0.declaredName == "reviewer" })
        let server = try #require(plan.additions.first { $0.identity.kind == .mcpServer })
        // A client installed it, so the client owns it and keeps owning it.
        #expect(package.authority == .nativeOwned)
        #expect(package.nativeRoutes == [.init(client: .codex, externalPluginID: "browser")])
        #expect(member.identity.parentPackageID == package.identity.id)
        #expect(member.authority == .nativeOwned)
        // Nothing becomes ours from a scan.
        #expect(standalone.authority == .trackedOnly)
        #expect(standalone.identity.parentPackageID == nil)
        #expect(server.authority == .trackedOnly)
        // Packages come before their members, so the write can land in order.
        let packageIndex = try #require(plan.additions.firstIndex(of: package))
        let memberIndex = try #require(plan.additions.firstIndex(of: member))
        #expect(packageIndex < memberIndex)
    }

    @Test func aStandaloneSkillObservedAgainIsPlannedOnce() throws {
        let document = try Fixture.document(artifacts: [])
        let observations = [
            Fixture.observation(.claudeCode, skills: ["docx"], plugins: []),
            Fixture.observation(.codexCLI, skills: ["docx"], plugins: []),
            Fixture.observation(.kiroCLI, skills: ["docx"], plugins: []),
        ]
        let inventory = ScannedInventory(skills: [Fixture.skill("docx")], mcpServers: [], plugins: [])

        let plan = WorkspaceObservationReconciliation.plan(
            document: document, observations: observations, inventory: inventory)

        // One skill in three apps is one row; where it was found is the mark
        // beside it, not a second row.
        #expect(plan.additions.count == 1)
        #expect(plan.additions.first?.declaredName == "docx")
    }

    // MARK: - What a check leaves alone

    @Test func rowsAlreadyHereAreNeverChangedAndASecondPlanIsEmpty() throws {
        let mine = ArtifactID()
        let tracked = ArtifactID()
        let document = try Fixture.document(artifacts: [
            // Ours, with content: a scan must never touch it, even though it
            // sees a skill of the same name on disk.
            .init(
                identity: .init(id: mine, kind: .skill, displayName: "Docx"), authority: .centralPersonal,
                declaredName: "docx", contentDigest: .init(value: String(repeating: "a", count: 64))),
            .init(
                identity: .init(id: tracked, kind: .skill, displayName: "Reviewer"), authority: .trackedOnly,
                declaredName: "reviewer"),
        ])
        let observation = Fixture.observation(.claudeCode, skills: ["docx", "reviewer", "new-one"], plugins: [])
        let inventory = ScannedInventory(
            skills: [Fixture.skill("docx"), Fixture.skill("reviewer"), Fixture.skill("new-one")], mcpServers: [], plugins: [])

        let plan = WorkspaceObservationReconciliation.plan(
            document: document, observations: [observation], inventory: inventory)
        #expect(plan.additions.map(\.declaredName) == ["new-one"])

        var applied = document
        _ = try WorkspaceObservationReconciliationCommand(expectedRevisionID: document.revision.id, plan: plan)
            .apply(to: &applied)
        for id in [mine, tracked] {
            #expect(applied.artifacts.first { $0.identity.id == id } == document.artifacts.first { $0.identity.id == id })
        }

        // With the library caught up, the same check has nothing to add.
        let again = WorkspaceObservationReconciliation.plan(
            document: applied, observations: [observation], inventory: inventory)
        #expect(again.isEmpty)
    }

    @Test func aSkillThatDisappearedIsNotTakenAway() throws {
        let document = try Fixture.document(artifacts: [
            .init(
                identity: .init(id: ArtifactID(), kind: .skill, displayName: "Reviewer"), authority: .trackedOnly,
                declaredName: "reviewer")
        ])
        let observation = Fixture.observation(.claudeCode, skills: [], plugins: [])

        let plan = WorkspaceObservationReconciliation.plan(
            document: document, observations: [observation],
            inventory: ScannedInventory(skills: [], mcpServers: [], plugins: []))

        // A scan that did not see it this time is not a person deciding it
        // should go.
        #expect(plan.isEmpty)
    }

    @Test func aPackageSomebodyRemovedIsNotPutBackAndNeitherAreItsMembers() throws {
        let document = try Fixture.document(
            artifacts: [], tombstoneAliases: [NativePackageAdoption.pluginAlias(client: .claude, externalPluginID: "core@aim")])
        let observation = Fixture.observation(
            .claudeCode, skills: ["core:brazil"], plugins: ["core@aim"], memberships: ["core:brazil": "core@aim"])
        let inventory = ScannedInventory(
            skills: [Fixture.skill("core:brazil")], mcpServers: [],
            plugins: [Fixture.plugin("core@aim", members: ["core:brazil"])])

        let plan = WorkspaceObservationReconciliation.plan(
            document: document, observations: [observation], inventory: inventory)

        #expect(plan.isEmpty)
        #expect(plan.skipped.count == 2)
        #expect(plan.skipped[0].contains("removed from the library before"))
    }

    @Test func aMemberTheCheckCannotPlaceInsideItsPackageIsLeftOutRatherThanWrittenAsAClaim() throws {
        let packageID = ArtifactID()
        let document = try Fixture.document(artifacts: [
            .init(
                identity: .init(id: packageID, kind: .nativePlugin, displayName: "Core"),
                authority: .nativeOwned, declaredName: "core@aim",
                nativeRoutes: [.init(client: .claude, externalPluginID: "core@aim")])
        ])
        // The client reports the member but not where the package lives, so
        // no relative path can be worked out.
        var observation = Fixture.observation(.claudeCode, skills: ["core:brazil"], plugins: ["core@aim"])
        observation.pluginMetadata["core@aim"] = .init(
            name: "Core", source: "Claude plugin inventory", scope: "This Mac", enabled: true, skillIDs: ["core:brazil"])
        observation.skillMetadata["core:brazil"] = .init(
            path: "/Users/fixture/.claude/plugins/cache/aim/core/1.0/skills/brazil", source: "core@aim",
            providerPluginID: "core@aim")
        let inventory = ScannedInventory(
            skills: [Fixture.skill("core:brazil")], mcpServers: [],
            plugins: [Fixture.plugin("core@aim", members: ["core:brazil"])])

        let plan = WorkspaceObservationReconciliation.plan(
            document: document, observations: [observation], inventory: inventory)

        #expect(plan.isEmpty)
        #expect(plan.skipped == ["core:brazil: its package owns it, but the check could not say where inside it."])
    }

    @Test func anItemTwoPackagesClaimBelongsToNeither() throws {
        let document = try Fixture.document(artifacts: [])
        let observation = Fixture.observation(
            .codexCLI, skills: ["shared"], plugins: ["one", "two"], memberships: ["shared": "one"])
        let inventory = ScannedInventory(
            skills: [Fixture.skill("shared")], mcpServers: [],
            plugins: [Fixture.plugin("one", members: ["shared"]), Fixture.plugin("two", members: ["shared"])])

        let plan = WorkspaceObservationReconciliation.plan(
            document: document, observations: [observation], inventory: inventory)

        #expect(plan.additions.filter { $0.identity.kind == .nativePlugin }.count == 2)
        #expect(!plan.additions.contains { $0.identity.kind == .skill })
        #expect(plan.skipped == ["shared: more than one package claims it, so it belongs to neither."])
    }

    // MARK: - Writing it

    @Test func thePlanLandsAsOneRevisionAndReplayReturnsTheSameReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let observation = Fixture.observation(
            .claudeCode, skills: ["core:brazil", "docx"], plugins: ["core@aim"], memberships: ["core:brazil": "core@aim"])
        let inventory = ScannedInventory(
            skills: [Fixture.skill("core:brazil"), Fixture.skill("docx")], mcpServers: [],
            plugins: [Fixture.plugin("core@aim", members: ["core:brazil"])])
        let head = try #require(try fixture.store.snapshot()).document
        let plan = WorkspaceObservationReconciliation.plan(document: head, observations: [observation], inventory: inventory)
        let command = WorkspaceObservationReconciliationCommand(expectedRevisionID: head.revision.id, plan: plan)

        let receipt = try await fixture.service.reconcileObservedInventory(command)

        let after = try #require(try fixture.store.snapshot()).document
        #expect(after.revision.id == receipt.committedRevisionID)
        #expect(Set(receipt.affectedArtifactIDs) == Set(plan.additions.map(\.identity.id)))
        #expect(after.artifacts.count == head.artifacts.count + 3)
        try after.validateStructure()
        // The one row that was here before is exactly as it was.
        #expect(after.artifacts.first { $0.identity.id == Fixture.existing } == head.artifacts.first { $0.identity.id == Fixture.existing })

        let replayed = try await fixture.service.reconcileObservedInventory(command)
        #expect(replayed == receipt)
        #expect(try #require(try fixture.store.snapshot()).document.artifacts.count == head.artifacts.count + 3)
    }

    @Test func anEmptyPlanIsRefusedRatherThanCommittedAsAnEmptyRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let head = try #require(try fixture.store.snapshot()).document

        await #expect(throws: WorkspaceObservationReconciliationError.nothingToAdd) {
            try await fixture.service.reconcileObservedInventory(
                .init(expectedRevisionID: head.revision.id, plan: .init()))
        }
        #expect(try #require(try fixture.store.snapshot()).document.revision.id == head.revision.id)
    }

    @Test func aRowAnotherWriterAddedFirstIsNotDuplicatedWhenThePlanLands() throws {
        let document = try Fixture.document(artifacts: [])
        let observation = Fixture.observation(.claudeCode, skills: ["docx"], plugins: [])
        let inventory = ScannedInventory(skills: [Fixture.skill("docx")], mcpServers: [], plugins: [])
        let plan = WorkspaceObservationReconciliation.plan(
            document: document, observations: [observation], inventory: inventory)
        // Between planning and landing, somebody else recorded the same skill.
        var head = document
        head.artifacts.append(
            .init(identity: .init(id: ArtifactID(), kind: .skill, displayName: "Docx"), authority: .trackedOnly, declaredName: "docx"))

        let written = try WorkspaceObservationReconciliationCommand(expectedRevisionID: head.revision.id, plan: plan)
            .apply(to: &head)

        #expect(written.isEmpty)
        #expect(head.artifacts.filter { $0.declaredName == "docx" }.count == 1)
    }

    // MARK: - Fixture

    private struct Fixture {
        static let existing = ArtifactID()
        static let packageRoot = "/Users/fixture/.claude/plugins/cache/aim/core/1.0"
        let root: URL
        let store: WorkspaceRevisionStore
        let service: WorkspaceApplicationService

        init() throws {
            root = try TemporaryFolder("observation-reconciliation").url
            let writerID = WorkspaceObjectID()
            let document = try Self.document(
                artifacts: [
                    .init(
                        identity: .init(id: Self.existing, kind: .skill, displayName: "Reviewer"),
                        authority: .centralPersonal, declaredName: "reviewer")
                ], writerID: writerID)
            let device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            store = try WorkspaceRevisionStore(
                containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            service = WorkspaceApplicationService(store: store, writerID: writerID)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        static func document(
            artifacts: [ArtifactRecord], tombstoneAliases: [ExternalAlias] = [],
            writerID: WorkspaceObjectID = WorkspaceObjectID()
        ) throws -> PortableWorkspaceDocument {
            let revisionID = WorkspaceObjectID()
            return try WorkspaceDocumentCoding.seal(
                .init(
                    workspaceID: WorkspaceObjectID(), revision: .init(id: revisionID, writerID: writerID),
                    artifacts: artifacts,
                    tombstones: tombstoneAliases.isEmpty
                        ? [] : [.init(artifactID: ArtifactID(), aliases: tombstoneAliases, deletedInRevisionID: revisionID)]))
        }

        /// `memberships` maps a skill to the package that delivers it, which
        /// also supplies the package's location and the skill's path inside it,
        /// the way a client reports them.
        static func observation(
            _ surface: TargetSurface, skills: [String], plugins: [String], memberships: [String: String] = [:]
        ) -> TargetObservation {
            var pluginMetadata: [String: ObservedPluginMetadata] = [:]
            for package in Set(memberships.values) {
                pluginMetadata[package] = .init(
                    name: package.capitalized, source: packageRoot, scope: "This Mac", enabled: true,
                    skillIDs: memberships.filter { $0.value == package }.map(\.key).sorted())
            }
            return .init(
                surface: surface, installed: true, commandAvailable: true, version: "1.0.0",
                discoveredSkills: skills, discoveredPlugins: plugins,
                skillMetadata: memberships.reduce(into: [:]) { result, membership in
                    let bareName = membership.key.split(separator: ":").last.map(String.init) ?? membership.key
                    result[membership.key] = .init(
                        path: "\(packageRoot)/skills/\(bareName)/SKILL.md", source: membership.value,
                        providerPluginID: membership.value)
                },
                pluginMetadata: pluginMetadata,
                capabilities: .init(
                    supportsPluginInstall: true, supportsProjectScope: true, supportsLocalMarketplace: false,
                    supportsMCPAuthentication: false, supportsConnectorDiscovery: false, requiresNewSession: true,
                    requiresRestart: false, supportsMachineReadableOutput: true),
                lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }

        static func skill(_ id: String) -> Skill {
            .init(
                id: id, name: id, displayName: id.capitalized, summary: "Fixture", bundle: "standalone", scope: "This Mac",
                owned: false, triggers: [], negativeTrigger: "", files: ["SKILL.md"], clients: [], validationCount: 0)
        }

        static func plugin(_ id: String, members: [String]) -> Plugin {
            .init(
                id: id, name: id.capitalized, summary: "Fixture", source: "Codex", scope: "This Mac", revision: "current",
                skills: members, profiles: [], clients: [], installed: true)
        }

        static func server(_ id: String) -> MCPServer {
            .init(
                id: id, name: id.capitalized, summary: "Fixture", endpoint: "git-mcp", transport: .stdio,
                authentication: "None", scope: "This Mac", clients: [], secretNames: [])
        }
    }
}

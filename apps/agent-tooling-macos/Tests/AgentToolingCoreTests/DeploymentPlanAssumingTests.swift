import Darwin
import Foundation
import Testing

@testable import AgentToolingCore

/// A what-if plan: what saving some contributions would plan, before they are
/// saved. It is the plan the library gives once they are saved, step for step
/// and exclusion for exclusion, it saves nothing, and it refuses what a batch
/// would refuse.
@Suite("Deployment plan assuming contributions")
struct DeploymentPlanAssumingTests {
    @Test func theWhatIfPlanIsThePlanAfterSaving() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let additions = fixture.additions()

        let whatIf = try await fixture.plan(assuming: additions)
        let head = try #require(try fixture.store.snapshot()).document.revision.id
        _ = try await fixture.service.applyAssignmentBatch(.init(expectedRevisionID: head, additions: additions))
        let saved = try await fixture.plan()

        #expect(Self.steps(whatIf) == Self.steps(saved))
        #expect(Self.exclusions(whatIf) == Self.exclusions(saved))
        #expect(Self.requirements(whatIf) == Self.requirements(saved))
        #expect(whatIf.resolvedTargets == saved.resolvedTargets)
    }

    /// The cells setup's grid reads from it: Release Notes installs into Codex
    /// and Claude Code has it; Supabase installs into Claude Code and Codex
    /// has no route for it.
    @Test func eachPlacementReadsAsThePlannerDecides() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let whatIf = try await fixture.plan(assuming: fixture.additions())

        #expect(
            Self.steps(whatIf)
                == [
                    Step(artifact: fixture.skill, destination: fixture.codex.physicalDestinationID, action: "installContent"),
                    Step(artifact: fixture.plugin, destination: fixture.claude.physicalDestinationID, action: "installNativePackage"),
                ].sorted())
        #expect(
            Self.exclusions(whatIf)
                == [
                    Exclusion(artifact: fixture.skill, destination: fixture.claude.physicalDestinationID, reason: .alreadyPresent),
                    Exclusion(artifact: fixture.plugin, destination: fixture.codex.physicalDestinationID, reason: .missingNativeRoute),
                ].sorted())
    }

    @Test func planningAWhatIfSavesNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let before = try #require(try fixture.store.snapshot())

        _ = try await fixture.plan(assuming: fixture.additions())

        let after = try #require(try fixture.store.snapshot())
        #expect(after.document.revision.id == before.document.revision.id)
        #expect(after.document.assignments.isEmpty)
    }

    @Test func noAdditionsIsTheCommittedPlan() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let head = try #require(try fixture.store.snapshot()).document.revision.id
        _ = try await fixture.service.applyAssignmentBatch(.init(expectedRevisionID: head, additions: fixture.additions()))

        let plain = try await fixture.service.deploymentPlan(
            targets: fixture.targets, observations: fixture.observations, nativeInstallRoutes: fixture.routes)
        let assumingNothing = try await fixture.plan(assuming: [])

        #expect(Self.steps(plain) == Self.steps(assumingNothing))
        #expect(Self.exclusions(plain) == Self.exclusions(assumingNothing))
    }

    /// What a batch would refuse is refused here too, with the batch's error.
    @Test func whatABatchRefusesIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let tracked = AssignmentContribution(
            artifactID: fixture.tracked, destination: .init(surface: .codexCLI, scope: .user), reason: .manual)
        await #expect(throws: WorkspaceAssignmentCommandError.unsupportedArtifact) {
            _ = try await fixture.plan(assuming: [tracked])
        }

        let first = fixture.additions()
        let head = try #require(try fixture.store.snapshot()).document.revision.id
        _ = try await fixture.service.applyAssignmentBatch(.init(expectedRevisionID: head, additions: first))
        let again = AssignmentContribution(artifactID: fixture.skill, destination: first[0].destination, reason: .manual)
        await #expect(throws: WorkspaceAssignmentCommandError.contributionConflict) {
            _ = try await fixture.plan(assuming: [again])
        }
    }

    // MARK: - Comparing plans

    struct Step: Hashable, Comparable {
        let artifact: ArtifactID
        let destination: WorkspaceObjectID
        let action: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            [lhs.artifact.rawValue.uuidString, lhs.destination.rawValue.uuidString, lhs.action]
                .lexicographicallyPrecedes([rhs.artifact.rawValue.uuidString, rhs.destination.rawValue.uuidString, rhs.action])
        }
    }

    struct Exclusion: Hashable, Comparable {
        let artifact: ArtifactID?
        let destination: WorkspaceObjectID?
        let reason: WorkspaceDeploymentExclusionReason

        static func < (lhs: Self, rhs: Self) -> Bool {
            [lhs.artifact?.rawValue.uuidString ?? "", lhs.destination?.rawValue.uuidString ?? "", lhs.reason.rawValue]
                .lexicographicallyPrecedes(
                    [rhs.artifact?.rawValue.uuidString ?? "", rhs.destination?.rawValue.uuidString ?? "", rhs.reason.rawValue])
        }
    }

    private static func steps(_ plan: WorkspaceDeploymentPlan) -> [Step] {
        plan.items.map { item in
            let action =
                switch item.action {
                case .installContent: "installContent"
                case .updateContent: "updateContent"
                case .installNativePackage: "installNativePackage"
                case .configureManagedConnection: "configureManagedConnection"
                case .removeContent: "removeContent"
                case .removeManagedConnection: "removeManagedConnection"
                }
            return Step(artifact: item.artifactID, destination: item.physicalDestinationID, action: action)
        }.sorted()
    }

    private static func exclusions(_ plan: WorkspaceDeploymentPlan) -> [Exclusion] {
        plan.exclusions.map { Exclusion(artifact: $0.artifactID, destination: $0.physicalDestinationID, reason: $0.reason) }.sorted()
    }

    /// Each requirement's item, destination and the contributions behind it.
    private static func requirements(_ plan: WorkspaceDeploymentPlan) -> Set<[String]> {
        Set(
            plan.requirements.map { requirement in
                [requirement.artifactID.rawValue.uuidString, requirement.physicalDestinationID.rawValue.uuidString]
                    + requirement.contributions.map(\.id.rawValue.uuidString).sorted()
            })
    }

    // MARK: - Fixture

    /// A library with Release Notes (its content held), Supabase from Claude
    /// Code's catalog and Webapp Testing, which it only tracks; Codex and
    /// Claude Code checked on this Mac; and Claude Code already holding
    /// Release Notes' approved copy.
    private struct Fixture {
        let root: URL
        let store: WorkspaceRevisionStore
        let contentStore: CentralPackageContentStore
        let service: WorkspaceApplicationService
        let skill = ArtifactID()
        let plugin = ArtifactID()
        let tracked = ArtifactID()
        let codex: ResolvedAssignmentTarget
        let claude: ResolvedAssignmentTarget
        let observations: [WorkspaceDeploymentObservation]
        let routes: Set<NativePackageRoute>

        var targets: [ResolvedAssignmentTarget] { [codex, claude] }

        init() async throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "deployment-plan-assuming-\(UUID())")
            let contentURL = root.appending(path: "content")
            try FileManager.default.createDirectory(
                at: contentURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let tree = try CapturedPackageTree(entries: [
                .init(
                    relativePath: "SKILL.md",
                    kind: .file(
                        bytes: Data("---\nname: release-notes\ndescription: Fixture\n---\n\n# Release notes\n".utf8),
                        executable: false))
            ])
            let route = NativePackageRoute(client: .claude, externalPluginID: "supabase@claude-plugins-official")
            routes = [route]
            let writerID = WorkspaceObjectID()
            let document = try WorkspaceDocumentCoding.seal(
                .init(
                    revision: .init(writerID: writerID),
                    artifacts: [
                        .init(
                            identity: .init(id: skill, kind: .skill, displayName: "Release Notes"), authority: .centralPersonal,
                            declaredName: "release-notes", contentDigest: tree.digest),
                        .init(
                            identity: .init(id: plugin, kind: .nativePlugin, displayName: "Supabase"), authority: .nativeOwned,
                            declaredName: route.externalPluginID, nativeRoutes: [route]),
                        .init(
                            identity: .init(id: tracked, kind: .skill, displayName: "Webapp Testing"), authority: .trackedOnly,
                            declaredName: "webapp-testing"),
                    ]))
            var device = DeviceWorkspaceState(workspaceID: document.workspaceID)
            let checked = Date(timeIntervalSince1970: 1_700_000_000)
            device.capabilityEvidence = [(TargetSurface.codexCLI, "0.164.0"), (.claudeCode, "2.1.304")].flatMap { surface, version in
                [ComponentKind.skill, .plugin].map {
                    TargetCapabilityEvidence(
                        surface: surface, installedClientVersion: version, adapterContractVersion: 1, component: $0,
                        scopes: [.user], support: .supported, observedAt: checked)
                }
            }
            codex = .init(
                selector: .init(surface: .codexCLI, scope: .user, logicalProjectID: nil), physicalDestinationID: WorkspaceObjectID(),
                installedClientVersion: "0.164.0", adapterContractVersion: 1,
                componentContexts: [.init(component: .skill, transport: nil), .init(component: .plugin, transport: nil)])
            claude = .init(
                selector: .init(surface: .claudeCode, scope: .user, logicalProjectID: nil), physicalDestinationID: WorkspaceObjectID(),
                installedClientVersion: "2.1.304", adapterContractVersion: 1,
                componentContexts: [.init(component: .skill, transport: nil), .init(component: .plugin, transport: nil)])
            observations = [
                .init(artifactID: skill, physicalDestinationID: claude.physicalDestinationID, isPresent: true, contentDigest: tree.digest),
                .init(artifactID: skill, physicalDestinationID: codex.physicalDestinationID, isPresent: false),
                .init(artifactID: plugin, physicalDestinationID: claude.physicalDestinationID, isPresent: false),
            ]
            store = try WorkspaceRevisionStore(containerRoot: root, workspaceID: document.workspaceID, deviceID: device.deviceID)
            try store.initialize(document: document, device: device)
            contentStore = try CentralPackageContentStore(directory: contentURL)
            service = WorkspaceApplicationService(store: store, writerID: writerID, contentStore: contentStore)
            _ = try await contentStore.store(tree)
        }

        /// Release Notes and Supabase in Codex and in Claude Code, on every
        /// Mac.
        func additions() -> [AssignmentContribution] {
            [skill, plugin].flatMap { artifact in
                [TargetSurface.codexCLI, .claudeCode].map {
                    AssignmentContribution(artifactID: artifact, destination: .init(surface: $0, scope: .user), reason: .manual)
                }
            }
        }

        func plan(assuming additions: [AssignmentContribution] = []) async throws -> WorkspaceDeploymentPlan {
            try await service.deploymentPlan(
                targets: targets, observations: observations, nativeInstallRoutes: routes, assuming: additions)
        }

        func remove() {
            func unlock(_ url: URL) {
                var value = stat()
                guard lstat(url.path, &value) == 0 else { return }
                _ = chmod(url.path, 0o700)
                guard value.st_mode & S_IFMT == S_IFDIR else { return }
                for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                    unlock(child)
                }
            }
            unlock(root)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

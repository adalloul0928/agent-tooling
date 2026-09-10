import Foundation
import Testing

@testable import AgentToolingCore

/// How a workspace begins when there is nothing to begin from. Not a migration:
/// nothing is read from another store, and a scan never takes ownership of
/// somebody's files.
@Suite("Workspace first run")
struct WorkspaceFirstRunTests {
    @Test func aScanBecomesTheFirstRevisionWithNothingClaimedAsOurs() throws {
        let result = try WorkspaceFirstRun.prepare(
            observations: [Self.observation(.codexCLI, skills: ["reviewer"], plugins: [])],
            inventory: .init(skills: [Self.skill("reviewer")], mcpServers: [], plugins: []))

        #expect(result.skillCount == 1)
        let artifact = try #require(result.document.artifacts.first)
        // Taking ownership of somebody's files is a decision they make, not one
        // a first launch makes for them.
        #expect(artifact.authority == .trackedOnly)
        #expect(artifact.contentDigest == nil)
        #expect(artifact.declaredName == "reviewer")
    }

    @Test func aPackageAClientInstalledKeepsThatClientAsItsOwner() throws {
        let result = try WorkspaceFirstRun.prepare(
            observations: [Self.observation(.codexCLI, skills: [], plugins: ["browser"])],
            inventory: .init(skills: [], mcpServers: [], plugins: [Self.plugin("browser", members: [])]))

        let package = try #require(result.document.artifacts.first)
        #expect(package.authority == .nativeOwned)
        #expect(package.nativeRoutes == [.init(client: .codex, externalPluginID: "browser")])
        #expect(result.packageCount == 1)
    }

    @Test func aPackageWithNoRouteIsOnlyTrackedBecauseNothingCouldUpdateIt() throws {
        let result = try WorkspaceFirstRun.prepare(
            observations: [Self.observation(.codexCLI, skills: [], plugins: [])],
            inventory: .init(skills: [], mcpServers: [], plugins: [Self.plugin("browser", members: [])]))

        #expect(result.document.artifacts.first?.authority == .trackedOnly)
        #expect(result.document.artifacts.first?.nativeRoutes.isEmpty == true)
    }

    @Test func aMemberKeepsItsMembershipAndItsPackageStaysResponsibleForIt() throws {
        let result = try WorkspaceFirstRun.prepare(
            observations: [Self.observation(.codexCLI, skills: ["browse"], plugins: ["browser"],
                                            memberships: ["browse": "browser"])],
            inventory: .init(skills: [Self.skill("browse")], mcpServers: [],
                             plugins: [Self.plugin("browser", members: ["browse"])]))

        let package = try #require(result.document.artifacts.first { $0.identity.kind == .nativePlugin })
        let member = try #require(result.document.artifacts.first { $0.identity.kind == .skill })
        #expect(member.identity.parentPackageID == package.identity.id)
        // The package owns it either way. A child claiming a different
        // authority from the thing that delivers it would make two things
        // responsible for one file.
        #expect(member.authority == .nativeOwned)
        #expect(member.nativeRoutes.isEmpty)
        // A native-owned member has to say where it lives inside its package.
        #expect(member.packageRelativePath == "skills/member")
    }

    @Test func aPackageWhoseMembersCannotBeLocatedIsARecordRatherThanAClaim() throws {
        // A route was seen, but nothing says where this skill lives inside the
        // package. Claiming the client owns something this build cannot point
        // at would be a claim with nothing behind it.
        let result = try WorkspaceFirstRun.prepare(
            observations: [Self.observation(.codexCLI, skills: ["browse"], plugins: ["browser"])],
            inventory: .init(skills: [Self.skill("browse")], mcpServers: [],
                             plugins: [Self.plugin("browser", members: ["browse"])]))

        let package = try #require(result.document.artifacts.first { $0.identity.kind == .nativePlugin })
        #expect(package.authority == .trackedOnly)
        #expect(package.nativeRoutes.isEmpty)
        let member = try #require(result.document.artifacts.first { $0.identity.kind == .skill })
        #expect(member.authority == .trackedOnly)
        #expect(member.packageRelativePath == nil)
    }

    @Test func anItemTwoPackagesClaimBelongsToNeitherRatherThanArbitrarilyToOne() throws {
        let result = try WorkspaceFirstRun.prepare(
            observations: [Self.observation(.codexCLI, skills: ["shared"], plugins: ["one", "two"])],
            inventory: .init(skills: [Self.skill("shared")], mcpServers: [],
                             plugins: [Self.plugin("one", members: ["shared"]),
                                       Self.plugin("two", members: ["shared"])]))

        // Claimed by both, so it is recorded standalone rather than assigned to
        // whichever sorted first.
        #expect(result.document.artifacts.filter { $0.identity.kind == .skill }.isEmpty)
    }

    @Test func aPackagesMemberIsNotAlsoRecordedAsAStandaloneThing() throws {
        let result = try WorkspaceFirstRun.prepare(
            observations: [Self.observation(.codexCLI, skills: ["browse"], plugins: ["browser"],
                                            memberships: ["browse": "browser"])],
            inventory: .init(skills: [Self.skill("browse")], mcpServers: [],
                             plugins: [Self.plugin("browser", members: [])]))

        let skills = result.document.artifacts.filter { $0.identity.kind == .skill }
        #expect(skills.count == 1)
        #expect(skills.first?.identity.parentPackageID != nil)
    }

    @Test func whatThisMacObservedIsKeptAsDeviceStateNotPortableIntent() throws {
        let result = try WorkspaceFirstRun.prepare(
            observations: [Self.observation(.codexCLI, skills: ["reviewer"], plugins: [])],
            inventory: .init(skills: [Self.skill("reviewer")], mcpServers: [], plugins: []))

        #expect(result.device.observations.count == 1)
        let portable = try WorkspaceDocumentCoding.encode(result.document)
        #expect(!String(decoding: portable, as: UTF8.self).contains("lastScannedAt"))
    }

    @Test func whatEachClientCanCarryIsRecordedFromTheSameScan() throws {
        let observations = [Self.observation(.codexCLI, skills: ["reviewer"], plugins: [])]
        let result = try WorkspaceFirstRun.prepare(
            observations: observations,
            inventory: .init(skills: [Self.skill("reviewer")], mcpServers: [], plugins: []))

        // Without this a brand-new workspace could record an assignment and then
        // refuse to plan it, because the check that admits a destination would
        // have nothing to read.
        #expect(!result.device.capabilityEvidence.isEmpty)
        #expect(
            result.device.capabilityEvidence
                == TargetCapabilityEvidence.derive(from: observations))
        #expect(result.device.capabilityEvidence.allSatisfy { $0.surface == .codexCLI })
        #expect(result.device.capabilityEvidence.allSatisfy { $0.installedClientVersion == "1.0.0" })
        // It is this Mac's record of this Mac, and nothing about it is portable.
        let portable = try WorkspaceDocumentCoding.encode(result.document)
        #expect(!String(decoding: portable, as: UTF8.self).contains("capabilityEvidence"))
    }

    @Test func aClientThatDidNotAnswerIsRecordedAsNothingRatherThanAsCapable() throws {
        let result = try WorkspaceFirstRun.prepare(
            observations: [Self.unavailable(.geminiCLI)],
            inventory: .init(skills: [], mcpServers: [], plugins: []))

        #expect(result.device.observations.count == 1)
        #expect(result.device.capabilityEvidence.isEmpty)
    }

    @Test func anEmptyMacProducesAnEmptyButValidWorkspace() throws {
        let result = try WorkspaceFirstRun.prepare(
            observations: [], inventory: .init(skills: [], mcpServers: [], plugins: []))

        #expect(result.document.artifacts.isEmpty)
        #expect(throws: Never.self) { try result.document.validateStructure() }
        #expect(result.skillCount == 0 && result.packageCount == 0 && result.connectionCount == 0)
    }

    @Test func aFirstRunIsOnlyEverFirst() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "first-run-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let prepared = try WorkspaceFirstRun.prepare(
            observations: [], inventory: .init(skills: [], mcpServers: [], plugins: []))
        let store = try WorkspaceRevisionStore(containerRoot: root.appending(path: "store"),
            workspaceID: prepared.document.workspaceID, deviceID: prepared.device.deviceID)
        try store.initialize(document: prepared.document, device: prepared.device)

        // Starting over on top of an existing workspace would discard whatever
        // that workspace had decided.
        #expect(throws: WorkspaceRevisionStoreError.alreadyInitialized) {
            try store.initialize(document: prepared.document, device: prepared.device)
        }
    }

    /// Files on disk but no command that answers, which is not the same as a
    /// client nobody looked for.
    private static func unavailable(_ surface: TargetSurface) -> TargetObservation {
        .init(
            surface: surface, installed: true, commandAvailable: false, version: nil,
            capabilities: .init(
                supportsPluginInstall: true, supportsProjectScope: true,
                supportsLocalMarketplace: false, supportsMCPAuthentication: false,
                supportsConnectorDiscovery: false, requiresNewSession: true, requiresRestart: false,
                supportsMachineReadableOutput: true),
            lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static func skill(_ id: String) -> Skill {
        .init(id: id, name: id, displayName: id.capitalized, summary: "Fixture", bundle: "standalone",
              scope: "This Mac", owned: false, triggers: [], negativeTrigger: "",
              files: ["SKILL.md"], clients: [], validationCount: 0)
    }

    private static func plugin(_ id: String, members: [String]) -> Plugin {
        .init(id: id, name: id.capitalized, summary: "Fixture", source: "Codex", scope: "This Mac",
              revision: "current", skills: members, profiles: [], clients: [], installed: true)
    }

    private static let packageRoot = "/Users/fixture/.codex/plugins/browser"

    /// `memberships` maps a skill to the package that delivers it. Supplying it
    /// also supplies the package's own location and that skill's path inside it,
    /// which is what a client actually reports.
    private static func observation(
        _ surface: TargetSurface, skills: [String], plugins: [String],
        memberships: [String: String] = [:]
    ) -> TargetObservation {
        var pluginMetadata: [String: ObservedPluginMetadata] = [:]
        for package in Set(memberships.values) {
            pluginMetadata[package] = .init(
                name: package.capitalized, source: packageRoot, scope: "This Mac",
                enabled: true, skillIDs: memberships.filter { $0.value == package }.map(\.key).sorted())
        }
        return .init(
            surface: surface, installed: true, commandAvailable: true, version: "1.0.0",
            discoveredSkills: skills, discoveredPlugins: plugins,
            skillMetadata: memberships.mapValues {
                .init(path: "\(packageRoot)/skills/member/SKILL.md", source: $0, providerPluginID: $0)
            },
            pluginMetadata: pluginMetadata,
            capabilities: .init(supportsPluginInstall: true, supportsProjectScope: true,
                                supportsLocalMarketplace: false, supportsMCPAuthentication: false,
                                supportsConnectorDiscovery: false, requiresNewSession: true,
                                requiresRestart: false, supportsMachineReadableOutput: true),
            lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}

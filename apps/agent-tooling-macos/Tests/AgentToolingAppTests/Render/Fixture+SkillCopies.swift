import Foundation

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Two plugins re-ship one skill and AIM copies it into Kiro's folder: three
/// entries, one skill. The plugins' copies match; AIM's differs.
@MainActor
struct SkillCopiesScenario {
    let index: SkillInventoryIndex
    let wootSkill = ArtifactID()
    let coreSkill = ArtifactID()
    let loose = ArtifactID()

    init() throws {
        let woot = ArtifactID()
        let core = ArtifactID()
        let snapshot = try Self.snapshot(artifacts: [
            .init(
                identity: .init(id: woot, kind: .nativePlugin, displayName: "WootAICapabilities All"), authority: .nativeOwned,
                declaredName: "WootAICapabilities-all@aim",
                nativeRoutes: [.init(client: .claude, externalPluginID: "WootAICapabilities-all@aim")]),
            .init(
                identity: .init(id: core, kind: .nativePlugin, displayName: "AmazonBuilderCoreAIAgents Core"), authority: .nativeOwned,
                declaredName: "AmazonBuilderCoreAIAgents-core@aim",
                nativeRoutes: [.init(client: .claude, externalPluginID: "AmazonBuilderCoreAIAgents-core@aim")]),
            .init(
                identity: .init(id: wootSkill, kind: .skill, displayName: "Agent Sop Author", parentPackageID: woot),
                authority: .nativeOwned, declaredName: "WootAICapabilities-all:agent-sop-author",
                packageRelativePath: "skills/agent-sop-author"),
            .init(
                identity: .init(id: coreSkill, kind: .skill, displayName: "Agent Sop Author", parentPackageID: core),
                authority: .nativeOwned, declaredName: "AmazonBuilderCoreAIAgents-core:agent-sop-author",
                packageRelativePath: "skills/agent-sop-author"),
            .init(
                identity: .init(id: loose, kind: .skill, displayName: "Agent Sop Author"), authority: .trackedOnly,
                declaredName: "agent-sop-author"),
        ])
        let same = String(repeating: "a", count: 64)
        var claude = ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true)
        claude.skillMetadata = [
            "WootAICapabilities-all:agent-sop-author": .init(
                path: "/p/woot/agent-sop-author", source: "WootAICapabilities-all@aim",
                providerPluginID: "WootAICapabilities-all@aim", definitionDigest: same),
            "AmazonBuilderCoreAIAgents-core:agent-sop-author": .init(
                path: "/p/core/agent-sop-author", source: "AmazonBuilderCoreAIAgents-core@aim",
                providerPluginID: "AmazonBuilderCoreAIAgents-core@aim", definitionDigest: same),
        ]
        var codex = ShellRenderFixture.observation(.codexCLI, installed: true, commandAvailable: true)
        codex.skillMetadata = claude.skillMetadata.filter { $0.key.hasPrefix("Woot") }
        var kiro = ShellRenderFixture.observation(.kiroCLI, installed: true, commandAvailable: true)
        kiro.skillMetadata = [
            "agent-sop-author": .init(
                path: "/h/.kiro/skills/agent-sop-author", source: "Standalone Kiro CLI skill",
                definitionDigest: String(repeating: "b", count: 64),
                externalManager: .init(tool: "AIM", package: "core-skills"))
        ]
        index = try SkillInventoryIndex(
            library: WorkspaceLibraryReadModel(snapshot: snapshot), snapshot: snapshot,
            observations: [claude, codex, kiro], ownershipJSON: "{}")
    }

    private static func snapshot(artifacts: [ArtifactRecord]) throws -> WorkspaceApplicationSnapshot {
        let workspaceID = WorkspaceObjectID()
        let document = try WorkspaceDocumentCoding.seal(
            .init(workspaceID: workspaceID, revision: .init(writerID: WorkspaceObjectID()), artifacts: artifacts))
        return .init(document: document, device: DeviceWorkspaceState(workspaceID: workspaceID))
    }
}

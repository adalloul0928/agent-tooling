import Foundation

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Three copies of one skill; two match and one differs.
@MainActor
struct SkillCopiesScenario {
    let index: SkillInventoryIndex
    let exampleSkill = ArtifactID()
    let coreSkill = ArtifactID()
    let loose = ArtifactID()

    init() throws {
        let example = ArtifactID()
        let core = ArtifactID()
        let snapshot = try Self.snapshot(artifacts: [
            .init(
                identity: .init(id: example, kind: .nativePlugin, displayName: "ExampleTools All"), authority: .nativeOwned,
                declaredName: "ExampleTools-all@example",
                nativeRoutes: [.init(client: .claude, externalPluginID: "ExampleTools-all@example")]),
            .init(
                identity: .init(id: core, kind: .nativePlugin, displayName: "SharedTools Core"), authority: .nativeOwned,
                declaredName: "SharedTools-core@example",
                nativeRoutes: [.init(client: .claude, externalPluginID: "SharedTools-core@example")]),
            .init(
                identity: .init(id: exampleSkill, kind: .skill, displayName: "Agent Sop Author", parentPackageID: example),
                authority: .nativeOwned, declaredName: "ExampleTools-all:agent-sop-author",
                packageRelativePath: "skills/agent-sop-author"),
            .init(
                identity: .init(id: coreSkill, kind: .skill, displayName: "Agent Sop Author", parentPackageID: core),
                authority: .nativeOwned, declaredName: "SharedTools-core:agent-sop-author",
                packageRelativePath: "skills/agent-sop-author"),
            .init(
                identity: .init(id: loose, kind: .skill, displayName: "Agent Sop Author"), authority: .trackedOnly,
                declaredName: "agent-sop-author"),
        ])
        let same = String(repeating: "a", count: 64)
        var claude = ShellRenderFixture.observation(.claudeCode, installed: true, commandAvailable: true)
        claude.skillMetadata = [
            "ExampleTools-all:agent-sop-author": .init(
                path: "/p/example/agent-sop-author", source: "ExampleTools-all@example",
                providerPluginID: "ExampleTools-all@example", definitionDigest: same),
            "SharedTools-core:agent-sop-author": .init(
                path: "/p/core/agent-sop-author", source: "SharedTools-core@example",
                providerPluginID: "SharedTools-core@example", definitionDigest: same),
        ]
        var codex = ShellRenderFixture.observation(.codexCLI, installed: true, commandAvailable: true)
        codex.skillMetadata = claude.skillMetadata.filter { $0.key.hasPrefix("Example") }
        var kiro = ShellRenderFixture.observation(.kiroCLI, installed: true, commandAvailable: true)
        kiro.skillMetadata = [
            "agent-sop-author": .init(
                path: "/h/.kiro/skills/agent-sop-author", source: "Standalone Kiro CLI skill",
                definitionDigest: String(repeating: "b", count: 64),
                externalManager: .init(tool: "Example Manager", package: "core-skills"))
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

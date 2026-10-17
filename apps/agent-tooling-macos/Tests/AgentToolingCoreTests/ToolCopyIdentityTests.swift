import Foundation
import Testing

@testable import AgentToolingCore

/// Copies of one tool: the same skill re-shipped by several plugins, or
/// copied into a client's folder by a package manager.
@Suite("Tool copy identity")
struct ToolCopyIdentityTests {
    @Test func theCallableNameDropsAPluginsNamespaceAndCase() {
        #expect(ToolCopyIdentity.callableName("WootAICapabilities-all:agent-sop-author") == "agent-sop-author")
        #expect(ToolCopyIdentity.callableName("Agent-SOP-Author") == "agent-sop-author")
        #expect(ToolCopyIdentity.bareName("Woot:Agent-SOP-Author") == "Agent-SOP-Author")
        #expect(ToolCopyIdentity.callableName(nil) == nil, "a display name is never an identity")
        #expect(ToolCopyIdentity.callableName("  ") == nil)
    }

    @Test func onlyTheMetadataMappingIsStripped() {
        let text = """
            ---
            name: agent-sop-author
            description: Writes SOPs.
            version: 1.0.0
            metadata:
              brazil_version: 1.0.34586.0
              commit: 009fd6b
            tags:
            - skill
            ---

            # Agent SOP Author
            metadata: in the body stays
            """
        let stripped = ToolCopyIdentity.strippingPackagingMetadata(text)
        #expect(!stripped.contains("brazil_version"))
        #expect(!stripped.contains("commit: 009fd6b"))
        #expect(stripped.contains("version: 1.0.0"), "the skill's own version is meaningful and kept")
        #expect(stripped.contains("tags:\n- skill"))
        #expect(stripped.contains("metadata: in the body stays"), "only frontmatter is touched")
        #expect(ToolCopyIdentity.strippingPackagingMetadata("# No frontmatter") == "# No frontmatter")
    }

    @Test func copiesThatDifferOnlyInTheirBuildStampShareADigest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let woot = try writeSkill(at: root.appending(path: "woot/agent-sop-author"), stamp: "1.0.1", body: "Do it.")
        let core = try writeSkill(at: root.appending(path: "core/agent-sop-author"), stamp: "1.0.2", body: "Do it.")
        let older = try writeSkill(at: root.appending(path: "old/agent-sop-author"), stamp: "1.0.1", body: "Do it differently.")
        // A manager's marker is not part of the skill.
        try "core-skills\n".write(to: core.appending(path: ".aim-managed"), atomically: true, encoding: .utf8)

        let first = try #require(ToolCopyIdentity.definitionDigest(ofSkillAt: woot))
        #expect(first.count == 64)
        #expect(ToolCopyIdentity.definitionDigest(ofSkillAt: core) == first)
        #expect(ToolCopyIdentity.definitionDigest(ofSkillAt: older) != first)

        try "#!/bin/sh\n".write(to: core.appending(path: "validate.sh"), atomically: true, encoding: .utf8)
        #expect(ToolCopyIdentity.definitionDigest(ofSkillAt: core) != first, "every other file counts")
        #expect(ToolCopyIdentity.definitionDigest(ofSkillAt: root.appending(path: "missing")) == nil)
    }

    /// A file whose name begins with a combining mark is part of the skill
    /// like any other, so a copy that adds one does not share the digest of
    /// a copy without it and is not called identical apart from its stamp.
    @Test func aFileNamedWithALeadingCombiningMarkCounts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = try writeSkill(at: root.appending(path: "plain/pdf"), stamp: "1", body: "Read PDFs.")
        let added = try writeSkill(at: root.appending(path: "added/pdf"), stamp: "1", body: "Read PDFs.")
        let script = added.appending(path: "\u{301}run.sh")
        try "#!/bin/sh\necho added\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))

        let digest = try #require(ToolCopyIdentity.definitionDigest(ofSkillAt: plain))
        #expect(ToolCopyIdentity.definitionDigest(ofSkillAt: added) != digest)
    }

    /// Skills that bundle fonts or images run to megabytes; they are still compared.
    @Test func aSkillWithLargeAssetsIsStillCompared() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try writeSkill(at: root.appending(path: "a/canvas"), stamp: "1", body: "Draw.")
        let second = try writeSkill(at: root.appending(path: "b/canvas"), stamp: "2", body: "Draw.")
        let font = Data(repeating: 7, count: 6 * 1_024 * 1_024)
        for folder in [first, second] { try font.write(to: folder.appending(path: "font.ttf")) }

        let digest = try #require(ToolCopyIdentity.definitionDigest(ofSkillAt: first))
        #expect(ToolCopyIdentity.definitionDigest(ofSkillAt: second) == digest)
        #expect(ToolCopyIdentity.definitionDigest(ofSkillAt: first, maximumBytes: 1_024 * 1_024) == nil, "the bound still holds")
    }

    @Test func insightsSeeOneSkillPerReShippedCopy() {
        let woot = skill("1", name: "agent-sop-author", summary: "Writes SOPs.", owned: false, clients: [.claude])
        let core = skill("2", name: "agent-sop-author", summary: "Writes SOPs.", owned: false, clients: [.codex])
        let kiro = skill("3", name: "agent-sop-author", summary: "", owned: false, clients: [.kiro])
        let mine = skill("4", name: "agent-sop-author", summary: "Writes SOPs.", owned: true, clients: [])
        let other = skill("5", name: "brazil", summary: "Builds.", owned: false, clients: [])

        let collapsed = ToolCopyIdentity.collapsingCopies([woot, core, kiro, mine, other])
        #expect(collapsed.map(\.id) == ["4", "5"], "the copy this library maintains is kept")
        #expect(Set(collapsed[0].clients.map(\.client)) == [.claude, .codex, .kiro], "where the others were asked for is kept")
    }

    @Test func differentSkillsThatShareANameStayApart() {
        let first = skill("1", name: "review", summary: "Reviews the first package.", owned: false, clients: [])
        let second = skill("2", name: "review", summary: "Reviews the second package.", owned: false, clients: [])
        #expect(ToolCopyIdentity.collapsingCopies([first, second]).count == 2)
    }

    // MARK: - Fixtures

    private func skill(_ id: String, name: String, summary: String, owned: Bool, clients: [ClientKind]) -> Skill {
        Skill(
            id: id, name: name, displayName: name, summary: summary, bundle: "", scope: "user", owned: owned, triggers: [],
            negativeTrigger: "", files: [],
            clients: clients.map { ClientState(client: $0, state: .pending, detail: "", isInstalled: nil) }, validationCount: 0)
    }

    private func writeSkill(at folder: URL, stamp: String, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "---\nname: agent-sop-author\ndescription: Writes SOPs.\nmetadata:\n  brazil_version: \(stamp)\n---\n\n\(body)\n"
        try text.write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        return folder
    }
}

@Suite("External skill managers")
struct ExternalSkillManagerIndexTests {
    @Test func aimsPlacementRecordNamesThePackage() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let state = home.appending(path: ".aim/state/skills")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "schemaVersion": 1, "packageName": "DalloulPersonalAI",
            "targets": [[
                "client": "kiro", "targetRoot": home.path(percentEncoded: false), "scope": "USER",
                "skills": [
                    ["skillName": "thermo", "relativeDir": ".kiro/skills/thermo", "sourcePackage": "DalloulPersonalAI"],
                    ["skillName": "escape", "relativeDir": "../outside"],
                ],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: record).write(to: state.appending(path: "DalloulPersonalAI-abc.json"))

        let index = ExternalSkillManagerIndex.load(homeURL: home)
        let placed = index.manager(forSkillAt: home.appending(path: ".kiro/skills/thermo"))
        #expect(placed == ObservedExternalManager(tool: "AIM", package: "DalloulPersonalAI"))
        #expect(placed?.label == "AIM · DalloulPersonalAI")
        #expect(index.manager(forSkillAt: home.appending(path: ".kiro/skills/mine")) == nil, "a folder nothing names is not placed")
        #expect(index.manager(forSkillAt: home.deletingLastPathComponent().appending(path: "outside")) == nil)
    }

    @Test func aMarkerOrTheCoreManifestIsEnough() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let skills = home.appending(path: ".kiro/skills")
        let marked = skills.appending(path: "brazil")
        let listed = skills.appending(path: "wiki-edit")
        for folder in [marked, listed] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "core-skills\n".write(to: marked.appending(path: ".aim-managed"), atomically: true, encoding: .utf8)
        try #"{"owner":"core-skills","skills":{"wiki-edit":{"digest":"x"}}}"#
            .write(to: skills.appending(path: ".aim-core-skills.json"), atomically: true, encoding: .utf8)

        let index = ExternalSkillManagerIndex.load(homeURL: home)
        #expect(index.manager(forSkillAt: marked) == ObservedExternalManager(tool: "AIM", package: "core-skills"))
        #expect(index.manager(forSkillAt: listed) == ObservedExternalManager(tool: "AIM", package: "core-skills"))
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appending(path: "ToolCopyIdentityTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

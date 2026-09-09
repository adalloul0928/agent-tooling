import Foundation
import Testing

@testable import AgentToolingCore

/// Reading real files into layers. It only reads: nothing is rewritten,
/// reformatted or assumed empty.
@Suite("Configuration layer reader")
struct ConfigurationLayerReaderTests {
    @Test func claudeLayersAreReadInPrecedenceOrderAndExplainOneValue() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".claude/settings.json", in: fixture.home, """
        {"model":"user-model","permissions":{"allow":["Read"],"other":true},"experimental":{"x":1}}
        """)
        try fixture.write(".claude/settings.json", in: fixture.project, """
        {"model":"project-model","permissions":{"allow":["Bash(git:*)"]}}
        """)
        let before = try fixture.contents(".claude/settings.json", in: fixture.home)

        let layers = try ConfigurationLayerReader()
            .claudeCodeLayers(homeRoot: fixture.home, projectRoot: fixture.project)
        let result = EffectiveConfigurationResolver.resolve(
            adapter: ClaudeCodeConfigurationAdapter(), installedClientVersion: "2.0.0", layers: layers)

        #expect(layers.map(\.kind) == [.project, .user])
        let model = result.rows.first { $0.key == "model" }
        #expect(model?.value == .string("project-model"))
        #expect(model?.definingSourcePath?.hasSuffix("project/.claude/settings.json") == true)
        let allowed = result.rows.first { $0.key == "permissions.allow" }
        #expect(allowed?.value == .list([.string("Bash(git:*)"), .string("Read")]))
        // Unknown nested permission keys and unknown top-level keys stay visible.
        #expect(result.unrecognized.map(\.key).contains("permissions.other"))
        #expect(result.rows.contains { $0.key == "env" } == false)
        // Reading changed nothing on disk.
        #expect(try fixture.contents(".claude/settings.json", in: fixture.home) == before)
    }

    @Test func anAbsentFileIsNoLayerWhileAnUnreadableOneIsAnError() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(try ConfigurationLayerReader().claudeCodeLayers(homeRoot: fixture.home).isEmpty)

        try fixture.write(".claude/settings.json", in: fixture.home, "{ not json")
        #expect(throws: ConfigurationLayerReadError.unreadable) {
            _ = try ConfigurationLayerReader().claudeCodeLayers(homeRoot: fixture.home)
        }
    }

    @Test func aManagedPolicyFileIsReadAsNotWritable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("managed-settings.json", in: fixture.root, #"{"model":"policy-model"}"#)

        let layers = try ConfigurationLayerReader().claudeCodeLayers(
            homeRoot: fixture.home,
            managedPolicyPath: fixture.root.appending(path: "managed-settings.json"))

        #expect(layers.count == 1)
        #expect(layers.first?.kind == .managedPolicy)
        #expect(layers.first?.isWritable == false)
    }

    @Test func codexReadsItsLocalConfigurationAndOnlyUsesProfileFilesWhenTheReleaseDoes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".codex/config.toml", in: fixture.home, """
        # base
        model = "gpt-5-codex"
        approval_policy = "on-request"
        [mcp_servers.files]
        command = "npx"
        """)
        try fixture.write(".codex/work.config.toml", in: fixture.home, """
        model = "gpt-5"
        """)

        let modern = try ConfigurationLayerReader().codexLayers(
            homeRoot: fixture.home,
            adapter: CodexConfigurationAdapter(installedClientVersion: "0.140.0"),
            profileName: "work")
        let older = try ConfigurationLayerReader().codexLayers(
            homeRoot: fixture.home,
            adapter: CodexConfigurationAdapter(installedClientVersion: "0.133.0"),
            profileName: "work")

        #expect(modern.map(\.kind) == [.project, .user])
        #expect(older.map(\.kind) == [.user])
        let resolved = EffectiveConfigurationResolver.resolve(
            adapter: CodexConfigurationAdapter(installedClientVersion: "0.140.0"),
            installedClientVersion: "0.140.0", layers: modern)
        #expect(resolved.rows.first { $0.key == "model" }?.value == .string("gpt-5"))
        #expect(resolved.rows.first { $0.key == "approval_policy" }?.value == .string("on-request"))
        // A table is recorded by name without claiming to understand it.
        #expect(older.first?.values["mcp_servers.files"] == .opaque("Configured"))
    }

    @Test func anOversizedFileIsRefusedRatherThanRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let padding = String(repeating: "x", count: ConfigurationLayerReader.maximumFileBytes)
        try fixture.write(".claude/settings.json", in: fixture.home, #"{"model":"\#(padding)"}"#)

        #expect(throws: ConfigurationLayerReadError.fileTooLarge) {
            _ = try ConfigurationLayerReader().claudeCodeLayers(homeRoot: fixture.home)
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let project: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "configuration-layers-\(UUID())")
            home = root.appending(path: "home")
            project = root.appending(path: "project")
            for url in [home, project] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
        }

        func write(_ relativePath: String, in directory: URL, _ contents: String) throws {
            let url = directory.appending(path: relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(contents.utf8).write(to: url)
        }

        func contents(_ relativePath: String, in directory: URL) throws -> Data {
            try Data(contentsOf: directory.appending(path: relativePath))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

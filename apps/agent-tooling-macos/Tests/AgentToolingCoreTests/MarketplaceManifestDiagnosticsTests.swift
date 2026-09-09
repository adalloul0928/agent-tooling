import Foundation
import Testing

@testable import AgentToolingCore

struct MarketplaceManifestDiagnosticsTests {
    @Test func portableManifestWarningsRemainReviewableWithoutChangingPackageBytes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "marketplace-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let manifestURL = root.appending(path: "plugin.json")
        let original = Data(
            """
            {"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"warning-plugin","futureField":{"enabled":true},"extensions":null}
            """.utf8
        )
        try original.write(to: manifestURL)
        let source = ToolingSource(name: "Fixture", kind: .localFolder, location: root.path(percentEncoded: false))

        let packages = try MarketplaceService().inspect(source)

        #expect(packages.count == 1)
        let package = try #require(packages.first)
        #expect(package.name == "warning-plugin")
        #expect(package.conflicts?.map(\.summary).contains("plugin.json: ignored unknown field \"futureField\".") == true)
        #expect(package.conflicts?.map(\.summary).contains("plugin.json: ignored non-object extensions.") == true)
        #expect(package.trustSummary == "Review manifest warnings before installing")
        #expect(try Data(contentsOf: manifestURL) == original)
    }

    @Test func marketplaceLoadsIgnoredOverflowValuesFromPortableManifests() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "marketplace-overflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let manifestURL = root.appending(path: "plugin.json")
        let original = Data(
            """
            {"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"overflow-plugin","ignored":1e400,"extensions":{"com.example.future":{"limit":1e400}}}
            """.utf8
        )
        try original.write(to: manifestURL)
        let source = ToolingSource(name: "Fixture", kind: .localFolder, location: root.path(percentEncoded: false))

        let package = try #require(MarketplaceService().inspect(source).first)

        #expect(package.name == "overflow-plugin")
        #expect(package.conflicts?.contains(where: { $0.summary.contains("ignored unknown field \"ignored\"") }) == true)
        #expect(package.hasExecutableContent)
        #expect(try Data(contentsOf: manifestURL) == original)
    }

    @Test func marketplaceIsolatesInvalidSkillsAndFixedComponentKinds() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "marketplace-components-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"$schema\":\"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json\",\"name\":\"component-plugin\"}".utf8)
            .write(to: root.appending(path: "plugin.json"))
        try FileManager.default.createDirectory(at: root.appending(path: "skills/bad"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "skills/good"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "skills/quoted"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "skills/duplicate"), withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: root.appending(path: "skills/bad/SKILL.md"))
        try Data("---\nname: good\ndescription: Good\n---\n".utf8).write(to: root.appending(path: "skills/good/SKILL.md"))
        try Data("---\nname: 'quoted'\ndescription: >-\n  A folded\n  description\n---\n".utf8).write(to: root.appending(path: "skills/quoted/SKILL.md"))
        try Data("---\nname: duplicate\nname: duplicate\ndescription: Invalid\n---\n".utf8).write(to: root.appending(path: "skills/duplicate/SKILL.md"))
        try FileManager.default.createDirectory(at: root.appending(path: "mcp.json"), withIntermediateDirectories: true)

        let source = ToolingSource(name: "Fixture", kind: .localFolder, location: root.path(percentEncoded: false))
        let package = try #require(MarketplaceService().inspect(source).first)

        #expect(package.components.contains(.skill))
        #expect(!package.components.contains(.mcpServer))
        #expect(package.conflicts?.contains(where: { $0.summary == "bad: invalid skill." }) == true)
        #expect(package.conflicts?.contains(where: { $0.summary == "duplicate: invalid skill." }) == true)
        #expect(package.conflicts?.contains(where: { $0.summary.contains("quoted:") }) == false)
        #expect(package.conflicts?.contains(where: { $0.summary == "mcp.json: invalid component location." }) == true)
    }

    @Test func marketplaceDisablesOnlyMCPWhenSchemaVersionDiffers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "marketplace-mcp-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"$schema\":\"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json\",\"name\":\"version-plugin\"}".utf8)
            .write(to: root.appending(path: "plugin.json"))
        try Data("{\"$schema\":\"https://agent-plugins.org/schemas/2.0.0/mcp.schema.json\",\"mcpServers\":{}}".utf8)
            .write(to: root.appending(path: "mcp.json"))

        let source = ToolingSource(name: "Fixture", kind: .localFolder, location: root.path(percentEncoded: false))
        let package = try #require(MarketplaceService().inspect(source).first)

        #expect(!package.components.contains(.mcpServer))
        #expect(package.conflicts?.contains(where: { $0.summary == "mcp.json: schema version does not match plugin.json." }) == true)
    }

    @Test func marketplaceReportsDanglingAndEscapingFixedComponentsWithoutRejectingPlugin() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "marketplace-fixed-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"$schema\":\"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json\",\"name\":\"links-plugin\"}".utf8).write(to: root.appending(path: "plugin.json"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "skills"), withDestinationURL: root.appending(path: "missing-skills"))
        let outside = root.deletingLastPathComponent().appending(path: "outside-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "mcp.json"), withDestinationURL: outside)

        let source = ToolingSource(name: "Fixture", kind: .localFolder, location: root.path(percentEncoded: false))
        let package = try #require(MarketplaceService().inspect(source).first)

        #expect(package.conflicts?.contains(where: { $0.summary == "skills: invalid component location." }) == true)
        #expect(package.conflicts?.contains(where: { $0.summary == "mcp.json: invalid component location." }) == true)
    }
}

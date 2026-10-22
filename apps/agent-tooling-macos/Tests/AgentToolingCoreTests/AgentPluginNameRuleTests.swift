import Foundation
import Testing

@testable import AgentToolingCore

/// The package-name rule and its two siblings once compiled to functions that
/// refused every input in release builds of this module. These cases run in
/// both configurations; CI runs this suite in release as well.
@Suite("Agent Plugins name rule")
struct AgentPluginNameRuleTests {
    @Test(arguments: ["a", "dad-update2", "dad-update", "x.y", "ab-cd", "a1.b2-c3", String(repeating: "a", count: 64)])
    func acceptsWellFormedNames(_ name: String) {
        #expect(AgentPluginManifest.isValidName(name))
    }

    @Test(arguments: [
        "", "-a", "a-", ".a", "a.", "a--b", "a..b", "A", "dad_update", "dad update", "dad-update2\n", "dad\u{2011}update",
        String(repeating: "a", count: 65),
    ])
    func rejectsMalformedNames(_ name: String) {
        #expect(!AgentPluginManifest.isValidName(name))
    }

    @Test func theLoaderAcceptsAManifestNamedLikeACodexDraft() throws {
        let json = """
            {"$schema": "\(AgentPluginManifest.schemaIdentifier)", "name": "dad-update2", "version": "0.1.0",
             "description": "Draft a text update.", "author": {"name": "Example", "email": "example@example.com"}}
            """
        let manifest = try AgentPluginManifest.decodeAndValidate(Data(json.utf8))
        #expect(manifest.name == "dad-update2")
        #expect(manifest.author?.name == "Example")
    }

    @Test func theLoaderStillRefusesAnUnknownAuthorKey() {
        let json = """
            {"$schema": "\(AgentPluginManifest.schemaIdentifier)", "name": "dad-update2", "author": {"name": "Example", "twitter": "x"}}
            """
        #expect(throws: AgentPluginValidationError.self) {
            _ = try AgentPluginManifest.decodeAndValidate(Data(json.utf8))
        }
    }
}

import Foundation
import Testing

@testable import AgentToolingCore

struct PackageContractTests {
    @Test func canonicalManifestRoundTripsSchemaAndExtensions() throws {
        let manifest = try AgentPluginManifest(
            name: "developer-workflows",
            version: "1.0.0",
            description: "Portable development workflows",
            author: AgentPluginAuthor(name: "Agent Tooling"),
            license: "Apache-2.0",
            keywords: ["skills", "mcp"],
            extensions: [
                "com.example.claude": .object(["commands": .array([.string("review")])])
            ]
        )

        let data = try AgentToolingCoding.encoder().encode(manifest)
        let decoded = try AgentPluginManifest.decodeAndValidate(data)

        #expect(decoded == manifest)
        #expect(String(decoding: data, as: UTF8.self).contains("\"$schema\""))
    }

    @Test func canonicalManifestRejectsUnsafeNamesAndUnnamespacedExtensions() throws {
        #expect(throws: AgentPluginValidationError.self) {
            _ = try AgentPluginManifest(name: "Unsafe Name")
        }
        #expect(throws: AgentPluginValidationError.self) {
            _ = try AgentPluginManifest(
                name: "safe-name",
                extensions: ["claude": .object([:])]
            )
        }
        #expect(throws: AgentPluginValidationError.self) {
            _ = try AgentPluginManifest(
                name: "safe-name",
                extensions: ["com.example": .string("not an object")]
            )
        }
    }
}

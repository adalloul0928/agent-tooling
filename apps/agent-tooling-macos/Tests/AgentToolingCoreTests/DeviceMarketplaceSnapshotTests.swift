import Foundation
import Testing
@testable import AgentToolingCore

struct DeviceMarketplaceSnapshotTests {
    @Test func canonicalizesSetBackedFieldsWithoutChangingLegacyObjectShape() throws {
        let package = MarketplacePackage(
            id: "package", name: "Package", publisher: "Publisher", summary: "Summary", sourceID: UUID(), sourceName: "Catalog",
            revision: "r1", license: "MIT", components: [.mcpServer, .skill, .plugin], supportedClients: [.gemini, .claude, .codex],
            authentication: "OAuth", hasExecutableContent: true, trustSummary: "Reviewed", location: "https://example.com/package",
            isInstalled: true, requestedCredentialNames: [], conflicts: [], tools: [])
        let reversed = MarketplacePackage(
            id: package.id, name: package.name, publisher: package.publisher, summary: package.summary, sourceID: package.sourceID,
            sourceName: package.sourceName, revision: package.revision, license: package.license,
            components: [.plugin, .skill, .mcpServer], supportedClients: [.codex, .claude, .gemini],
            authentication: package.authentication, hasExecutableContent: package.hasExecutableContent, trustSummary: package.trustSummary,
            location: package.location, isInstalled: package.isInstalled, requestedCredentialNames: [], conflicts: [], tools: [])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(DeviceMarketplaceSnapshot(package))
        #expect(bytes == (try encoder.encode(DeviceMarketplaceSnapshot(reversed))))
        #expect(String(decoding: bytes, as: UTF8.self).contains("supportedClients"))
        #expect(try JSONDecoder().decode(DeviceMarketplaceSnapshot.self, from: bytes).package == package)
    }

    @Test func decodesEveryLegacyPackageFieldWithoutNestingThePackage() throws {
        let date = Date(timeIntervalSinceReferenceDate: 123_456.125)
        let package = MarketplacePackage(
            id: "package",
            name: "Package",
            publisher: "Publisher",
            summary: "Summary",
            sourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000042"),
            sourceName: "Catalog",
            revision: "r1",
            license: "MIT",
            components: [.skill, .plugin, .mcpServer],
            supportedClients: [.claude, .codex],
            authentication: "OAuth",
            hasExecutableContent: true,
            trustSummary: "Reviewed",
            location: "https://example.com/package",
            isInstalled: true,
            nativeInstalls: [
                NativeInstall(
                    client: .codex,
                    executable: "agent-tool",
                    arguments: ["install", "two words"],
                    removalArguments: ["remove"],
                    scope: .project,
                    detail: "Native route",
                    isInstalled: false
                )
            ],
            provenance: PackageProvenance(
                source: PackageSource(kind: .openAIPluginDirectory, location: "https://example.com/catalog"),
                lock: SourceLock(revision: "abcdef", digest: "sha256:123"),
                publisher: "Publisher"
            ),
            requestedCredentialNames: ["API_TOKEN"],
            ownership: .managed,
            updateStatus: .updateAvailable,
            conflicts: [PackageConflict(id: "conflict", summary: "Needs review")],
            lastUpdate: PackageUpdateRecord(date: date, origin: .catalogListing),
            tools: [
                MCPToolDescriptor(
                    name: "read",
                    title: "Read",
                    summary: "Reads data",
                    annotations: MCPToolAnnotations(readOnly: true),
                    inputFields: [MCPSchemaField(name: "query", type: "string", isRequired: true)],
                    outputFields: [MCPSchemaField(name: "result", type: "string")],
                    declaresInputSchema: true,
                    declaresOutputSchema: true
                )
            ]
        )

        let bytes = try JSONEncoder().encode(DeviceMarketplaceSnapshot(package))
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        #expect(object?["package"] == nil)
        #expect(object?["nativeInstalls"] != nil)
        #expect(try JSONDecoder().decode(DeviceMarketplaceSnapshot.self, from: bytes).package == package)
    }
}

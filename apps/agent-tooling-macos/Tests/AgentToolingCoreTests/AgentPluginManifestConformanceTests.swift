import Foundation
import Testing

@testable import AgentToolingCore

struct AgentPluginManifestConformanceTests {
    private static let schema = AgentPluginManifest.schemaIdentifier

    @Test func loaderReportsAndIgnoresEveryUnknownRootField() throws {
        let result = try load([
            "$schema": .string(Self.schema),
            "name": .string("valid-plugin"),
            "futureFlag": .bool(true),
            "publisherData": .object(["kept-out-of-model": .number(1)]),
        ])

        #expect(result.manifest.name == "valid-plugin")
        #expect(result.diagnostics == [
            .init(kind: .ignoredUnknownRootField("futureFlag")),
            .init(kind: .ignoredUnknownRootField("publisherData")),
        ])
    }

    @Test(arguments: invalidDefinedFieldCases)
    func loaderRejectsInvalidDefinedFields(_ testCase: InvalidFieldCase) throws {
        #expect(throws: AgentPluginValidationError.self) {
            _ = try load(testCase.root)
        }
    }

    @Test func loaderReportsAndIgnoresNonObjectExtensions() throws {
        let result = try load([
            "$schema": .string(Self.schema),
            "name": .string("valid-plugin"),
            "extensions": .array([.string("not an object")]),
        ])

        #expect(result.manifest.extensions == nil)
        #expect(result.diagnostics == [.init(kind: .ignoredNonObjectExtensions)])
    }

    @Test func loaderTreatsNullExtensionsAsTheDocumentedNonObjectException() throws {
        let result = try load([
            "$schema": .string(Self.schema),
            "name": .string("valid-plugin"),
            "extensions": .null,
        ])

        #expect(result.manifest.extensions == nil)
        #expect(result.diagnostics == [.init(kind: .ignoredNonObjectExtensions)])
    }

    @Test func loaderPreservesOpaqueExtensionValuesWithoutValidatingThem() throws {
        let opaque: [String: JSONValue] = [
            "not a valid namespace": .array([.null, .string("opaque"), .object(["unknown": .bool(true)])]),
        ]
        let result = try load([
            "$schema": .string(Self.schema),
            "name": .string("valid-plugin"),
            "extensions": .object(opaque),
        ])

        #expect(result.manifest.extensions == opaque)
        let reencoded = try AgentToolingCoding.encoder().encode(result.manifest)
        let roundTrip = try AgentToolingCoding.decoder().decode(AgentPluginManifest.self, from: reencoded)
        #expect(roundTrip.extensions == opaque)
    }

    @Test func loaderAppliesCustomLimitsOnlyWhenRequested() throws {
        let root: [String: JSONValue] = [
            "$schema": .string(Self.schema),
            "name": .string("valid-plugin"),
            "description": .string(String(repeating: "a", count: 9_000)),
        ]
        #expect(try load(root).manifest.description?.count == 9_000)
        #expect(throws: AgentPluginManifestPolicyError.self) {
            _ = try load(root, policy: .init(maximumCharactersByField: ["description": 10]))
        }
    }

    @Test func controlCharacterPolicyIncludesKeywords() throws {
        let root: [String: JSONValue] = [
            "$schema": .string(Self.schema),
            "name": .string("valid-plugin"),
            "keywords": .array([.string("contains\ncontrol")]),
        ]
        #expect(throws: AgentPluginManifestPolicyError.self) {
            _ = try load(root, policy: .init(rejectsControlCharacters: true))
        }
    }

    @Test func publicCodableDecodeUsesTheSameManifestValidation() throws {
        let data = try data([
            "$schema": .string(Self.schema),
            "name": .string("valid-plugin"),
            "description": .null,
            "unknown": .string("reported only by the diagnostic loader"),
        ])

        #expect(throws: AgentPluginValidationError.self) {
            _ = try AgentToolingCoding.decoder().decode(AgentPluginManifest.self, from: data)
        }
        #expect(throws: AgentPluginValidationError.self) {
            _ = try AgentPluginManifest.load(data)
        }
    }

    @Test func ignoredOverflowNumbersDoNotRejectTheLoaderOrCodableProjection() throws {
        let data = Data(
            """
            {"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"valid-plugin","futureValue":1e400,"extensions":{"com.example.future":{"limit":1e400}}}
            """.utf8
        )

        let loaded = try AgentPluginManifest.load(data)
        let decoded = try AgentToolingCoding.decoder().decode(AgentPluginManifest.self, from: data)

        #expect(loaded.manifest.name == "valid-plugin")
        #expect(decoded.name == "valid-plugin")
        #expect(loaded.extensionNamespaces == ["com.example.future"])
        #expect(loaded.diagnostics == [.init(kind: .ignoredUnknownRootField("futureValue"))])
        #expect(loaded.rawManifestData == data)
        #expect(loaded.manifest.extensions == nil)
    }

    private static let invalidDefinedFieldCases: [InvalidFieldCase] = [
        .init("missing schema", ["name": .string("valid-plugin")]),
        .init("missing name", ["$schema": .string(schema)]),
        .init("unsupported schema", ["$schema": .string("https://agent-plugins.org/schemas/2.0.0/plugin.schema.json"), "name": .string("valid-plugin")]),
        .init("null optional", ["$schema": .string(schema), "name": .string("valid-plugin"), "version": .null]),
        .init("wrong metadata type", ["$schema": .string(schema), "name": .string("valid-plugin"), "homepage": .number(3)]),
        .init("nonobject author", ["$schema": .string(schema), "name": .string("valid-plugin"), "author": .string("author")]),
        .init("unknown author field", ["$schema": .string(schema), "name": .string("valid-plugin"), "author": .object(["handle": .string("a")])]),
        .init("null author field", ["$schema": .string(schema), "name": .string("valid-plugin"), "author": .object(["name": .null])]),
        .init("nonstring keyword", ["$schema": .string(schema), "name": .string("valid-plugin"), "keywords": .array([.number(1)])]),
    ]

    struct InvalidFieldCase: Sendable {
        let name: String
        let root: [String: JSONValue]

        init(_ name: String, _ root: [String: JSONValue]) {
            self.name = name
            self.root = root
        }
    }

    private func load(
        _ root: [String: JSONValue],
        policy: AgentPluginManifestIngestionPolicy? = nil
    ) throws -> AgentPluginManifestLoadResult {
        try AgentPluginManifest.load(data(root), ingestionPolicy: policy)
    }

    private func data(_ root: [String: JSONValue]) throws -> Data {
        try AgentToolingCoding.encoder().encode(JSONValue.object(root))
    }
}

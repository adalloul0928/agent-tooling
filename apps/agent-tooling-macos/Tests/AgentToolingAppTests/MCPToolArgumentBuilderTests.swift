import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

@Suite("Generated tool argument encoding")
struct MCPToolArgumentBuilderTests {
    private var searchForm: MCPToolInputForm {
        MCPToolInputForm.make(
            from: .object([
                "type": .string("object"),
                "required": .array([.string("query")]),
                "properties": .object([
                    "query": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer")]),
                    "deep": .object(["type": .string("boolean")]),
                    "mode": .object(["type": .string("string"), "enum": .array([.string("fast"), .string("slow")])]),
                ]),
            ])
        )
    }

    @Test func typedFieldsBecomeTypedJSON() throws {
        let arguments = try MCPToolArgumentBuilder.build(
            form: searchForm,
            values: ["query": "hello", "limit": "5", "deep": "true", "mode": "fast"],
            rawObject: "{}"
        )

        #expect(arguments["query"] == .string("hello"))
        #expect(arguments["limit"] == .number(5))
        #expect(arguments["deep"] == .bool(true))
        #expect(arguments["mode"] == .string("fast"))
    }

    @Test func anEmptyOptionalFieldIsOmittedAndAnEmptyRequiredFieldIsRefused() throws {
        let arguments = try MCPToolArgumentBuilder.build(
            form: searchForm,
            values: ["query": "hello"],
            rawObject: "{}"
        )
        #expect(arguments.keys.sorted() == ["query"])

        #expect(throws: MCPToolArgumentError.self) {
            try MCPToolArgumentBuilder.build(form: searchForm, values: [:], rawObject: "{}")
        }
    }

    @Test func aNonNumericValueForANumberFieldIsRefused() {
        #expect(throws: MCPToolArgumentError.self) {
            try MCPToolArgumentBuilder.build(
                form: searchForm,
                values: ["query": "hello", "limit": "many"],
                rawObject: "{}"
            )
        }
        #expect(throws: MCPToolArgumentError.self) {
            try MCPToolArgumentBuilder.build(
                form: searchForm,
                values: ["query": "hello", "limit": "1.5"],
                rawObject: "{}"
            )
        }
    }

    @Test func anUnrenderableSchemaFallsBackToATypedJSONObject() throws {
        let form = MCPToolInputForm.make(from: .string("this is not an object schema"))

        let arguments = try MCPToolArgumentBuilder.build(
            form: form,
            values: [:],
            rawObject: #"{"filter":{"since":"2026-01-01"},"limit":3}"#
        )

        #expect(arguments["limit"] == .number(3))
        #expect(arguments["filter"] == .object(["since": .string("2026-01-01")]))

        #expect(throws: MCPToolArgumentError.self) {
            try MCPToolArgumentBuilder.build(form: form, values: [:], rawObject: "not json")
        }
        #expect(throws: MCPToolArgumentError.self) {
            try MCPToolArgumentBuilder.build(form: form, values: [:], rawObject: "[1,2,3]")
        }
    }

    @Test func aToolWithNoArgumentsProducesAnEmptyObject() throws {
        let form = MCPToolInputForm.make(from: .object(["type": .string("object"), "properties": .object([:])]))

        #expect(try MCPToolArgumentBuilder.build(form: form, values: [:], rawObject: "{}").isEmpty)
    }

    @Test func anOversizedArgumentPayloadIsRefused() {
        let form = MCPToolInputForm.make(from: .string("raw"))
        let oversized = "{\"a\":\"" + String(repeating: "x", count: MCPTestConnectionPolicy.maximumArgumentBytes) + "\"}"

        #expect(throws: MCPToolArgumentError.self) {
            try MCPToolArgumentBuilder.build(form: form, values: [:], rawObject: oversized)
        }
    }
}

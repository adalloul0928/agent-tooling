import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingMCP

/// What setup's Let your apps ask says the helper can do is what the helper
/// offers: the same tools, in the same order, split the same way into those
/// that look things up and those that only ask. And an agent may name any of
/// the four apps a request is for, Kiro CLI included.
@Suite("Agent Tooling connection · catalog")
struct AgentToolingConnectionCatalogTests {
    @Test func theLookUpToolsAreTheReadOnlyTools() {
        #expect(ToolCatalog.readOnlyTools.map(\.name) == AgentToolingConnection.lookUpTools.map(\.name))
        #expect(ToolCatalog.readOnlyTools.allSatisfy { $0.tier == .readOnly })
    }

    @Test func theAskToolsAreTheRequestTools() {
        #expect(ToolCatalog.reviewQueueTools.map(\.name) == AgentToolingConnection.askTools.map(\.name))
        #expect(ToolCatalog.reviewQueueTools.allSatisfy { $0.tier == .queuesReview })
        #expect(ToolCatalog.tools.count == AgentToolingConnection.lookUpTools.count + AgentToolingConnection.askTools.count)
    }

    @Test func aRequestMayNameEveryAppKiroCLIIncluded() throws {
        guard case .object(let schema) = ToolSchema.targets, case .object(let items)? = schema["items"],
            case .array(let names)? = items["enum"]
        else {
            Issue.record("the targets schema lists no names")
            return
        }
        #expect(names == ["codex", "claude-code", "gemini", "kiro-cli"].map(JSONValue.string))
        #expect(schema["maxItems"] == .number(Double(ClientKind.allCases.count)))

        let tool = try #require(ToolCatalog.reviewQueueTools.first { $0.name == "request_install_skill" })
        let all = try ToolArguments(
            tool: tool,
            params: .object(["arguments": .object(["targets": .array(names)])]))
        #expect(try all.requiredTargets().count == 4)
        let kiro = try ToolArguments(
            tool: tool, params: .object(["arguments": .object(["targets": .array([.string("kiro-cli")])])]))
        #expect(try kiro.requiredTargets() == [.kiro])
        let moon = try ToolArguments(
            tool: tool, params: .object(["arguments": .object(["targets": .array([.string("moon")])])]))
        let refusal = #expect(throws: ToolInputError.self) { try moon.requiredTargets() }
        guard case .notInEnumeration(_, let allowed)? = refusal else {
            Issue.record("a name outside the list is refused by naming the list")
            return
        }
        #expect(allowed == ["codex", "claude-code", "gemini", "kiro-cli"])
    }
}

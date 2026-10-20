import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingMCP

/// The review-link tool hands out links to screens, and the setup stage is
/// not one: `agent-tooling://setup` opens a window of its own, so a client of
/// this server can neither be offered it nor have it built.
@Suite("Review links never open setup")
struct OpenReviewScreenSetupTests {
    @Test func theToolDoesNotOfferTheSetupLink() throws {
        let tool = try #require(ToolCatalog.tools.first { $0.name == "open_review_screen" })
        guard case .object(let schema) = tool.inputSchema, case .object(let properties)? = schema["properties"],
            case .object(let screen)? = properties["screen"], case .array(let values)? = screen["enum"]
        else {
            Issue.record("open_review_screen lists no screens")
            return
        }
        let screens = values.compactMap(\.stringValue)
        #expect(screens.contains("overview"))
        #expect(!screens.contains("setup"))
    }

    @Test func theToolRefusesToBuildTheSetupLink() throws {
        let harness = try MCPTestHarness()
        try harness.initialize()

        let response = harness.rawCallTool("open_review_screen", arguments: ["screen": .string("setup")])

        #expect(response?["error"] != nil)
    }
}

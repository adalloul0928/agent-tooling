import Foundation
import Testing

@testable import AgentToolingCore

/// Agent Tooling's own connection is known by its name. A connection a person
/// pastes or adds from a catalog under that name would read as the own one,
/// left out of the library and labelled as Agent Tooling's in each app, so
/// those ways in refuse it; only setup's Let your apps ask records it.
@Suite("Managed MCP server intake · the reserved name")
struct ManagedMCPServerIntakeReservedNameTests {
    @Test(arguments: ["Agent Tooling", "agent-tooling", "AGENT-TOOLING"])
    func aPasteUnderTheOwnConnectionsNameIsRefused(_ name: String) throws {
        var draft = MCPDraft()
        draft.name = name
        draft.endpoint = "/Users/example/src/agent-tooling/.build/debug/agent-tooling-mcp"
        draft.transport = .stdio
        draft.authentication = "None"
        let command = try ManagedMCPServerIntakeCommand(expectedRevisionID: WorkspaceObjectID(), draft: draft)

        #expect(ManagedMCPServerIntakeCommand.isReservedName(command.declaredName))
        #expect(throws: ManagedMCPServerIntakeError.reservedName(command.declaredName)) { try command.refusingReservedName() }
        #expect(
            ManagedMCPServerIntakeError.reservedName("agent-tooling").errorDescription
                == "agent-tooling is the name of Agent Tooling’s own connection, which setup’s Let your apps ask adds. "
                + "Choose another name. Nothing was saved.")
    }

    @Test func anyOtherNameIsTaken() throws {
        var draft = MCPDraft()
        draft.name = "Agent Tooling Dev"
        draft.endpoint = "/Users/example/src/agent-tooling/.build/debug/agent-tooling-mcp"
        draft.transport = .stdio
        draft.authentication = "None"
        let command = try ManagedMCPServerIntakeCommand(expectedRevisionID: WorkspaceObjectID(), draft: draft)

        #expect(command.declaredName == "agent-tooling-dev")
        #expect(throws: Never.self) { try command.refusingReservedName() }
    }
}

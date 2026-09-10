import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The paste sheet's server path, end to end and with stubs only.
///
/// Two things are worth checking here rather than in the command's own tests:
/// that the sheet a person opens from Connections actually draws in both the
/// paste and the add-a-connection shapes, and that a connection recorded
/// through it comes back out of the library as one the console can test.
@Suite("Paste import · connections")
@MainActor
struct PasteImportServerIntakeTests {
    @Test func theAddConnectionSheetDrawsItsFormWithNothingPasted() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try captureMCPPane(
            PasteImportSheet(workspace: fixture.workspace, mode: .newConnection),
            named: "add-connection")
    }

    @Test func aConnectionRecordedThroughTheSheetsCommandLightsTheConsole() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        var draft = MCPDraft()
        draft.name = "Linear"
        draft.endpoint = "https://mcp.linear.app/sse"
        draft.transport = .http

        let head = try #require(try await fixture.workspace.service.snapshot()).document.revision.id
        _ = try await fixture.workspace.service.intakeManagedMCPServer(
            .init(expectedRevisionID: head, draft: draft))
        await fixture.workspace.library.refresh()

        let library = try #require(fixture.workspace.library.state?.library)
        let projected = try #require(
            VersionedInventoryProjection.inventory(library).mcpServers
                .first { $0.name == "Linear" })
        #expect(projected.isManagedDefinition)
        #expect(
            try MCPTestConnectionPolicy.resolve(server: projected)
                == .http(url: try #require(URL(string: "https://mcp.linear.app/sse"))))

        // The fixture's own tracked server is still what it was: recording one
        // connection says nothing about a server somebody merely observed.
        let observed = try #require(
            VersionedInventoryProjection.inventory(library).mcpServers
                .first { $0.name == "Example Server" })
        #expect(!observed.isManagedDefinition)
        #expect(observed.endpoint.isEmpty)

        try captureMCPPane(renderShell(.mcpServers, fixture: fixture), named: "connections-recorded")
    }

    @Test func aRecordedConnectionIsARowAnAgentsRequestCanLandOn() async throws {
        let fixture = try await ShellRenderFixture(requestQueue: LivePendingRequestQueue())
        defer { fixture.remove() }
        let endpoint = "https://mcp.linear.app/sse"
        let request = try PendingRequestQueueService.enqueue(
            kind: .addMCPServer, title: "Add Linear",
            summary: "A local client asked for the Linear connection.",
            componentID: "Linear", scope: .user, targets: [.claude], reason: nil,
            reviewDetails: .init(endpoint: endpoint, transport: MCPTransport.http.rawValue),
            fingerprintInputs: ["Linear", MCPTransport.http.rawValue, endpoint, ""],
            clientLabel: "Claude Code", store: fixture.store
        ).request

        // Approving never creates a library item, so before the connection is
        // recorded there is nothing for the request to land on.
        await fixture.workspace.requests.refresh()
        guard case .refused(let reason) = await fixture.workspace.requests.accept(request) else {
            Issue.record("a request naming nothing in the library was accepted")
            return
        }
        #expect(reason.contains("is not in your library"))

        var draft = MCPDraft()
        draft.name = "Linear"
        draft.endpoint = endpoint
        draft.transport = .http
        let head = try #require(try await fixture.workspace.service.snapshot()).document.revision.id
        _ = try await fixture.workspace.service.intakeManagedMCPServer(
            .init(expectedRevisionID: head, draft: draft))
        await fixture.workspace.library.refresh()
        await fixture.workspace.requests.refresh()

        let waiting = try #require(fixture.workspace.requests.requests.first)
        #expect(await fixture.workspace.requests.accept(waiting) == .assignmentSaved)

        // What landed is a saved choice about where the connection is wanted,
        // and nothing more.
        let snapshot = try #require(try fixture.store.snapshot())
        #expect(snapshot.document.assignments.count == 1)
        #expect(snapshot.document.assignments.first?.destination.surface == .claudeCode)
    }

    @Test func theSheetReadsTheDroppedCredentialNamesStraightOffTheDraft() throws {
        let pasted = """
            claude mcp add tenant --transport http --url https://mcp.example.com/rpc \
            -e API_KEY=super-secret-value -H X-Tenant=acme-secret
            """
        guard case .mcp(let result) = try PastedDefinitionParser.parse(pasted),
            let server = result.servers.first
        else {
            Issue.record("the paste did not read as an MCP server")
            return
        }

        #expect(server.secretNames == ["API_KEY", "X-Tenant"])
        // The values the parser dropped are nowhere in what it handed back.
        for note in server.notes {
            #expect(!note.contains("super-secret-value"))
            #expect(!note.contains("acme-secret"))
        }
    }
}

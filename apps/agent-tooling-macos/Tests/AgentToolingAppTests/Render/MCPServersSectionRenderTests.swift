import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The connections tab draws inside the Library family.
@Suite("Library · Connections renders")
@MainActor
struct MCPServersSectionRenderTests {
    @Test func theShellDrawsMCPServers() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(fixture.connectionsScreen())
    }

    @Test func theDetailPaneDrawsForAServerNobodyMayAssign() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let entry = try #require(fixture.connectionEntries.first)

        // The fixture's server is tracked only, which is exactly the case the
        // pane must state rather than offer an action for.
        #expect(entry.isAssignable == false)
        #expect(entry.assignmentExplanation != nil)

        try expectDrawn(
            MCPDetailView(
                entry: entry, workspaceRoot: fixture.home, isBusy: false,
                onAssign: {}, onRemove: { _ in }
            )
            .environment(MCPCapabilityModel()))
    }

    @Test func theDetailPaneDrawsARequestedServerWithoutClaimingItIsInstalled() throws {
        let entry = MCPConnectionFixture.entry(
            name: "Linear",
            requested: [MCPConnectionFixture.request(.claudeCode), MCPConnectionFixture.request(.codexCLI)])

        // Two saved requests, and no app that actually carries it.
        #expect(entry.routedClients.isEmpty)
        #expect(entry.verdict.state == .pending)
        #expect(entry.verdict.text == "Asked for in 2 places")
        #expect(entry.server.clients.allSatisfy { $0.reportsLocalPresence == false })

        try captureMCPPane(
            MCPDetailView(
                entry: entry, workspaceRoot: FileManager.default.temporaryDirectory, isBusy: false,
                onAssign: {}, onRemove: { _ in }
            )
            .environment(MCPCapabilityModel()),
            named: "detail-requested")
    }

    @Test func aNativeRouteIsTheOnlyThingThatLightsTheAppMarks() {
        let routed = MCPConnectionFixture.entry(
            name: "Bundled", ownershipLabel: "Managed by its app", isManaged: false,
            routes: [.init(client: .claude, externalPluginID: "example@vendor")],
            requested: [MCPConnectionFixture.request(.codexCLI)],
            isAssignable: false, explanation: "Its app owns this one.")

        // The request for Codex is a saved choice; only the Claude route is a
        // claim about what an app actually carries.
        #expect(routed.routedClients == [.claude])
        #expect(routed.involvedClients == [.claude, .codex])
        #expect(routed.verdict.state == .healthy)
        #expect(routed.verdict.text == "In Claude Code")
    }

    @Test func aServerNobodyHasAskedForSaysSo() {
        let idle = MCPConnectionFixture.entry(name: "Unused")

        #expect(idle.needsADecision)
        #expect(idle.verdict.text == "Not asked for anywhere")
    }

    @Test func theStackPaneDrawsAndKeepsUnassignableItemsOutOfTheReview() throws {
        let entries = [
            MCPConnectionFixture.entry(name: "Alpha"),
            MCPConnectionFixture.entry(
                name: "Beta", ownershipLabel: "Managed by its app", isManaged: false,
                isAssignable: false, explanation: "Its app owns this one."),
        ]

        try captureMCPPane(
            MCPStackPane(entries: entries, isBusy: false, onAssign: {}, onClear: {}),
            named: "stack")
    }

    @Test func thePasteSheetDrawsAndExplainsWhereAServerDefinitionCannotGo() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        // The explanation is the whole point of the server branch, so it is
        // asserted rather than left to the pixels.
        #expect(PasteImportSheet.noServerIntakeExplanation.contains("no command"))

        try captureMCPPane(PasteImportSheet(workspace: fixture.workspace), named: "paste")
    }

    @Test func aPastedSkillBecomesFrontmatterTheWorkspaceCanRead() throws {
        var draft = SkillDraft()
        draft.name = "Release Notes"
        draft.purpose = "Draft release notes from a changelog: \"quoted\" and all."
        draft.triggers = ["release notes", "", "changelog"]
        draft.negativeTrigger = "Do not use it for marketing copy."

        let markdown = PasteImportSheet.skillMarkdown(
            identifier: "release-notes", displayName: "Release Notes", draft: draft)
        let frontmatter = try SkillFrontmatter.parse(markdown)

        #expect(frontmatter.name == "release-notes")
        #expect(frontmatter.description.contains("changelog"))
        #expect(markdown.contains("- release notes"))
        #expect(markdown.contains("Do not use it for marketing copy."))
    }
}

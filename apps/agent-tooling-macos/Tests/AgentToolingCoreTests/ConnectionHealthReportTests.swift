import Foundation
import Testing

@testable import AgentToolingCore

/// The parser is a pure function over a client's listing, so every status shape
/// the two clients print is pinned to a fixed string here — no process, no
/// machine state. A shape it has not seen becomes `.unknown` carrying the line
/// rather than being misread.
@Suite("Connection health report parsing")
struct ConnectionHealthReportTests {
    @Test func aConnectedServerParses() throws {
        let entries = ConnectionHealthReport.parse(
            client: .claude,
            text: "everything: npx -y @scope/server - ✔ Connected")
        try #require(entries.count == 1)
        let entry = entries[0]
        #expect(entry.name == "everything")
        #expect(entry.status == .connected)
        #expect(entry.summary == "npx -y @scope/server")
        #expect(entry.source == .unknown)
    }

    @Test func aFailedServerKeepsTheDetailAfterTheEmDash() throws {
        let entries = ConnectionHealthReport.parse(
            client: .claude,
            text: "git: https://mcp.example.com/sse - ✘ Failed to connect — connection refused")
        try #require(entries.count == 1)
        #expect(entries[0].status == .failed(detail: "connection refused"))
        #expect(entries[0].isRemoteEndpoint)
    }

    @Test func needsAuthenticationParses() throws {
        let entries = ConnectionHealthReport.parse(
            client: .claude,
            text: "linear: https://mcp.linear.app/sse - ! Needs authentication")
        try #require(entries.count == 1)
        #expect(entries[0].status == .needsAuthentication)
    }

    @Test func pendingApprovalParses() throws {
        let entries = ConnectionHealthReport.parse(
            client: .claude,
            text: "review: npx server - ⏸ Pending approval (run `claude` to approve)")
        try #require(entries.count == 1)
        #expect(entries[0].status == .pendingApproval)
    }

    @Test func disabledParses() throws {
        let entries = ConnectionHealthReport.parse(
            client: .claude,
            text: "old: npx server - ⊘ Disabled for this project (re-enable via /mcp)")
        try #require(entries.count == 1)
        #expect(entries[0].status == .disabled)
    }

    /// A tail this parser has not seen is kept verbatim rather than folded into
    /// failed, so an unfamiliar client update is shown as-is.
    @Test func anUnfamiliarStatusIsKeptAsUnknown() throws {
        let entries = ConnectionHealthReport.parse(
            client: .claude,
            text: "weird: npx server - ✽ Reticulating splines")
        try #require(entries.count == 1)
        #expect(entries[0].status == .unknown(rawText: "✽ Reticulating splines"))
    }

    /// A plugin server is named `plugin:<plugin>:<server>`; the display name is
    /// the server, the source is the plugin.
    @Test func aPluginServerStripsThePrefixIntoAPluginName() throws {
        let entries = ConnectionHealthReport.parse(
            client: .claude,
            text: "plugin:devtools:inspector: npx inspector - ✔ Connected")
        try #require(entries.count == 1)
        #expect(entries[0].name == "plugin:devtools:inspector")
        #expect(entries[0].displayName == "inspector")
        #expect(entries[0].source == .plugin("devtools"))
        #expect(entries[0].pluginName == "devtools")
    }

    /// A claude.ai connector is marked from the indicator in its line.
    @Test func aClaudeAIConnectorIsRecognised() throws {
        let entries = ConnectionHealthReport.parse(
            client: .claude,
            text: "Gmail: claude.ai connector - ! Needs authentication")
        try #require(entries.count == 1)
        #expect(entries[0].isClaudeAIConnector)
        #expect(entries[0].source == .claudeAI)
    }

    /// The health-check header line has no server shape and is skipped.
    @Test func theHeaderLineIsSkipped() {
        let entries = ConnectionHealthReport.parse(
            client: .claude,
            text: "Checking MCP server health…\nfoo: npx foo - ✔ Connected")
        #expect(entries.count == 1)
        #expect(entries.first?.name == "foo")
    }

    /// A bearer token in a printed header never reaches the parsed summary.
    @Test func aTokenInTheSummaryIsRedacted() throws {
        let entries = ConnectionHealthReport.parse(
            client: .claude,
            text: "api: npx server --header Authorization: Bearer sk-abcdef0123456789abcd - ✔ Connected")
        try #require(entries.count == 1)
        #expect(!entries[0].summary.contains("sk-abcdef0123456789abcd"))
        #expect(entries[0].summary.contains("[redacted]"))
    }

    /// Codex reports no health in its listing, so JSON entries come back
    /// unknown, carrying the URL as their summary.
    @Test func codexJSONListsServersAsUnknown() throws {
        let json = """
            {"mcpServers": {"docs": {"url": "https://mcp.docs.example/sse"}}}
            """
        let entries = ConnectionHealthReport.parseCodex(jsonOrText: json)
        try #require(entries.count == 1)
        #expect(entries[0].client == .codex)
        #expect(entries[0].name == "docs")
        #expect(entries[0].summary == "https://mcp.docs.example/sse")
        if case .unknown = entries[0].status {} else { Issue.record("expected unknown status") }
    }

    /// When Codex answers a text table rather than JSON, the reader falls back
    /// to it and still lists servers as unknown.
    @Test func codexFallsBackToTheTextTable() throws {
        let table = "Name    Command\nlocal   npx -y @scope/local"
        let entries = ConnectionHealthReport.parseCodex(jsonOrText: table)
        try #require(entries.count == 1)
        #expect(entries[0].name == "local")
    }

    /// Kiro lists servers with no health check; every entry is unknown.
    @Test func kiroListsServersAsUnknown() throws {
        let entries = ConnectionHealthReport.parse(
            client: .kiro,
            text: "fetch  uvx mcp-server-fetch")
        try #require(entries.count == 1)
        #expect(entries[0].client == .kiro)
        #expect(entries[0].name == "fetch")
        if case .unknown = entries[0].status {} else { Issue.record("expected unknown status") }
    }
}

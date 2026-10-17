import Foundation
import Testing

@testable import AgentToolingCore

/// The offer on a row is a pure function of the entry, so the reasoning that
/// decides which button shows is pinned here rather than left to the view.
@Suite("Connection health action classification")
struct ConnectionHealthActionTests {
    private func entry(
        client: ClientKind = .claude,
        name: String = "server",
        source: ConnectionHealthSource = .unknown,
        status: ConnectionHealthStatus,
        summary: String = "https://mcp.example.com/sse"
    ) -> ConnectionHealthEntry {
        ConnectionHealthEntry(
            client: client, name: name, displayName: name, source: source,
            status: status, summary: summary, rawLine: name)
    }

    /// A remote server that needs authentication is signed in through its
    /// client's own flow.
    @Test func remoteNeedsAuthenticationOffersReauthenticate() {
        let action = ConnectionHealthActionClassifier.action(
            for: entry(status: .needsAuthentication))
        #expect(action == .reauthenticate(client: .claude, name: "server"))
    }

    /// A remote failure is also a login, since that is what a failed remote
    /// server most often needs.
    @Test func remoteFailureOffersReauthenticate() {
        let action = ConnectionHealthActionClassifier.action(
            for: entry(status: .failed(detail: "token expired")))
        #expect(action == .reauthenticate(client: .claude, name: "server"))
    }

    /// A stdio server that failed is reconnected in the client, not signed in
    /// from here.
    @Test func localFailureOffersReconnectOnly() {
        let action = ConnectionHealthActionClassifier.action(
            for: entry(status: .failed(detail: "spawn error"), summary: "npx -y @scope/server"))
        if case .reconnectOnly = action {} else { Issue.record("expected reconnectOnly, got \(action)") }
    }

    /// A hosted connector cannot OAuth locally, so the only useful move is the
    /// connectors page — even when it is a remote endpoint.
    @Test func aClaudeAIConnectorOpensTheConnectorsPage() {
        let action = ConnectionHealthActionClassifier.action(
            for: entry(source: .claudeAI, status: .needsAuthentication))
        #expect(action == .openClaudeAIConnectors)
    }

    /// An Anthropic-hosted failure detail routes to the connectors page even
    /// without the connector source flag.
    @Test func anAnthropicHostedFailureOpensTheConnectorsPage() {
        let action = ConnectionHealthActionClassifier.action(
            for: entry(status: .failed(detail: "is Anthropic-hosted and doesn't support local OAuth")))
        #expect(action == .openClaudeAIConnectors)
    }

    /// A rejected session token is a client login problem, answered on the
    /// connectors page rather than by a per-server login.
    @Test func aRejectedSessionTokenOpensTheConnectorsPage() {
        let action = ConnectionHealthActionClassifier.action(
            for: entry(status: .failed(detail: "connected · session token rejected")))
        #expect(action == .openClaudeAIConnectors)
    }

    @Test func pendingApprovalOffersReconnectOnly() {
        let action = ConnectionHealthActionClassifier.action(for: entry(status: .pendingApproval))
        if case .reconnectOnly = action {} else { Issue.record("expected reconnectOnly, got \(action)") }
    }

    @Test func settledStatesOfferNothing() {
        for status in [ConnectionHealthStatus.connected, .disabled, .notConfigured] {
            #expect(ConnectionHealthActionClassifier.action(for: entry(status: status)) == .none)
        }
    }

    @Test func theConnectorsURLIsTheOneConstant() throws {
        let url = try #require(ConnectionHealthAction.claudeAIConnectorsURL)
        #expect(url.absoluteString == "https://claude.ai/customize/connectors")
    }
}

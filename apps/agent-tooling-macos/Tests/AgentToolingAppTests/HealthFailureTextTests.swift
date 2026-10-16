import AgentToolingCore
import Testing

@testable import AgentToolingApp

/// Pins what Health shows for a failed check. The bug: a CLI fragment such as
/// "is Anthropic-hosted and doesn't support local OAuth" was shown verbatim,
/// reading as a broken sentence.
@Suite("Health failure text")
struct HealthFailureTextTests {
    @Test("A claude.ai connector gets the app's own sentence")
    func claudeAIConnector() {
        #expect(
            HealthFailureText.text(
                detail: "is Anthropic-hosted and doesn't support local OAuth",
                routesToClaudeAIConnectors: true)
                == "This connector runs on claude.ai, so you sign in to it there.")
    }

    @Test("Any other failure keeps its detail with a capital first letter")
    func otherFailureCapitalizes() {
        #expect(
            HealthFailureText.text(detail: "is Anthropic-hosted and doesn't support local OAuth", routesToClaudeAIConnectors: false)
                == "Is Anthropic-hosted and doesn't support local OAuth")
        #expect(
            HealthFailureText.text(detail: "the server stopped responding", routesToClaudeAIConnectors: false)
                == "The server stopped responding")
    }

    @Test("An already-capitalized detail is left as written")
    func leavesCapitalizedDetail() {
        #expect(
            HealthFailureText.text(detail: "Timed out", routesToClaudeAIConnectors: false) == "Timed out")
    }

    /// The fragment the review saw is the check's own detail on the row, under
    /// the connection's name. The first fix reached only the sign-in result
    /// line, so the row still printed it verbatim.
    @Test("A failed check's own detail on the row reads as a sentence")
    func failedCheckDetailOnTheRow() {
        let gmail = entry(
            "Gmail", source: .claudeAI, status: .failed(detail: "is Anthropic-hosted and doesn't support local OAuth"))
        #expect(
            HealthFailureText.statusDetail(of: gmail, action: ConnectionHealthActionClassifier.action(for: gmail))
                == HealthFailureText.claudeAISentence)

        let local = entry("inspector", source: .plugin("devtools"), status: .failed(detail: "connection refused"))
        #expect(
            HealthFailureText.statusDetail(of: local, action: ConnectionHealthActionClassifier.action(for: local))
                == "Connection refused")

        let connected = entry("local", source: .user, status: .connected)
        #expect(HealthFailureText.statusDetail(of: connected, action: .none) == nil)
        let silent = entry("quiet", source: .user, status: .failed(detail: ""))
        #expect(HealthFailureText.statusDetail(of: silent, action: .none) == nil)
    }

    private func entry(_ name: String, source: ConnectionHealthSource, status: ConnectionHealthStatus) -> ConnectionHealthEntry {
        ConnectionHealthEntry(
            client: .claude, name: name, displayName: name, source: source, status: status,
            summary: "npx \(name)", rawLine: "\(name): npx \(name)")
    }
}

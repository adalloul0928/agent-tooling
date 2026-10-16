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
}

import AgentToolingCore

/// The sentence shown for a failed connection health check, kept apart from
/// the view so both outcomes can be pinned in a test.
///
/// A failure detail reaches Health as a verbatim CLI fragment, for example
/// "is Anthropic-hosted and doesn't support local OAuth" from `claude mcp
/// list`, which reads as a broken sentence. When the entry's only fix is the
/// claude.ai connectors page, the app substitutes its own whole sentence;
/// every other failure keeps its detail but with a capital first letter.
enum HealthFailureText {
    static let claudeAISentence = "This connector runs on claude.ai, so you sign in to it there."

    static func text(detail: String, routesToClaudeAIConnectors: Bool) -> String {
        routesToClaudeAIConnectors ? claudeAISentence : detail.capitalizedFirst
    }

    /// The line a row shows under a connection the check found failing, or
    /// nil when it did not fail or said nothing about why. The check's own
    /// detail is where the fragment above appears, so it is read the same way
    /// as a failed sign-in.
    static func statusDetail(of entry: ConnectionHealthEntry, action: ConnectionHealthAction) -> String? {
        guard case .failed(let detail) = entry.status, !detail.isEmpty else { return nil }
        return text(detail: detail, routesToClaudeAIConnectors: action == .openClaudeAIConnectors)
    }
}

import Testing

@testable import AgentToolingApp

/// Health's sign-in-to-all confirmation and its button's tooltip. With one
/// connection the heading read "Sign in to 1 connection" over a body that
/// opened pages "one connection after another", and the tooltip promised to
/// sign in to it "one at a time".
@Suite("Bulk sign-in wording")
@MainActor
struct BulkSignInWordingTests {
    @Test("One connection is signed in to, not one after another")
    func oneConnection() {
        let text = BulkReauthenticateConfirmation.explanation(count: 1)
        #expect(
            text
                == "The sign-in prints a page to visit; Agent Tooling opens it in your browser and waits for the tool to confirm.")
        #expect(!text.contains("one connection after another"))
        #expect(!text.hasPrefix("Each"))
    }

    @Test("Several connections are opened one after another")
    func severalConnections() {
        #expect(
            BulkReauthenticateConfirmation.explanation(count: 3)
                == "Each sign-in prints a page to visit; Agent Tooling opens it in your browser, "
                + "one connection after another, and waits for the tool to confirm.")
    }

    @Test("The tooltip paces only several sign-ins")
    func tooltipAgreesWithTheCount() {
        #expect(
            HealthView.bulkHelpText(count: 1, commands: ["claude mcp reauth linear"])
                == "Signs in to 1 connection:\nclaude mcp reauth linear")
        #expect(
            HealthView.bulkHelpText(count: 2, commands: ["claude mcp reauth linear", "codex mcp login github"])
                == "Signs in to 2 connections, one at a time:\nclaude mcp reauth linear\ncodex mcp login github")
    }
}

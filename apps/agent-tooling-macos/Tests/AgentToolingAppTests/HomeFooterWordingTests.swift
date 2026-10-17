import Testing

@testable import AgentToolingApp

/// The line under Home's update cards that says what installs on its own. It
/// lowercased each kind's singular display name, so it read "Updates to skill
/// and mcp server install on their own", and the two cards pointed at the
/// Settings rows that set this in two different ways.
@Suite("Home footer wording")
@MainActor
struct HomeFooterWordingTests {
    @Test("The review card names the automatic kinds in the plural, as the Settings rows do")
    func updatesFooterNamesKindsLikeSettings() {
        #expect(
            OverviewView.updatesFooter(automatic: [.skill, .mcpServer])
                == "Updates to skills and connections install on their own (Settings › General › Updates). "
                + "Everything else waits here.")
        #expect(
            OverviewView.updatesFooter(automatic: [.plugin])
                == "Updates to plugins install on their own (Settings › General › Updates). Everything else waits here.")
    }

    @Test("The other-Macs card uses the same nouns and the same path")
    func incomingFooterNamesKindsLikeSettings() {
        #expect(
            OverviewView.incomingFooter(automatic: [.skill, .mcpServer])
                == "Arriving skills and connections install on their own (Settings › General › Updates). The rest wait here.")
    }

    @Test("Nothing automatic says that nothing installs on its own")
    func nothingAutomatic() {
        #expect(OverviewView.updatesFooter(automatic: []) == "Nothing installs until you approve it here.")
        #expect(
            OverviewView.incomingFooter(automatic: [])
                == "Nothing from another Mac installs here until you press Install.")
    }

    @Test("No footer says MCP server, in any case")
    func noFooterSaysServer() {
        let footers = [
            OverviewView.updatesFooter(automatic: [.skill, .plugin, .mcpServer]),
            OverviewView.incomingFooter(automatic: [.skill, .plugin, .mcpServer]),
        ]
        for footer in footers {
            #expect(!footer.localizedCaseInsensitiveContains("server"), "\(footer) names a server")
        }
    }
}

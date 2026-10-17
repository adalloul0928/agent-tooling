import AgentToolingCore
import Foundation
import Testing

@testable import AgentToolingApp

/// The words the Skills, Projects and Activity screens build from data rather
/// than write out: what they call a library item, and how they count one.
/// The app names the library item a "connection" and an installed item a
/// "copy" everywhere else, and one of anything reads in the singular.
@Suite("Skills, Projects and Activity wording")
struct SkillsProjectsActivityWordingTests {
    private func component(_ id: String, kind: ComponentKind) -> ProjectComponentRecord {
        ProjectComponentRecord(
            id: id, name: id, kind: kind, client: .claude, sharing: .committed,
            sourceRelativePath: ".mcp.json", sourcePath: nil)
    }

    private func folder(
        skills: Int = 0, connections: Int = 0, plugins: Int = 0, branch: String? = nil, detached: Bool = false
    ) -> DiscoveredProject {
        DiscoveredProject(
            path: "/tmp/found", name: "found", gitBranch: branch, isDetachedHead: detached,
            skills: (0..<skills).map { component("skill-\($0)", kind: .skill) },
            mcpServers: (0..<connections).map { component("connection-\($0)", kind: .mcpServer) },
            plugins: (0..<plugins).map { component("plugin-\($0)", kind: .plugin) })
    }

    @Test("A found folder counts its connections as connections, one in the singular")
    func foundFolderNamesConnections() {
        #expect(folder(connections: 1).foundFolderSummary == "1 connection")
        #expect(folder(connections: 2).foundFolderSummary == "2 connections")
        #expect(!folder(connections: 3).foundFolderSummary.contains("server"))
    }

    @Test("A found folder lists each kind it holds, in the singular for one")
    func foundFolderCountsEachKind() {
        #expect(
            folder(skills: 1, connections: 1, plugins: 1, branch: "main").foundFolderSummary
                == "1 skill · 1 connection · 1 plugin · on main")
        #expect(folder(skills: 2, plugins: 3).foundFolderSummary == "2 skills · 3 plugins")
        #expect(folder(skills: 1, branch: "4f2a9c1", detached: true).foundFolderSummary == "1 skill · at 4f2a9c1")
    }

    @Test("A found folder with nothing of the library's says so rather than reading as empty")
    func foundFolderWithNothingSaysSo() {
        #expect(folder().foundFolderSummary == "No agent files")
        #expect(folder(branch: "main").foundFolderSummary == "No agent files · on main")
    }

    /// The Activity tab is "Receipts", and the list under it was headed
    /// "Receipts" too: the same word twice, one over the other.
    @Test("The receipts list is headed with what its tab does not already say")
    func receiptsHeadingAddsToTheTab() {
        #expect(ActivityView.listHeading == "Recorded on this Mac")
        #expect(!ActivityView.listHeading.localizedCaseInsensitiveContains(AppSection.activity.tabTitle))
    }

    @Test("Drift names installed copies, and one copy in the singular")
    func driftNamesInstalledCopies() {
        #expect(InstallDriftNotice.title(count: 1) == "1 installed copy differs from what you reviewed")
        #expect(InstallDriftNotice.title(count: 2) == "2 installed copies differ from what you reviewed")
        #expect(!InstallDriftNotice.title(count: 2).contains("package"))
    }

    @Test("The source editor says how far the line count moved, one line in the singular")
    func sourceEditorLineDelta() {
        let summary = SkillSourceEditorSheet.changeSummary(from:to:)
        #expect(summary("a\nb", "a\nb") == "0 changed · same line count")
        #expect(summary("a\nb", "a\nc\nd") == "1 changed · +1 line")
        #expect(summary("a", "a\nb\nc") == "0 changed · +2 lines")
        #expect(summary("a\nb\nc", "a\nb") == "0 changed · -1 line")
        #expect(summary("a\nb\nc", "x") == "1 changed · -2 lines")
    }

    @Test("A scan source counts its conversations, as the heading does, and one in the singular")
    func coverageCounts() {
        #expect(CoverageRow.countsText(conversations: 1, items: 1) == "1 conversation · 1 item")
        #expect(CoverageRow.countsText(conversations: 12, items: 0) == "12 conversations · 0 items")
    }

    @Test("VoiceOver hears the scanning state in the words on screen")
    func scanningStateReadsAsShown() {
        #expect(
            InsightsView.scanningAccessibilityLabel
                == "Reviewing recent work. The scan is read-only. No skill, plugin, or connection will be installed.")
    }

    private func recommendation(_ kind: ToolRecommendationKind, packageID: String? = nil) -> ToolRecommendation {
        ToolRecommendation(
            id: "r", kind: kind, title: "t", summary: "s", rationale: "r", confidence: .high,
            supportingConversationCount: 1, marketplacePackageID: packageID)
    }

    @Test("Creating a skill names the assistant that will draft it, and opens a sheet")
    func createNamesTheDraftingAssistant() {
        let create = recommendation(.createCustomSkill)
        #expect(RecommendationRow.actionTitle(for: create, assistant: .claude) == "Create with Claude Code…")
        #expect(RecommendationRow.actionTitle(for: create, assistant: .codex) == "Create with Codex…")
        // The request review sheet's create button is titled by the same builder.
        for assistant in ClientKind.allCases {
            #expect(RecommendationRow.actionTitle(for: create, assistant: assistant) == ActionTitles.createSkill(with: assistant))
        }
    }

    @Test("Opening a skill or Discover only navigates, so takes no ellipsis")
    func navigatingActionsTakeNoEllipsis() {
        #expect(RecommendationRow.actionTitle(for: recommendation(.useExistingSkill), assistant: .claude) == "Open skill")
        #expect(RecommendationRow.actionTitle(for: recommendation(.plugin), assistant: .claude) == "Browse Discover")
        #expect(
            RecommendationRow.actionTitle(for: recommendation(.mcpServer, packageID: "p"), assistant: .claude)
                == "Review in Discover")
    }
}

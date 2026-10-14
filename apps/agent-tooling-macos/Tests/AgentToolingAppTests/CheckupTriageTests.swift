import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Hundreds of findings become a handful of rows, each in the right bucket
/// with the right one button.
@Suite("Checkup triage")
struct CheckupTriageTests {
    private let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)

    private func finding(_ kind: SetupFinding.Kind, _ subject: String, client: ClientKind? = .claude, actions: [SetupAction]) -> SetupFinding {
        SetupFinding(kind: kind, severity: kind == .missingPluginInstall ? .high : .low, client: client, subject: subject, title: subject, detail: "d", evidence: ["~/x/\(subject)"], actions: actions)
    }

    private func path(_ name: String) -> String { home.appending(path: ".claude/skills/\(name)").path(percentEncoded: false) }

    @Test func findingsTheAssistantDidNotSpeakToAreGroupedByKindAndAppIntoBuckets() {
        let findings = [
            finding(.skillWithoutDefinition, "a", actions: [.removeSkillCopy(path: path("a"), client: .claude)]),
            finding(.skillWithoutDefinition, "b", actions: [.removeSkillCopy(path: path("b"), client: .claude)]),
            finding(.brokenSkillLink, "gone", actions: [.removeBrokenLink(path: path("gone"), client: .claude)]),
            finding(.unmanagedSkill, "docx", actions: [.adoptSkill(path: path("docx"), client: .claude), .removeSkillCopy(path: path("docx"), client: .claude)]),
            finding(.unmanagedSkill, "pdf", client: .codex, actions: [.adoptSkill(path: "/Users/example/.agents/skills/pdf", client: .codex)]),
            // Two plugins both carry it: nothing to remove.
            finding(.duplicateSkillInClient, "brazil", actions: []),
            // A loose copy beside a plugin's: the loose one can go.
            finding(.duplicateSkillInClient, "cr-review", actions: [.removeSkillCopy(path: path("cr-review"), client: .claude)]),
            finding(.unreachableMCPCommand, "memory", client: .kiro, actions: [.disableMCPServer(name: "memory", client: .kiro), .inspectMCPServer(name: "memory", client: .kiro)]),
            finding(.mcpServerRepeatedAcrossClients, "slack", client: nil, actions: [.manageMCPServer(name: "slack", clients: [.claude, .codex])]),
        ]
        let checkup = SetupCheckup(audit: SetupAuditReport(clients: [.claude, .codex, .kiro], findings: findings, counts: [:]))

        let items = CheckupTriage.items(from: checkup)

        func item(_ id: String) -> CheckupItem? { items.first { $0.id == id } }
        let empties = item("group:skillWithoutDefinition:Claude Code")
        #expect(empties?.bucket == .fix)
        #expect(empties?.title == "2 empty skill folders")
        #expect(empties?.primaryTitle == "Remove all 2")
        #expect(empties?.actions.count == 2)

        #expect(item("group:brokenSkillLink:Claude Code")?.primaryTitle == "Remove the link")

        let unmanagedClaude = item("group:unmanagedSkill:Claude Code")
        #expect(unmanagedClaude?.bucket == .decide, "adopting is a judgment, not a fix")
        #expect(unmanagedClaude?.primaryTitle == "Add to library")
        #expect(unmanagedClaude?.actions == [.adoptSkill(path: path("docx"), client: .claude)], "the group's button adopts; removing is on the row")
        #expect(item("group:unmanagedSkill:Codex")?.count == 1, "grouped per app")

        let loose = item("group:duplicateSkillInClient:Claude Code")
        #expect(loose?.bucket == .fix)
        #expect(loose?.count == 1)
        #expect(loose?.title == "A loose copy of a skill")
        #expect(loose?.actions.count == 1)
        let plugins = item("group:duplicateSkillInClient:Claude Code:plugins")
        #expect(plugins?.bucket == .fine, "two plugins carrying one skill is nothing this app can change")
        #expect(plugins?.canRun == false)

        let unreachable = item("group:unreachableMCPCommand:Kiro CLI")
        #expect(unreachable?.bucket == .decide)
        #expect(unreachable?.primaryTitle == "Turn it off")
        #expect(unreachable?.actions == [.disableMCPServer(name: "memory", client: .kiro)])

        let repeated = item("group:mcpServerRepeatedAcrossClients:-")
        #expect(repeated?.bucket == .decide)
        #expect(repeated?.canRun == false)
        #expect(repeated?.opens == .mcpServers)

        // Sorted: fix before decide, worst first within, then bigger groups.
        let buckets = items.map { $0.bucket }
        #expect(buckets == buckets.sorted())
    }

    @Test func aRecommendationSpeaksForTheFindingsItNamedAndSetsTheirBucket() {
        let loose = (1...3).map { finding(.duplicateSkillInClient, "s\($0)", actions: [.removeSkillCopy(path: path("s\($0)"), client: .claude)]) }
        let stale = (1...2).map { finding(.stalePluginCache, "p\($0)", client: .codex, actions: [.pruneStalePluginCache(paths: ["/Users/example/.aim/plugins/codex/other\($0)"], client: .codex)]) }
        let audit = SetupAuditReport(clients: [.claude, .codex], findings: loose + stale, counts: [:])
        let review = SetupReview(
            client: .claude, auditGeneratedAt: audit.generatedAt, summary: "s",
            recommendations: [
                SetupRecommendation(
                    id: "r1", category: .duplicates, title: "Remove the loose copies", summary: "3 loose copies", rationale: "r", client: .claude, priority: 1,
                    provenance: .investigated(source: "~/.claude/skills"), action: .take(loose[0].actions[0]), findingIDs: loose.map(\.id)),
                SetupRecommendation(
                    id: "r2", category: .cleanup, title: "Do not run the Codex cleanups", summary: "Those are other plugins", rationale: "r", client: .codex, priority: 5,
                    provenance: .investigated(source: "~/.aim/plugins/codex"), action: .readOnly, findingIDs: stale.map(\.id)),
                SetupRecommendation(
                    id: "r3", category: .settings, title: "Turn on tool search", summary: "s", rationale: "r", client: .claude, priority: 9,
                    provenance: .opinion, action: .setSetting(client: .claude, key: "toolSearch", value: "true"), findingIDs: []),
            ])
        let checkup = SetupCheckup(audit: audit, review: review)

        let items = CheckupTriage.items(from: checkup)

        #expect(items.count == 3, "every finding is spoken for; no leftover groups")
        let remove = items.first { $0.id == "r1" }
        #expect(remove?.bucket == .fix)
        #expect(remove?.actions.count == 3, "one removal per named finding, not just the one the assistant pointed at")
        #expect(remove?.primaryTitle == "Remove all 3")
        let leave = items.first { $0.id == "r2" }
        #expect(leave?.bucket == .fine)
        #expect(leave?.canRun == false, "\"leave these\" has nothing to run; dismissing is the button")
        #expect(leave?.findings.count == 2)
        let setting = items.first { $0.id == "r3" }
        #expect(setting?.bucket == .fix)
        #expect(setting?.settings.map(\.key) == ["toolSearch"])
        #expect(setting?.primaryTitle == "Set toolSearch")

        let plan = CheckupTriage.fixAll(items)
        #expect(plan.total == 4, "three removals and one setting; the \"leave these\" row is not in it")
        #expect(plan.lines == ["Move a skill folder to Agent Tooling's trash × 3", "Change a setting in an app's configuration file (backed up first)"])
    }

    @Test func aDismissedFindingLeavesItsGroupAndAnEmptyGroupDisappears() {
        let a = finding(.skillWithoutDefinition, "a", actions: [.removeSkillCopy(path: path("a"), client: .claude)])
        let b = finding(.skillWithoutDefinition, "b", actions: [.removeSkillCopy(path: path("b"), client: .claude)])
        var checkup = SetupCheckup(audit: SetupAuditReport(clients: [.claude], findings: [a, b], counts: [:]))
        #expect(CheckupTriage.items(from: checkup).first?.count == 2)
        checkup.dismissedFindingIDs = [a.id]
        #expect(CheckupTriage.items(from: checkup).first?.count == 1)
        #expect(CheckupTriage.items(from: checkup).first?.title == "An empty skill folder")
        checkup.dismissedFindingIDs = [a.id, b.id]
        #expect(CheckupTriage.items(from: checkup).isEmpty)
    }

    @Test func theSummaryIsShownOneSentenceAtATime() {
        let sentences = CheckupView.sentences("Most of your setup works. The loudest alarms turned out to be false! What is left is small?")
        #expect(sentences == ["Most of your setup works.", "The loudest alarms turned out to be false!", "What is left is small?"])
    }
}

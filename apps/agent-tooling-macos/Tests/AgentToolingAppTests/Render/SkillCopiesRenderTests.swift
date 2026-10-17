import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// A skill with copies draws one row with a badge, and its details list each
/// copy. `MCP_LAYOUT_CAPTURE` writes the PNGs for a person to look at.
@Suite("Skill copies render")
@MainActor
struct SkillCopiesRenderTests {
    @Test func theDetailPaneListsEveryCopy() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let scenario = try SkillCopiesScenario()
        let skill = try #require(scenario.index.skills.first { $0.id == scenario.loose })

        try captureMCPPane(
            SkillDetailView(
                skill: skill, workspace: fixture.workspace, content: fixture.contentSession(), inventory: scenario.index,
                availableClients: [.claude, .codex, .kiro],
                onEditSource: {}, onAssign: {}, onExport: {}, onOpenPlugin: { _ in }
            )
            .environment(\.skillTrialOpening) { _ in RecordingSkillTrialOpening(available: []) },
            named: "skill-copies-detail")
    }

    @Test func theListDrawsOneRowWithABadge() throws {
        let scenario = try SkillCopiesScenario()
        let index = scenario.index
        let groups = SkillListPresentation.groups(
            skills: index.skills, grouping: .none, presentation: index.presentation(for:), copies: index.copies(of:))
        let group = try #require(groups.first)
        let columns = SkillTableColumns(width: 1_000, selecting: false, describing: false)

        try captureMCPPane(
            VStack(spacing: 0) {
                ForEach(group.skills) { skill in
                    let members = group.members(of: skill)
                    let copies = index.copies(of: skill)
                    SkillCollectionRow(
                        skill: skill, presentation: index.presentation(for: skill),
                        observed: members.reduce(into: Set<ClientKind>()) { $0.formUnion(index.observedClients[$1.id] ?? []) },
                        management: index.management(of: skill),
                        copies: SkillCopySummary(copies: copies.count, versions: index.versions(among: copies).count),
                        moreSources: members.count - 1, selected: false, columns: columns, activate: {})
                }
            }
            .frame(width: 1_000),
            named: "skill-copies-row")
    }
}

import AgentToolingCore
import Testing

@testable import AgentToolingApp

/// What a plugin bundles, as each screen says it. The install sheet said
/// "Includes 3 bundled items", a project's Plugins tab "Includes 3 tools", and
/// onboarding "Includes 2 skills · 1 connection", all for one plugin.
@Suite("Included summary")
@MainActor
struct IncludedSummaryTests {
    private func child(_ kind: ArtifactKind, _ name: String) -> WorkspaceLibraryIncludedItem {
        .init(
            artifactID: ArtifactID(), displayName: name, kind: kind, ownership: .nativeOwned,
            parentPluginLabel: "Core", declaredName: nil, observedDescription: nil,
            requestedAssignments: [], nativeRoutes: [])
    }

    private func plugin(including children: [WorkspaceLibraryIncludedItem]) -> WorkspaceLibraryReadModelRow {
        .init(
            artifactID: ArtifactID(), displayName: "Core", kind: .nativePlugin, ownership: .nativeOwned,
            parentPluginLabel: nil, declaredName: "core", sourceLabel: nil, observedDescription: nil,
            includedChildren: children, requestedAssignments: [], isAssignable: true,
            assignmentExplanation: nil, assignableReasons: [.manual], nativeRoutes: [])
    }

    private var core: WorkspaceLibraryReadModelRow {
        plugin(including: [child(.skill, "Review"), child(.mcpServer, "Linear"), child(.skill, "Release")])
    }

    @Test("A plugin's tools are counted by kind, in the Library's order")
    func countedByKind() {
        #expect(core.includedSummary == "Includes 2 skills · 1 connection")
        #expect(plugin(including: [child(.skill, "Review")]).includedSummary == "Includes 1 skill")
        #expect(
            plugin(including: [child(.mcpServer, "Linear"), child(.nativePlugin, "Nested")]).includedSummary
                == "Includes 1 plugin · 1 connection")
    }

    @Test("A plugin that bundles nothing says nothing about it")
    func nothingBundled() {
        #expect(plugin(including: []).includedSummary == nil)
    }

    @Test("Anything bundled that is not a skill, plugin or connection is still counted")
    func otherKindsAreItems() {
        #expect(plugin(including: [child(.preset, "Starter")]).includedSummary == "Includes 1 item")
        #expect(
            plugin(including: [child(.skill, "Review"), child(.preset, "Starter")]).includedSummary
                == "Includes 1 skill · 1 item")
    }

    @Test("The install sheet and a project's Plugins tab say it the same way")
    func everyScreenSaysItOneWay() {
        let sheet = WorkspaceAssignmentSheet.itemDetail(for: core)
        let project = ProjectDetailView.componentDetail(for: core)

        #expect(sheet == "Native plugin · Includes 2 skills · 1 connection")
        #expect(project == "Managed by its app · Includes 2 skills · 1 connection")
        for detail in [sheet, project] {
            #expect(!detail.contains("bundled item"), "\(detail) counts bundled items")
            #expect(!detail.contains("tool"), "\(detail) counts tools")
        }
    }

    @Test("A row with nothing bundled shows only whose it is")
    func noChildrenNoClause() {
        let skill = WorkspaceLibraryReadModelRow(
            artifactID: ArtifactID(), displayName: "Review", kind: .skill, ownership: .centralPersonal,
            parentPluginLabel: nil, declaredName: "review", sourceLabel: nil, observedDescription: nil,
            includedChildren: [], requestedAssignments: [], isAssignable: true,
            assignmentExplanation: nil, assignableReasons: [.manual], nativeRoutes: [])

        #expect(WorkspaceAssignmentSheet.itemDetail(for: skill) == "Personal library")
        #expect(!ProjectDetailView.componentDetail(for: skill).contains("Includes"))
    }
}

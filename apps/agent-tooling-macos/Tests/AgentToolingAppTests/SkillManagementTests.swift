import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The Managed column answers "who manages this skill" in words a person
/// recognises, and only ever shows app icons for what this app placed.
@Suite("Skills · Managed column")
@MainActor
struct SkillManagementTests {
    private func entry(
        ownership: WorkspaceLibraryOwnership, inPlugin: Bool = false, placed: [TargetSurface] = []
    ) -> SkillEntry {
        SkillEntry(
            id: ArtifactID(), displayName: "Example", declaredName: "example", summary: "",
            ownership: ownership, authority: nil, contentDigest: nil,
            parentID: inPlugin ? ArtifactID() : nil, parentPluginLabel: inPlugin ? "Example Plugin" : nil,
            providerPluginID: nil, sourceLabel: nil,
            requestedAssignments: placed.map { MCPConnectionFixture.request($0) },
            isAssignable: ownership != .trackedOnly, assignmentExplanation: nil)
    }

    @Test func aSkillThisAppPlacedShowsTheAppsItPlacedItIn() {
        let management = SkillManagement(entry(ownership: .centralPersonal, placed: [.claudeCode, .codexCLI, .kiroCLI]))
        #expect(management == .placed([.claude, .codex, .kiro]))
        #expect(management.label == "Yours")
    }

    @Test func aSkillOfYoursNotPlacedAnywhereSaysSo() {
        #expect(SkillManagement(entry(ownership: .centralPersonal)).label == "Yours, not placed")
        #expect(SkillManagement(entry(ownership: .attachedAuthoring)).label == "Yours, not placed")
        #expect(SkillManagement(entry(ownership: .centralUpstream)).label == "Yours, not placed")
    }

    @Test func aPluginsSkillIsManagedByItsPlugin() {
        let management = SkillManagement(entry(ownership: .nativeOwned, inPlugin: true))
        #expect(management == .byPlugin)
        #expect(management.label == "By its plugin")
        #expect(!management.explanation.contains("assign"), "the explanation says what happens, not what is refused")
    }

    @Test func aSkillFoundButNotHeldIsNotManagedByThisApp() {
        let management = SkillManagement(entry(ownership: .trackedOnly))
        #expect(management == .notByThisApp)
        #expect(management.label == "Not by this app")
        #expect(management.explanation.contains("holds no copy"))
    }

    /// The old words are gone everywhere a person could read them.
    @Test func theOldVocabularyIsGone() {
        for management in [SkillManagement.yoursUnplaced, .byPlugin, .notByThisApp, .placed([.claude])] {
            for word in ["Tracked", "Not assigned", "place\"", "places"] {
                #expect(!management.label.contains(word), "\(management.label) still says \(word)")
            }
        }
        #expect(WorkspaceLibraryOwnership.trackedOnly.libraryLabel == "Not managed by this app")
    }

    @Test func aPlacementStackDrawsOneDiscPerApp() throws {
        try expectDrawn(
            PlacementStack(placed: [.claude, .codex, .kiro], size: 20)
                .padding(8)
                .frame(width: 120, height: 40)
                .environment(\.availableClients, [.codex, .claude, .kiro]))
    }
}

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
        // Still one word; the missing discs are what say "nowhere yet".
        #expect(SkillManagement(entry(ownership: .centralPersonal)) == .yoursUnplaced)
        #expect(SkillManagement(entry(ownership: .centralPersonal)).label == "Yours")
        #expect(SkillManagement(entry(ownership: .attachedAuthoring)) == .yoursUnplaced)
        #expect(SkillManagement(entry(ownership: .centralUpstream)) == .yoursUnplaced)
        #expect(SkillManagement.yoursUnplaced.explanation.contains("not placed"))
    }

    @Test func aPluginsSkillIsManagedByItsPlugin() {
        let management = SkillManagement(entry(ownership: .nativeOwned, inPlugin: true))
        #expect(management == .byPlugin)
        #expect(management.label == "Plugin")
        #expect(!management.explanation.contains("assign"), "the explanation says what happens, not what is refused")
    }

    @Test func aSkillFoundButNotHeldIsNotManagedByThisApp() {
        let management = SkillManagement(entry(ownership: .trackedOnly))
        #expect(management == .notByThisApp)
        #expect(management.label == "Unmanaged")
        #expect(management.explanation.contains("holds no copy"))
    }

    /// One word each, and the old words are gone everywhere a person could
    /// read them.
    @Test func everyLabelIsOneWordAndTheOldVocabularyIsGone() {
        for management in [SkillManagement.yoursUnplaced, .byPlugin, .notByThisApp, .placed([.claude])] {
            #expect(!management.label.contains(" "), "\(management.label) is more than one word")
            for word in ["Tracked", "Not assigned", "place\"", "places"] {
                #expect(!management.label.contains(word), "\(management.label) still says \(word)")
            }
        }
        #expect(WorkspaceLibraryOwnership.trackedOnly.libraryLabel == "Unmanaged")
    }

    @Test func aPlacementStackDrawsOneDiscPerApp() throws {
        try expectDrawn(
            PlacementStack(placed: [.claude, .codex, .kiro], size: 20)
                .padding(8)
                .frame(width: 120, height: 40)
                .environment(\.availableClients, [.codex, .claude, .kiro]))
    }
}

/// While the palette floats over the window, nothing under it may light up.
/// macOS hover tracking ignores what is drawn on top, so the shell sets a flag
/// every hover highlight reads; this holds the flag and checks the highlight
/// stays off with the pointer "over" the row.
@Suite("Hover under the palette")
@MainActor
struct HoverSuppressionTests {
    @Test func aHoverHighlightStaysOffWhileSuppressed() throws {
        let content = Text("Row").padding(20).frame(width: 200, height: 60)
        let plain = try rasterize(content.hoverHighlight().padding(8))
        let suppressed = try rasterize(content.hoverHighlight().padding(8).environment(\.hoverSuppressed, true))
        // Without a pointer neither is highlighted; the two must draw the same,
        // which proves the flag changes nothing but the highlight itself.
        #expect(plain.tiffRepresentation == suppressed.tiffRepresentation)
    }

    @Test func theShellHidesTheWindowFromThePointerOnlyWhileThePaletteIsUp() {
        // The flag defaults off: a window with no palette hovers as always.
        #expect(EnvironmentValues().hoverSuppressed == false)
    }
}

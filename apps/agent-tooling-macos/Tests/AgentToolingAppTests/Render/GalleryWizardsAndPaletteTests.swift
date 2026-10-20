import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The skill creator, the command palette, and the sidebar on its own. The
/// creator carries the states that change its layout; the sidebar is captured
/// separately because the shell's behind-window sidebar material does not
/// composite in an off-screen capture. The setup stage has galleries of its
/// own.
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · Creator and palette", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryWizardsAndPaletteTests {
    private static let both: [RenderAppearance] = [.light, .dark]

    // MARK: Skill creator

    /// The skill creator empty, mid-conversation, and reviewing a generated
    /// draft, plus the chooser that opens it.
    @Test func skillCreatorStates() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }

            // The chooser that picks which assistant drafts the skill.
            try gallerySnapshot(
                SkillCreationChooserSheet(managedClients: [.claude, .codex]) { _ in },
                area: "Library · Skills", screen: "Skill creation chooser", state: "both-clients",
                size: SheetGallerySize.medium, appearance: appearance,
                source: "Sources/AgentToolingApp/SkillCreationChooserSheet.swift")

            // Empty, before anything is asked.
            try gallerySnapshot(
                SkillCreatorSheet(
                    workspace: fixture.workspace, drafting: StubSkillDrafting(),
                    installing: RecordingSkillCreatorInstalling(), client: .claude, onCreated: { _, _ in }),
                area: "Library · Skills", screen: "Skill creator", state: "empty",
                size: SheetGallerySize.wide, appearance: appearance,
                source: "Sources/AgentToolingApp/SkillsView.swift:172")

            // Mid-conversation, waiting on an answer.
            let request = SkillDraftRequest(
                client: .claude, instruction: "Write a release-readiness skill.", targets: [.claude])
            let asking = fixture.skillDraftSession(
                StubSkillDrafting(script: [.reply("Which release checks matter most to you?")]))
            await asking.start(request)
            try gallerySnapshot(
                SkillCreatorSheet(
                    workspace: fixture.workspace, session: asking, client: .claude, onCreated: { _, _ in }),
                area: "Library · Skills", screen: "Skill creator", state: "mid-conversation",
                size: SheetGallerySize.wide, appearance: appearance,
                source: "Sources/AgentToolingApp/SkillsView.swift:172")

            // Reviewing the generated package.
            let reviewRequest = SkillDraftRequest(
                instruction: "Write a release-readiness skill.", targets: [.codex])
            let staged = try fixture.stageSkillDraft(request: reviewRequest)
            let reviewing = fixture.skillDraftSession(StubSkillDrafting(answer: staged))
            await reviewing.start(reviewRequest)
            try gallerySnapshot(
                SkillCreatorSheet(
                    workspace: fixture.workspace, session: reviewing, client: .codex, onCreated: { _, _ in }),
                area: "Library · Skills", screen: "Skill creator", state: "reviewing-draft",
                size: SheetGallerySize.wide, appearance: appearance,
                source: "Sources/AgentToolingApp/SkillsView.swift:172")
        }
    }

    // MARK: Command palette

    /// The palette open over Home, with the catalog's results in it.
    @Test func commandPalette() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            await fixture.workspace.device.refresh()
            try gallerySnapshot(
                AppShellView(workspace: fixture.workspace, initialSection: .overview, paletteVisible: true),
                area: "Command palette", screen: "Command palette", state: "results",
                appearance: appearance, source: "Sources/AgentToolingApp/CommandPalette.swift:290")
        }
    }

    // MARK: Sidebar

    /// The real sidebar on its own, so a reviewer sees the navigation chrome the
    /// shell images cannot composite off-screen. Rendered as `SidebarView`
    /// renders in its own section tests.
    @Test func sidebar() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            await fixture.workspace.device.refresh()
            try gallerySnapshot(
                SidebarView(workspace: fixture.workspace, selection: .constant(.overview))
                    .environment(AppNavigationState())
                    .background(AgentTheme.contentBackground),
                area: "Home", screen: "Sidebar", state: "apps-expanded",
                size: CGSize(width: 260, height: 720), appearance: appearance,
                source: "Sources/AgentToolingApp/SidebarView.swift:9")
        }
    }
}

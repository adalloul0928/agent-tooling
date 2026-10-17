import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// First run, the wizards, the skill creator, the command palette, and the
/// sidebar on its own. The wizards and the creator carry the states that change
/// their layout; the sidebar is captured separately because the shell's
/// behind-window sidebar material does not composite in an off-screen capture.
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · First run and palette", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryWizardsAndPaletteTests {
    private static let both: [RenderAppearance] = [.light, .dark]
    private static let wizardSize = CGSize(width: 860, height: 640)

    // MARK: First-launch chooser

    /// The chooser the app shows before a workspace exists: start fresh, and
    /// the join-another-Mac form it expands into.
    @Test func firstLaunchChooser() throws {
        for appearance in Self.both {
            try gallerySnapshot(
                FirstLaunchChooser(start: {}, join: { _, _ in }, isBusy: false, error: nil),
                area: "First run and wizards", screen: "First-launch chooser", state: "start",
                size: Self.wizardSize, appearance: appearance,
                source: "Sources/AgentToolingApp/AgentToolingApp.swift:235")
            try gallerySnapshot(
                FirstLaunchChooser(
                    start: {}, join: { _, _ in }, isBusy: false,
                    error: "That folder is not a workspace this Mac can join."),
                area: "First run and wizards", screen: "First-launch chooser", state: "error",
                size: Self.wizardSize, appearance: appearance,
                source: "Sources/AgentToolingApp/AgentToolingApp.swift:235")
        }
    }

    // MARK: Onboarding wizard

    /// Every stop of the onboarding wizard: what the first run found, choosing
    /// apps, and assigning.
    @Test func onboardingWizardSteps() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            await fixture.workspace.device.refresh()
            for step in [OnboardingStep.found, .apps, .assign] {
                try gallerySnapshot(
                    OnboardingWizard(workspace: fixture.workspace, step: step, onFinish: {})
                        .environment(AppNavigationState()),
                    area: "First run and wizards", screen: "Onboarding wizard",
                    state: "step-\(step.title.lowercased())",
                    size: Self.wizardSize, appearance: appearance,
                    source: "Sources/AgentToolingApp/OnboardingWizard.swift:58")
            }
        }
    }

    // MARK: Setup wizard

    /// Every stop of the setup wizard, over a checkup with one finding of each
    /// kind and a review on top.
    @Test func setupWizardSteps() async throws {
        let checkup = ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"))
        let stops: [SetupWizardStep] = [
            .apps, .audit, .review, .category(.cleanup), .category(.unmanaged),
            .category(.settings), .done,
        ]
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture(setupServices: StubSetupServices(restored: checkup))
            defer { fixture.remove() }
            for stop in stops {
                try gallerySnapshot(
                    SetupWizardSheet(
                        workspace: fixture.workspace, session: fixture.workspace.setup,
                        onClose: {}, initialStep: stop),
                    area: "First run and wizards", screen: "Setup wizard",
                    state: "step-\(setupStepName(stop))",
                    size: Self.wizardSize, appearance: appearance,
                    source: "Sources/AgentToolingApp/SetupWizardSheet.swift:79")
            }
        }
    }

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

/// A short, file-safe name for a setup-wizard stop.
private func setupStepName(_ step: SetupWizardStep) -> String {
    switch step {
    case .apps: "apps"
    case .audit: "audit"
    case .review: "review"
    case .category(let category): "category-\(category)"
    case .done: "done"
    }
}

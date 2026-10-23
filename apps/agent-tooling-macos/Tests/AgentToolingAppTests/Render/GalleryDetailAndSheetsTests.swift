import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Detail panes with something selected, and the sheets, popovers and
/// inspectors presented across the app, each at its own size in light and dark
/// with realistic content. The views are reached the same way their own render
/// tests reach them — a selection seam, a scripted session, a built request —
/// so a gallery image is a screen those tests already guard, captured.
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · Detail and sheets", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryDetailAndSheetsTests {
    private static let both: [RenderAppearance] = [.light, .dark]

    // MARK: Detail panes

    /// A plugin opened from the palette splits the plugins list into its
    /// master-detail layout and reveals the row.
    @Test func pluginDetailPane() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            try await fixture.addRequestedPackage()
            let navigation = AppNavigationState()
            navigation.openItem(
                ShellRenderFixture.plugin.rawValue.uuidString.lowercased(), in: .plugins)
            try gallerySnapshot(
                AppShellView(workspace: fixture.workspace, initialSection: .plugins, navigation: navigation),
                area: "Library · Plugins", screen: "Plugin detail", state: "selected",
                appearance: appearance, source: "Sources/AgentToolingApp/PluginsView.swift:327")
        }
    }

    /// A preset selected but not followed: its items and the follow action.
    @Test func presetDetailPane() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            guard let presets = fixture.workspace.presets else { continue }
            await presets.refresh()
            try gallerySnapshot(
                PresetsView(
                    session: presets, library: fixture.workspace.library,
                    export: fixture.workspace.export, initialSelection: ShellRenderFixture.presetID
                )
                .environment(AppNavigationState()),
                area: "Library · Presets", screen: "Preset detail", state: "unfollowed",
                appearance: appearance, source: "Sources/AgentToolingApp/PresetsView.swift")
        }
    }

    /// A project with a tool assigned to it, opened straight into its detail.
    @Test func projectDetailPane() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            try await fixture.assignSkillToFixtureProject()
            try gallerySnapshot(
                ProjectsView(workspace: fixture.workspace, initialSelection: ShellRenderFixture.projectID)
                    .environment(AppNavigationState()),
                area: "Projects", screen: "Project detail", state: "assigned",
                appearance: appearance, source: "Sources/AgentToolingApp/ProjectDetailView.swift")
        }
    }

    // MARK: Install / assignment sheet

    /// The one sheet Skills, Plugins, Presets and Connections open to choose
    /// where an item is used — the install flow's choose step.
    @Test func assignmentSheetChoose() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            try gallerySnapshot(
                WorkspaceAssignmentSheet(
                    session: fixture.workspace.library, artifactIDs: [ShellRenderFixture.skill]),
                area: "Library · Skills", screen: "Assignment sheet", state: "choose",
                size: SheetSize.large, appearance: appearance,
                source: "Sources/AgentToolingApp/SkillsView.swift:161")
        }
    }

    /// The same sheet with apps already ticked — the review step, where the
    /// footer's write action is live.
    @Test func assignmentSheetReview() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            try gallerySnapshot(
                WorkspaceAssignmentSheet(
                    session: fixture.workspace.library, artifactIDs: [ShellRenderFixture.skill],
                    initialClients: [.claude, .gemini]),
                area: "Library · Skills", screen: "Assignment sheet", state: "review",
                size: SheetSize.large, appearance: appearance,
                source: "Sources/AgentToolingApp/SkillsView.swift:161")
        }
    }

    // MARK: Plan review sheet

    /// The reviewed plan every client write goes through, with an install step
    /// and an excluded tracked item.
    @Test func planReviewSheet() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            try gallerySnapshot(
                PlanReviewSheet(
                    workspace: fixture.workspace, plan: ShellRenderFixture.deploymentPlan()),
                area: "Apps · Clients", screen: "Plan review sheet", state: "install-and-exclusion",
                size: SheetSize.xlarge, appearance: appearance,
                source: "Sources/AgentToolingApp/PlanReviewSheet.swift")
        }
    }

    // MARK: Request review sheet

    /// A queued local request with the refusal a review shows when the item is
    /// not in the library.
    @Test func requestReviewSheet() async throws {
        for appearance in Self.both {
            try gallerySnapshot(
                PendingRequestReviewSheet(
                    request: ShellRenderFixture.pendingRequest(),
                    refusal: "Standalone Skill is not in your library, and approving a request never adds one.",
                    onDefer: {}, onReject: {}, onContinue: {}),
                area: "Apps · Clients", screen: "Request review sheet", state: "refused",
                size: SheetSize.xlarge, appearance: appearance,
                source: "Sources/AgentToolingApp/Sections/ClientsSection.swift:55")
        }
    }

    // MARK: Checkup Fix All

    /// Fix All over a checkup with one finding of each kind.
    @Test func fixAllSheet() throws {
        let checkup = ShellRenderFixture.setupCheckup(home: URL(filePath: "/Users/example"))
        let plan = CheckupTriage.fixAll(CheckupTriage.items(from: checkup))
        for appearance in Self.both {
            try gallerySnapshot(
                FixAllSheet(plan: plan, onCancel: {}, onConfirm: {}),
                area: "Apps · Checkup", screen: "Fix All sheet", state: "every-kind",
                size: CGSize(width: SheetSize.small.width, height: SheetSize.large.height), appearance: appearance,
                source: "Sources/AgentToolingApp/CheckupView.swift:100")
        }
    }

    // MARK: Account review sheet

    /// The reviewed edit that makes this Mac follow an account preference. The
    /// plan comes from a recorded preference and a read account; a stub reader
    /// offline produces neither, so this is listed as unrenderable rather than
    /// faked.
    @Test func accountReviewSheet() {
        GalleryIndex.shared.addNote(
            "Account review sheet (AccountChangesReviewSheet, Sources/AgentToolingApp/AccountsView.swift:54): "
                + "needs an AccountPreferencePlan, which is built from a shared preference plus a read account. "
                + "The offline stub account reader produces no readable account, so no plan can be built in a "
                + "test without changing Sources; not rendered.")
    }

    // MARK: Paste import

    /// The paste-import sheet in each of its two modes. Its parsed and error
    /// states live in private `@State` the sheet fills from text a person
    /// types, with no seam to seed from a test, so the gallery shows the two
    /// entry modes and the index records why the parsed and error layouts are
    /// not captured.
    @Test func pasteImportSheet() async throws {
        for appearance in Self.both {
            let fixture = try await ShellRenderFixture()
            defer { fixture.remove() }
            try gallerySnapshot(
                PasteImportSheet(workspace: fixture.workspace, mode: .paste),
                area: "Library · Connections", screen: "Paste import sheet", state: "paste-mode",
                size: SheetSize.large, appearance: appearance,
                source: "Sources/AgentToolingApp/MCPServersView.swift:79")
            try gallerySnapshot(
                PasteImportSheet(workspace: fixture.workspace, mode: .newConnection),
                area: "Library · Connections", screen: "Paste import sheet", state: "new-connection-mode",
                size: SheetSize.large, appearance: appearance,
                source: "Sources/AgentToolingApp/MCPServersView.swift:81")
        }
        GalleryIndex.shared.addNote(
            "Paste import sheet parsed/error states: the parsed-definition and parse-error layouts are driven "
                + "by private @State the sheet fills from typed text; there is no test seam to seed that text "
                + "without editing Sources, so only the two entry modes are captured.")
    }
}

/// Flexible detail canvases and popover height budgets. Fixed-size product
/// sheets use their own `SheetSize` constants at each capture callsite.
enum SheetGallerySize {
    static let large = CGSize(width: 820, height: 720)
    /// A popover's content view, drawn at the compact footprint the system
    /// gives a popover rather than at a sheet's width.
    static let popover = CGSize(width: 360, height: 320)
    /// A three-pane sheet — the skill creator's conversation, file list and
    /// preview — needs more width than a form sheet or it clips.
    static let wide = CGSize(width: 1_120, height: 760)
}

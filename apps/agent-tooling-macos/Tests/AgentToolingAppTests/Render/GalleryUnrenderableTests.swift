import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp

/// Indexes system-drawn surfaces that the gallery cannot host: alerts,
/// dialogs, panels and menus. Panel records are checked against source;
/// dialog and menu text is maintained here. Enabled only when
/// AGENT_TOOLING_SCREEN_GALLERY specifies an output folder.
@Suite("Gallery · Unrenderable surfaces", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryUnrenderableTests {
    @Test func recordSystemDrawnSurfaces() throws {
        let index = GalleryIndex.shared

        index.addUnrenderable(
            control: "Confirmation dialog",
            text: "Clear saved insights? · This removes the saved aggregate report. Client chat history will not be changed. · "
                + "[Clear saved insights] [Cancel]",
            source: "Sources/AgentToolingApp/InsightsView.swift:99")
        index.addUnrenderable(
            control: "Confirmation dialog",
            text:
                "Go back to this version? · Your current version is kept in this list, so you can come back to it. Nothing in your apps changes until you install. · [Restore] [Cancel]",
            source: "Sources/AgentToolingApp/Sections/HistorySection.swift:44")
        index.addUnrenderable(
            control: "Confirmation dialog",
            text:
                "Replace this skill's files with the repository's? · Your version is replaced by what this repository publishes, and stays in this workspace's history. The skill remains your own until you follow the repository. · [Use the repository's version] [Cancel]",
            source: "Sources/AgentToolingApp/SkillUpstreamLinkSheet.swift:356")
        index.addUnrenderable(
            control: "Alert",
            text: "Run <tool> on <server>? · <per-tool confirmation message> · [Run tool] [Cancel]",
            source: "Sources/AgentToolingApp/MCPTestConsoleView.swift:242")

        let built = try SourcePanel.inApp()
        for record in GalleryPanelRecord.all {
            let line = built.first { $0.panel == record.panel }.map { ":\($0.line)" } ?? ""
            index.addUnrenderable(
                control: record.control, text: record.text,
                source: "Sources/AgentToolingApp/\(record.panel.file)\(line)")
        }

        index.addUnrenderable(
            control: "Menu",
            text:
                "The sidebar's device switcher and each row's context and assignment menus are AppKit menus drawn by the system; their items are the same actions the panels and sheets above present.",
            source: "Sources/AgentToolingApp/AssignmentDeviceScopeMenu.swift")

        // The setup stage's own system-drawn surfaces, their words read from
        // the copy the screens show, so the index cannot drift from them.
        let helper = LaunchpadCopy.Helper.self
        let moveScreen = "Launchpad/Screens/LaunchpadMoveScreen.swift"
        index.addUnrenderable(
            control: "Alert (S00, an older copy in Applications)",
            text: "\(helper.replaceQuestion) · \(helper.replaceDetail) · [\(helper.cancel)] [\(helper.replaceAndReopen)]",
            source: try Self.source(moveScreen, line: "LaunchpadCopy.Helper.replaceQuestion"))
        let placeScreen = "Launchpad/Screens/LaunchpadPlaceScreen.swift"
        index.addUnrenderable(
            control: "Menu (S10, One project)",
            text:
                "\(LaunchpadCopy.Place.chooseProject) · one item for each tracked project, by its name; the grid is worked out for the one chosen",
            source: try Self.source(placeScreen, line: "Menu(copy.chooseProject)"))

        // The menu bar extra is a system menu-style scene, so its items are
        // listed for each phase of the launch, with their exact text, rather
        // than screenshot.
        let phases: [(String, AppLaunchState.Phase)] = [
            ("While setup owns the app", .setup), ("While the library opens", .opening),
            ("When it could not open", .failed("")), ("Once it is open", .ready),
        ]
        let menus = phases.map { name, phase in
            "\(name): "
                + AppLaunchState.menuBarItems(for: phase).filter { $0 != .divider }.map(\.title).joined(separator: " · ")
        }
        index.addUnrenderable(
            control: "Menu bar item",
            text: menus.joined(separator: " — ") + " (Checking Apps… and Preparing Changes… while busy)",
            source: "Sources/AgentToolingApp/Launchpad/AppWindowRoots.swift")
    }

    /// `Sources/AgentToolingApp/<file>:<line>`, at the first line of `file`
    /// that holds `anchor`.
    private static func source(_ file: String, line anchor: String) throws -> String {
        let source = try #require(try PackageSourceFile.all(in: "AgentToolingApp").first { $0.path == file }, "no \(file)")
        let index = try #require(source.lines.firstIndex { $0.contains(anchor) }, "\(file) no longer holds \(anchor)")
        return "Sources/AgentToolingApp/\(file):\(index + 1)"
    }
}

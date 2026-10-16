import Foundation
import Testing

@testable import AgentToolingApp

/// The system-drawn surfaces the gallery does not screenshot — alerts,
/// confirmation dialogs and open panels, each drawn by macOS rather than by a
/// view the harness can host. They are recorded in the index with their exact
/// text from the source, so the gallery still accounts for every surface.
///
/// Enabled only when `AGENT_TOOLING_SCREEN_GALLERY` names an output folder.
@Suite("Gallery · Unrenderable surfaces", .serialized, .enabled(if: GalleryOutput.isOn))
@MainActor
struct GalleryUnrenderableTests {
    @Test func recordSystemDrawnSurfaces() {
        let index = GalleryIndex.shared

        index.addUnrenderable(
            control: "Confirmation dialog",
            text: "Clear saved insights? · This removes the saved aggregate report. Client chat history will not be changed. · "
                + "[Clear saved insights] [Cancel]",
            source: "Sources/AgentToolingApp/InsightsView.swift:99")
        index.addUnrenderable(
            control: "Confirmation dialog",
            text: "Go back to this version? · Your current version is kept in this list, so you can come back to it. Nothing in your apps changes until you install. · [Restore] [Cancel]",
            source: "Sources/AgentToolingApp/Sections/HistorySection.swift:44")
        index.addUnrenderable(
            control: "Confirmation dialog",
            text: "Replace this skill's files with the repository's? · Your version is replaced by what this repository publishes, and stays in this workspace's history. The skill remains your own until you follow the repository. · [Use the repository's version] [Cancel]",
            source: "Sources/AgentToolingApp/SkillUpstreamLinkSheet.swift:356")
        index.addUnrenderable(
            control: "Alert",
            text: "Run <tool> on <server>? · <per-tool confirmation message> · [Run tool] [Cancel]",
            source: "Sources/AgentToolingApp/MCPTestConsoleView.swift:242")

        index.addUnrenderable(
            control: "Open panel",
            text: "Export Package · prompt \"Export\" · \"Choose a folder on this Mac to write the package into.\" · folders",
            source: "Sources/AgentToolingApp/CollectionSharing.swift:48")
        index.addUnrenderable(
            control: "Open panel",
            text: "Choose the MCP project folder · prompt \"Choose\" · folders",
            source: "Sources/AgentToolingApp/PasteImportSheet.swift:639")
        index.addUnrenderable(
            control: "Open panel",
            text: "prompt \"Use Folder\" · folders (link a workspace folder)",
            source: "Sources/AgentToolingApp/SyncSettingsView.swift:374")
        index.addUnrenderable(
            control: "Open panel",
            text: "prompt \"Use Folder\" · folders (link a sync folder)",
            source: "Sources/AgentToolingApp/SyncSettingsView.swift:385")
        index.addUnrenderable(
            control: "Open panel",
            text: "prompt \"Use folder\" · folders (link a project folder)",
            source: "Sources/AgentToolingApp/ProjectEditingSheets.swift:314")

        index.addUnrenderable(
            control: "Menu",
            text: "The sidebar's device switcher and each row's context and assignment menus are AppKit menus drawn by the system; their items are the same actions the panels and sheets above present.",
            source: "Sources/AgentToolingApp/AssignmentDeviceScopeMenu.swift")

        // The menu bar extra is a system menu-style scene, so its items are
        // listed with their exact text rather than screenshot.
        index.addUnrenderable(
            control: "Menu bar item",
            text: "Open Agent Tooling · Check Setup (Checking setup… while busy) · Review sync (Preparing changes… while busy) · Quit Agent Tooling",
            source: "Sources/AgentToolingApp/AgentToolingApp.swift:182")
    }
}

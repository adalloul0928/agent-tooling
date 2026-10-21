import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp

@Suite(
    "Documentation screenshots", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["AGENT_TOOLING_DOCUMENTATION_OUTPUT"] != nil))
@MainActor
struct DocumentationScreenshotsTests {
    @Test func captureHomeAndLibrary() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["AGENT_TOOLING_DOCUMENTATION_OUTPUT"])
        let directory = URL(filePath: output, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let preferences = try ShellRenderFixture.preferences()
        defer { preferences.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterInstall)
        defer { sample.remove() }
        let workspace = sample.workspace
        await workspace.recordAssistantRuns(.off).value
        flow.go(to: .done)
        await LaunchpadDoneScreen.model(flow).appear(flow)
        try #require(LaunchpadStageView.footer(for: flow).primary).action()
        #expect(flow.pendingHandOff == .overview)
        workspace.setupProgress.setChecklistHidden(true)
        await workspace.library.refresh()
        await workspace.device.refresh()
        await workspace.marketplace.refresh()
        let savedSnapshot = try workspace.store.snapshot()
        let snapshot = try #require(savedSnapshot)
        #expect(snapshot.document.subscriptions.isEmpty)
        #expect(workspace.sync?.isConnected == false)

        let size = CGSize(width: 1_360, height: 760)
        for (section, name) in [(AppSection.overview, "app-home"), (.skills, "app-library")] {
            let view = ZStack {
                AgentTheme.contentBackground
                AgentTheme.canvasGradient
                AppShellView(workspace: workspace, initialSection: section)
                    .environment(\.snapshotNow, FinishSetupFixture.installedAt)
                    .environment(\.stageMotion, .still)
                    .environment(\.finishSetupServices, FinishSetupFixture.services)
                    .environment(\.skillContentService, StubSkillContentService())
                    .defaultAppStorage(preferences.defaults)
            }
            .ignoresSafeArea()
            try await captureWindow(view, to: directory.appending(path: "\(name).png"), size: size)
        }
    }

    @Test func captureSetup() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["AGENT_TOOLING_DOCUMENTATION_OUTPUT"])
        let directory = URL(filePath: output, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        let (flow, sample) = try await fixture.flow(at: .afterLibrary)
        defer { sample.remove() }
        let placement = try #require(LaunchpadPlaceScreen.placement(for: flow))
        await placement.load(decisions: flow.decisions)
        let view = ZStack {
            AgentTheme.stageGroundOpaque
            fixture.stage(flow)
        }
        .background(WindowConfigurator(role: .setup))
        .ignoresSafeArea()
        try await captureWindow(view, to: directory.appending(path: "app-setup.png"), size: WindowSize.stage, stage: true)
    }

    /// Window capture preserves system-composited controls that view caching omits.
    private func captureWindow(
        _ view: some View, to output: URL, size: CGSize = shellWindowSize, stage: Bool = false
    ) async throws {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Agent Tooling"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if !stage {
            window.toolbar = NSToolbar(identifier: "documentation")
            window.toolbarStyle = .unifiedCompact
        }
        window.appearance = NSAppearance(named: .aqua)
        host.appearance = window.appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        if stage {
            host.sizingOptions = []
            window.setFrame(CGRect(origin: .zero, size: size), display: false)
        }
        NSApplication.shared.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(700))

        let capture = Process()
        capture.executableURL = URL(filePath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", output.path]
        try capture.run()
        while capture.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        try #require(capture.terminationStatus == 0, "Window capture requires Screen Recording access.")

        // Remove metadata chunks while preserving the compressed pixels exactly.
        let bytes = [UInt8](try Data(contentsOf: output))
        try #require(bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        var clean = Data(bytes.prefix(8))
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            let end = offset + length + 12
            try #require(end <= bytes.count)
            let kind = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            if !["tEXt", "zTXt", "iTXt", "eXIf"].contains(kind) {
                clean.append(contentsOf: bytes[offset..<end])
            }
            offset = end
        }
        try #require(offset == bytes.count)
        try clean.write(to: output, options: .atomic)
    }
}

import AgentToolingCore
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

private actor ToolHiveInspectorRenderRunner: CommandRunning {
    private var calls: [(String, [String])] = []

    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        calls.append((executable, arguments))
        guard executable == "thv", arguments == ["status", "fixture", "--format", "json"] else {
            throw ToolHiveInspectorRenderError.unexpectedCommand
        }
        return CommandOutput(
            status: 0,
            standardOutput: #"{"name":"fixture","status":"running","health":"unknown","package":"registry.example/fixture","url":"http://127.0.0.1:8080/mcp","port":8080,"transport":"streamable-http","proxy_mode":"enabled","group":"preview","uptime":"1m"}"#,
            standardError: ""
        )
    }

    func recordedCalls() -> [(String, [String])] { calls }
}

private enum ToolHiveInspectorRenderError: Error { case unexpectedCommand }

@Suite("ToolHive inspector render coverage")
@MainActor
struct ToolHiveInspectorRenderTests {
    @Test func inspectorRendersReadOnlyStatusInBothAppearances() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let root = FileManager.default.temporaryDirectory.appending(path: "toolhive-inspector-render-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = ToolHiveInspectorRenderRunner()
            let model = try AppModel(
                store: WorkspaceStore(rootURL: root.appending(path: "store")),
                runner: runner,
                homeURL: root.appending(path: "home")
            )
            let workload = MCPRuntimeServer(
                name: "fixture",
                package: "registry.example/fixture",
                status: "running",
                url: "http://127.0.0.1:8080/mcp",
                transport: "streamable-http"
            )
            let view = NSHostingView(
                rootView: ToolHiveWorkloadInspector(workload: workload)
                    .environment(model)
                    .environment(\.colorScheme, scheme)
                    .frame(width: 720, height: 650)
            )
            view.frame = NSRect(x: 0, y: 0, width: 720, height: 650)
            let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }

            // Let the hosting view enter SwiftUI's task phase, then use a
            // bounded yield sequence rather than polling a live process.
            try await Task.sleep(for: .milliseconds(20))
            for _ in 0..<20 {
                if !(await runner.recordedCalls()).isEmpty { break }
                await Task.yield()
            }
            let calls = await runner.recordedCalls()
            #expect(calls.count == 1)
            #expect(calls.first?.0 == "thv")
            #expect(calls.first?.1 == ["status", "fixture", "--format", "json"])

            try await Task.sleep(for: .milliseconds(50))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(bitmap.size == NSSize(width: 720, height: 650))

            if let directory = ProcessInfo.processInfo.environment["TOOLHIVE_LAYOUT_CAPTURE"],
               let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appending(path: "toolhive-inspector-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}

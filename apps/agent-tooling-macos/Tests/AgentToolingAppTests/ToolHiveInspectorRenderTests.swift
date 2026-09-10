import AgentToolingCore
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp

/// A runtime that answers from a script and records what it was asked, so the
/// inspector's read-only contract is checked without launching `thv`.
private actor RecordingRuntimeInspector: MCPRuntimeInspecting {
    private var statusCalls: [String] = []
    private var logCalls: [(String, Bool)] = []

    func inspect() async throws -> MCPRuntimeReading {
        MCPRuntimeReading(
            statuses: [
                MCPRuntimeStatus(
                    id: "toolhive", displayName: "ToolHive", isAvailable: true, version: "0.4.1",
                    capabilities: [.health, .logs], detail: "Read-only workload status available.")
            ],
            workloads: [
                MCPRuntimeServer(
                    name: "fixture", package: "registry.example/fixture", status: "running",
                    url: "http://127.0.0.1:8080/mcp", transport: "streamable-http")
            ])
    }

    func workloadStatus(_ name: String) async throws -> ToolHiveInspectionResult<ToolHiveWorkloadStatus> {
        statusCalls.append(name)
        return .available(
            ToolHiveWorkloadStatus(
                name: name, status: "running", health: "unknown", package: "registry.example/fixture",
                url: "http://127.0.0.1:8080/mcp", port: 8_080, transport: "streamable-http",
                proxyMode: "enabled", group: "preview", uptime: "1m"),
            diagnostic: nil)
    }

    func workloadLogs(_ name: String, proxy: Bool) async throws -> ToolHiveLogSnapshot {
        logCalls.append((name, proxy))
        return ToolHiveLogSnapshot(
            workloadName: name, isProxyLog: proxy, output: "listening on 127.0.0.1:8080",
            isTruncated: false)
    }

    func recordedStatusCalls() -> [String] { statusCalls }
    func recordedLogCalls() -> [(String, Bool)] { logCalls }
}

@Suite("ToolHive inspector render coverage")
@MainActor
struct ToolHiveInspectorRenderTests {
    private static let workload = MCPRuntimeServer(
        name: "fixture", package: "registry.example/fixture", status: "running",
        url: "http://127.0.0.1:8080/mcp", transport: "streamable-http")

    @Test func inspectorRendersReadOnlyStatusInBothAppearances() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let inspector = RecordingRuntimeInspector()
            let view = NSHostingView(
                rootView: ToolHiveWorkloadInspector(workload: Self.workload, inspector: inspector)
                    .environment(\.colorScheme, scheme)
                    .frame(width: 720, height: 650)
            )
            view.frame = NSRect(x: 0, y: 0, width: 720, height: 650)
            let window = NSWindow(
                contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }

            // Let the hosting view enter SwiftUI's task phase, then use a
            // bounded yield sequence rather than polling a live process.
            try await Task.sleep(for: .milliseconds(20))
            for _ in 0..<20 {
                if !(await inspector.recordedStatusCalls()).isEmpty { break }
                await Task.yield()
            }
            #expect(await inspector.recordedStatusCalls() == ["fixture"])
            // Opening the sheet reads status and nothing else: logs are loaded
            // only when somebody asks for them.
            #expect(await inspector.recordedLogCalls().isEmpty)

            try await Task.sleep(for: .milliseconds(50))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(bitmap.size == NSSize(width: 720, height: 650))
        }
    }

    @Test func theRuntimesSheetDrawsWhatOneCheckSaw() async throws {
        let session = MCPRuntimeSession(inspector: StubMCPRuntimeInspector())
        #expect(session.lastCheckedAt == nil)
        #expect(session.statuses.isEmpty)

        await session.refresh()

        #expect(session.errorMessage == nil)
        #expect(session.lastCheckedAt != nil)
        #expect(session.statuses.map(\.displayName) == ["Direct client configuration", "ToolHive"])
        #expect(session.workloads.map(\.name) == ["fixture"])

        try captureMCPPane(
            MCPRuntimesSheet(inspector: StubMCPRuntimeInspector(), session: session), named: "runtimes")
    }

    @Test func aRuntimeThatCannotBeReadKeepsTheLastAnswerOnScreen() async throws {
        let session = MCPRuntimeSession(inspector: StubMCPRuntimeInspector())
        await session.refresh()
        let checked = try #require(session.lastCheckedAt)

        let failing = MCPRuntimeSession(inspector: FailingRuntimeInspector())
        await failing.refresh()

        #expect(failing.errorMessage != nil)
        #expect(failing.lastCheckedAt == nil)
        // The successful session is untouched by the failing one.
        #expect(session.lastCheckedAt == checked)
    }

    @Test func theRuntimesSheetSaysNothingHasBeenCheckedBeforeAnythingRuns() throws {
        try captureMCPPane(
            MCPRuntimesSheet(inspector: EmptyMCPRuntimeInspector()), named: "runtimes-unchecked")
    }
}

private struct FailingRuntimeInspector: MCPRuntimeInspecting {
    func inspect() async throws -> MCPRuntimeReading {
        throw MCPRuntimeReadingError.listFailed("thv exited with status 1.")
    }

    func workloadStatus(_ name: String) async throws -> ToolHiveInspectionResult<ToolHiveWorkloadStatus> {
        .commandFailed(diagnostic: "thv exited with status 1.")
    }

    func workloadLogs(_ name: String, proxy: Bool) async throws -> ToolHiveLogSnapshot {
        throw MCPRuntimeReadingError.unsupportedList
    }
}

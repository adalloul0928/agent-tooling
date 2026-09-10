import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// General draws appearance, this Mac's MCP connection modes, and managed
/// policy awareness.
@Suite("Settings · General renders")
@MainActor
struct SettingsSectionRenderTests {
    @Test func theShellDrawsSettings() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(
            renderShell(.settings, fixture: fixture)
                .environment(\.mcpRuntimeObserver, StubMCPRuntimeObserver()))
    }

    /// ToolHive being unavailable is a normal, common state — the screen must
    /// still draw something, not fail or go blank.
    @Test func theShellDrawsSettingsWhenToolHiveIsUnavailable() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }

        try expectDrawn(
            renderShell(.settings, fixture: fixture)
                .environment(\.mcpRuntimeObserver, StubMCPRuntimeObserver(toolHiveAvailable: false)))
    }
}

/// This Mac's MCP connection modes, scripted so a render test never launches
/// a real `thv` process.
private struct StubMCPRuntimeObserver: MCPRuntimeObserving {
    var toolHiveAvailable = true

    func statuses() async -> [MCPRuntimeStatus] {
        [
            LiveMCPRuntimeObserver.direct,
            MCPRuntimeStatus(
                id: "toolhive", displayName: "ToolHive", isAvailable: toolHiveAvailable,
                version: toolHiveAvailable ? "1.2.3" : nil,
                capabilities: toolHiveAvailable ? [.health, .logs] : [],
                detail: toolHiveAvailable
                    ? "Read-only workload status and log inspection available." : "ToolHive is not installed."),
        ]
    }

    func servers(after toolHiveStatus: MCPRuntimeStatus) async throws -> [MCPRuntimeServer] {
        guard toolHiveAvailable else { return [] }
        return [MCPRuntimeServer(name: "example-server", package: "example/server", status: "running")]
    }
}

import AgentToolingCore
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

@Suite("Connection table cells")
@MainActor
struct ConnectionTableCellTests {
    @Test func clientCellsRenderWithoutAnObservableEnvironmentAfterFiltering() throws {
        // Native table recycling can render a cell outside the parent's environment.
        // Deliberately omit AppModel and MCPCapabilityModel, including on updates.
        let host = NSHostingView(rootView: TableClientMarks(clients: [.codex, .claude], present: [.codex, .claude]))
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        for present: Set<ClientKind> in [[.codex, .claude], [.claude], [], [.codex]] {
            host.rootView = TableClientMarks(clients: [.codex, .claude], present: present)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.size.width == 100)
        }
    }
}

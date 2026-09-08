import AgentToolingCore
import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

@Suite("Skills browsing layout")
@MainActor
struct SkillsLayoutRenderTests {
    @Test func fullWidthBrowserRendersAtCompactAndWideSizes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "skills-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try AppModel(store: WorkspaceStore(rootURL: root))
        for width in [800.0, 1200.0] {
            let view = NSHostingView(
                rootView: SkillsView()
                    .environment(model)
                    .environment(AppNavigationState())
                    .environment(\.colorScheme, .dark)
                    .frame(width: width, height: 700))
            view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(abs(bitmap.size.width - width) < 1)
            #expect(abs(bitmap.size.height - 700) < 1)
            if let destination = ProcessInfo.processInfo.environment["SKILLS_LAYOUT_CAPTURE"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: "\(destination)-\(Int(width)).png"))
            }
        }
    }
}

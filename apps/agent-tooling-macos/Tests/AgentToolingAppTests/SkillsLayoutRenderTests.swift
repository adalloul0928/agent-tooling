import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The browser has two layouts, and a pane is not a window: the narrow one has
/// to hold up beside an open inspector, and the wide one has to fill a real
/// window without leaving the list at the width the narrow one used.
@Suite("Skills browsing layout")
@MainActor
struct SkillsLayoutRenderTests {
    @Test func fullWidthBrowserRendersAtCompactAndWideSizes() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let preferences = try ShellRenderFixture.preferences()
        defer { preferences.remove() }
        await fixture.assignStandaloneSkill()

        for width in [800.0, 1_200.0] {
            let bitmap = try Self.draw(fixture, preferences: preferences, width: width, label: "list")
            #expect(abs(bitmap.size.width - width) < 1)
            #expect(abs(bitmap.size.height - 700) < 1)
            #expect(distinctColours(in: bitmap) > 4, "the browser drew a blank frame at \(Int(width))")
        }
    }

    /// Revealing one skill splits the pane. The inspector is the half that most
    /// often lays out to nothing, because everything in it is conditional on
    /// what the workspace happens to know about that row.
    @Test func revealingASkillDrawsTheInspectorBesideTheList() async throws {
        let fixture = try await ShellRenderFixture()
        defer { fixture.remove() }
        let preferences = try ShellRenderFixture.preferences()
        defer { preferences.remove() }
        await fixture.assignStandaloneSkill()

        let navigation = AppNavigationState()
        navigation.open(.skill(ShellRenderFixture.skill.rawValue.uuidString.lowercased()))
        let bitmap = try Self.draw(
            fixture, preferences: preferences, width: 1_200, label: "detail", navigation: navigation)
        #expect(distinctColours(in: bitmap) > 4, "the inspector drew a blank frame")
    }

    /// Set `SKILLS_LAYOUT_CAPTURE` to a path prefix to keep the frames, which is
    /// how these layouts are looked at rather than only asserted about.
    private static func draw(
        _ fixture: ShellRenderFixture, preferences: RenderPreferences, width: CGFloat, label: String,
        navigation: AppNavigationState = AppNavigationState()
    ) throws -> NSBitmapImageRep {
        let view =
            SkillsView(workspace: fixture.workspace, content: fixture.contentSession())
            .environment(navigation)
            .environment(\.skillContentService, StubSkillContentService())
            .environment(\.availableClients, ClientKind.allCases)
            .defaultAppStorage(preferences.defaults)
            .frame(width: width, height: 700)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        // An off-screen window, so the view draws with a real appearance rather
        // than the flattened one a detached hierarchy falls back to. Nothing is
        // ordered front: the frame is captured, not shown.
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let destination = ProcessInfo.processInfo.environment["SKILLS_LAYOUT_CAPTURE"],
            let png = bitmap.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(fileURLWithPath: "\(destination)-\(label)-\(Int(width)).png"))
        }
        return bitmap
    }
}

extension ShellRenderFixture {
    /// The screen's own session, over the fixture's workspace and a scripted
    /// content service, so a layout test never reads a content store.
    func contentSession(content: any SkillContentServing = StubSkillContentService()) -> SkillContentSession {
        SkillContentSession(
            service: workspace.service, library: workspace.library,
            cacheRoot: root.appending(path: "cache", directoryHint: .isDirectory), content: content)
    }
}

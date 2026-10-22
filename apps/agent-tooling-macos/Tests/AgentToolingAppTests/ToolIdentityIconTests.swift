import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

@Suite("Tool icons")
@MainActor
struct ToolIdentityIconTests {
    @Test("Tool kinds have drawable native symbols in both appearances")
    func nativeIconsAreDrawable() throws {
        let kinds: [ToolingKind] = [
            .skill, .plugin, .mcpServer, .profile, .collection, .library,
            .activity, .source, .connection, .account, .settings,
        ]
        for kind in kinds {
            let symbol = try #require(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil))
            #expect(symbol.size.width > 0)
            #expect(symbol.size.height > 0)
            for appearance in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(
                    content: ToolIdentityIcon(packageID: "sample@community", fallback: kind)
                        .environment(\.colorScheme, appearance)
                )
                let pixels = try #require(renderer.cgImage)
                #expect(pixels.width == Int(Size.identityIconLarge))
                #expect(pixels.height == Int(Size.identityIconLarge))
            }
        }
    }
}

import AppKit
import SwiftUI
import Testing

@testable import AgentToolingApp

@Suite("Tool identity artwork")
@MainActor
struct ToolIdentityIconTests {
    @Test("Installed and catalog identities resolve to the same packaged artwork")
    func realIngestedIdentifiersResolve() throws {
        // Installed Plugin.id retains the native identifier. MarketplacePackage.id
        // adds the client prefix; these examples are present in both ingestors.
        let expected: [(String, String)] = [
            ("github@openai-curated-remote", "ToolGitHub"),
            ("codex:github@openai-curated-remote", "ToolGitHub"),
            ("github@openai-curated", "ToolGitHub"),
            ("claude:github@claude-plugins-official", "ToolGitHub"),
            ("claude:linear@claude-plugins-official", "ToolLinear"),
            ("linear@openai-curated", "ToolLinear"),
            ("sentry@openai-curated", "ToolSentry"),
            ("claude:sentry@claude-plugins-official", "ToolSentry"),
            ("vercel@openai-curated", "ToolVercel"),
            ("claude:vercel@claude-plugins-official", "ToolVercel"),
            ("shopify@openai-curated-remote", "ToolShopify"),
            ("codex:documents@openai-primary-runtime", "ToolDocuments"),
            ("codex:chrome@openai-bundled", "ToolChrome"),
            ("codex:simview@toolingtools", "ToolSimView"),
        ]
        for (identifier, name) in expected {
            let asset = try #require(ToolIdentityAssets.asset(for: identifier))
            #expect(asset.asset == name)
        }
    }

    @Test("A matching display name or unrecognized source never borrows a brand")
    func unrelatedNamesakesStayUnbranded() {
        for identifier in [
            "GitHub", "github", "codex:github", "github@another-marketplace",
            "codex:github@another-marketplace", "claude:linear@community",
            "native:github@openai-curated-remote", "codex:claude:github@openai-curated-remote",
            "mcp-registry:io.github.community/github@1", "github@openai-curated-remote-extra",
        ] {
            #expect(ToolIdentityAssets.asset(for: identifier) == nil)
        }
    }

    @Test("Every supplied logo decodes into drawable artwork from the app resources")
    func bundledArtworkIsDrawable() throws {
        let identifiers = [
            "openai-templates@openai-curated-remote", "vercel@openai-curated-remote",
            "linear@openai-curated-remote", "twilio-developer-kit@openai-curated-remote",
            "plugin-management@openai-curated-remote", "github@openai-curated-remote",
            "codex-security@openai-curated-remote", "finances@openai-curated-remote",
            "sentry@openai-curated-remote", "deep-research-work@openai-curated-remote",
            "visualize@openai-bundled", "sites@openai-bundled", "browser@openai-bundled",
            "chrome@openai-bundled", "computer-history@openai-bundled", "computer-use@openai-bundled",
            "template-creator@openai-primary-runtime", "spreadsheets@openai-primary-runtime",
            "pdf@openai-primary-runtime", "presentations@openai-primary-runtime",
            "documents@openai-primary-runtime", "simview@toolingtools",
            "supabase@claude-plugins-official", "shopify-ai-toolkit@claude-plugins-official",
        ]
        for identifier in identifiers {
            let asset = try #require(ToolIdentityAssets.asset(for: identifier))
            for appearance in [ColorScheme.light, .dark] {
                let image = try #require(ToolIdentityAssets.image(for: asset, colorScheme: appearance))
                var bounds = NSRect(x: 0, y: 0, width: 44, height: 44)
                let pixels = try #require(image.cgImage(forProposedRect: &bounds, context: nil, hints: nil))
                #expect(pixels.width > 0)
                #expect(pixels.height > 0)
            }
        }
    }

    @Test("Appearance variants preserve the supplied artwork")
    func appearanceVariantsMatchTheirSources() throws {
        // Deep Research supplies the same blue telescope SVG for both appearances.
        // GitHub and Visualize supply different artwork, so those must switch pixels.
        for (identifier, hasDistinctArtwork) in [
            ("github@openai-curated-remote", true),
            ("deep-research-work@openai-curated-remote", false),
            ("visualize@openai-bundled", true),
        ] {
            let asset = try #require(ToolIdentityAssets.asset(for: identifier))
            #expect(asset.files.contains { $0.hasPrefix("icon-dark.") })
            let light = try #require(ToolIdentityAssets.image(for: asset, colorScheme: .light))
            let dark = try #require(ToolIdentityAssets.image(for: asset, colorScheme: .dark))
            let lightPixels = try #require(light.tiffRepresentation)
            let darkPixels = try #require(dark.tiffRepresentation)
            #expect(light !== dark)
            #expect((lightPixels != darkPixels) == hasDistinctArtwork, "\(identifier) appearance artwork")
        }
    }
}

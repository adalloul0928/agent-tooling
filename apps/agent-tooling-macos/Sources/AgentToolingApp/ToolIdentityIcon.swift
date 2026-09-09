import AppKit
import SwiftUI

/// Package artwork is separate from the kind of item and the apps it runs in.
/// Only exact catalog identities resolve to bundled artwork. An icon makes no
/// statement about installation, authentication, or publisher verification.
struct ToolIdentityIcon: View {
    let packageID: String
    var fallback: ToolingKind = .plugin
    var size: CGFloat = 44
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let asset = artwork {
                if ClientBrandAssets.hasCompiledCatalog {
                    Image(asset.asset, bundle: .module)
                        .resizable()
                        .scaledToFit()
                } else if let image = ToolIdentityAssets.image(for: asset, colorScheme: colorScheme) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    fallbackSymbol
                }
            } else {
                fallbackSymbol
            }
        }
        .frame(width: size, height: size)
        .background(artworkBackground)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var fallbackSymbol: some View {
        Image(systemName: fallback.symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.5, weight: .regular))
            .foregroundStyle(.secondary)
    }

    private var artwork: ToolIdentityAssets.Asset? {
        ToolIdentityAssets.asset(for: packageID)
    }

    private var artworkBackground: Color {
        guard let artwork else { return Color(nsColor: .controlBackgroundColor) }
        return colorScheme == .dark && artwork.files.contains(where: { $0.hasPrefix("icon-dark.") }) ? .black : .white
    }
}

@MainActor
enum ToolIdentityAssets {
    struct Asset: Decodable {
        let asset: String
        let packageID: String
        let files: [String]
    }

    private struct Manifest: Decodable {
        let assets: [Asset]
    }

    private static let images = NSCache<NSString, NSImage>()
    private static let assets: [String: Asset] = {
        guard let url = Bundle.module.url(forResource: "ToolIconSources", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return [:] }
        return Dictionary(manifest.assets.map { ($0.packageID, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    // These catalog entries expose the same named integrations. Keeping the
    // full package identity avoids assigning a brand to a namesake package.
    private static let aliases: [String: String] = [
        "github@openai-curated": "github@openai-curated-remote",
        "linear@openai-curated": "linear@openai-curated-remote",
        "sentry@openai-curated": "sentry@openai-curated-remote",
        "vercel@openai-curated": "vercel@openai-curated-remote",
        "github@claude-plugins-official": "github@openai-curated-remote",
        "linear@claude-plugins-official": "linear@openai-curated-remote",
        "sentry@claude-plugins-official": "sentry@openai-curated-remote",
        "vercel@claude-plugins-official": "vercel@openai-curated-remote",
        "shopify@openai-curated-remote": "shopify-ai-toolkit@claude-plugins-official",
    ]

    static func asset(for packageID: String) -> Asset? {
        let identity: String
        if packageID.hasPrefix("codex:") {
            identity = String(packageID.dropFirst("codex:".count))
        } else if packageID.hasPrefix("claude:") {
            identity = String(packageID.dropFirst("claude:".count))
        } else {
            identity = packageID
        }
        return assets[aliases[identity] ?? identity]
    }

    static func image(for asset: Asset, colorScheme: ColorScheme) -> NSImage? {
        let darkFile = asset.files.first { $0.hasPrefix("icon-dark.") }
        let lightFile = asset.files.first { $0.hasPrefix("icon.") }
        guard let file = colorScheme == .dark ? darkFile ?? lightFile : lightFile else { return nil }
        let key = "\(asset.asset)/\(file)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        if ClientBrandAssets.hasCompiledCatalog {
            var resolved: NSImage?
            let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            appearance?.performAsCurrentDrawingAppearance {
                guard let image = Bundle.module.image(forResource: NSImage.Name(asset.asset)) else { return }
                var bounds = NSRect(origin: .zero, size: image.size)
                guard let pixels = image.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else { return }
                resolved = NSImage(cgImage: pixels, size: bounds.size)
            }
            if let resolved { images.setObject(resolved, forKey: key) }
            return resolved
        }
        guard
            let url = Bundle.module.resourceURL?
                .appending(path: "Assets.xcassets", directoryHint: .isDirectory)
                .appending(path: "\(asset.asset).imageset", directoryHint: .isDirectory)
                .appending(path: file, directoryHint: .notDirectory),
            let image = NSImage(contentsOf: url)
        else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}

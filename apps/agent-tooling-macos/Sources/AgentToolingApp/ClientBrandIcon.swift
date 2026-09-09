import AgentToolingCore
import AppKit
import SwiftUI

struct ClientBrandIcon: View {
    let client: ClientKind
    var size: CGFloat = 22
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if ClientBrandAssets.hasCompiledCatalog {
                Image(assetName, bundle: .module)
                    .resizable()
            } else if let image = ClientBrandAssets.image(for: client, colorScheme: colorScheme) {
                Image(nsImage: image)
                    .resizable()
            } else {
                Image(systemName: "app")
                    .resizable()
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var assetName: String {
        switch client {
        case .codex: "ClientCodex"
        case .claude: "ClientClaude"
        case .gemini: "ClientGemini"
        }
    }
}

enum ClientBrandAssets {
    static let hasCompiledCatalog: Bool = {
        Bundle.module.url(forResource: "Assets", withExtension: "car") != nil
    }()

    @MainActor private static let fallbackImages = NSCache<NSString, NSImage>()

    @MainActor
    static func image(for client: ClientKind, colorScheme: ColorScheme) -> NSImage? {
        let key = "\(client.rawValue)/\(colorScheme == .dark ? "dark" : "light")" as NSString
        if let cached = fallbackImages.object(forKey: key) { return cached }
        guard let url = sourceURL(for: client, colorScheme: colorScheme), let image = NSImage(contentsOf: url) else { return nil }
        fallbackImages.setObject(image, forKey: key)
        return image
    }

    static func sourceURL(for client: ClientKind, colorScheme: ColorScheme) -> URL? {
        let imageSet: String
        let fileName: String
        switch client {
        case .codex:
            imageSet = "ClientCodex.imageset"
            fileName = colorScheme == .dark ? "codex-dark.svg" : "codex-light.svg"
        case .claude:
            imageSet = "ClientClaude.imageset"
            fileName = "claude.svg"
        case .gemini:
            imageSet = "ClientGemini.imageset"
            fileName = "gemini.svg"
        }

        let url = Bundle.module.resourceURL?
            .appending(path: "Assets.xcassets", directoryHint: .isDirectory)
            .appending(path: imageSet, directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
        guard let url, FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }
}

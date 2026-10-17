import AgentToolingCore
import AppKit
import SwiftUI

/// SwiftPM's native accessor looks beside the executable's main bundle and in
/// the build directory. A packaged macOS app keeps its resources in
/// Contents/Resources, so resolve that location before using the build fallback.
enum AppResources {
    static let bundle: Bundle = packagedBundle(in: .main) ?? .module

    static func packagedBundle(in application: Bundle) -> Bundle? {
        guard let url = application.url(forResource: "AgentTooling_AgentToolingApp", withExtension: "bundle") else { return nil }
        return Bundle(url: url)
    }

    /// Invoked by the finished app in CI, before opening a workspace. Checking
    /// the resolved location prevents a copy left in the build directory from
    /// making a broken distributable pass.
    @MainActor
    static func verifyPackagedResources() throws {
        guard let packaged = packagedBundle(in: .main),
            bundle.bundleURL.resolvingSymlinksInPath() == packaged.bundleURL.resolvingSymlinksInPath()
        else { throw VerificationError.missing("the app's resource bundle") }

        for client in ClientKind.allCases {
            if ClientBrandAssets.hasCompiledCatalog {
                let name = ClientBrandAssets.assetName(for: client)
                guard bundle.image(forResource: NSImage.Name(name)) != nil else { throw VerificationError.missing(name) }
            } else {
                for appearance in [ColorScheme.light, .dark] {
                    guard ClientBrandAssets.image(for: client, colorScheme: appearance) != nil else {
                        throw VerificationError.missing("\(client.rawValue) artwork")
                    }
                }
            }
        }

        guard let manifestURL = bundle.url(forResource: "ToolIconSources", withExtension: "json") else {
            throw VerificationError.missing("the package artwork manifest")
        }
        struct Manifest: Decodable {
            let assets: [ToolIdentityAssets.Asset]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard !manifest.assets.isEmpty else { throw VerificationError.missing("package artwork") }
        for asset in manifest.assets {
            for appearance in [ColorScheme.light, .dark] {
                guard ToolIdentityAssets.image(for: asset, colorScheme: appearance) != nil else {
                    throw VerificationError.missing(asset.asset)
                }
            }
        }
    }

    private enum VerificationError: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name): "Could not load \(name) from the packaged app."
            }
        }
    }
}

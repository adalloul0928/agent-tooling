import Foundation

/// Identity preserved by the native catalog parsers in `MarketplacePackage.id`.
/// Display fields, source labels and install commands are not identity evidence.
public struct NativeCatalogPackageIdentity: Hashable, Sendable {
    public let client: ClientKind
    public let externalPluginID: String

    init(client: ClientKind, externalPluginID: String) {
        self.client = client
        self.externalPluginID = externalPluginID
    }

    public static func recognize(_ package: MarketplacePackage) -> Self? {
        let client: ClientKind
        let prefix: String
        let expectedCatalog: SourceKind
        if package.id.hasPrefix("codex:") {
            client = .codex
            prefix = "codex:"
            expectedCatalog = .openAIPluginDirectory
        } else if package.id.hasPrefix("claude:") {
            client = .claude
            prefix = "claude:"
            expectedCatalog = .claudeMarketplace
        } else {
            return nil
        }

        let externalPluginID = String(package.id.dropFirst(prefix.count))
        guard isParserIdentifier(externalPluginID),
              package.components == [.plugin],
              package.supportedClients.contains(client),
              package.ownership == nil || package.ownership == .nativeClient else {
            return nil
        }
        if let provenance = package.provenance,
           provenance.source.kind != expectedCatalog {
            return nil
        }
        return Self(client: client, externalPluginID: externalPluginID)
    }

    /// Mirrors MarketplaceService.safeCatalogIdentifier after parsing. The
    /// encoded package ID must already be canonical; recognition never trims it.
    private static func isParserIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 128,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.hasPrefix("-") else {
            return false
        }
        let punctuation = "._-@".unicodeScalars
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || punctuation.contains($0)
        }
    }
}

import Foundation

/// Who stands behind a listing, decided only from what the catalog actually
/// verified. There is no fourth "probably fine": a listing whose publisher
/// nobody checked is `unverified`, and says so.
public enum PackageClassification: String, Codable, CaseIterable, Identifiable, Sendable {
    case reference
    case official
    case community
    case unverified

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .reference: "Reference"
        case .official: "Official"
        case .community: "Community"
        case .unverified: "Unverified"
        }
    }

    /// The one-line meaning of the badge itself, independent of any package.
    public var definition: String {
        switch self {
        case .reference: "Published by the authors of the protocol itself."
        case .official: "The catalog verified the publisher against a domain they control."
        case .community: "A third-party publisher, verified only as an account in the catalog."
        case .unverified: "Nothing in this listing establishes who published it."
        }
    }
}

/// A badge plus the exact observation behind it, so the tooltip can say what
/// was checked rather than asking a person to trust a word.
public struct PackageClassificationVerdict: Codable, Hashable, Sendable {
    public var classification: PackageClassification
    public var evidence: String

    public init(classification: PackageClassification, evidence: String) {
        self.classification = classification
        self.evidence = evidence
    }
}

/// Turns the catalog a package came from into a provenance badge.
///
/// The official MCP registry is the only catalog here that verifies a
/// publisher at all, and it verifies two different things: a reverse-DNS
/// namespace is proved with a DNS record for that domain, while an
/// `io.github.*` namespace is proved with the GitHub account that owns it.
/// Those are exactly PulseMCP's "official" and "community", so the badge is
/// reporting a fact rather than a guess. Everything else — native client
/// catalogs, folders and Git checkouts a person added — carries no publisher
/// verification, and is labeled `unverified` with the reason.
public enum MarketplaceProvenanceClassifier {
    private static let protocolNamespace = "io.modelcontextprotocol"
    private static let protocolAccount = "modelcontextprotocol"
    /// Namespaces the registry proves by signing in to a code-hosting account
    /// rather than by a DNS record on a company's own domain.
    private static let accountNamespaces: [(prefix: String, provider: String)] = [
        ("io.github.", "GitHub"), ("com.github.", "GitHub"), ("io.gitlab.", "GitLab"), ("com.gitlab.", "GitLab"),
    ]

    public static func classify(_ package: MarketplacePackage) -> PackageClassificationVerdict {
        switch package.catalogKind {
        case .mcpRegistry:
            return registryVerdict(for: package)
        case .claudeMarketplace:
            return PackageClassificationVerdict(
                classification: .community,
                evidence:
                    "Claude Code listed this plugin from \(marketplacePhrase(package)). A Claude marketplace does not verify who wrote a plugin, so the publisher stays a third party until you read the source yourself."
            )
        case .openAIPluginDirectory:
            return PackageClassificationVerdict(
                classification: .community,
                evidence:
                    "Codex listed this plugin from \(marketplacePhrase(package)). The Codex catalog does not verify who wrote a plugin, so the publisher stays a third party until you read the source yourself."
            )
        case .localFolder, .gitRepository:
            return userAddedVerdict()
        case .agentPlugins, .geminiExtensionGallery:
            return PackageClassificationVerdict(
                classification: .unverified,
                evidence: "This source is a format reference, not a catalog that verifies publishers."
            )
        case nil:
            if package.sourceID != nil { return userAddedVerdict() }
            return PackageClassificationVerdict(
                classification: .unverified,
                evidence: "This listing does not record which catalog produced it, so no publisher check can be attributed to it."
            )
        }
    }

    private static func userAddedVerdict() -> PackageClassificationVerdict {
        PackageClassificationVerdict(
            classification: .unverified,
            evidence:
                "You added this folder or checkout yourself. Agent Tooling read the package on disk, which establishes what it contains but not who published it."
        )
    }

    /// Only the namespace decides the badge. A listing's repository URL is a
    /// field the publisher writes for themselves, so pointing it at the
    /// protocol's own repository must never earn the protocol's own badge.
    private static func registryVerdict(for package: MarketplacePackage) -> PackageClassificationVerdict {
        guard let namespace = namespace(of: package.name) else {
            return PackageClassificationVerdict(
                classification: .unverified,
                evidence:
                    "This registry listing has no namespaced name, so the registry's publisher check cannot be attributed to a domain or an account."
            )
        }
        if namespace == protocolNamespace || namespace.hasPrefix("\(protocolNamespace).") {
            return PackageClassificationVerdict(
                classification: .reference,
                evidence:
                    "Published in the official MCP registry under \(protocolNamespace), the namespace the registry reserves for the protocol authors' own reference servers."
            )
        }
        if let match = accountNamespaces.first(where: { namespace.hasPrefix($0.prefix) }) {
            let account = String(namespace.dropFirst(match.prefix.count))
            if account == protocolAccount {
                return PackageClassificationVerdict(
                    classification: .reference,
                    evidence:
                        "The official MCP registry verified the \(namespace) namespace against the \(protocolAccount) account on \(match.provider), which is the protocol authors' own account."
                )
            }
            return PackageClassificationVerdict(
                classification: .community,
                evidence:
                    "The official MCP registry verified the \(namespace) namespace against the \(account.isEmpty ? "publishing" : account) account on \(match.provider). That proves who holds the account, not that a company stands behind this server."
            )
        }
        guard namespace.contains(".") else {
            return PackageClassificationVerdict(
                classification: .unverified,
                evidence:
                    "The \(namespace) namespace is not a reverse-DNS name, so the registry's domain check cannot be attributed to this listing."
            )
        }
        let domain = namespace.split(separator: ".").reversed().joined(separator: ".")
        return PackageClassificationVerdict(
            classification: .official,
            evidence:
                "The official MCP registry verified the \(namespace) namespace against a DNS record on \(domain), so this listing was published by whoever controls that domain."
        )
    }

    private static func namespace(of name: String) -> String? {
        guard let separator = name.firstIndex(of: "/") else { return nil }
        let namespace = String(name[name.startIndex..<separator]).lowercased()
        return namespace.isEmpty ? nil : namespace
    }

    private static func marketplacePhrase(_ package: MarketplacePackage) -> String {
        let publisher = package.publisher.trimmingCharacters(in: .whitespacesAndNewlines)
        return publisher.isEmpty ? "a marketplace you configured" : "the \(publisher) marketplace you configured"
    }
}

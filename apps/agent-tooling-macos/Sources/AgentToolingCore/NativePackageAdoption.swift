import Foundation

/// Whether a native package a catalog lists is already an item in this library,
/// and which one.
///
/// Discover asks this to decide what its button says, and the command that adds
/// a listing asks the same question to decide whether there is anything to add.
/// They must never disagree, so the question is answered in one place and has
/// exactly four answers.
///
/// Only two of them are identity. A route and a client's plugin alias are facts
/// this app wrote down about one package in one client's namespace; an equal
/// declared name is not. The workspace contract is explicit that equal names are
/// insufficient identity evidence, and two publishers shipping a "docs" package
/// is exactly the case that rule exists for — so a name match is reported as the
/// ambiguity it is, for a person to settle, rather than quietly merged or
/// quietly duplicated. A display name is never consulted at all.
public enum NativePackageAdoption {
    /// The identity evidence that matched.
    public enum MatchReason: String, Hashable, Sendable {
        /// The row carries this client's route for this exact package ID. This
        /// is how a scan records a package the client installed, and how an
        /// earlier adoption records itself.
        case nativeRoute
        /// The row carries this client's plugin alias for this package ID.
        case alias
        /// The row is a native package that declared this ID, with no route
        /// naming the client. A first run records a package this way when it
        /// could not locate the package's own member files. Same-named is not
        /// the same as same package, so this never stands on its own.
        case declaredName
    }

    public struct Match: Hashable, Sendable {
        public let artifactID: ArtifactID
        public let displayName: String
        public let reason: MatchReason

        public init(artifactID: ArtifactID, displayName: String, reason: MatchReason) {
            self.artifactID = artifactID
            self.displayName = displayName
            self.reason = reason
        }
    }

    public enum Recognition: Hashable, Sendable {
        /// Nothing in this library is this package.
        case none
        /// This library already holds this exact package.
        case exact(Match)
        /// A package declaring the same identifier is here, recorded without a
        /// route naming this client. It may be the same package seen through
        /// another app, or a different package of the same name. This build
        /// cannot tell, so it says so.
        case sameDeclaredName(Match)
        /// This package was removed from the library before.
        case removed
    }

    public static func recognize(
        client: ClientKind, externalPluginID: String, in document: PortableWorkspaceDocument
    ) -> Recognition {
        let route = NativePackageRoute(client: client, externalPluginID: externalPluginID)
        let alias = pluginAlias(client: client, externalPluginID: externalPluginID)
        let roots = document.artifacts.filter { $0.identity.parentPackageID == nil }
        if let found = roots.first(where: { $0.nativeRoutes.contains(route) }) {
            return .exact(
                .init(
                    artifactID: found.identity.id,
                    displayName: found.identity.displayName, reason: .nativeRoute))
        }
        if let found = roots.first(where: { $0.identity.aliases.contains(alias) }) {
            return .exact(
                .init(
                    artifactID: found.identity.id,
                    displayName: found.identity.displayName, reason: .alias))
        }
        // A tombstone keeps the identity of something a person decided to
        // remove. Adding it back is their decision to make explicitly;
        // recreating it as a side effect of a catalog listing is not.
        if document.tombstones.contains(where: { $0.aliases.contains(alias) }) { return .removed }
        let named = roots.first {
            $0.identity.kind == .nativePlugin && $0.declaredName == externalPluginID
                && ($0.authority == .nativeOwned || $0.authority == .trackedOnly)
        }
        return named.map {
            .sameDeclaredName(
                .init(
                    artifactID: $0.identity.id,
                    displayName: $0.identity.displayName, reason: .declaredName))
        } ?? .none
    }

    /// The external identity a client's own plugin ID has inside this workspace.
    ///
    /// The namespace form is the one the workspace contract names — `claude.plugin`,
    /// `codex.plugin` — so a route and an alias describe the same fact rather
    /// than two competing ones.
    public static func pluginAlias(client: ClientKind, externalPluginID: String) -> ExternalAlias {
        .init(namespace: pluginAliasNamespace(client), value: externalPluginID)
    }

    public static func pluginAliasNamespace(_ client: ClientKind) -> String {
        switch client {
        case .claude: "claude.plugin"
        case .codex: "codex.plugin"
        case .gemini: "gemini.plugin"
        }
    }
}

/// The catalogs this build knows how to ask, named in one place.
///
/// A screen must not construct a provider for itself. Which registries this app
/// is willing to reach is a decision about where it sends a request, and that
/// decision belongs beside the providers rather than beside a button: a view
/// that could build its own could point "the official registry" anywhere.
///
/// The list is deliberately allowed to be empty. A provider whose construction
/// fails — an unreachable configuration, a base URL that is not HTTPS — is left
/// out rather than substituted, so a caller that gets nothing back knows no
/// catalog can be asked instead of asking a different one by accident.
public enum MarketplaceProviderRegistry {
    /// Every provider this build ships, ready to query.
    ///
    /// The official MCP registry, the official Claude plugins catalog, and the
    /// skills.sh skill registry. Native client catalogs are read through
    /// `MarketplaceService.discoverNativeCatalogs`, and folders a person added
    /// are read through `MarketplaceService.inspect`; neither is a remote
    /// provider, and neither belongs here.
    public static func builtIn() -> [any MarketplaceProvider] {
        var providers: [any MarketplaceProvider] = []
        if let registry = try? OfficialMCPRegistryProvider() { providers.append(registry) }
        if let claude = try? ClaudePluginsOfficialCatalogProvider() { providers.append(claude) }
        if let skills = try? SkillsShRegistryProvider() { providers.append(skills) }
        return providers
    }
}

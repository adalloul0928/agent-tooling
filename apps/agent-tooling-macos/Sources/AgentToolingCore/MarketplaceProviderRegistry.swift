/// Central registry of allowed catalog providers. Views use this list so
/// endpoint selection remains a provider policy. Failed constructions are
/// omitted without substituting another endpoint; the list may be empty.
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

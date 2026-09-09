import Foundation

/// Device wire adapter that preserves MarketplacePackage's legacy object shape
/// while making its two set-backed fields deterministic.
struct DeviceMarketplaceSnapshot: Codable {
    var package: MarketplacePackage
    init(_ package: MarketplacePackage) { self.package = package }
    init(from decoder: any Decoder) throws { package = try MarketplacePackage(from: decoder) }

    private enum CodingKeys: String, CodingKey {
        case id, name, publisher, summary, sourceID, sourceName, revision, license, components, supportedClients
        case authentication, hasExecutableContent, trustSummary, location, isInstalled, nativeInstalls, provenance
        case requestedCredentialNames, ownership, updateStatus, conflicts, lastUpdate, tools
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(package.id, forKey: .id); try c.encode(package.name, forKey: .name)
        try c.encode(package.publisher, forKey: .publisher); try c.encode(package.summary, forKey: .summary)
        try c.encodeIfPresent(package.sourceID, forKey: .sourceID); try c.encode(package.sourceName, forKey: .sourceName)
        try c.encodeIfPresent(package.revision, forKey: .revision); try c.encodeIfPresent(package.license, forKey: .license)
        try c.encode(package.components.sorted { $0.rawValue < $1.rawValue }, forKey: .components)
        try c.encode(package.supportedClients.sorted { $0.rawValue < $1.rawValue }, forKey: .supportedClients)
        try c.encodeIfPresent(package.authentication, forKey: .authentication)
        try c.encode(package.hasExecutableContent, forKey: .hasExecutableContent)
        try c.encode(package.trustSummary, forKey: .trustSummary); try c.encode(package.location, forKey: .location)
        try c.encode(package.isInstalled, forKey: .isInstalled); try c.encode(package.nativeInstalls, forKey: .nativeInstalls)
        try c.encodeIfPresent(package.provenance, forKey: .provenance)
        try c.encodeIfPresent(package.requestedCredentialNames, forKey: .requestedCredentialNames)
        try c.encodeIfPresent(package.ownership, forKey: .ownership); try c.encodeIfPresent(package.updateStatus, forKey: .updateStatus)
        try c.encodeIfPresent(package.conflicts, forKey: .conflicts); try c.encodeIfPresent(package.lastUpdate, forKey: .lastUpdate)
        try c.encodeIfPresent(package.tools, forKey: .tools)
    }
}

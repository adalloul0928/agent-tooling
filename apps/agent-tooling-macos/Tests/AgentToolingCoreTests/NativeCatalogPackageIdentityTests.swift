import Foundation
import Testing

@testable import AgentToolingCore

struct NativeCatalogPackageIdentityTests {
    @Test func recognizesActualCodexAndClaudeParserRows() throws {
        let service = MarketplaceService()
        let codex = try #require(service.packagesFromCodexCatalogJSON("""
        {"available":[{"pluginId":"reviewer@team","name":"Reviewer","marketplaceName":"Team"}]}
        """).first)
        let claude = try #require(service.packagesFromClaudeCatalogJSON("""
        [{"name":"browser","marketplace":"company-market","installed":true}]
        """).first)

        #expect(NativeCatalogPackageIdentity.recognize(codex) == Self.identity(.codex, "reviewer@team"))
        #expect(NativeCatalogPackageIdentity.recognize(claude) == Self.identity(.claude, "browser@company-market"))
    }

    @Test func displayChangesAndInstallArgumentsDoNotReplaceEncodedIdentity() throws {
        var package = Self.package(id: "codex:reviewer@team", client: .codex)
        package.name = "A completely different display name"
        package.publisher = "Unrelated publisher label"
        package.sourceName = "Changed source label"
        package.location = "/different/display/path"
        package.nativeInstalls = [.init(
            client: .claude,
            executable: "not-codex",
            arguments: ["plugin", "add", "spoof@other"],
            detail: "Untrusted display command"
        )]

        #expect(NativeCatalogPackageIdentity.recognize(package) == Self.identity(.codex, "reviewer@team"))

        var spoof = package
        spoof.id = "unrelated-package"
        spoof.name = "reviewer@team"
        spoof.sourceID = UUID()
        #expect(NativeCatalogPackageIdentity.recognize(spoof) == nil)
    }

    @Test func rejectsMalformedOrNoncanonicalEncodedIdentifiers() {
        let malformed = [
            "codex:",
            "codex:-leading",
            "codex:contains/slash",
            "codex:contains space",
            "codex: reviewer@team",
            "codex:reviewer@team ",
            "claude:contains:colon",
            "claude:\(String(repeating: "a", count: 129))",
        ]
        for id in malformed {
            #expect(NativeCatalogPackageIdentity.recognize(Self.package(
                id: id,
                client: id.hasPrefix("claude:") ? .claude : .codex
            )) == nil)
        }
    }

    @Test func requiresPluginComponentAndSupportForTheEncodedClient() {
        var package = Self.package(id: "codex:reviewer@team", client: .codex)
        package.supportedClients = [.claude]
        #expect(NativeCatalogPackageIdentity.recognize(package) == nil)

        package.supportedClients = [.codex]
        package.components = [.plugin, .skill]
        #expect(NativeCatalogPackageIdentity.recognize(package) == nil)
    }

    @Test func explicitCatalogProvenanceMustAgreeWithTheEncodedClient() {
        var package = Self.package(id: "claude:browser@company", client: .claude)
        package.provenance = .init(source: .init(
            kind: .openAIPluginDirectory,
            location: "https://example.invalid/catalog"
        ))
        #expect(NativeCatalogPackageIdentity.recognize(package) == nil)

        package.provenance = .init(source: .init(
            kind: .claudeMarketplace,
            location: "https://example.invalid/catalog"
        ))
        #expect(NativeCatalogPackageIdentity.recognize(package) == Self.identity(.claude, "browser@company"))
    }

    @Test func onlyNativeOrUnspecifiedOwnershipCanRepresentNativeCatalogIdentity() {
        var package = Self.package(id: "codex:reviewer@team", client: .codex)
        package.ownership = .managed
        #expect(NativeCatalogPackageIdentity.recognize(package) == nil)

        package.ownership = .unmanaged
        #expect(NativeCatalogPackageIdentity.recognize(package) == nil)

        package.ownership = .nativeClient
        #expect(NativeCatalogPackageIdentity.recognize(package) == Self.identity(.codex, "reviewer@team"))

        package.ownership = nil
        #expect(NativeCatalogPackageIdentity.recognize(package) == Self.identity(.codex, "reviewer@team"))
    }

    private static func identity(_ client: ClientKind, _ id: String) -> NativeCatalogPackageIdentity {
        NativeCatalogPackageIdentity(client: client, externalPluginID: id)
    }

    private static func package(id: String, client: ClientKind) -> MarketplacePackage {
        MarketplacePackage(
            id: id,
            name: "Display only",
            publisher: "Publisher label",
            summary: "Catalog fixture",
            sourceName: "Catalog label",
            components: [.plugin],
            supportedClients: [client],
            location: "Display location"
        )
    }
}

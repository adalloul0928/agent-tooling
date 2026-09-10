import AgentToolingCore
import Foundation
import Testing

/// The catalog reader, used the way anything outside `AgentToolingCore` has to
/// use it.
///
/// This file imports the package normally rather than `@testable`, on purpose.
/// Every call below is one a screen makes, so if one of these types slipped back
/// to `internal` this file would stop compiling — which is the failure worth
/// having, since the screen would go quietly empty instead.
struct MarketplaceProviderRegistryTests {
    @Test func theBuiltInCatalogIsTheOfficialRegistry() {
        let providers = MarketplaceProviderRegistry.builtIn()

        #expect(providers.count == 1)
        #expect(providers.first?.id == "mcp.official-registry")
        #expect(providers.first?.displayName == "Official MCP Registry")
    }

    /// The registry provider is constructed, never searched: building one is an
    /// offline check of its base URL, and a unit test has no business opening a
    /// socket to find out whether the registry is up this morning.
    @Test func aCatalogThatCannotBeReachedOverHTTPSIsNotSubstituted() {
        #expect(throws: (any Error).self) {
            try OfficialMCPRegistryProvider(baseURL: URL(fileURLWithPath: "/tmp/registry"))
        }
    }

    /// The five catalogs Discover lists before anybody adds one. They are
    /// reference rows: `inspect` returns nothing for them, because a vendor
    /// listing is a place to look rather than a folder to read.
    @Test func theDefaultSourcesAreTheVendorCatalogsAndNoneOfThemIsAFolder() throws {
        let service = MarketplaceService()

        let sources = service.defaultSources()

        #expect(
            Set(sources.map(\.kind))
                == [.agentPlugins, .claudeMarketplace, .openAIPluginDirectory, .geminiExtensionGallery, .mcpRegistry])
        for source in sources {
            #expect(try service.inspect(source).isEmpty)
        }
    }

    /// One catalog folder, read end to end through the public API: inspected
    /// into packages, then folded with a second reading of the same folder into
    /// one row rather than two.
    @Test func aFolderCatalogIsInspectedAndDeduplicatedThroughThePublicAPI() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "marketplace-registry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(
            #"{"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"reviewed-plugin"}"#.utf8
        ).write(to: root.appending(path: "plugin.json"))
        let source = ToolingSource(
            name: "Catalog folder", kind: .localFolder, location: root.path(percentEncoded: false))
        let service = MarketplaceService()

        let packages = try service.inspect(source)

        #expect(packages.map(\.name) == ["reviewed-plugin"])
        #expect(packages.first?.sourceID == source.id)
        // A catalog read twice is still one catalog.
        #expect(service.deduplicatedPackages(packages + packages).count == 1)
    }

    /// A client whose catalog command is not there is reported as unreadable
    /// rather than as a client that publishes nothing, and a client this
    /// workspace does not manage is not asked at all.
    @Test func nativeCatalogsAreReadPerClientAndReportWhatTheyCouldNotRead() async {
        let discovery = await MarketplaceService.discoverNativeCatalogs(
            runner: RefusingCommandRunner(), clients: [.claude])

        #expect(discovery.packages.isEmpty)
        #expect(discovery.outcomes[.claude] == .incomplete)
        #expect(discovery.outcomes[.codex] == .excluded)
        #expect(discovery.notes[.claude]?.isEmpty == false)
    }
}

/// A client CLI that is not installed. Nothing here launches a process.
private struct RefusingCommandRunner: CommandRunning {
    func run(executable: String, arguments: [String], currentDirectory: URL?) async throws -> CommandOutput {
        CommandOutput(status: 127, standardOutput: "", standardError: "command not found: \(executable)")
    }
}

import AgentToolingTestSupport
import Foundation
import Testing

@testable import AgentToolingApp
@testable import AgentToolingCore

/// Bundled public listings must be valid without a live catalog refresh.
@Suite("Starter shelf")
@MainActor
struct StarterShelfTests {
    @Test func theBundledShelfDecodesInItsOrderWithPublicListingsOnly() throws {
        let entries = try StarterShelf.entries()

        #expect(entries.map(\.name) == ["Supabase", "Vercel", "GitHub for Codex", "MCP Builder"])
        #expect(
            entries.map(\.packageID) == [
                "claude:supabase@claude-plugins-official", "claude:vercel@claude-plugins-official", "codex:github@openai-curated",
                "skills-sh:anthropics/skills/mcp-builder",
            ])
        #expect(entries.map(\.client) == [.claude, .claude, .codex, nil])
        #expect(
            entries.map(\.summary) == [
                "Supabase database, auth and storage from Claude Code.", "Deploy and inspect Vercel projects.",
                "GitHub issues and pull requests in Codex.", "Guides building an MCP server.",
            ])
        #expect(
            entries.map(\.source) == [
                "Claude Code’s catalog", "Claude Code’s catalog", "Codex’s catalog · separate from Claude Code’s GitHub",
                "skills.sh · anthropics/skills",
            ])
        // Only the public catalogs: the official Claude plugins, OpenAI's
        // curated directory and public skills.sh repositories.
        let publicCatalogs = ["@claude-plugins-official", "@openai-curated", "skills-sh:anthropics/"]
        #expect(entries.allSatisfy { entry in publicCatalogs.contains { entry.packageID.contains($0) } })
    }

    @Test func eachPluginIsAListingItsCatalogsParserWouldLeave() throws {
        for entry in try StarterShelf.entries() where entry.kind == .plugin {
            let package = try #require(StarterShelf.package(for: entry, retained: nil))
            let client = try #require(entry.client)
            let identity = try #require(NativeCatalogPackageIdentity.recognize(package), "\(entry.name)")
            #expect(identity.client == client)
            #expect("\(client == .claude ? "claude" : "codex"):\(identity.externalPluginID)" == entry.packageID)
            #expect(NativePackageAdoptionCommand.refusal(adding: package, for: client) == nil, "\(entry.name) can be added")
            #expect(package.nativeInstalls.map(\.client) == [client])
        }
    }

    @Test func theSkillIsASkillsShListing() throws {
        let entry = try #require(try StarterShelf.entries().first { $0.kind == .skill })
        let package = try #require(StarterShelf.package(for: entry, retained: nil))

        let listing = try #require(WorkspaceMarketplaceSession.skillsShListing(package))
        #expect(listing.repository == "anthropics/skills")
        #expect(listing.skillID == "mcp-builder")
        #expect(package.installCount == nil, "an install count comes only from a catalog that was read")
    }

    @Test func aListingACatalogGaveFillsInOnlyWhatACatalogKnows() throws {
        let entry = try #require(try StarterShelf.entries().last)
        var listed = try #require(StarterShelf.package(for: entry, retained: nil))
        listed.name = "mcp-builder"
        listed.summary = "Agent skill published from anthropics/skills."
        listed.installCount = 12_400

        let package = try #require(StarterShelf.packages(retained: [listed]).last)

        #expect(package.installCount == 12_400)
        #expect(package.name == "MCP Builder", "the shelf's own words stay")
        #expect(package.summary == "Guides building an MCP server.")
    }

    @Test func thePackagedResourceCheckCoversTheShelf() throws {
        try AppResources.verifyStarterShelf()
    }

    @Test func theMarketplacesShelfAsksNoCatalog() async throws {
        let catalog = LibraryCountingCatalog()
        var fixture = try await LaunchpadFixture()
        defer { fixture.remove() }
        fixture.environment.sessions.marketplaceProviders = { _ in [catalog] }
        let workspace = try await fixture.sample(.afterRead).workspace

        let shelf = workspace.marketplace.starterShelf()

        #expect(shelf.map(\.id) == (try StarterShelf.entries()).map(\.packageID))
        #expect(await catalog.searches == 0)
        #expect(workspace.marketplace.lastRefreshedAt == nil)
        #expect(workspace.marketplace.isRefreshing == false)
    }
}

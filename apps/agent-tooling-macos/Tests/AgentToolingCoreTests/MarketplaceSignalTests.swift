import Foundation
import Testing

@testable import AgentToolingCore

private func package(
    id: String,
    name: String,
    publisher: String = "fixture",
    summary: String = "A reviewed fixture package.",
    sourceID: UUID? = nil,
    sourceName: String = "Fixture",
    revision: String? = "1.0.0",
    license: String? = "MIT",
    components: Set<ComponentKind> = [.mcpServer],
    location: String = "https://github.com/example/fixture",
    provenanceKind: SourceKind? = nil,
    lastUpdate: PackageUpdateRecord? = nil
) -> MarketplacePackage {
    MarketplacePackage(
        id: id,
        name: name,
        publisher: publisher,
        summary: summary,
        sourceID: sourceID,
        sourceName: sourceName,
        revision: revision,
        license: license,
        components: components,
        supportedClients: Set(ClientKind.allCases),
        location: location,
        provenance: provenanceKind.map { kind in
            PackageProvenance(source: PackageSource(kind: kind, location: location))
        },
        lastUpdate: lastUpdate
    )
}

@Suite("Marketplace provenance")
struct MarketplaceProvenanceTests {
    @Test func registryNamespacesDecideBetweenReferenceOfficialAndCommunity() {
        let reference = MarketplaceProvenanceClassifier.classify(
            package(
                id: "mcp-registry:io.modelcontextprotocol/everything@1", name: "io.modelcontextprotocol/everything",
                provenanceKind: .mcpRegistry))
        #expect(reference.classification == .reference)
        #expect(reference.evidence.contains("io.modelcontextprotocol"))

        let official = MarketplaceProvenanceClassifier.classify(
            package(id: "mcp-registry:com.stripe/mcp@1", name: "com.stripe/mcp", provenanceKind: .mcpRegistry))
        #expect(official.classification == .official)
        #expect(official.evidence.contains("stripe.com"))

        let community = MarketplaceProvenanceClassifier.classify(
            package(id: "mcp-registry:io.github.acme/notes@1", name: "io.github.acme/notes", provenanceKind: .mcpRegistry))
        #expect(community.classification == .community)
        #expect(community.evidence.contains("acme account on GitHub"))
    }

    @Test func referenceComesFromTheVerifiedNamespaceAndNeverFromASelfDeclaredRepository() {
        let verifiedAccount = MarketplaceProvenanceClassifier.classify(
            package(
                id: "mcp-registry:io.github.modelcontextprotocol/git@1",
                name: "io.github.modelcontextprotocol/git",
                provenanceKind: .mcpRegistry))
        #expect(verifiedAccount.classification == .reference)

        // A repository URL is a field publishers write for themselves, so
        // pointing it at the protocol's own repository must change nothing.
        let impostor = MarketplaceProvenanceClassifier.classify(
            package(
                id: "mcp-registry:io.github.evil/git@1",
                name: "io.github.evil/git",
                location: "https://github.com/modelcontextprotocol/servers",
                provenanceKind: .mcpRegistry))
        #expect(impostor.classification == .community)
    }

    @Test func nativeClientCatalogsAreCommunityAndSayWhyTheyAreNotVerified() {
        let claude = MarketplaceProvenanceClassifier.classify(
            package(id: "claude:reviewer@team-marketplace", name: "reviewer", publisher: "team-marketplace", components: [.plugin]))
        #expect(claude.classification == .community)
        #expect(claude.evidence.contains("does not verify"))

        let codex = MarketplaceProvenanceClassifier.classify(
            package(id: "codex:reviewer@team", name: "reviewer", publisher: "team", components: [.plugin]))
        #expect(codex.classification == .community)
    }

    @Test func unverifiableListingsSayUnverifiedRatherThanGuessing() {
        let folder = MarketplaceProvenanceClassifier.classify(
            package(
                id: "\(UUID().uuidString):local-pack", name: "local-pack", sourceID: UUID(), components: [.skill],
                location: "/Users/example/packages/local-pack"))
        #expect(folder.classification == .unverified)
        #expect(folder.evidence.contains("not who published it"))

        let unknownCatalog = MarketplaceProvenanceClassifier.classify(
            package(id: "unknown:thing", name: "thing", components: [.plugin]))
        #expect(unknownCatalog.classification == .unverified)

        let unnamespacedRegistry = MarketplaceProvenanceClassifier.classify(
            package(id: "mcp-registry:plain@1", name: "plain", provenanceKind: .mcpRegistry))
        #expect(unnamespacedRegistry.classification == .unverified)

        let gallery = MarketplaceProvenanceClassifier.classify(
            package(id: "gallery:thing", name: "thing", provenanceKind: .geminiExtensionGallery))
        #expect(gallery.classification == .unverified)
    }

    @Test func everyClassificationCarriesEvidence() {
        let samples = [
            package(id: "mcp-registry:io.modelcontextprotocol/a@1", name: "io.modelcontextprotocol/a", provenanceKind: .mcpRegistry),
            package(id: "mcp-registry:com.example/b@1", name: "com.example/b", provenanceKind: .mcpRegistry),
            package(id: "claude:c@market", name: "c"),
            package(id: "local", name: "d", sourceID: UUID()),
        ]
        for sample in samples {
            let verdict = MarketplaceProvenanceClassifier.classify(sample)
            #expect(!verdict.evidence.isEmpty)
            #expect(verdict.evidence.count > 40)
        }
    }
}

@Suite("Marketplace sorting")
struct MarketplaceSortingTests {
    private var fixtures: [MarketplacePackage] {
        [
            package(
                id: "b", name: "filesystem", summary: "Read files.",
                lastUpdate: PackageUpdateRecord(date: Date(timeIntervalSince1970: 3_000), origin: .catalogListing)),
            package(id: "a", name: "Filesystem", summary: "Another listing with the same name."),
            package(
                id: "c", name: "archive", publisher: "filesystem-labs", summary: "Archive things.",
                lastUpdate: PackageUpdateRecord(date: Date(timeIntervalSince1970: 9_000), origin: .catalogListing)),
            package(id: "d", name: "zebra", summary: "Mentions filesystem in the summary."),
        ]
    }

    @Test func everySortIsTotalAndIndependentOfInputOrder() {
        for order in MarketplaceSortOrder.allCases {
            let forward = MarketplaceSorting.sorted(fixtures, by: order, searchTerm: "filesystem")
            let reversed = MarketplaceSorting.sorted(fixtures.reversed(), by: order, searchTerm: "filesystem")
            let resorted = MarketplaceSorting.sorted(forward, by: order, searchTerm: "filesystem")
            #expect(forward.map(\.id) == reversed.map(\.id))
            #expect(forward.map(\.id) == resorted.map(\.id))
            #expect(Set(forward.map(\.id)) == Set(fixtures.map(\.id)))
            #expect(forward.count == fixtures.count)
        }
    }

    @Test func nameOrderBreaksTiesByIdentifier() {
        let sorted = MarketplaceSorting.sorted(fixtures, by: .name)
        #expect(sorted.map(\.id) == ["c", "a", "b", "d"])
    }

    @Test func relevanceRanksNameMatchesAboveSummaryMatches() {
        let sorted = MarketplaceSorting.sorted(fixtures, by: .relevance, searchTerm: "filesystem")
        #expect(sorted.prefix(2).map(\.id) == ["a", "b"])
        #expect(sorted.last?.id == "d")
        #expect(
            MarketplaceSorting.relevanceScore(fixtures[0], searchTerm: "filesystem")
                > MarketplaceSorting.relevanceScore(fixtures[3], searchTerm: "filesystem"))
    }

    @Test func relevanceWithoutASearchTermIsNameOrder() {
        #expect(
            MarketplaceSorting.sorted(fixtures, by: .relevance, searchTerm: "  ").map(\.id)
                == MarketplaceSorting.sorted(fixtures, by: .name).map(\.id))
        #expect(MarketplaceSorting.relevanceScore(fixtures[0], searchTerm: "") == 0)
    }

    @Test func recentlyUpdatedPutsListingsWithoutADateLast() {
        let sorted = MarketplaceSorting.sorted(fixtures, by: .recentlyUpdated)
        #expect(sorted.map(\.id) == ["c", "b", "a", "d"])
    }
}

@Suite("Marketplace grading")
struct MarketplaceGradingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func ungradableInputsReportNotGradedRatherThanAPass() throws {
        let sparse = MarketplacePackage(
            id: "claude:sparse@market",
            name: "sparse",
            publisher: "market",
            summary: MarketplaceCopy.availableClaudePlugin,
            sourceName: "market",
            components: [.plugin],
            supportedClients: [.claude],
            location: "sparse@market"
        )
        let grades = MarketplaceGrading.grades(for: sparse, asOf: now)

        let license = try #require(grades.first(where: { $0.kind == .license }))
        #expect(license.grade == nil)
        #expect(license.letter == PackageGradeVerdict.notGradedLetter)
        #expect(license.detail.contains("no license"))

        let maintenance = try #require(grades.first(where: { $0.kind == .maintenance }))
        #expect(maintenance.grade == nil)
        #expect(maintenance.letter == PackageGradeVerdict.notGradedLetter)

        let quality = try #require(grades.first(where: { $0.kind == .quality }))
        #expect(quality.grade == .d)
        #expect(quality.detail.contains("a description from the publisher"))
        #expect(quality.detail.contains("a license"))
    }

    @Test func completeListingsEarnLettersAndStateWhatWasMeasured() throws {
        let complete = package(
            id: "mcp-registry:com.example/full@2.1.0",
            name: "com.example/full",
            summary: "A complete listing with a description written by its publisher.",
            license: "Apache-2.0",
            provenanceKind: .mcpRegistry,
            lastUpdate: PackageUpdateRecord(date: now.addingTimeInterval(-60 * 60 * 24 * 10), origin: .catalogListing)
        )
        let grades = MarketplaceGrading.grades(for: complete, asOf: now)

        #expect(grades.map(\.kind) == [.license, .quality, .maintenance])
        #expect(try #require(grades.first(where: { $0.kind == .license })).grade == .a)
        #expect(try #require(grades.first(where: { $0.kind == .quality })).grade == .a)
        let maintenance = try #require(grades.first(where: { $0.kind == .maintenance }))
        #expect(maintenance.grade == .a)
        #expect(maintenance.detail.contains("10 days ago"))
        for grade in grades {
            #expect(!grade.measurement.isEmpty)
        }
        #expect(try #require(grades.first(where: { $0.kind == .quality })).measurement.contains("never starts the server"))
    }

    @Test func anUnrecognizedLicenseIsGradedLowerButNeverInvented() throws {
        let custom = package(id: "local:custom", name: "custom", sourceID: UUID(), license: "All rights reserved, contact us.")
        let license = try #require(MarketplaceGrading.grades(for: custom, asOf: now).first(where: { $0.kind == .license }))
        #expect(license.grade == .b)
        #expect(license.detail.contains("not in a form this app recognizes"))
    }

    @Test func ageDrivesTheMaintenanceLetterAndStalenessIsDisclosed() throws {
        let old = package(
            id: "mcp-registry:com.example/old@1",
            name: "com.example/old",
            provenanceKind: .mcpRegistry,
            lastUpdate: PackageUpdateRecord(date: now.addingTimeInterval(-60 * 60 * 24 * 900), origin: .catalogListing)
        )
        let verdict = try #require(
            MarketplaceGrading.grades(for: old, reachability: .unreachable("Unavailable: HTTP status 503"), asOf: now)
                .first(where: { $0.kind == .maintenance }))
        #expect(verdict.grade == .f)
        #expect(verdict.detail.contains("unreachable"))
    }

    @Test func anUnreachableSourceWithoutADateStaysUngraded() throws {
        let unreachable = package(id: "mcp-registry:com.example/dark@1", name: "com.example/dark", provenanceKind: .mcpRegistry)
        let verdict = try #require(
            MarketplaceGrading.grades(for: unreachable, reachability: .unreachable("Unavailable: timed out"), asOf: now)
                .first(where: { $0.kind == .maintenance }))
        #expect(verdict.grade == nil)
        #expect(verdict.detail.contains("timed out"))
    }
}

@Suite("Secret field masking")
struct SecretFieldMaskingTests {
    @Test func credentialShapedNamesAreMaskedAndOrdinaryOnesAreNot() {
        for name in ["API_KEY", "apiKey", "github-token", "client_secret", "PASSWORD", "authorization", "session"] {
            #expect(SecretFieldMasking.isSecretLike(name), "\(name) should be treated as a secret field")
        }
        for name in ["monkey", "root_path", "workspace", "keyboardLayout", "author"] {
            #expect(!SecretFieldMasking.isSecretLike(name), "\(name) should not be treated as a secret field")
        }
    }

    @Test func maskedValuesNeverEchoTheirInput() {
        #expect(SecretFieldMasking.maskedValue("sk-live-1234") == SecretFieldMasking.placeholder)
        #expect(SecretFieldMasking.maskedValue(nil) == SecretFieldMasking.placeholder)
    }
}

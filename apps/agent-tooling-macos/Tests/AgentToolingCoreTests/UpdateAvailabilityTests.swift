import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Update availability")
struct UpdateAvailabilityTests {
    private func plugin(
        id: String = "release-tools",
        source: String = "/Users/example/sources/release-tools",
        revision: String = "a1b2c3d"
    ) -> Plugin {
        Plugin(
            id: id,
            name: "Release Tools",
            summary: "Installed from a local plugin source.",
            source: source,
            scope: "This Mac",
            revision: revision,
            skills: [],
            profiles: [],
            clients: [ClientState(client: .claude, state: .healthy, detail: "Installed", isInstalled: true)],
            installed: true
        )
    }

    private func source(
        location: String = "/Users/example/sources/release-tools",
        refreshed: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        revision: String? = "a1b2c3d"
    ) -> ToolingSource {
        ToolingSource(
            name: "Release Tools",
            kind: .gitRepository,
            location: location,
            lastRefreshedAt: refreshed,
            lastRevision: revision
        )
    }

    @Test("Reports up to date only when a tracked revision was compared")
    func reportsUpToDateOnlyAfterAComparison() {
        let verdict = UpdateAvailabilityEvaluator.evaluate(plugin: plugin(), sources: [source()], packages: [])

        #expect(verdict == .upToDate(revision: "a1b2c3d"))
        #expect(verdict.health == .healthy)
    }

    @Test("Reports an available update when the tracked source moved ahead")
    func reportsAvailableUpdate() {
        let verdict = UpdateAvailabilityEvaluator.evaluate(
            plugin: plugin(),
            sources: [source(revision: "f9e8d7c")],
            packages: []
        )

        #expect(verdict == .updateAvailable(installed: "a1b2c3d", available: "f9e8d7c"))
        #expect(verdict.health == .pending)
        #expect(verdict.hasUpdate)
        let mixed = UpdateAvailabilityEvaluator.evaluate(
            plugin: plugin(), sources: [source(revision: "1.0.0")], packages: [])
        #expect(mixed.isUnverified)
        #expect(!mixed.hasUpdate)
    }

    @Test("Never claims up to date for an unchecked or unreported revision")
    func neverClaimsUpToDateWithoutEvidence() {
        let neverRefreshed = UpdateAvailabilityEvaluator.evaluate(
            plugin: plugin(),
            sources: [source(refreshed: nil)],
            packages: []
        )
        #expect(neverRefreshed.isUnverified)
        #expect(neverRefreshed.title == "Not checked")

        let unknownInstalled = UpdateAvailabilityEvaluator.evaluate(
            plugin: plugin(revision: "Unknown"),
            sources: [source()],
            packages: []
        )
        #expect(unknownInstalled.isUnverified)
        #expect(unknownInstalled.detail.contains("installed revision"))

        let noRevisionReported = UpdateAvailabilityEvaluator.evaluate(
            plugin: plugin(),
            sources: [source(revision: nil)],
            packages: []
        )
        #expect(noRevisionReported.isUnverified)
    }

    @Test("Reports a missing source when no reviewed source covers the local folder")
    func reportsMissingSource() {
        let verdict = UpdateAvailabilityEvaluator.evaluate(plugin: plugin(), sources: [], packages: [])

        #expect(verdict.title == "Update status unknown")
        #expect(verdict.health == .pending)
    }

    @Test("Reports a check failure when the client did not say where a plugin came from")
    func reportsCheckFailureForUntrackedOrigin() {
        let verdict = UpdateAvailabilityEvaluator.evaluate(
            plugin: plugin(source: "Claude Code configuration"),
            sources: [],
            packages: []
        )

        #expect(verdict.title == "Update status unknown")
    }

    @Test("Prefers the catalog verdict, including its unresolved states")
    func prefersCatalogVerdict() {
        func package(status: PackageUpdateStatus?, revision: String?) -> MarketplacePackage {
            MarketplacePackage(
                id: "claude:release-tools",
                name: "Release Tools",
                publisher: "example",
                summary: "",
                sourceName: "Claude marketplace",
                revision: revision,
                components: [.plugin],
                supportedClients: [.claude],
                location: "https://example.com/catalog",
                updateStatus: status
            )
        }

        #expect(
            UpdateAvailabilityEvaluator.evaluate(
                plugin: plugin(),
                sources: [],
                packages: [package(status: .updateAvailable, revision: "f9e8d7c")]
            ) == .updateAvailable(installed: "a1b2c3d", available: "f9e8d7c")
        )
        #expect(
            UpdateAvailabilityEvaluator.evaluate(
                plugin: plugin(),
                sources: [],
                packages: [package(status: .locallyModified, revision: "f9e8d7c")]
            ).isUnverified
        )
        #expect(
            UpdateAvailabilityEvaluator.evaluate(
                plugin: plugin(),
                sources: [],
                packages: [package(status: .unknown, revision: nil)]
            ).isUnverified
        )
        #expect(
            UpdateAvailabilityEvaluator.evaluate(
                plugin: plugin(),
                sources: [],
                packages: [package(status: .current, revision: "a1b2c3d")]
            ) == .upToDate(revision: "a1b2c3d")
        )
    }

    @Test("Names and incompatible clients cannot establish update provenance")
    func rejectsUnrelatedCatalogMatches() {
        let unrelated = MarketplacePackage(
            id: "claude:other@publisher", name: "Release Tools", publisher: "publisher",
            summary: "", sourceName: "Other", revision: "new",
            components: [.plugin], supportedClients: [.claude], location: "")
        #expect(UpdateAvailabilityEvaluator.catalogPackage(for: plugin(), in: [unrelated]) == nil)
        var wrongClient = unrelated
        wrongClient.id = "codex:release-tools"
        wrongClient.supportedClients = [.codex]
        #expect(UpdateAvailabilityEvaluator.catalogPackage(for: plugin(), in: [wrongClient]) == nil)
        let summary = UpdateAvailabilityEvaluator.summary([
            .unknown(reason: "No revision"), .notChecked(reason: "Not refreshed")
        ])
        #expect(summary.checkFailed == 0)
        #expect(summary.sourceMissing == 0)
        #expect(summary.uncheckedCount == 2)
    }

    @Test("Summarizes only what was measured")
    func summarizesOnlyMeasuredVerdicts() {
        let summary = UpdateAvailabilityEvaluator.summary([
            .upToDate(revision: "a"),
            .updateAvailable(installed: "a", available: "b"),
            .checkFailed(reason: "no revision"),
            .sourceMissing(reason: "gone"),
        ])

        #expect(summary.upToDate == 1)
        #expect(summary.uncheckedCount == 2)
        #expect(summary.sentence == "1 update available · 1 check failed · 1 source missing")
        #expect(UpdateAvailabilityEvaluator.summary([.upToDate(revision: "a")]).sentence == "1 up to date")
    }
}

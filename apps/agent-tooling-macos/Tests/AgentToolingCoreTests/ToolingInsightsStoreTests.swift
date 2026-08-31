import Foundation
import Testing

@testable import AgentToolingCore

@Suite("Tooling insights persistence")
struct ToolingInsightsStoreTests {
    @Test func aggregateReportRoundTripsAndCanBeRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceStore(rootURL: root)
        let generatedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let report = InsightsReport(
            id: UUID(uuidString: "D5174DD8-1274-4D28-BD0D-98B9508DFA6A")!,
            generatedAt: generatedAt,
            windowStart: generatedAt.addingTimeInterval(-7 * 86_400),
            coverage: [
                ConversationScanCoverage(
                    client: .codex,
                    sourceID: "fixture",
                    sourceName: "Fixture history",
                    status: .scanned,
                    conversationsScanned: 2,
                    itemsInspected: 8,
                    latestItemAt: generatedAt,
                    detail: "Only aggregate fixture coverage."
                )
            ],
            skillUsage: [
                SkillUsageMetric(
                    skillID: "release-readiness",
                    skillName: "Release Readiness",
                    inferredObservedUses: 2,
                    evidenceLevel: .inferred,
                    provenance: [.codexExplicitReference],
                    observedClients: [.codex],
                    lastObservedAt: generatedAt
                )
            ],
            qualityFindings: [],
            recommendations: [],
            conversationsScanned: 2,
            itemsInspected: 8
        )

        try store.saveInsightsReport(report)
        #expect(try store.loadInsightsReport() == report)

        try store.removeInsightsReport()
        #expect(try store.loadInsightsReport() == nil)
    }

    @Test @MainActor func unavailableHistoryIsRecordedAsNeedingAttention() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "empty-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let model = try AppModel(
            store: WorkspaceStore(rootURL: root.appending(path: "workspace", directoryHint: .isDirectory)),
            homeURL: home
        )

        await model.runInsightsScan(
            options: InsightScanOptions(
                clients: [.claude, .codex],
                includeMarketplaceRecommendations: false
            )
        )

        #expect(model.insightsReport?.coverage.allSatisfy { $0.status == .unavailable } == true)
        #expect(model.activities.first?.title == "Tooling insights updated")
        #expect(model.activities.first?.state == .attention)
    }
}

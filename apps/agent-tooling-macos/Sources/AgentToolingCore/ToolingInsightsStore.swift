import Foundation

extension WorkspaceStore {
    private static var insightsReportKey: String { "insights.report.v1" }

    public func loadInsightsReport() throws -> InsightsReport? {
        try load(Self.insightsReportKey, as: InsightsReport.self)
    }

    public func saveInsightsReport(_ report: InsightsReport) throws {
        try save(report, for: Self.insightsReportKey)
    }

    public func removeInsightsReport() throws {
        try remove(Self.insightsReportKey)
    }
}

import Foundation

@testable import AgentToolingApp
@testable import AgentToolingCore

/// The shapes Insights needs: one scan's worth of findings, and a scan that
/// answers with them.
///
/// A real scan reads this Mac's chat history and keeps its report in this Mac's
/// support folder. Neither belongs in a test, so both are scripted here and the
/// screen is handed these instead.
extension ShellRenderFixture {
    /// One report with something in every section, so a screen that draws only
    /// its empty states fails rather than passing on a blank list.
    nonisolated static func insightsReport(
        generatedAt: Date = .now,
        recommendations: [ToolRecommendation]? = nil
    ) -> InsightsReport {
        InsightsReport(
            generatedAt: generatedAt,
            windowStart: generatedAt.addingTimeInterval(-30 * 24 * 60 * 60),
            coverage: [
                ConversationScanCoverage(
                    client: .claude, sourceID: "claude.projects", sourceName: "Claude Code history",
                    status: .scanned, conversationsScanned: 12, itemsInspected: 480,
                    latestItemAt: generatedAt.addingTimeInterval(-3_600), supportsUsageAttribution: true,
                    detail: "Read 12 recent conversations from this Mac's local history."),
                ConversationScanCoverage(
                    client: .codex, sourceID: "codex.sessions", sourceName: "Codex history",
                    status: .degraded, conversationsScanned: 3, itemsInspected: 41,
                    detail: "Some sessions were larger than the per-item limit and were not inspected."),
            ],
            skillUsage: [
                SkillUsageMetric(
                    skillID: "standalone-skill", skillName: "Standalone Skill",
                    exactObservedUses: 4, evidenceLevel: .exact, provenance: [.claudeSkillToolCall],
                    observedClients: [.claude], lastObservedAt: generatedAt.addingTimeInterval(-7_200)),
                SkillUsageMetric(
                    skillID: "bundled-skill", skillName: "Bundled Skill", evidenceLevel: .noObservedUse),
            ],
            qualityFindings: [
                SkillQualityFinding(
                    id: "finding.description", skillID: "bundled-skill", severity: .warning,
                    category: .description, title: "Bundled Skill has no description",
                    detail: "Nothing in the skill says when it should be used.",
                    recommendedAction: "Add one sentence naming the work this skill is for."),
                SkillQualityFinding(
                    id: "finding.triggers", skillID: "standalone-skill", severity: .information,
                    category: .triggers, title: "Standalone Skill lists one trigger",
                    detail: "A single trigger phrase leaves most requests unmatched.",
                    recommendedAction: "List the other phrasings you actually use."),
            ],
            recommendations: recommendations ?? defaultRecommendations,
            conversationsScanned: 15,
            itemsInspected: 521)
    }

    /// One of each kind an action can be offered for: an installed skill to
    /// open, and a draft somebody would have to review.
    nonisolated static var defaultRecommendations: [ToolRecommendation] {
        [
            ToolRecommendation(
                id: "local-skill:standalone-skill", kind: .useExistingSkill,
                title: "Use Standalone Skill",
                summary: "Turns a release note into the four places it has to be repeated.",
                rationale: "Recent requests overlap with this installed skill, but no supported activation evidence was observed.",
                confidence: .high, supportingConversationCount: 5, skillID: "standalone-skill",
                sourceName: "Local library"),
            ToolRecommendation(
                id: "draft:changelog", kind: .createCustomSkill,
                title: "A skill for the weekly changelog",
                summary: "The same four steps were repeated by hand in several recent conversations.",
                rationale: "Repeated work with no installed skill that matches it.",
                confidence: .medium, supportingConversationCount: 3,
                draftInstruction: "Write a skill that turns a week of merged pull requests into a changelog entry."),
        ]
    }
}

/// A scan that answers with what a test scripted, and a report kept in memory.
///
/// Nothing here reads a transcript, runs a command, or writes a file, so a
/// render of this screen says the same thing on every Mac.
final class StubInsightsServices: InsightsServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: InsightsReport?
    private var answer: InsightsReport
    private var scans = 0
    private let holdFor: Duration?
    private let keepFails: Bool

    /// `restored` is what this Mac had kept before the screen opened;
    /// `holdFor` makes a scan long enough to be stopped halfway.
    init(
        answer: InsightsReport,
        restored: InsightsReport? = nil,
        holdFor: Duration? = nil,
        keepFails: Bool = false
    ) {
        self.answer = answer
        self.holdFor = holdFor
        self.keepFails = keepFails
        kept = restored
    }

    var scanCount: Int {
        lock.withLock { scans }
    }

    var keptReport: InsightsReport? {
        lock.withLock { kept }
    }

    func answer(with report: InsightsReport) {
        lock.withLock { answer = report }
    }

    func scan(options: InsightScanOptions, skills: [Skill], homeURL: URL) async -> InsightsReport {
        lock.withLock { scans += 1 }
        // Returns early when the scan is stopped, which is what a person
        // pressing Cancel is waiting to see.
        if let holdFor { try? await Task.sleep(for: holdFor) }
        return lock.withLock { answer }
    }

    func lastReport() -> InsightsReport? {
        lock.withLock { kept }
    }

    func keep(_ report: InsightsReport) throws {
        if keepFails { throw CocoaError(.fileWriteNoPermission) }
        lock.withLock { kept = report }
    }

    func forget() throws {
        lock.withLock { kept = nil }
    }
}

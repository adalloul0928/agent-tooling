import Foundation
import SQLite3
import Testing

@testable import AgentToolingCore

struct ToolingInsightsTests {
    @Test func scanAggregatesProvenanceWithoutPersistingConversationText() async throws {
        let home = try TemporaryInsightsHome()
        defer { home.remove() }
        let now = Date.now
        try home.createCodexHistory(
            rows: [
                (
                    "codex-thread",
                    "userMessage",
                    [
                        "type": "userMessage",
                        "fixtureTurnID": "release-turn",
                        "content": [
                            [
                                "type": "text",
                                "text":
                                    "Use $release-readiness for a release readiness build review. PRIVATE_CHAT_SENTINEL api_key=do-not-store",
                            ]
                        ],
                    ],
                    now.addingTimeInterval(-120).timeIntervalSince1970 * 1_000
                ),
                (
                    "codex-thread",
                    "commandExecution",
                    [
                        "type": "commandExecution",
                        "fixtureTurnID": "release-turn",
                        "command": "sed -n 1,120p /tmp/skills/release-readiness/SKILL.md",
                    ],
                    now.addingTimeInterval(-110).timeIntervalSince1970 * 1_000
                ),
            ]
        )
        try home.createClaudeTranscript(
            name: "primary",
            rows: [
                [
                    "type": "user",
                    "sessionId": "claude-session",
                    "uuid": "turn-one",
                    "timestamp": isoDate(now.addingTimeInterval(-100)),
                    "message": [
                        "role": "user",
                        "content": "Run release readiness tests before the build. CLAUDE_PRIVATE_SENTINEL",
                    ],
                ],
                [
                    "type": "assistant",
                    "sessionId": "claude-session",
                    "timestamp": isoDate(now.addingTimeInterval(-90)),
                    "attributionSkill": "release-readiness",
                    "message": ["role": "assistant", "content": []],
                ],
                [
                    "type": "assistant",
                    "sessionId": "claude-session",
                    "timestamp": isoDate(now.addingTimeInterval(-89)),
                    "attributionSkill": "release-readiness",
                    "message": [
                        "role": "assistant",
                        "content": [
                            [
                                "type": "tool_use",
                                "name": "Skill",
                                "input": ["skill": "release-readiness"],
                            ]
                        ],
                    ],
                ],
                [
                    "type": "user",
                    "sessionId": "claude-session",
                    "uuid": "turn-two",
                    "timestamp": isoDate(now.addingTimeInterval(-80)),
                    "message": ["role": "user", "content": "Check the release build again"],
                ],
                [
                    "type": "assistant",
                    "sessionId": "claude-session",
                    "timestamp": isoDate(now.addingTimeInterval(-70)),
                    "message": [
                        "role": "assistant",
                        "content": [
                            [
                                "type": "tool_use",
                                "name": "Skill",
                                "input": ["skill": "release-readiness"],
                            ]
                        ],
                    ],
                ],
                [
                    "type": "assistant",
                    "sessionId": "claude-session",
                    "timestamp": isoDate(now.addingTimeInterval(-69)),
                    "message": [
                        "role": "assistant",
                        "content": [
                            [
                                "type": "tool_use",
                                "name": "Skill",
                                "input": ["skill": "single-use"],
                            ]
                        ],
                    ],
                ],
            ]
        )
        try home.createClaudeTranscript(
            relativeDirectory: "project/subagents",
            name: "ignored",
            rows: [
                [
                    "type": "assistant", "sessionId": "ignored", "timestamp": isoDate(now),
                    "attributionSkill": "unused-skill",
                ]
            ]
        )
        try home.createClaudeTranscript(
            name: "skill-injections",
            rows: [
                [
                    "type": "assistant", "sessionId": "ignored", "timestamp": isoDate(now),
                    "attributionSkill": "unused-skill",
                ]
            ]
        )

        let releaseSkill = makeSkill(
            id: "release-readiness",
            displayName: "Release Readiness",
            summary: "Checks build, test, review, and release readiness before shipping.",
            triggers: ["Check release readiness", "Validate this build"],
            negativeTrigger: "Draft a release announcement"
        )
        let unusedSkill = makeSkill(
            id: "unused-skill",
            displayName: "Unused Skill",
            summary: "Reviews database migrations before a production deployment.",
            triggers: ["Review this migration"],
            negativeTrigger: "Write a new feature"
        )
        let singleUseSkill = makeSkill(
            id: "single-use",
            displayName: "Single Use",
            summary: "Performs one focused compatibility check before a client update.",
            triggers: ["Check client compatibility"],
            negativeTrigger: "Install an unrelated tool"
        )
        let package = MarketplacePackage(
            id: "catalog.release-tools",
            name: "Release Tools",
            publisher: "Fixture",
            summary: "Release readiness build testing and review automation.",
            sourceName: "Fixture catalog",
            components: [.plugin, .skill],
            supportedClients: [.claude, .codex],
            location: "https://example.invalid/release-tools"
        )
        let routeInstalledPackage = MarketplacePackage(
            id: "catalog.installed-release-tools",
            name: "Installed Release Tools",
            publisher: "Fixture",
            summary: "Release readiness build testing and review automation.",
            sourceName: "Fixture catalog",
            components: [.plugin],
            supportedClients: [.codex],
            location: "https://example.invalid/installed-release-tools",
            nativeInstalls: [
                NativeInstall(
                    client: .codex,
                    executable: "codex",
                    arguments: ["plugin", "add", "installed-release-tools"],
                    detail: "Fixture route",
                    isInstalled: true
                )
            ]
        )

        let report = await ToolingInsightsService().scan(
            options: InsightScanOptions(lookbackDays: 7, includeMarketplaceRecommendations: true),
            skills: [releaseSkill, unusedSkill, singleUseSkill],
            marketplacePackages: [package, routeInstalledPackage],
            homeURL: home.url
        )
        let releaseUsage = try #require(report.skillUsage.first(where: { $0.skillID == releaseSkill.id }))
        let unusedUsage = try #require(report.skillUsage.first(where: { $0.skillID == unusedSkill.id }))

        #expect(releaseUsage.exactObservedUses == 2)
        #expect(releaseUsage.inferredObservedUses == 1)
        #expect(releaseUsage.evidenceLevel == .exact)
        #expect(releaseUsage.provenance.contains(.claudeAttribution))
        #expect(releaseUsage.provenance.contains(.claudeSkillToolCall))
        #expect(releaseUsage.provenance.contains(.codexExplicitReference))
        #expect(releaseUsage.provenance.contains(.skillDefinitionRead))
        #expect(unusedUsage.evidenceLevel == .noObservedUse)
        #expect(unusedUsage.usageSummary == "No observed use")
        #expect(report.coverage.contains(where: { $0.sourceID == "claude-project-jsonl-v1" }))
        #expect(report.coverage.contains(where: { $0.sourceID == "codex-thread-history-sqlite-v1" }))
        #expect(report.recommendations.contains(where: { $0.marketplacePackageID == package.id }))
        #expect(!report.recommendations.contains(where: { $0.marketplacePackageID == routeInstalledPackage.id }))
        #expect(report.qualityFindings.contains(where: { $0.id == "single-use:low-observed-use" }))
        #expect(report.storesRawConversationContent == false)

        let encoded = try AgentToolingCoding.encoder(prettyPrinted: true).encode(report)
        let persisted = try #require(String(data: encoded, encoding: .utf8))
        #expect(!persisted.contains("PRIVATE_CHAT_SENTINEL"))
        #expect(!persisted.contains("CLAUDE_PRIVATE_SENTINEL"))
        #expect(!persisted.contains("do-not-store"))
        #expect(!persisted.contains("api_key"))

        var legacyObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "marketplaceDiscovery")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])
        #expect(try AgentToolingCoding.decoder().decode(InsightsReport.self, from: legacyData).marketplaceDiscovery == nil)
    }

    @Test func onlineDiscoveryUsesOnlyAuditedGenericSearchTerms() async throws {
        let home = try TemporaryInsightsHome()
        defer { home.remove() }
        let now = Date.now.timeIntervalSince1970 * 1_000
        try home.createCodexHistory(
            rows: [
                (
                    "thread-one",
                    "userMessage",
                    [
                        "type": "userMessage",
                        "content": [
                            [
                                "type": "text",
                                "text": "Automate browser testing PRIVATE_MARKETPLACE_SENTINEL",
                            ]
                        ],
                    ],
                    now - 2_000
                ),
                (
                    "thread-two",
                    "userMessage",
                    [
                        "type": "userMessage",
                        "content": [
                            [
                                "type": "text",
                                "text": "Browser automation testing for PRIVATE_MARKETPLACE_SENTINEL",
                            ]
                        ],
                    ],
                    now - 1_000
                ),
            ]
        )
        let package = MarketplacePackage(
            id: "online.browser-tools",
            name: "Browser Tools",
            publisher: "Fixture",
            summary: "Browser automation and testing tools.",
            sourceName: "Online fixture",
            components: [.mcpServer],
            supportedClients: [.codex],
            location: "https://example.invalid/browser-tools"
        )
        let provider = RecordingMarketplaceProvider(package: package)
        let unrelatedPackage = MarketplacePackage(
            id: "online.unrelated",
            name: "Weather Notifier",
            publisher: "Fixture",
            summary: "Forecast notifications for outdoor plans.",
            sourceName: "Online fixture",
            components: [.mcpServer],
            supportedClients: [.codex],
            location: "https://example.invalid/weather"
        )
        let unrelatedProvider = RecordingMarketplaceProvider(package: unrelatedPackage)

        let report = await ToolingInsightsService().scan(
            options: InsightScanOptions(clients: [.codex], includeMarketplaceRecommendations: true),
            skills: [],
            marketplacePackages: [],
            homeURL: home.url,
            marketplaceProviders: [provider, unrelatedProvider]
        )
        let searches = await provider.recordedSearches()

        #expect(searches.contains("browser"))
        #expect(searches.count <= 4)
        #expect(searches.allSatisfy { !$0.contains("PRIVATE_MARKETPLACE_SENTINEL") })
        #expect(searches.allSatisfy { !$0.contains(where: \Character.isWhitespace) })
        #expect(report.recommendations.contains(where: { $0.marketplacePackageID == package.id }))
        #expect(
            report.recommendations.first(where: { $0.marketplacePackageID == package.id })?.marketplacePackage == package
        )
        #expect(!report.recommendations.contains(where: { $0.marketplacePackageID == unrelatedPackage.id }))
        let discovery = try #require(report.marketplaceDiscovery)
        #expect(discovery.queriesAttempted == searches.count * 2)
        #expect(discovery.queriesSucceeded == discovery.queriesAttempted)
        #expect(discovery.queriesFailed == 0)
        let persisted = String(
            decoding: try AgentToolingCoding.encoder().encode(report),
            as: UTF8.self
        )
        #expect(!persisted.contains("PRIVATE_MARKETPLACE_SENTINEL"))
    }

    @Test func ambiguousUnqualifiedSkillAliasesAreNotAttributed() async throws {
        let home = try TemporaryInsightsHome()
        defer { home.remove() }
        let now = Date.now.timeIntervalSince1970 * 1_000
        try home.createCodexHistory(
            rows: [
                (
                    "alias-thread",
                    "userMessage",
                    [
                        "type": "userMessage",
                        "fixtureTurnID": "unqualified-turn",
                        "content": [["type": "text", "text": "Use $review"]],
                    ],
                    now - 1_000
                ),
                (
                    "alias-thread",
                    "userMessage",
                    [
                        "type": "userMessage",
                        "fixtureTurnID": "qualified-turn",
                        "content": [["type": "text", "text": "Use $plugin-one:review"]],
                    ],
                    now
                ),
            ]
        )
        let first = makeSkill(
            id: "plugin-one:review",
            displayName: "Review",
            summary: "Reviews the first package with an intentionally shared display name.",
            triggers: ["Review the first package"],
            negativeTrigger: "Review the second package"
        )
        let second = makeSkill(
            id: "plugin-two:review",
            displayName: "Review",
            summary: "Reviews the second package with an intentionally shared display name.",
            triggers: ["Review the second package"],
            negativeTrigger: "Review the first package"
        )

        let report = await ToolingInsightsService().scan(
            options: InsightScanOptions(clients: [.codex]),
            skills: [first, second],
            marketplacePackages: [],
            homeURL: home.url
        )
        let firstUsage = try #require(report.skillUsage.first(where: { $0.skillID == first.id }))
        let secondUsage = try #require(report.skillUsage.first(where: { $0.skillID == second.id }))

        #expect(firstUsage.inferredObservedUses == 1)
        #expect(secondUsage.evidenceLevel == .noObservedUse)
    }

    @Test func boundedScansKeepNewestItemsAndMarkCoverageDegraded() async throws {
        let home = try TemporaryInsightsHome()
        defer { home.remove() }
        let now = Date.now
        var codexRows: [(String, String, [String: Any], Double)] = []
        for index in 0..<11 {
            let text =
                if index == 0 { "Use $old-skill" } else if index == 10 { "Use $new-skill" } else { "A generic recent request" }
            codexRows.append(
                (
                    "long-codex-thread",
                    "userMessage",
                    ["type": "userMessage", "content": [["type": "text", "text": text]]],
                    now.addingTimeInterval(Double(index - 20)).timeIntervalSince1970 * 1_000
                )
            )
        }
        try home.createCodexHistory(rows: codexRows)

        var claudeRows: [[String: Any]] = []
        for index in 0..<11 {
            if index == 0 || index == 10 {
                claudeRows.append([
                    "type": "assistant",
                    "sessionId": "long-claude-session",
                    "timestamp": isoDate(now.addingTimeInterval(Double(index - 20))),
                    "attributionSkill": index == 0 ? "old-skill" : "new-skill",
                    "message": ["role": "assistant", "content": []],
                ])
            } else {
                claudeRows.append([
                    "type": "user",
                    "sessionId": "long-claude-session",
                    "uuid": "turn-\(index)",
                    "timestamp": isoDate(now.addingTimeInterval(Double(index - 20))),
                    "message": ["role": "user", "content": "A generic recent request"],
                ])
            }
        }
        try home.createClaudeTranscript(name: "long", rows: claudeRows)
        let oldSkill = makeSkill(
            id: "old-skill",
            displayName: "Old Skill",
            summary: "Checks an older bounded-history scanner fixture for regression coverage.",
            triggers: ["Use the old fixture"],
            negativeTrigger: "Use something else"
        )
        let newSkill = makeSkill(
            id: "new-skill",
            displayName: "New Skill",
            summary: "Checks a recent bounded-history scanner fixture for regression coverage.",
            triggers: ["Use the new fixture"],
            negativeTrigger: "Use something else"
        )

        let report = await ToolingInsightsService().scan(
            options: InsightScanOptions(maximumItemsPerConversation: 10),
            skills: [oldSkill, newSkill],
            marketplacePackages: [],
            homeURL: home.url
        )
        let oldUsage = try #require(report.skillUsage.first(where: { $0.skillID == oldSkill.id }))
        let newUsage = try #require(report.skillUsage.first(where: { $0.skillID == newSkill.id }))

        #expect(oldUsage.evidenceLevel == .noObservedUse)
        #expect(newUsage.exactObservedUses == 1)
        #expect(newUsage.inferredObservedUses == 1)
        #expect(report.coverage.allSatisfy { $0.status == .degraded })
    }

    @Test func transcriptByteBudgetDegradesSafelyWithoutReadingOversizedHistory() async throws {
        let home = try TemporaryInsightsHome()
        defer { home.remove() }
        let skill = makeSkill(
            id: "budget-skill",
            displayName: "Budget Skill",
            summary: "Verifies the aggregate transcript byte budget for local history scans.",
            triggers: ["Check transcript budget"],
            negativeTrigger: "Read an unrelated file"
        )
        try home.createClaudeTranscript(
            name: "oversized",
            rows: [
                [
                    "type": "user",
                    "sessionId": "budget-session",
                    "uuid": "turn",
                    "timestamp": isoDate(.now),
                    "message": ["role": "user", "content": String(repeating: "browser ", count: 400)],
                ]
            ]
        )
        let service = ToolingInsightsService(
            scanner: LocalConversationScanner(maximumClaudeTranscriptBytes: 1_024)
        )

        let report = await service.scan(
            options: InsightScanOptions(clients: [.claude]),
            skills: [skill],
            marketplacePackages: [],
            homeURL: home.url
        )
        let usage = try #require(report.skillUsage.first)
        let transcriptCoverage = try #require(
            report.coverage.first(where: { $0.sourceID == "claude-project-jsonl-v1" })
        )

        #expect(transcriptCoverage.status == .degraded)
        #expect(transcriptCoverage.itemsInspected == 0)
        #expect(usage.evidenceLevel == .trackingUnavailable)
    }

    @Test func oversizedSingleTranscriptIsExplicitlyReportedAsDegraded() async throws {
        let home = try TemporaryInsightsHome()
        defer { home.remove() }
        try home.createRawClaudeTranscript(name: "too-large", byteCount: 16 * 1_024 * 1_024 + 1)

        let report = await ToolingInsightsService().scan(
            options: InsightScanOptions(clients: [.claude]),
            skills: [],
            marketplacePackages: [],
            homeURL: home.url
        )
        let transcriptCoverage = try #require(
            report.coverage.first(where: { $0.sourceID == "claude-project-jsonl-v1" })
        )

        #expect(transcriptCoverage.status == .degraded)
        #expect(transcriptCoverage.itemsInspected == 0)
        #expect(transcriptCoverage.detail.contains("safe read limits"))
    }

    @Test func oversizedClaudeItemMakesNoObservedUseUnavailable() async throws {
        let home = try TemporaryInsightsHome()
        defer { home.remove() }
        let skill = makeSkill(
            id: "claude-item-coverage",
            displayName: "Claude Item Coverage",
            summary: "Checks that incomplete Claude transcript rows cannot produce a confident unused result.",
            triggers: ["Check Claude item coverage"],
            negativeTrigger: "Check an unrelated source"
        )
        let validLine = String(
            decoding: try JSONSerialization.data(
                withJSONObject: [
                    "type": "user",
                    "sessionId": "mixed-session",
                    "uuid": "valid-turn",
                    "timestamp": isoDate(.now),
                    "message": ["role": "user", "content": "A generic recent request"],
                ],
                options: [.sortedKeys]
            ),
            as: UTF8.self
        )
        try home.createRawClaudeTranscript(
            name: "mixed-items",
            lines: [validLine, String(repeating: "x", count: 4 * 1_024 + 1)]
        )
        try home.createCodexHistory(
            rows: [
                (
                    "complete-thread",
                    "userMessage",
                    ["type": "userMessage", "content": [["type": "text", "text": "A generic request"]]],
                    Date.now.timeIntervalSince1970 * 1_000
                )
            ]
        )

        let report = await ToolingInsightsService().scan(
            options: InsightScanOptions(maximumItemBytes: 4 * 1_024),
            skills: [skill],
            marketplacePackages: [],
            homeURL: home.url
        )
        let usage = try #require(report.skillUsage.first)
        let coverage = try #require(
            report.coverage.first(where: { $0.sourceID == "claude-project-jsonl-v1" })
        )

        #expect(coverage.status == .degraded)
        #expect(coverage.itemsInspected == 1)
        #expect(coverage.itemsSkipped == 1)
        #expect(coverage.detail.contains("1 malformed or oversized transcript item was skipped"))
        #expect(usage.evidenceLevel == .trackingUnavailable)
    }

    @Test func malformedCodexItemMakesNoObservedUseUnavailable() async throws {
        let home = try TemporaryInsightsHome()
        defer { home.remove() }
        let skill = makeSkill(
            id: "codex-item-coverage",
            displayName: "Codex Item Coverage",
            summary: "Checks that incomplete Codex transcript rows cannot produce a confident unused result.",
            triggers: ["Check Codex item coverage"],
            negativeTrigger: "Check an unrelated source"
        )
        let now = Date.now.timeIntervalSince1970 * 1_000
        try home.createCodexHistory(
            rows: [
                (
                    "mixed-thread",
                    "userMessage",
                    ["type": "userMessage", "content": [["type": "text", "text": "A generic request"]]],
                    now - 1
                )
            ]
        )
        try home.appendRawCodexHistoryRow(
            threadID: "mixed-thread",
            itemType: "userMessage",
            payload: "{not-json",
            timestamp: now
        )

        let report = await ToolingInsightsService().scan(
            options: InsightScanOptions(clients: [.codex]),
            skills: [skill],
            marketplacePackages: [],
            homeURL: home.url
        )
        let usage = try #require(report.skillUsage.first)
        let coverage = try #require(
            report.coverage.first(where: { $0.sourceID == "codex-thread-history-sqlite-v1" })
        )

        #expect(coverage.status == .degraded)
        #expect(coverage.itemsInspected == 1)
        #expect(coverage.itemsSkipped == 1)
        #expect(coverage.detail.contains("1 malformed or oversized transcript item was skipped"))
        #expect(usage.evidenceLevel == .trackingUnavailable)
    }

    @Test func claudeSQLiteFallbackUsesCurrentJoinedSchemaForIntentOnly() async throws {
        let home = try TemporaryInsightsHome()
        defer { home.remove() }
        try home.createClaudeStore(
            rows: [
                (
                    "user-uuid",
                    "session-id",
                    "user",
                    ["role": "user", "content": "Research browser automation"],
                    Date.now.timeIntervalSince1970
                )
            ]
        )
        let skill = makeSkill(
            id: "claude-target",
            displayName: "Claude Target",
            summary: "Confirms that fallback message storage does not claim activation telemetry.",
            triggers: ["Run the Claude target"],
            negativeTrigger: "Run another target"
        )

        let report = await ToolingInsightsService().scan(
            options: InsightScanOptions(clients: [.claude]),
            skills: [skill],
            marketplacePackages: [],
            homeURL: home.url
        )
        let coverage = try #require(report.coverage.first)
        let usage = try #require(report.skillUsage.first)

        #expect(coverage.sourceID == "claude-store-sqlite-v1")
        #expect(coverage.status == .scanned)
        #expect(coverage.itemsInspected == 1)
        #expect(coverage.supportsUsageAttribution == false)
        #expect(usage.evidenceLevel == .trackingUnavailable)
    }

    @Test func noObservedUseIsScopedToEachSkillsTargetClients() async throws {
        let home = try TemporaryInsightsHome()
        defer { home.remove() }
        try home.createCodexHistory(
            rows: [
                (
                    "codex-only",
                    "userMessage",
                    ["type": "userMessage", "content": [["type": "text", "text": "A generic request"]]],
                    Date.now.timeIntervalSince1970 * 1_000
                )
            ]
        )
        var claudeSkill = makeSkill(
            id: "claude-only",
            displayName: "Claude Only",
            summary: "Targets only Claude Code for usage coverage scope testing.",
            triggers: ["Use the Claude fixture"],
            negativeTrigger: "Use Codex"
        )
        claudeSkill.clients = [
            ClientState(client: .claude, state: .healthy, detail: "Installed", isInstalled: true)
        ]
        var codexSkill = makeSkill(
            id: "codex-only",
            displayName: "Codex Only",
            summary: "Targets only Codex for usage coverage scope testing.",
            triggers: ["Use the Codex fixture"],
            negativeTrigger: "Use Claude"
        )
        codexSkill.clients = [
            ClientState(client: .codex, state: .healthy, detail: "Installed", isInstalled: true)
        ]

        let report = await ToolingInsightsService().scan(
            options: InsightScanOptions(),
            skills: [claudeSkill, codexSkill],
            marketplacePackages: [],
            homeURL: home.url
        )
        let claudeUsage = try #require(report.skillUsage.first(where: { $0.skillID == claudeSkill.id }))
        let codexUsage = try #require(report.skillUsage.first(where: { $0.skillID == codexSkill.id }))

        #expect(claudeUsage.evidenceLevel == .trackingUnavailable)
        #expect(codexUsage.evidenceLevel == .noObservedUse)
    }

    @Test func missingAndCorruptSourcesDegradeWithoutInventingZeroUsage() async throws {
        let home = try TemporaryInsightsHome()
        defer { home.remove() }
        let codexDirectory = home.url.appending(path: ".codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: codexDirectory.appending(path: "thread_history_1.sqlite"))
        let skill = makeSkill(
            id: "fixture",
            displayName: "Fixture Skill",
            summary: "A sufficiently descriptive fixture skill used by this scanner test.",
            triggers: ["Run the fixture"],
            negativeTrigger: "Do something unrelated"
        )

        let report = await ToolingInsightsService().scan(
            options: InsightScanOptions(),
            skills: [skill],
            marketplacePackages: [],
            homeURL: home.url
        )
        let usage = try #require(report.skillUsage.first)

        #expect(usage.evidenceLevel == .trackingUnavailable)
        #expect(usage.usageSummary == "Tracking unavailable")
        #expect(report.coverage.contains(where: { $0.client == .codex && $0.status == .degraded }))
        #expect(report.coverage.contains(where: { $0.client == .claude && $0.status == .unavailable }))
        #expect(report.conversationsScanned == 0)
        #expect(report.itemsInspected == 0)
    }

    @Test func staticQualityScannerProducesActionableDeterministicFindings() async throws {
        let home = try TemporaryInsightsHome()
        defer { home.remove() }
        let weakSkill = Skill(
            id: "weak-skill",
            name: "weak-skill",
            displayName: "Weak Skill",
            summary: "Too short",
            bundle: "fixture",
            scope: "This Mac",
            owned: true,
            triggers: ["Do the thing", "do the thing"],
            negativeTrigger: "",
            files: ["/Users/example/private/helper.sh"],
            clients: [],
            validationCount: 0
        )
        let driftSkill = Skill(
            id: "drift-skill",
            name: "drift-skill",
            displayName: "Drift Skill",
            summary: "Checks the desired client installation state for a managed package.",
            bundle: "fixture",
            scope: "This Mac",
            owned: true,
            triggers: ["Check installation drift"],
            negativeTrigger: "Inspect an unrelated package",
            files: ["SKILL.md"],
            clients: [
                ClientState(
                    client: .codex,
                    state: .attention,
                    detail: "Expected but missing",
                    isInstalled: false
                )
            ],
            validationCount: 1
        )
        let vendorSkill = Skill(
            id: "vendor-skill",
            name: "vendor-skill",
            displayName: "Vendor Skill",
            summary: "",
            bundle: "vendor",
            scope: "This Mac",
            owned: false,
            triggers: [],
            negativeTrigger: "",
            files: [],
            clients: [],
            validationCount: 0
        )
        let metadataUnavailableSkill = Skill(
            id: "metadata-unavailable",
            name: "metadata-unavailable",
            displayName: "Metadata Unavailable",
            summary: "Represents a managed inventory row whose trigger metadata was not parsed.",
            bundle: "fixture",
            scope: "This Mac",
            owned: true,
            triggers: [],
            negativeTrigger: "",
            files: ["SKILL.md"],
            clients: [],
            validationCount: 1
        )

        let report = await ToolingInsightsService().scan(
            options: InsightScanOptions(clients: []),
            skills: [weakSkill, driftSkill, vendorSkill, metadataUnavailableSkill],
            marketplacePackages: [],
            homeURL: home.url
        )
        let identifiers = Set(report.qualityFindings.map(\.id))

        #expect(identifiers.contains("weak-skill:description-too-short"))
        #expect(identifiers.contains("weak-skill:duplicate-triggers"))
        #expect(identifiers.contains("weak-skill:missing-negative-trigger"))
        #expect(identifiers.contains("weak-skill:missing-skill-file"))
        #expect(identifiers.contains("weak-skill:machine-path"))
        #expect(identifiers.contains("drift-skill:client-drift"))
        #expect(!identifiers.contains("weak-skill:client-drift"))
        #expect(!identifiers.contains("weak-skill:no-observed-use"))
        #expect(!identifiers.contains(where: { $0.hasPrefix("vendor-skill:") }))
        #expect(!identifiers.contains("metadata-unavailable:missing-triggers"))
        #expect(!identifiers.contains("metadata-unavailable:missing-negative-trigger"))
    }
}

private func makeSkill(
    id: String,
    displayName: String,
    summary: String,
    triggers: [String],
    negativeTrigger: String
) -> Skill {
    Skill(
        id: id,
        name: id,
        displayName: displayName,
        summary: summary,
        bundle: "fixture",
        scope: "This Mac",
        owned: true,
        triggers: triggers,
        negativeTrigger: negativeTrigger,
        files: ["SKILL.md"],
        clients: [],
        validationCount: 1
    )
}

private func isoDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private final class TemporaryInsightsHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "agent-tooling-insights-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func createCodexHistory(rows: [(String, String, [String: Any], Double)]) throws {
        let directory = url.appending(path: ".codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appending(path: "thread_history_1.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path(percentEncoded: false), &database) == SQLITE_OK, let database else {
            throw FixtureError.database
        }
        defer { sqlite3_close(database) }
        guard
            sqlite3_exec(
                database,
                "CREATE TABLE thread_items(thread_id TEXT, item_type TEXT, item_json TEXT, created_at_ms REAL, turn_id TEXT)",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        else { throw FixtureError.database }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard
            sqlite3_prepare_v2(
                database,
                "INSERT INTO thread_items(thread_id, item_type, item_json, created_at_ms, turn_id) VALUES (?, ?, ?, ?, ?)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else { throw FixtureError.database }
        for (rowIndex, row) in rows.enumerated() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let json = try String(
                decoding: JSONSerialization.data(withJSONObject: row.2, options: [.sortedKeys]),
                as: UTF8.self
            )
            let turnID = row.2["fixtureTurnID"] as? String ?? "turn-\(rowIndex)"
            guard sqlite3_bind_text(statement, 1, row.0, -1, fixtureSQLiteTransient) == SQLITE_OK,
                sqlite3_bind_text(statement, 2, row.1, -1, fixtureSQLiteTransient) == SQLITE_OK,
                sqlite3_bind_text(statement, 3, json, -1, fixtureSQLiteTransient) == SQLITE_OK,
                sqlite3_bind_double(statement, 4, row.3) == SQLITE_OK,
                sqlite3_bind_text(statement, 5, turnID, -1, fixtureSQLiteTransient) == SQLITE_OK,
                sqlite3_step(statement) == SQLITE_DONE
            else { throw FixtureError.database }
        }
    }

    func createClaudeTranscript(
        relativeDirectory: String = "project",
        name: String,
        rows: [[String: Any]]
    ) throws {
        let directory = url.appending(path: ".claude/projects/\(relativeDirectory)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines =
            try rows.map {
                String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
            }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: directory.appending(path: "\(name).jsonl"))
    }

    func createRawClaudeTranscript(name: String, byteCount: Int) throws {
        let directory = url.appending(path: ".claude/projects/project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: byteCount).write(to: directory.appending(path: "\(name).jsonl"))
    }

    func createRawClaudeTranscript(name: String, lines: [String]) throws {
        let directory = url.appending(path: ".claude/projects/project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = lines.joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: directory.appending(path: "\(name).jsonl"))
    }

    func appendRawCodexHistoryRow(
        threadID: String,
        itemType: String,
        payload: String,
        timestamp: Double
    ) throws {
        let databaseURL = url.appending(path: ".codex/thread_history_1.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path(percentEncoded: false), &database) == SQLITE_OK, let database else {
            throw FixtureError.database
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard
            sqlite3_prepare_v2(
                database,
                "INSERT INTO thread_items(thread_id, item_type, item_json, created_at_ms, turn_id) VALUES (?, ?, ?, ?, ?)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
            sqlite3_bind_text(statement, 1, threadID, -1, fixtureSQLiteTransient) == SQLITE_OK,
            sqlite3_bind_text(statement, 2, itemType, -1, fixtureSQLiteTransient) == SQLITE_OK,
            sqlite3_bind_text(statement, 3, payload, -1, fixtureSQLiteTransient) == SQLITE_OK,
            sqlite3_bind_double(statement, 4, timestamp) == SQLITE_OK,
            sqlite3_bind_text(statement, 5, "raw-turn", -1, fixtureSQLiteTransient) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_DONE
        else { throw FixtureError.database }
    }

    func createClaudeStore(rows: [(String, String, String, [String: Any], Double)]) throws {
        let directory = url.appending(path: ".claude", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appending(path: "__store.db")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path(percentEncoded: false), &database) == SQLITE_OK, let database else {
            throw FixtureError.database
        }
        defer { sqlite3_close(database) }
        let schema = """
            CREATE TABLE base_messages(
                uuid TEXT PRIMARY KEY, parent_uuid TEXT, session_id TEXT, timestamp REAL, message_type TEXT
            );
            CREATE TABLE user_messages(uuid TEXT PRIMARY KEY, message TEXT, timestamp REAL);
            CREATE TABLE assistant_messages(uuid TEXT PRIMARY KEY, message TEXT, timestamp REAL);
            """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else { throw FixtureError.database }

        for row in rows {
            let message = String(
                decoding: try JSONSerialization.data(withJSONObject: row.3, options: [.sortedKeys]),
                as: UTF8.self
            )
            try insert(
                sql: "INSERT INTO base_messages(uuid, session_id, timestamp, message_type) VALUES (?, ?, ?, ?)",
                strings: [row.0, row.1],
                timestamp: row.4,
                trailingString: row.2,
                database: database
            )
            let table = row.2 == "assistant" ? "assistant_messages" : "user_messages"
            try insert(
                sql: "INSERT INTO \(table)(uuid, message, timestamp) VALUES (?, ?, ?)",
                strings: [row.0, message],
                timestamp: row.4,
                database: database
            )
        }
    }

    private func insert(
        sql: String,
        strings: [String],
        timestamp: Double,
        trailingString: String? = nil,
        database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw FixtureError.database
        }
        var index: Int32 = 1
        for string in strings {
            guard sqlite3_bind_text(statement, index, string, -1, fixtureSQLiteTransient) == SQLITE_OK else {
                throw FixtureError.database
            }
            index += 1
        }
        guard sqlite3_bind_double(statement, index, timestamp) == SQLITE_OK else { throw FixtureError.database }
        index += 1
        if let trailingString {
            guard sqlite3_bind_text(statement, index, trailingString, -1, fixtureSQLiteTransient) == SQLITE_OK else {
                throw FixtureError.database
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.database }
    }
}

private let fixtureSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum FixtureError: Error {
    case database
}

private actor RecordingMarketplaceProvider: MarketplaceProvider {
    nonisolated let id = "fixture.recording"
    nonisolated let displayName = "Recording fixture"
    private let package: MarketplacePackage
    private var searches: [String] = []

    init(package: MarketplacePackage) {
        self.package = package
    }

    func search(_ query: MarketplaceQuery) async throws -> MarketplacePage {
        if let search = query.search { searches.append(search) }
        return MarketplacePage(packages: [package])
    }

    func recordedSearches() -> [String] { searches }
}

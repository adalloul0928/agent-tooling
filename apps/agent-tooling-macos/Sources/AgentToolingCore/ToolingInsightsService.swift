import Foundation

public struct ToolingInsightsService: Sendable {
    private let scanner: LocalConversationScanner

    public init(scanner: LocalConversationScanner = LocalConversationScanner()) {
        self.scanner = scanner
    }

    public func scan(
        options: InsightScanOptions,
        skills: [Skill],
        marketplacePackages: [MarketplacePackage],
        homeURL: URL,
        marketplaceProviders: [any MarketplaceProvider] = []
    ) async -> InsightsReport {
        let now = Date.now
        let artifact = scanner.scan(options: options, skills: skills, homeURL: homeURL, now: now)
        let discovery = await discoverMarketplacePackages(
            options: options.bounded,
            cachedPackages: marketplacePackages,
            providers: marketplaceProviders,
            messages: artifact.messages
        )
        let usage = buildUsage(skills: skills, artifact: artifact)
        let findings = buildQualityFindings(skills: skills, usage: usage)
        let recommendations = buildRecommendations(
            options: options.bounded,
            skills: skills,
            packages: discovery.packages,
            discoverySupport: discovery.supportByPackageID,
            usage: usage,
            messages: artifact.messages
        )
        return InsightsReport(
            generatedAt: now,
            windowStart: artifact.windowStart,
            coverage: artifact.coverage.sorted { lhs, rhs in lhs.client.rawValue < rhs.client.rawValue },
            skillUsage: usage,
            qualityFindings: findings,
            recommendations: recommendations,
            marketplaceDiscovery: discovery.summary,
            conversationsScanned: artifact.coverage.reduce(0) { $0 + $1.conversationsScanned },
            itemsInspected: artifact.coverage.reduce(0) { $0 + $1.itemsInspected }
        )
    }
}

private func buildUsage(skills: [Skill], artifact: ConversationScanArtifact) -> [SkillUsageMetric] {
    let grouped = Dictionary(grouping: artifact.evidence, by: \UsageEvidence.skillID)
    return skills.map { skill in
        let evidence = grouped[skill.id] ?? []
        let exactKeys = Set(evidence.filter { $0.precision == .exact }.map(\.key))
        let inferredKeys = Set(evidence.filter { $0.precision == .inferred }.map(\.key)).subtracting(exactKeys)
        let exact = exactKeys.count
        let inferred = inferredKeys.count
        let explicitTargets = Set(skill.clients.map(\.client))
        let relevantCoverage =
            explicitTargets.isEmpty
            ? artifact.coverage
            : artifact.coverage.filter { explicitTargets.contains($0.client) }
        let observableCoverage =
            !relevantCoverage.isEmpty
            && relevantCoverage.allSatisfy {
                $0.supportsUsageAttribution == true
                    && ($0.itemsSkipped ?? 0) == 0
                    && ($0.status == .scanned || ($0.status == .degraded && $0.itemsInspected > 0))
            }
        let level: SkillUsageEvidenceLevel =
            if exact > 0 { .exact } else if inferred > 0 { .inferred } else if observableCoverage { .noObservedUse } else {
                .trackingUnavailable
            }
        return SkillUsageMetric(
            skillID: skill.id,
            skillName: skill.displayName,
            exactObservedUses: exact,
            inferredObservedUses: inferred,
            evidenceLevel: level,
            provenance: Set(evidence.map(\.provenance)),
            observedClients: Set(evidence.map(\.client)),
            lastObservedAt: evidence.map(\.date).max()
        )
    }.sorted { lhs, rhs in
        if lhs.observedUses != rhs.observedUses { return lhs.observedUses > rhs.observedUses }
        return lhs.skillName.localizedStandardCompare(rhs.skillName) == .orderedAscending
    }
}

private func buildQualityFindings(
    skills: [Skill],
    usage: [SkillUsageMetric]
) -> [SkillQualityFinding] {
    var findings: [SkillQualityFinding] = []
    let usageByID = Dictionary(uniqueKeysWithValues: usage.map { ($0.skillID, $0) })

    for skill in skills {
        guard skill.owned else { continue }
        let summary = skill.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.count < 24 {
            findings.append(
                finding(
                    skill: skill,
                    code: "description-too-short",
                    severity: .warning,
                    category: .description,
                    title: "Clarify when this skill should be used",
                    detail: "The description is too short to distinguish this skill from nearby workflows.",
                    action: "Describe the task, the situations that should trigger it, and its expected outcome."
                )
            )
        }
        let hasStructuredTriggerMetadata =
            !skill.triggers.isEmpty || !skill.negativeTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasStructuredTriggerMetadata {
            if skill.triggers.isEmpty {
                findings.append(
                    finding(
                        skill: skill,
                        code: "missing-triggers",
                        severity: .warning,
                        category: .triggers,
                        title: "Add realistic trigger phrases",
                        detail: "A negative boundary is recorded, but no positive example requests are available.",
                        action: "Add two or three phrases that resemble what a person would actually ask."
                    )
                )
            } else {
                let normalized = skill.triggers.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }.filter { !$0.isEmpty }
                if Set(normalized).count != normalized.count {
                    findings.append(
                        finding(
                            skill: skill,
                            code: "duplicate-triggers",
                            severity: .information,
                            category: .triggers,
                            title: "Remove duplicate trigger examples",
                            detail: "Repeated examples reduce the range of requests covered by the definition.",
                            action: "Replace duplicates with distinct ways a person might request the workflow."
                        )
                    )
                }
            }
            if skill.negativeTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                findings.append(
                    finding(
                        skill: skill,
                        code: "missing-negative-trigger",
                        severity: .information,
                        category: .triggers,
                        title: "Define a nearby request this skill should not handle",
                        detail: "A negative example helps prevent accidental activation for adjacent tasks.",
                        action: "Add one plausible request that belongs to another workflow."
                    )
                )
            }
        }
        if !skill.files.contains(where: { $0.lowercased() == "skill.md" }) {
            findings.append(
                finding(
                    skill: skill,
                    code: "missing-skill-file",
                    severity: .actionRequired,
                    category: .structure,
                    title: "Restore the canonical SKILL.md",
                    detail: "The managed inventory does not include the skill's required entry point.",
                    action: "Add SKILL.md to the package and validate it before installation."
                )
            )
        }
        let portableText = ([skill.summary, skill.negativeTrigger] + skill.triggers + skill.files).joined(separator: "\n")
        if portableText.contains("/Users/") || portableText.contains("~/") {
            findings.append(
                finding(
                    skill: skill,
                    code: "machine-path",
                    severity: .actionRequired,
                    category: .portability,
                    title: "Remove a machine-specific path",
                    detail: "The managed metadata contains a home-directory path that will not work for another user.",
                    action: "Resolve listed files relative to the skill directory and describe external paths as inputs."
                )
            )
        }
        let missingClients = skill.clients.filter { !$0.reportsLocalPresence }.map(\.client.rawValue).sorted()
        if !skill.clients.isEmpty, !missingClients.isEmpty {
            findings.append(
                finding(
                    skill: skill,
                    code: "client-drift",
                    severity: .warning,
                    category: .portability,
                    title: "Repair installation drift",
                    detail: "This managed skill is not currently present in: \(missingClients.joined(separator: ", ")).",
                    action: "Review the install plan for those clients, or remove clients that are no longer intended targets."
                )
            )
        }
        if usageByID[skill.id]?.evidenceLevel == .noObservedUse {
            findings.append(
                finding(
                    skill: skill,
                    code: "no-observed-use",
                    severity: .information,
                    category: .adoption,
                    title: "No observed use in the scan window",
                    detail: "The available history contained no supported activation evidence. This is not a complete usage count.",
                    action: "Review its description and triggers, archive it if obsolete, or keep it without changes."
                )
            )
        } else if let metric = usageByID[skill.id], (1...2).contains(metric.observedUses) {
            findings.append(
                finding(
                    skill: skill,
                    code: "low-observed-use",
                    severity: .information,
                    category: .adoption,
                    title: "Limited observed use in the scan window",
                    detail:
                        "Only \(metric.observedUses) supported use\(metric.observedUses == 1 ? "" : "s") was observed. History coverage is incomplete, so this is a lower bound rather than a definitive usage rate.",
                    action: "Review its activation guidance and keep, revise, or archive it based on your actual need."
                )
            )
        }
    }

    findings.append(contentsOf: overlappingSkillFindings(skills: skills))
    let severityOrder: [SkillQualitySeverity: Int] = [.actionRequired: 0, .warning: 1, .information: 2]
    return findings.sorted { lhs, rhs in
        let leftSeverity = severityOrder[lhs.severity] ?? 3
        let rightSeverity = severityOrder[rhs.severity] ?? 3
        if leftSeverity != rightSeverity { return leftSeverity < rightSeverity }
        if lhs.skillID != rhs.skillID { return lhs.skillID < rhs.skillID }
        return lhs.id < rhs.id
    }
}

private func finding(
    skill: Skill,
    code: String,
    severity: SkillQualitySeverity,
    category: SkillQualityCategory,
    title: String,
    detail: String,
    action: String
) -> SkillQualityFinding {
    SkillQualityFinding(
        id: "\(skill.id):\(code)",
        skillID: skill.id,
        severity: severity,
        category: category,
        title: title,
        detail: detail,
        recommendedAction: action
    )
}

private func overlappingSkillFindings(skills: [Skill]) -> [SkillQualityFinding] {
    let sorted = skills.filter(\.owned).sorted { $0.id < $1.id }
    guard sorted.count > 1 else { return [] }
    var findings: [SkillQualityFinding] = []
    for leftIndex in sorted.indices {
        for rightIndex in sorted.index(after: leftIndex)..<sorted.endIndex {
            let left = sorted[leftIndex]
            let right = sorted[rightIndex]
            let leftTokens = insightTokens(from: ([left.summary] + left.triggers).joined(separator: " "))
            let rightTokens = insightTokens(from: ([right.summary] + right.triggers).joined(separator: " "))
            let intersection = leftTokens.intersection(rightTokens)
            let union = leftTokens.union(rightTokens)
            guard intersection.count >= 4, !union.isEmpty,
                Double(intersection.count) / Double(union.count) >= 0.72
            else { continue }
            findings.append(
                finding(
                    skill: right,
                    code: "overlap-\(left.id)",
                    severity: .warning,
                    category: .overlap,
                    title: "Review overlap with \(left.displayName)",
                    detail: "The two definitions describe substantially similar requests.",
                    action: "Narrow their trigger boundaries or combine them into one maintained workflow."
                )
            )
        }
    }
    return findings
}

private struct RecommendationCandidate {
    var recommendation: ToolRecommendation
    var score: Int
}

private func buildRecommendations(
    options: InsightScanOptions,
    skills: [Skill],
    packages: [MarketplacePackage],
    discoverySupport: [String: Int],
    usage: [SkillUsageMetric],
    messages: [TokenizedConversationMessage]
) -> [ToolRecommendation] {
    guard !messages.isEmpty else { return [] }
    let usageByID = Dictionary(uniqueKeysWithValues: usage.map { ($0.skillID, $0) })
    var candidates: [RecommendationCandidate] = []

    for skill in skills {
        guard usageByID[skill.id]?.observedUses == 0 else { continue }
        let metadataTokens = insightTokens(
            from: ([skill.name, skill.displayName, skill.summary] + skill.triggers).joined(separator: " ")
        )
        let supporting = supportingConversations(messages: messages, metadataTokens: metadataTokens)
        guard supporting.count >= 2 else { continue }
        candidates.append(
            RecommendationCandidate(
                recommendation: ToolRecommendation(
                    id: "local-skill:\(skill.id)",
                    kind: .useExistingSkill,
                    title: "Use \(skill.displayName)",
                    summary: skill.summary,
                    rationale: "Recent requests overlap with this installed skill, but no supported activation evidence was observed.",
                    confidence: supporting.count >= 4 ? .high : .medium,
                    supportingConversationCount: supporting.count,
                    skillID: skill.id,
                    sourceName: "Local library"
                ),
                score: supporting.count * 10 + min(metadataTokens.count, 9)
            )
        )
    }

    if options.includeMarketplaceRecommendations {
        for package in packages where !package.isInstalled && package.installedClients.isEmpty {
            let metadataTokens = insightTokens(
                from: [package.name, package.publisher, package.summary, package.components.map(\.displayName).joined(separator: " ")]
                    .joined(separator: " ")
            )
            let supporting = supportingConversations(messages: messages, metadataTokens: metadataTokens)
            let supportCount = max(supporting.count, discoverySupport[package.id] ?? 0)
            guard supportCount >= 2 else { continue }
            let kind: ToolRecommendationKind
            if package.components.contains(.mcpServer) {
                kind = .mcpServer
            } else if package.components.contains(.plugin) {
                kind = .plugin
            } else if package.components.contains(.skill) {
                kind = .marketplaceSkill
            } else {
                continue
            }
            candidates.append(
                RecommendationCandidate(
                    recommendation: ToolRecommendation(
                        id: "marketplace:\(package.id)",
                        kind: kind,
                        title: package.name,
                        summary: package.summary,
                        rationale:
                            "Recent requests overlap with its published catalog metadata. Review provenance and permissions before installing.",
                        confidence: supportCount >= 4 ? .high : .medium,
                        supportingConversationCount: supportCount,
                        marketplacePackageID: package.id,
                        marketplacePackage: package,
                        sourceName: package.sourceName
                    ),
                    score: supportCount * 10 + min(metadataTokens.count, 9)
                )
            )
        }
    }

    for theme in insightThemes {
        let supporting = Set(
            messages.filter { message in
                message.tokens.intersection(theme.keywords).count >= theme.minimumKeywordMatches
            }.map(\.conversationID))
        guard supporting.count >= 2 else { continue }
        candidates.append(
            RecommendationCandidate(
                recommendation: ToolRecommendation(
                    id: "custom:\(theme.id)",
                    kind: .createCustomSkill,
                    title: theme.title,
                    summary: theme.summary,
                    rationale: "This workflow pattern appeared across multiple recent conversations and may be worth standardizing.",
                    confidence: supporting.count >= 4 ? .high : .medium,
                    supportingConversationCount: supporting.count,
                    sourceName: "Conversation pattern",
                    draftInstruction: theme.draftInstruction
                ),
                score: supporting.count * 10 + theme.keywords.count
            )
        )
    }

    var seen = Set<String>()
    return candidates.sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.recommendation.id < rhs.recommendation.id
    }.compactMap { candidate in
        guard seen.insert(candidate.recommendation.id).inserted else { return nil }
        return candidate.recommendation
    }.prefix(12).map { $0 }
}

private struct MarketplaceDiscovery {
    var packages: [MarketplacePackage]
    var supportByPackageID: [String: Int]
    var summary: MarketplaceDiscoverySummary
}

private func discoverMarketplacePackages(
    options: InsightScanOptions,
    cachedPackages: [MarketplacePackage],
    providers: [any MarketplaceProvider],
    messages: [TokenizedConversationMessage]
) async -> MarketplaceDiscovery {
    guard options.includeMarketplaceRecommendations, !providers.isEmpty else {
        return MarketplaceDiscovery(
            packages: cachedPackages,
            supportByPackageID: [:],
            summary: MarketplaceDiscoverySummary()
        )
    }
    let terms = safeDiscoveryTerms(from: messages)
    guard !terms.isEmpty else {
        return MarketplaceDiscovery(
            packages: cachedPackages,
            supportByPackageID: [:],
            summary: MarketplaceDiscoverySummary()
        )
    }

    var packagesByID: [String: MarketplacePackage] = [:]
    for package in cachedPackages where packagesByID[package.id] == nil {
        packagesByID[package.id] = package
    }
    var supportByPackageID: [String: Int] = [:]
    var summary = MarketplaceDiscoverySummary()
    providerLoop: for provider in providers.prefix(8) {
        for term in terms {
            guard !Task.isCancelled else {
                summary.wasCancelled = true
                break providerLoop
            }
            summary.queriesAttempted += 1
            let page: MarketplacePage
            do {
                page = try await provider.search(MarketplaceQuery(search: term.value, limit: 20))
                summary.queriesSucceeded += 1
            } catch {
                summary.queriesFailed += 1
                continue
            }
            summary.packagesReturned += min(page.packages.count, 20)
            for package in page.packages.prefix(20) {
                if packagesByID[package.id] == nil { packagesByID[package.id] = package }
                guard packageSupportsDiscoveryTerm(package, term: term.value) else { continue }
                supportByPackageID[package.id] = max(
                    supportByPackageID[package.id] ?? 0,
                    term.conversationCount
                )
            }
        }
    }
    return MarketplaceDiscovery(
        packages: packagesByID.values.sorted { $0.id < $1.id },
        supportByPackageID: supportByPackageID,
        summary: summary
    )
}

private func packageSupportsDiscoveryTerm(_ package: MarketplacePackage, term: String) -> Bool {
    let packageTokens = insightTokens(
        from: [
            package.name,
            package.summary,
            package.components.map(\.displayName).joined(separator: " "),
        ].joined(separator: " ")
    )
    let auditedTopics = Set(packageTokens.compactMap { discoveryVocabulary[$0] ?? $0 })
    return auditedTopics.contains(term)
}

private struct DiscoveryTerm {
    var value: String
    var conversationCount: Int
}

/// Search terms are selected only from this audited vocabulary. Arbitrary
/// transcript tokens, project names, paths, and identifiers never reach a
/// marketplace provider.
private let discoveryVocabulary: [String: String] = [
    "android": "android",
    "analytics": "analytics",
    "automation": "automation",
    "browser": "browser",
    "calendar": "calendar",
    "database": "database",
    "deploy": "deployment",
    "deployment": "deployment",
    "docker": "docker",
    "email": "email",
    "figma": "figma",
    "github": "github",
    "ios": "ios",
    "kubernetes": "kubernetes",
    "monitoring": "monitoring",
    "observability": "observability",
    "payments": "payments",
    "postgres": "postgres",
    "postgresql": "postgres",
    "research": "research",
    "security": "security",
    "sentry": "sentry",
    "shopify": "shopify",
    "slack": "slack",
    "supabase": "supabase",
    "testing": "testing",
    "tests": "testing",
]

private func safeDiscoveryTerms(from messages: [TokenizedConversationMessage]) -> [DiscoveryTerm] {
    var conversationsByTerm: [String: Set<String>] = [:]
    for message in messages {
        for token in message.tokens {
            guard let auditedTerm = discoveryVocabulary[token] else { continue }
            conversationsByTerm[auditedTerm, default: []].insert(message.conversationID)
        }
    }
    return conversationsByTerm.compactMap { term, conversations in
        guard conversations.count >= 2 else { return nil }
        return DiscoveryTerm(value: term, conversationCount: conversations.count)
    }.sorted { lhs, rhs in
        if lhs.conversationCount != rhs.conversationCount { return lhs.conversationCount > rhs.conversationCount }
        return lhs.value < rhs.value
    }.prefix(4).map { $0 }
}

private func supportingConversations(
    messages: [TokenizedConversationMessage],
    metadataTokens: Set<String>
) -> Set<String> {
    guard !metadataTokens.isEmpty else { return [] }
    return Set(
        messages.filter { message in
            let overlap = message.tokens.intersection(metadataTokens)
            return overlap.count >= 2
        }.map(\.conversationID))
}

private struct InsightTheme: Sendable {
    var id: String
    var title: String
    var summary: String
    var draftInstruction: String
    var keywords: Set<String>
    var minimumKeywordMatches: Int
}

private let insightThemes: [InsightTheme] = [
    InsightTheme(
        id: "release-readiness",
        title: "Create a release readiness skill",
        summary: "Standardize recurring build, test, review, and release checks.",
        draftInstruction:
            "Create a reusable release readiness skill that determines the relevant project checks, runs safe validation, reports blockers, and preserves explicit approval for publishing or deployment.",
        keywords: ["build", "release", "readiness", "review", "test", "tests", "validate", "verification", "deploy", "merge"],
        minimumKeywordMatches: 2
    ),
    InsightTheme(
        id: "browser-research",
        title: "Create a browser research skill",
        summary: "Turn repeated source-finding and comparison work into a consistent research workflow.",
        draftInstruction:
            "Create a browser research skill that gathers current primary sources, records dates and coverage limits, compares findings, and produces concise citations without taking external actions.",
        keywords: ["browse", "browser", "compare", "comparison", "current", "research", "search", "sources", "website", "online"],
        minimumKeywordMatches: 2
    ),
    InsightTheme(
        id: "ui-verification",
        title: "Create a UI verification skill",
        summary: "Capture a repeatable visual inspection and interaction-testing loop.",
        draftInstruction:
            "Create a UI verification skill that opens the exact build, inspects every affected screen in light and dark appearance, exercises interactions and empty/error states, and records visual plus automated evidence.",
        keywords: ["design", "screen", "swiftui", "ui", "ux", "visual", "layout", "dark", "light", "button"],
        minimumKeywordMatches: 2
    ),
    InsightTheme(
        id: "diagnostic-triage",
        title: "Create a diagnostic triage skill",
        summary: "Standardize recurring investigation, evidence collection, and fix verification.",
        draftInstruction:
            "Create a diagnostic triage skill that stays read-only during investigation, separates verified evidence from hypotheses, proposes scoped fixes, and verifies only changes the user approves.",
        keywords: ["bug", "debug", "diagnose", "error", "failure", "fix", "issue", "logs", "problem", "root"],
        minimumKeywordMatches: 2
    ),
    InsightTheme(
        id: "documentation-maintenance",
        title: "Create a documentation maintenance skill",
        summary: "Make recurring documentation updates consistent and verifiable.",
        draftInstruction:
            "Create a documentation maintenance skill that identifies the canonical source, updates only affected material, checks links and generated references, and clearly separates current guidance from historical notes.",
        keywords: ["docs", "documentation", "guide", "readme", "reference", "write", "update", "instructions", "manual", "notes"],
        minimumKeywordMatches: 2
    ),
]

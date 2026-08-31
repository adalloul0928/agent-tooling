import Foundation

/// User-controlled limits for a local, read-only conversation history scan.
/// The scanner never writes to either client's database and never includes
/// message text in its public result.
public struct InsightScanOptions: Codable, Hashable, Sendable {
    public var clients: Set<ClientKind>
    public var lookbackDays: Int
    public var maximumConversationsPerClient: Int
    public var maximumItemsPerConversation: Int
    public var maximumItemBytes: Int
    public var includeMarketplaceRecommendations: Bool

    public init(
        clients: Set<ClientKind> = [.claude, .codex],
        lookbackDays: Int = 30,
        maximumConversationsPerClient: Int = 50,
        maximumItemsPerConversation: Int = 500,
        maximumItemBytes: Int = 256 * 1_024,
        includeMarketplaceRecommendations: Bool = false
    ) {
        self.clients = clients
        self.lookbackDays = lookbackDays
        self.maximumConversationsPerClient = maximumConversationsPerClient
        self.maximumItemsPerConversation = maximumItemsPerConversation
        self.maximumItemBytes = maximumItemBytes
        self.includeMarketplaceRecommendations = includeMarketplaceRecommendations
    }

    var bounded: Self {
        var result = self
        result.clients = result.clients.intersection([.claude, .codex])
        result.lookbackDays = min(max(result.lookbackDays, 1), 365)
        result.maximumConversationsPerClient = min(max(result.maximumConversationsPerClient, 1), 200)
        result.maximumItemsPerConversation = min(max(result.maximumItemsPerConversation, 10), 2_000)
        result.maximumItemBytes = min(max(result.maximumItemBytes, 4 * 1_024), 1 * 1_024 * 1_024)
        return result
    }
}

public enum ConversationScanStatus: String, Codable, Hashable, Sendable {
    case scanned
    case degraded
    case unavailable
}

/// Describes what the scan could actually observe. This is intentionally
/// preserved with the report so a lower-bound count is never presented as
/// complete telemetry.
public struct ConversationScanCoverage: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(client.rawValue):\(sourceID)" }
    public var client: ClientKind
    public var sourceID: String
    public var sourceName: String
    public var adapterVersion: Int
    public var status: ConversationScanStatus
    public var conversationsScanned: Int
    public var itemsInspected: Int
    /// Items in the selected scan window that could not be inspected because
    /// they exceeded a bound or did not match the expected transcript shape.
    /// Optional so reports written before this counter existed still decode.
    public var itemsSkipped: Int?
    public var latestItemAt: Date?
    public var supportsUsageAttribution: Bool?
    public var detail: String

    public init(
        client: ClientKind,
        sourceID: String,
        sourceName: String,
        adapterVersion: Int = 1,
        status: ConversationScanStatus,
        conversationsScanned: Int = 0,
        itemsInspected: Int = 0,
        itemsSkipped: Int = 0,
        latestItemAt: Date? = nil,
        supportsUsageAttribution: Bool = false,
        detail: String
    ) {
        self.client = client
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.adapterVersion = adapterVersion
        self.status = status
        self.conversationsScanned = conversationsScanned
        self.itemsInspected = itemsInspected
        self.itemsSkipped = itemsSkipped
        self.latestItemAt = latestItemAt
        self.supportsUsageAttribution = supportsUsageAttribution
        self.detail = detail
    }
}

public enum SkillUsageEvidenceLevel: String, Codable, Hashable, Sendable {
    /// A client attributed a skill activation to a conversation turn.
    case exact
    /// A transcript explicitly named the skill or read its definition.
    case inferred
    /// At least one source was scanned, but no supported evidence was found.
    case noObservedUse
    /// No selected history source could be inspected.
    case trackingUnavailable
}

public enum SkillUsageProvenance: String, Codable, Hashable, Sendable {
    case claudeSkillToolCall
    case claudeAttribution
    case codexExplicitReference
    case skillDefinitionRead
}

public struct SkillUsageMetric: Identifiable, Codable, Hashable, Sendable {
    public var id: String { skillID }
    public var skillID: String
    public var skillName: String
    public var exactObservedUses: Int
    public var inferredObservedUses: Int
    public var evidenceLevel: SkillUsageEvidenceLevel
    public var provenance: Set<SkillUsageProvenance>
    public var observedClients: Set<ClientKind>
    public var lastObservedAt: Date?

    public init(
        skillID: String,
        skillName: String,
        exactObservedUses: Int = 0,
        inferredObservedUses: Int = 0,
        evidenceLevel: SkillUsageEvidenceLevel,
        provenance: Set<SkillUsageProvenance> = [],
        observedClients: Set<ClientKind> = [],
        lastObservedAt: Date? = nil
    ) {
        self.skillID = skillID
        self.skillName = skillName
        self.exactObservedUses = exactObservedUses
        self.inferredObservedUses = inferredObservedUses
        self.evidenceLevel = evidenceLevel
        self.provenance = provenance
        self.observedClients = observedClients
        self.lastObservedAt = lastObservedAt
    }

    public var observedUses: Int { exactObservedUses + inferredObservedUses }

    public var usageSummary: String {
        switch evidenceLevel {
        case .trackingUnavailable:
            "Tracking unavailable"
        case .noObservedUse:
            "No observed use"
        case .exact where inferredObservedUses > 0:
            "\(observedUses) observed uses (\(exactObservedUses) exact)"
        case .exact:
            "\(exactObservedUses) observed uses"
        case .inferred:
            "At least \(inferredObservedUses) inferred uses"
        }
    }
}

public enum SkillQualitySeverity: String, Codable, Hashable, Sendable {
    case information
    case warning
    case actionRequired
}

public enum SkillQualityCategory: String, Codable, Hashable, Sendable {
    case description
    case triggers
    case portability
    case structure
    case overlap
    case adoption
}

public struct SkillQualityFinding: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var skillID: String
    public var severity: SkillQualitySeverity
    public var category: SkillQualityCategory
    public var title: String
    public var detail: String
    public var recommendedAction: String

    public init(
        id: String,
        skillID: String,
        severity: SkillQualitySeverity,
        category: SkillQualityCategory,
        title: String,
        detail: String,
        recommendedAction: String
    ) {
        self.id = id
        self.skillID = skillID
        self.severity = severity
        self.category = category
        self.title = title
        self.detail = detail
        self.recommendedAction = recommendedAction
    }
}

public enum ToolRecommendationKind: String, Codable, Hashable, Sendable {
    case useExistingSkill
    case createCustomSkill
    case marketplaceSkill
    case mcpServer
    case plugin
}

public enum RecommendationConfidence: String, Codable, Hashable, Sendable {
    case high
    case medium
    case exploratory
}

/// A recommendation contains only catalog metadata, controlled taxonomy
/// labels, and aggregate counts. It never includes a conversation excerpt.
public struct ToolRecommendation: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var kind: ToolRecommendationKind
    public var title: String
    public var summary: String
    public var rationale: String
    public var confidence: RecommendationConfidence
    public var supportingConversationCount: Int
    public var skillID: String?
    public var marketplacePackageID: String?
    public var marketplacePackage: MarketplacePackage?
    public var sourceName: String?
    public var draftInstruction: String?

    public init(
        id: String,
        kind: ToolRecommendationKind,
        title: String,
        summary: String,
        rationale: String,
        confidence: RecommendationConfidence,
        supportingConversationCount: Int,
        skillID: String? = nil,
        marketplacePackageID: String? = nil,
        marketplacePackage: MarketplacePackage? = nil,
        sourceName: String? = nil,
        draftInstruction: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.rationale = rationale
        self.confidence = confidence
        self.supportingConversationCount = supportingConversationCount
        self.skillID = skillID
        self.marketplacePackageID = marketplacePackageID
        self.marketplacePackage = marketplacePackage
        self.sourceName = sourceName
        self.draftInstruction = draftInstruction
    }
}

public struct InsightsReport: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var generatedAt: Date
    public var windowStart: Date
    public var coverage: [ConversationScanCoverage]
    public var skillUsage: [SkillUsageMetric]
    public var qualityFindings: [SkillQualityFinding]
    public var recommendations: [ToolRecommendation]
    public var marketplaceDiscovery: MarketplaceDiscoverySummary?
    public var conversationsScanned: Int
    public var itemsInspected: Int
    public var reportFormatVersion: Int

    public init(
        id: UUID = UUID(),
        generatedAt: Date = .now,
        windowStart: Date,
        coverage: [ConversationScanCoverage],
        skillUsage: [SkillUsageMetric],
        qualityFindings: [SkillQualityFinding],
        recommendations: [ToolRecommendation],
        marketplaceDiscovery: MarketplaceDiscoverySummary? = nil,
        conversationsScanned: Int,
        itemsInspected: Int,
        reportFormatVersion: Int = 1
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.windowStart = windowStart
        self.coverage = coverage
        self.skillUsage = skillUsage
        self.qualityFindings = qualityFindings
        self.recommendations = recommendations
        self.marketplaceDiscovery = marketplaceDiscovery
        self.conversationsScanned = conversationsScanned
        self.itemsInspected = itemsInspected
        self.reportFormatVersion = reportFormatVersion
    }

    /// Raw conversation content exists only in ephemeral scanner memory.
    public var storesRawConversationContent: Bool { false }
}

public struct MarketplaceDiscoverySummary: Codable, Hashable, Sendable {
    public var queriesAttempted: Int
    public var queriesSucceeded: Int
    public var queriesFailed: Int
    public var packagesReturned: Int
    public var wasCancelled: Bool

    public init(
        queriesAttempted: Int = 0,
        queriesSucceeded: Int = 0,
        queriesFailed: Int = 0,
        packagesReturned: Int = 0,
        wasCancelled: Bool = false
    ) {
        self.queriesAttempted = queriesAttempted
        self.queriesSucceeded = queriesSucceeded
        self.queriesFailed = queriesFailed
        self.packagesReturned = packagesReturned
        self.wasCancelled = wasCancelled
    }
}

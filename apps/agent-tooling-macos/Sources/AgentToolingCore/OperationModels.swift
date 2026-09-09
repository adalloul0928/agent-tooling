import Foundation

public enum OperationKind: String, Codable, CaseIterable, Sendable {
    case scan
    case createSkill
    case installSkill
    case installPlugin
    case configureMCP
    case importSource
    case exportBackup
    case restoreBackup
    case exportEncryptedSync
    case restoreEncryptedSync
    case doctor
    case guidedAccountCheck
}

public enum OperationStepKind: String, Codable, CaseIterable, Sendable {
    case createDirectory
    case verifyCleanGitRepository
    case writeFile
    case writeEncryptedArchive
    case copyDirectory
    /// Removes a directory this app can prove it installed and that still
    /// matches what was approved. It never touches anything else.
    case removeManagedDirectory
    case replaceManagedLibrary
    case command
    case scan
    case openURL
    case manual
}

public struct OperationStep: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: OperationStepKind
    public var title: String
    public var detail: String
    public var executable: String?
    public var arguments: [String]
    public var sourcePath: String?
    /// SHA-256 of a reviewed source tree. Copy operations recompute this from
    /// the staged copy before committing so a changed source cannot bypass the
    /// review sheet.
    public var sourceFingerprint: String?
    public var destinationPath: String?
    /// Existing source-linked installation, captured when the repository was
    /// linked. Updates require this exact tree both at review and before swap.
    public var destinationFingerprint: String?
    /// Optional working directory for a native command. The engine accepts it
    /// only when it exactly matches the separately reviewed project root.
    public var currentDirectoryPath: String?
    /// The user-selected project root that authorizes a project-scoped skill
    /// destination. It is intentionally carried on the reviewed operation
    /// step instead of broadening the engine's global write allowlist.
    public var projectRootPath: String?
    public var contents: String?
    public var url: String?
    public var isReversible: Bool
    public var requiresUserAction: Bool
    /// Preflight and integrity checks stop the plan when they fail. Ordinary
    /// client-specific steps continue so one unavailable client does not hide
    /// successful work completed for another client.
    public var stopsOnFailure: Bool?

    public init(
        id: UUID = UUID(),
        kind: OperationStepKind,
        title: String,
        detail: String,
        executable: String? = nil,
        arguments: [String] = [],
        sourcePath: String? = nil,
        sourceFingerprint: String? = nil,
        destinationPath: String? = nil,
        destinationFingerprint: String? = nil,
        currentDirectoryPath: String? = nil,
        projectRootPath: String? = nil,
        contents: String? = nil,
        url: String? = nil,
        isReversible: Bool = true,
        requiresUserAction: Bool = false,
        stopsOnFailure: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.executable = executable
        self.arguments = arguments
        self.sourcePath = sourcePath
        self.sourceFingerprint = sourceFingerprint
        self.destinationPath = destinationPath
        self.destinationFingerprint = destinationFingerprint
        self.currentDirectoryPath = currentDirectoryPath
        self.projectRootPath = projectRootPath
        self.contents = contents
        self.url = url
        self.isReversible = isReversible
        self.requiresUserAction = requiresUserAction
        self.stopsOnFailure = stopsOnFailure ? true : nil
    }

    public var shouldStopOnFailure: Bool { stopsOnFailure == true }

    public var renderedCommand: String? {
        guard let executable else { return nil }
        let command = ([executable] + arguments).map(Self.shellEscaped).joined(separator: " ")
        return SensitiveValueRedactor.redact(command)
    }

    private static func shellEscaped(_ value: String) -> String {
        value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            ? value : "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}

enum SensitiveValueRedactor {
    private static let credentialExpressions: [NSRegularExpression] = [
        "(?i)https?://[^/@\\s]+@",
        "(?i)https?://[^\\s?#]+\\?[^\\s#]*(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|token|secret|password)=[^&\\s#]+",
        "(?im)(^|[ \\t])--?(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|token|secret|password)(?:=|[ \\t]+)[^\\s]+",
        "(?i)(api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|token|secret|password)\\s*[:=]\\s*[^\\s]+",
        "(?i)bearer\\s+[A-Za-z0-9._~+/-]+",
        "sk-[A-Za-z0-9_-]{16,}",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func containsCredentialValue(in text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return credentialExpressions.contains { expression in
            expression.firstMatch(in: text, range: range) != nil
        }
    }

    private static let replacements: [(expression: NSRegularExpression, replacement: String)] = {
        let patterns: [(pattern: String, replacement: String)] = [
            ("(?i)(https?://)[^/@\\s]+@", "$1[redacted]@"),
            ("(?i)(https?://[^\\s?#]+)\\?[^\\s#]+", "$1?[redacted]"),
            (
                "(?im)(^|[ \\t])(--?(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|token|secret|password)(?:=|[ \\t]+))[^\\s]+",
                "$1$2[redacted]"
            ),
            (
                "(?i)(api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|token|secret|password)\\s*[:=]\\s*[^\\s]+",
                "$1=[redacted]"
            ),
            (
                "(?m)(^|[ \\t])([A-Z0-9_]*(?:API_KEY|ACCESS_TOKEN|AUTH_TOKEN|CLIENT_SECRET|PASSWORD|SECRET|TOKEN))[ \\t]+[^\\s]+",
                "$1$2 [redacted]"
            ),
            ("(?i)bearer\\s+[A-Za-z0-9._~+/-]+", "Bearer [redacted]"),
            ("sk-[A-Za-z0-9_-]+", "[redacted]"),
        ]
        return patterns.compactMap { item in
            guard let expression = try? NSRegularExpression(pattern: item.pattern) else { return nil }
            return (expression, item.replacement)
        }
    }()

    static func redact(_ text: String) -> String {
        var value = text
        for replacement in replacements {
            let range = NSRange(value.startIndex..., in: value)
            value = replacement.expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement.replacement)
        }
        return value
    }
}

public struct OperationPlan: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: OperationKind
    public var title: String
    public var summary: String
    public var targetSurfaces: [TargetSurface]
    public var scope: ToolingScope
    public var steps: [OperationStep]
    public var createdAt: Date
    public var requiresConfirmation: Bool

    public init(
        id: UUID = UUID(),
        kind: OperationKind,
        title: String,
        summary: String,
        targetSurfaces: [TargetSurface] = [],
        scope: ToolingScope = .user,
        steps: [OperationStep],
        createdAt: Date = .now,
        requiresConfirmation: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.targetSurfaces = targetSurfaces
        self.scope = scope
        self.steps = steps
        self.createdAt = createdAt
        self.requiresConfirmation = requiresConfirmation
    }
}

public enum OperationStepStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case succeeded
    case failed
    case skipped
    case manual

    public var displayName: String {
        switch self {
        case .pending: "Never started"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .manual: "Needs you"
        }
    }
}

public struct OperationStepResult: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var stepID: UUID
    public var status: OperationStepStatus
    public var output: String
    public var startedAt: Date
    public var finishedAt: Date

    public init(id: UUID = UUID(), stepID: UUID, status: OperationStepStatus, output: String, startedAt: Date, finishedAt: Date) {
        self.id = id
        self.stepID = stepID
        self.status = status
        self.output = output
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// One named item from a batch, with the reason it ended the way it did.
///
/// A multi-step plan reports every item. Collapsing a batch into one verdict
/// hides the steps that were skipped and why, which is exactly the information
/// a person needs after a partial run.
public struct OperationItemOutcome: Identifiable, Codable, Hashable, Sendable {
    /// The identifier of the plan step this outcome belongs to.
    public var id: UUID
    public var title: String
    public var status: OperationStepStatus
    /// Why this item ended in this status, in the operator's words.
    public var reason: String

    public init(id: UUID, title: String, status: OperationStepStatus, reason: String) {
        self.id = id
        self.title = title
        self.status = status
        self.reason = reason
    }
}

public struct OperationReceipt: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var planID: UUID
    public var kind: OperationKind
    public var title: String
    public var state: HealthState
    public var targetSurfaces: [TargetSurface]
    public var results: [OperationStepResult]
    public var createdAt: Date
    public var verificationSummary: String
    /// Per-item outcomes, named and explained. Receipts written before this
    /// field existed decode with an empty list rather than failing to load.
    public var itemOutcomes: [OperationItemOutcome]

    public init(
        id: UUID = UUID(),
        planID: UUID,
        kind: OperationKind,
        title: String,
        state: HealthState,
        targetSurfaces: [TargetSurface],
        results: [OperationStepResult],
        createdAt: Date = .now,
        verificationSummary: String,
        itemOutcomes: [OperationItemOutcome] = []
    ) {
        self.id = id
        self.planID = planID
        self.kind = kind
        self.title = title
        self.state = state
        self.targetSurfaces = targetSurfaces
        self.results = results
        self.createdAt = createdAt
        self.verificationSummary = verificationSummary
        self.itemOutcomes = itemOutcomes
    }

    private enum CodingKeys: String, CodingKey {
        case id, planID, kind, title, state, targetSurfaces, results, createdAt, verificationSummary, itemOutcomes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        planID = try container.decode(UUID.self, forKey: .planID)
        kind = try container.decode(OperationKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        state = try container.decode(HealthState.self, forKey: .state)
        targetSurfaces = try container.decode([TargetSurface].self, forKey: .targetSurfaces)
        results = try container.decode([OperationStepResult].self, forKey: .results)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        verificationSummary = try container.decode(String.self, forKey: .verificationSummary)
        itemOutcomes = try container.decodeIfPresent([OperationItemOutcome].self, forKey: .itemOutcomes) ?? []
    }

    public func itemCount(_ status: OperationStepStatus) -> Int {
        results.count { $0.status == status }
    }

    /// "succeeded 2 · failed 1 · skipped 1", plus manual steps when there are
    /// any. Never a single aggregate word.
    public var outcomeTally: String {
        var parts = [
            "succeeded \(itemCount(.succeeded))",
            "failed \(itemCount(.failed))",
            "skipped \(itemCount(.skipped))",
        ]
        let manual = itemCount(.manual)
        if manual > 0 { parts.append("manual \(manual)") }
        return parts.joined(separator: " · ")
    }
}

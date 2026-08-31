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
    private static let credentialPatterns = [
        "(?i)https?://[^/@\\s]+@",
        "(?i)https?://[^\\s?#]+\\?[^\\s#]*(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|token|secret|password)=[^&\\s#]+",
        "(?im)(^|[ \\t])--?(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|token|secret|password)(?:=|[ \\t]+)[^\\s]+",
        "(?i)(api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|token|secret|password)\\s*[:=]\\s*[^\\s]+",
        "(?i)bearer\\s+[A-Za-z0-9._~+/-]+",
        "sk-[A-Za-z0-9_-]{16,}",
    ]

    static func containsCredentialValue(in text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return credentialPatterns.contains { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
            return expression.firstMatch(in: text, range: range) != nil
        }
    }

    static func redact(_ text: String) -> String {
        var value = text
        let replacements: [(pattern: String, replacement: String)] = [
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
        for replacement in replacements {
            guard let expression = try? NSRegularExpression(pattern: replacement.pattern) else { continue }
            let range = NSRange(value.startIndex..., in: value)
            value = expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement.replacement)
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

    public init(
        id: UUID = UUID(),
        planID: UUID,
        kind: OperationKind,
        title: String,
        state: HealthState,
        targetSurfaces: [TargetSurface],
        results: [OperationStepResult],
        createdAt: Date = .now,
        verificationSummary: String
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
    }
}

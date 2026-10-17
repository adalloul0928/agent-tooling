import Foundation

enum SourceLockFormat: String, Codable, Hashable, Sendable {
    case vercelGlobal, vercelProject
}

enum SourceLockReadStatus: String, Codable, Hashable, Sendable {
    case recognized, unsupportedVersion, malformed
}

enum SourceLockContext: Hashable, Sendable {
    case global(lockFilePath: String)
    case project(lockFilePath: String, projectRoot: String)

    var format: SourceLockFormat {
        switch self {
        case .global: .vercelGlobal
        case .project: .vercelProject
        }
    }

    var lockFilePath: String {
        switch self {
        case .global(let path), .project(let path, _): path
        }
    }
}

enum SourceLockLocator: Codable, Hashable, Sendable {
    case remote(repositoryID: String, sourceType: String, repositoryURL: String?, baseURL: String?)
    case deviceLocal(originalPath: String, resolvedPath: String?)
    case unavailable(sourceType: String)
}

enum SourceLockRevisionEvidence: Codable, Hashable, Sendable {
    /// A branch or tag request. It is not an approved or installed commit.
    case requestedRef(String)
}

enum SourceLockIntegrityAlgorithm: String, Codable, Hashable, Sendable {
    /// GitHub tree object ID for the skill folder. It is not a repository revision.
    case githubSkillFolderTreeObjectID
    /// Global v3 `skillFolderHash` from a non-GitHub provider; its algorithm is not declared.
    case vercelGlobalSkillFolderHashOpaque
    /// Vercel project lock v1: SHA-256 over each sorted relative path followed by its file bytes.
    case vercelProjectSkillFolderSHA256V1
    /// Provider-defined value whose algorithm is not declared by the pinned lock schema.
    case vercelWellKnownOpaque
}

struct SourceLockIntegrityEvidence: Codable, Hashable, Sendable {
    var algorithm: SourceLockIntegrityAlgorithm
    var value: String

    init(algorithm: SourceLockIntegrityAlgorithm, value: String) {
        self.algorithm = algorithm
        self.value = value
    }
}

enum SourceEvidenceGap: String, Codable, Hashable, Sendable {
    case missingRequestedRef
    case missingSkillPath
    case invalidSkillPath
    case invalidIntegrity
    case invalidLocator
    case deviceLocalOnly
}

struct SourceLockObservation: Codable, Hashable, Sendable {
    /// Installer timestamps are device observation metadata, not portable source claims.
    var installedAt: String?
    var updatedAt: String?
    var pluginNameHint: String?
    var subagentHints: [String]

    init(
        installedAt: String? = nil,
        updatedAt: String? = nil,
        pluginNameHint: String? = nil,
        subagentHints: [String] = []
    ) {
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.pluginNameHint = pluginNameHint
        self.subagentHints = subagentHints
    }
}

struct SourceLockEvidence: Codable, Hashable, Sendable {
    /// A dictionary key from the foreign lock. It is a display/match hint, never identity.
    var skillNameHint: String
    var locator: SourceLockLocator
    var revision: SourceLockRevisionEvidence?
    var skillPath: String?
    var integrity: [SourceLockIntegrityEvidence]
    var observation: SourceLockObservation
    var gaps: [SourceEvidenceGap]

    init(
        skillNameHint: String,
        locator: SourceLockLocator,
        revision: SourceLockRevisionEvidence? = nil,
        skillPath: String? = nil,
        integrity: [SourceLockIntegrityEvidence] = [],
        observation: SourceLockObservation = SourceLockObservation(),
        gaps: [SourceEvidenceGap] = []
    ) {
        self.skillNameHint = skillNameHint
        self.locator = locator
        self.revision = revision
        self.skillPath = skillPath
        self.integrity = integrity
        self.observation = observation
        self.gaps = gaps
    }
}

enum SourceLockDiagnosticCode: String, Codable, Hashable, Sendable {
    case documentTooLarge
    case malformedJSON
    case invalidRoot
    case unsupportedVersion
    case invalidSkillsMap
    case invalidEntry
    case invalidLocator
    case invalidSkillPath
    case invalidIntegrity
    case invalidObservation
    case invalidContext
}

struct SourceLockDiagnostic: Codable, Hashable, Sendable {
    var code: SourceLockDiagnosticCode
    var skillNameHint: String?
    var field: String?

    init(code: SourceLockDiagnosticCode, skillNameHint: String? = nil, field: String? = nil) {
        self.code = code
        self.skillNameHint = skillNameHint
        self.field = field
    }
}

struct SourceLockReadResult: Codable, Hashable, Sendable {
    var format: SourceLockFormat
    var schemaVersion: Int?
    var status: SourceLockReadStatus
    var evidence: [SourceLockEvidence]
    var diagnostics: [SourceLockDiagnostic]

    init(
        format: SourceLockFormat,
        schemaVersion: Int?,
        status: SourceLockReadStatus,
        evidence: [SourceLockEvidence] = [],
        diagnostics: [SourceLockDiagnostic] = []
    ) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.status = status
        self.evidence = evidence
        self.diagnostics = diagnostics
    }
}

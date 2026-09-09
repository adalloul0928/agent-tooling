import Foundation

public enum SourceLockFormat: String, Codable, Hashable, Sendable {
    case vercelGlobal, vercelProject
}

public enum SourceLockReadStatus: String, Codable, Hashable, Sendable {
    case recognized, unsupportedVersion, malformed
}

public enum SourceLockContext: Hashable, Sendable {
    case global(lockFilePath: String)
    case project(lockFilePath: String, projectRoot: String)

    public var format: SourceLockFormat {
        switch self {
        case .global: .vercelGlobal
        case .project: .vercelProject
        }
    }

    public var lockFilePath: String {
        switch self {
        case .global(let path), .project(let path, _): path
        }
    }
}

public enum SourceLockLocator: Codable, Hashable, Sendable {
    case remote(repositoryID: String, sourceType: String, repositoryURL: String?, baseURL: String?)
    case deviceLocal(originalPath: String, resolvedPath: String?)
    case unavailable(sourceType: String)
}

public enum SourceLockRevisionEvidence: Codable, Hashable, Sendable {
    /// A branch or tag request. It is not an approved or installed commit.
    case requestedRef(String)
}

public enum SourceLockIntegrityAlgorithm: String, Codable, Hashable, Sendable {
    /// GitHub tree object ID for the skill folder. It is not a repository revision.
    case githubSkillFolderTreeObjectID
    /// Global v3 `skillFolderHash` from a non-GitHub provider; its algorithm is not declared.
    case vercelGlobalSkillFolderHashOpaque
    /// Vercel project lock v1: SHA-256 over each sorted relative path followed by its file bytes.
    case vercelProjectSkillFolderSHA256V1
    /// Provider-defined value whose algorithm is not declared by the pinned lock schema.
    case vercelWellKnownOpaque
}

public struct SourceLockIntegrityEvidence: Codable, Hashable, Sendable {
    public var algorithm: SourceLockIntegrityAlgorithm
    public var value: String

    public init(algorithm: SourceLockIntegrityAlgorithm, value: String) {
        self.algorithm = algorithm
        self.value = value
    }
}

public enum SourceEvidenceGap: String, Codable, Hashable, Sendable {
    case missingRequestedRef
    case missingSkillPath
    case invalidSkillPath
    case invalidIntegrity
    case invalidLocator
    case deviceLocalOnly
}

public struct SourceLockObservation: Codable, Hashable, Sendable {
    /// Installer timestamps are device observation metadata, not portable source claims.
    public var installedAt: String?
    public var updatedAt: String?
    public var pluginNameHint: String?
    public var subagentHints: [String]

    public init(
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

public struct SourceLockEvidence: Codable, Hashable, Sendable {
    /// A dictionary key from the foreign lock. It is a display/match hint, never identity.
    public var skillNameHint: String
    public var locator: SourceLockLocator
    public var revision: SourceLockRevisionEvidence?
    public var skillPath: String?
    public var integrity: [SourceLockIntegrityEvidence]
    public var observation: SourceLockObservation
    public var gaps: [SourceEvidenceGap]

    public init(
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

public enum SourceLockDiagnosticCode: String, Codable, Hashable, Sendable {
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

public struct SourceLockDiagnostic: Codable, Hashable, Sendable {
    public var code: SourceLockDiagnosticCode
    public var skillNameHint: String?
    public var field: String?

    public init(code: SourceLockDiagnosticCode, skillNameHint: String? = nil, field: String? = nil) {
        self.code = code
        self.skillNameHint = skillNameHint
        self.field = field
    }
}

public struct SourceLockReadResult: Codable, Hashable, Sendable {
    public var format: SourceLockFormat
    public var schemaVersion: Int?
    public var status: SourceLockReadStatus
    public var evidence: [SourceLockEvidence]
    public var diagnostics: [SourceLockDiagnostic]

    public init(
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

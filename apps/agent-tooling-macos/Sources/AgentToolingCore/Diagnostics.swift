import Foundation

public struct DiagnosticBundleManifest: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var appVersion: String
    public var operatingSystem: String
    public var clients: [DiagnosticClient]
    public var validationSummary: DiagnosticValidationSummary
    public var receipts: [DiagnosticReceipt]
    public var errors: [String]

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date = .now,
        appVersion: String,
        operatingSystem: String,
        clients: [DiagnosticClient],
        validationSummary: DiagnosticValidationSummary,
        receipts: [DiagnosticReceipt],
        errors: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.operatingSystem = operatingSystem
        self.clients = clients
        self.validationSummary = validationSummary
        self.receipts = receipts
        self.errors = errors
    }
}

public struct DiagnosticClient: Codable, Hashable, Sendable {
    public var surface: TargetSurface
    public var isAvailable: Bool
    public var version: String?
    public var notes: [String]

    public init(surface: TargetSurface, isAvailable: Bool, version: String?, notes: [String]) {
        self.surface = surface
        self.isAvailable = isAvailable
        self.version = version
        self.notes = notes
    }
}

public struct DiagnosticValidationSummary: Codable, Hashable, Sendable {
    public var skillCount: Int
    public var mcpServerCount: Int
    public var pluginCount: Int
    public var profileCount: Int
    public var attentionCount: Int

    public init(skillCount: Int, mcpServerCount: Int, pluginCount: Int, profileCount: Int, attentionCount: Int) {
        self.skillCount = skillCount
        self.mcpServerCount = mcpServerCount
        self.pluginCount = pluginCount
        self.profileCount = profileCount
        self.attentionCount = attentionCount
    }
}

public struct DiagnosticReceipt: Codable, Hashable, Sendable {
    public var id: UUID
    public var planID: UUID
    public var kind: OperationKind
    public var title: String
    public var state: HealthState
    public var createdAt: Date
    public var verificationSummary: String
    public var results: [DiagnosticStepResult]

    public init(
        id: UUID,
        planID: UUID,
        kind: OperationKind,
        title: String,
        state: HealthState,
        createdAt: Date,
        verificationSummary: String,
        results: [DiagnosticStepResult]
    ) {
        self.id = id
        self.planID = planID
        self.kind = kind
        self.title = title
        self.state = state
        self.createdAt = createdAt
        self.verificationSummary = verificationSummary
        self.results = results
    }
}

public struct DiagnosticStepResult: Codable, Hashable, Sendable {
    public var status: OperationStepStatus
    public var output: String
    public var startedAt: Date
    public var finishedAt: Date

    public init(status: OperationStepStatus, output: String, startedAt: Date, finishedAt: Date) {
        self.status = status
        self.output = output
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct DiagnosticBundleExporter: Sendable {
    private let homeURL: URL

    public init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeURL = homeURL
    }

    public func manifest(
        snapshot: WorkspaceSnapshot,
        appVersion: String,
        errors: [String] = []
    ) -> DiagnosticBundleManifest {
        let clients = snapshot.targetObservations.map { observation in
            DiagnosticClient(
                surface: observation.surface,
                isAvailable: observation.isCommandAvailable,
                version: sanitized(observation.version ?? "").nilIfEmpty,
                notes: observation.notes.map(sanitized)
            )
        }.sorted { $0.surface.displayName < $1.surface.displayName }
        let attentionCount =
            snapshot.operationReceipts.filter { $0.state == .attention }.count
            + snapshot.targetObservations.filter { !$0.isCommandAvailable }.count
        let receipts = snapshot.operationReceipts.suffix(100).map { receipt in
            DiagnosticReceipt(
                id: receipt.id,
                planID: receipt.planID,
                kind: receipt.kind,
                title: sanitized(receipt.title),
                state: receipt.state,
                createdAt: receipt.createdAt,
                verificationSummary: sanitized(receipt.verificationSummary),
                results: receipt.results.map { result in
                    DiagnosticStepResult(
                        status: result.status,
                        output: sanitized(result.output),
                        startedAt: result.startedAt,
                        finishedAt: result.finishedAt
                    )
                }
            )
        }
        return DiagnosticBundleManifest(
            appVersion: sanitized(appVersion),
            operatingSystem: sanitized(ProcessInfo.processInfo.operatingSystemVersionString),
            clients: clients,
            validationSummary: DiagnosticValidationSummary(
                skillCount: snapshot.skills.count,
                mcpServerCount: snapshot.mcpServers.count,
                pluginCount: snapshot.plugins.count,
                profileCount: snapshot.profiles.count,
                attentionCount: attentionCount
            ),
            receipts: receipts,
            errors: errors.map(sanitized)
        )
    }

    public func export(_ manifest: DiagnosticBundleManifest, to destination: URL) throws {
        let fileManager = FileManager.default
        let standardized = destination.standardizedFileURL
        guard standardized.isFileURL else { throw DiagnosticBundleError.unsafeDestination }
        let parent = standardized.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw DiagnosticBundleError.unsafeDestination
        }
        if fileManager.fileExists(atPath: standardized.path(percentEncoded: false)) {
            let values = try standardized.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DiagnosticBundleError.unsafeDestination
            }
        }
        let data = try AgentToolingCoding.encoder(prettyPrinted: true).encode(manifest)
        try data.write(to: standardized, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: standardized.path(percentEncoded: false))
    }

    private func sanitized(_ value: String) -> String {
        let home = homeURL.standardizedFileURL.path(percentEncoded: false)
        var withoutPaths = value.replacingOccurrences(of: home, with: "~")
        let pathPatterns = [
            #"(?<![A-Za-z0-9._-])/(?:Users|home)/[^/\s]+"#,
            #"(?<![A-Za-z0-9._-])/(?:private/)?var/folders/[^/\s]+/[^/\s]+"#,
            #"(?i)(?<![A-Za-z0-9._-])[A-Z]:\\Users\\[^\\\s]+"#,
        ]
        for pattern in pathPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(withoutPaths.startIndex..., in: withoutPaths)
            withoutPaths = expression.stringByReplacingMatches(in: withoutPaths, range: range, withTemplate: "~")
        }
        let redacted = SensitiveValueRedactor.redact(withoutPaths)
        return String(redacted.prefix(16_384))
    }
}

enum DiagnosticBundleError: LocalizedError, Sendable {
    case unsafeDestination

    var errorDescription: String? {
        switch self {
        case .unsafeDestination: "Choose a regular file in an existing local folder for the support bundle."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

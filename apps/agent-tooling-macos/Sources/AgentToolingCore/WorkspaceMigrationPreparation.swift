import CryptoKit
import Foundation

public enum WorkspaceMigrationError: Error, Equatable, Sendable {
    case needsReview, invalidPreparation, missingPreparation, changedLegacyStore, changedSource(ArtifactID)
    case missingContent, preparationConflict, preparationPending
}

/// Device-local evidence. Paths and the raw checkpoint never enter portable sync.
public struct WorkspaceMigrationContentReference: Codable, Equatable, Sendable {
    public let artifactID: ArtifactID
    public let digest: ContentDigest
}

public struct WorkspaceMigrationSourceCapture: Codable, Equatable, Sendable {
    public let artifactID: ArtifactID
    public let directoryPath: String
}

public struct WorkspaceMigrationDeploymentName: Codable, Equatable, Sendable {
    public let artifactID: ArtifactID
    public let name: String
}

public struct WorkspaceMigrationManifest: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let attemptID: WorkspaceObjectID
    public let workspaceID: WorkspaceObjectID
    public let deviceID: WorkspaceObjectID
    public let initialRevisionID: WorkspaceObjectID
    public let legacyDatabasePath: String
    public let checkpointSHA256: String
    public let documentSHA256: String
    public let deviceSHA256: String
    public let content: [WorkspaceMigrationContentReference]
    public let sourceCaptures: [WorkspaceMigrationSourceCapture]
    public let deploymentNames: [WorkspaceMigrationDeploymentName]
}

/// Immutable review inputs, stored as three independently bounded canonical blobs.
/// Its initial revision is historical after bootstrap; later edits do not change it.
public struct WorkspaceMigrationRecord: Equatable, Sendable {
    public let manifest: WorkspaceMigrationManifest
    public let document: PortableWorkspaceDocument
    public let device: DeviceWorkspaceState
    public var inputDigest: String { get throws { try Self.hash(manifestBytes()) } }

    func manifestBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(manifest)
        guard bytes.count <= WorkspaceDocumentCoding.maximumDocumentBytes else {
            throw WorkspaceMigrationError.invalidPreparation
        }
        return bytes
    }

    static func decode(manifest bytes: Data, document documentBytes: Data, device deviceBytes: Data) throws -> Self {
        guard bytes.count <= WorkspaceDocumentCoding.maximumDocumentBytes else {
            throw WorkspaceMigrationError.invalidPreparation
        }
        let manifest = try JSONDecoder().decode(WorkspaceMigrationManifest.self, from: bytes)
        let document = try WorkspaceDocumentCoding.decode(documentBytes)
        let device = try WorkspaceDocumentCoding.decodeDeviceState(deviceBytes, against: document)
        let record = Self(manifest: manifest, document: document, device: device)
        try record.validate()
        // Reject ignored fields, alternate encodings and noncanonical ordering.
        guard try record.manifestBytes() == bytes else { throw WorkspaceMigrationError.invalidPreparation }
        return record
    }

    func validate() throws {
        let m = manifest
        guard m.formatVersion == 1, m.workspaceID == document.workspaceID,
              m.deviceID == device.deviceID, device.workspaceID == m.workspaceID,
              m.initialRevisionID == document.revision.id, document.revision.parentIDs.isEmpty,
              m.documentSHA256 == Self.hash(try WorkspaceDocumentCoding.encode(document)),
              m.deviceSHA256 == Self.hash(try WorkspaceDocumentCoding.encodeDeviceState(device)),
              m.legacyDatabasePath.hasPrefix("/"),
              NativeSkillDestination.isValidRoot(URL(fileURLWithPath: m.legacyDatabasePath)),
              Set(m.content.map(\.artifactID)).count == m.content.count,
              m.content.map(\.artifactID) == m.content.map(\.artifactID).sorted(),
              Set(m.sourceCaptures.map(\.artifactID)).count == m.sourceCaptures.count,
              m.sourceCaptures.map(\.artifactID) == m.sourceCaptures.map(\.artifactID).sorted(),
              Set(m.deploymentNames.map(\.artifactID)).count == m.deploymentNames.count,
              m.deploymentNames.map(\.artifactID) == m.deploymentNames.map(\.artifactID).sorted() else {
            throw WorkspaceMigrationError.invalidPreparation
        }
        try WorkspaceDomainValidation.requireDigest(m.checkpointSHA256, field: "migration checkpoint")
        try device.validateStructure(against: document)
        let definitions = Set(document.mcpDefinitions?.map(\.artifactID) ?? [])
        let central = document.artifacts.filter {
            switch $0.authority {
            case .centralPersonal, .centralUpstream: !definitions.contains($0.identity.id)
            default: false
            }
        }
        guard Set(central.map(\.identity.id)) == Set(m.content.map(\.artifactID)),
              Set(central.filter { $0.identity.parentPackageID == nil }.map(\.identity.id))
                == Set(m.sourceCaptures.map(\.artifactID)) else {
            throw WorkspaceMigrationError.invalidPreparation
        }
        for item in m.content {
            guard central.first(where: { $0.identity.id == item.artifactID })?.contentDigest == item.digest else {
                throw WorkspaceMigrationError.invalidPreparation
            }
        }
        for source in m.sourceCaptures {
            guard source.directoryPath.hasPrefix("/"),
                  NativeSkillDestination.isValidRoot(URL(fileURLWithPath: source.directoryPath)) else {
                throw WorkspaceMigrationError.invalidPreparation
            }
        }
        let assignedSkills = Set(document.assignments.compactMap { assignment -> ArtifactID? in
            guard document.artifacts.first(where: { $0.identity.id == assignment.artifactID })?.identity.kind == .skill else { return nil }
            return assignment.artifactID
        })
        guard assignedSkills == Set(m.deploymentNames.map(\.artifactID)),
              document.assignments.allSatisfy({ $0.destination.deviceIDs == [m.deviceID] }) else {
            throw WorkspaceMigrationError.invalidPreparation
        }
        for name in m.deploymentNames {
            guard let artifact = central.first(where: { $0.identity.id == name.artifactID }),
                  artifact.identity.kind == .skill, artifact.identity.parentPackageID == nil else {
                throw WorkspaceMigrationError.invalidPreparation
            }
            _ = try NativeSkillDestination.skillURL(client: .codex, skillID: name.name,
                homeURL: URL(fileURLWithPath: "/"), scope: .user, projectRoot: nil)
        }
    }

    static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Constructed exclusively from one checkpoint's assembly and assignment preview.
/// Building this value performs no I/O. Service staging checks the separate sources.
public struct WorkspaceMigrationPreparation: Sendable {
    public let record: WorkspaceMigrationRecord
    let checkpoint: WorkspaceLegacyCheckpoint
    let content: [ArtifactID: CapturedPackageTree]

    public static func build(
        attemptID: WorkspaceObjectID, checkpoint: WorkspaceLegacyCheckpoint, legacyDatabaseURL: URL,
        context: WorkspaceMigrationContext, decisions: WorkspaceMigrationDecisions,
        sourceDirectories: [ArtifactID: URL], projectIDsBySkillID: [ArtifactID: ArtifactID] = [:],
        nativePluginPlacements: [WorkspaceNativePluginMigrationPlacement] = []
    ) throws -> Self {
        guard NativeSkillDestination.isValidRoot(legacyDatabaseURL) else { throw WorkspaceMigrationError.invalidPreparation }
        let preview = try checkpoint.preview(context: context, decisions: decisions)
        guard let candidate = preview.assembly.candidate, preview.assembly.canAssemble else {
            throw WorkspaceMigrationError.needsReview
        }
        let skills = try WorkspaceSkillAssignmentMigration.preview(candidate: candidate, projectIDsBySkillID: projectIDsBySkillID)
        guard skills.canMigrate else { throw WorkspaceMigrationError.needsReview }
        let plugins = try WorkspaceNativePluginAssignmentMigration.preview(candidate: candidate, placements: nativePluginPlacements)
        guard plugins.canMigrate else { throw WorkspaceMigrationError.needsReview }
        var document = candidate.document
        document.assignments += skills.assignments + plugins.proposals
        document = try WorkspaceDocumentCoding.seal(document)
        let captures = try sourceDirectories.map { id, url in
            guard NativeSkillDestination.isValidRoot(url) else { throw WorkspaceMigrationError.invalidPreparation }
            return WorkspaceMigrationSourceCapture(artifactID: id, directoryPath: url.path)
        }.sorted { $0.artifactID < $1.artifactID }
        let manifest = WorkspaceMigrationManifest(formatVersion: 1, attemptID: attemptID,
            workspaceID: document.workspaceID, deviceID: candidate.device.deviceID,
            initialRevisionID: document.revision.id, legacyDatabasePath: legacyDatabaseURL.path,
            checkpointSHA256: checkpoint.sha256,
            documentSHA256: WorkspaceMigrationRecord.hash(try WorkspaceDocumentCoding.encode(document)),
            deviceSHA256: WorkspaceMigrationRecord.hash(try WorkspaceDocumentCoding.encodeDeviceState(candidate.device)),
            content: candidate.content.map { .init(artifactID: $0.key, digest: $0.value.digest) }.sorted { $0.artifactID < $1.artifactID },
            sourceCaptures: captures,
            deploymentNames: skills.deploymentNames.map { .init(artifactID: $0.key, name: $0.value) }.sorted { $0.artifactID < $1.artifactID })
        let record = WorkspaceMigrationRecord(manifest: manifest, document: document, device: candidate.device)
        try record.validate()
        return .init(record: record, checkpoint: checkpoint, content: candidate.content)
    }
}

public enum WorkspaceMigrationPhase: String, Sendable {
    case prepared, initialized
}

/// Initialized means the isolated revision store was bootstrapped. It never
/// means the packaged app switched stores, or that a native tool was installed.
public struct WorkspaceMigrationJournalEntry: Equatable, Sendable {
    public let record: WorkspaceMigrationRecord
    public let phase: WorkspaceMigrationPhase
}

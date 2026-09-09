import CryptoKit
import Foundation

public enum WorkspaceDocumentCoding {
    public static let maximumDocumentBytes = 32 * 1_024 * 1_024

    public static func seal(_ document: PortableWorkspaceDocument) throws -> PortableWorkspaceDocument {
        var sealed = document.canonicalized()
        sealed.revision.documentDigest = .unsealed
        try sealed.validateStructure()
        sealed.revision.documentDigest = try digest(for: sealed)
        return sealed
    }

    public static func encode(_ document: PortableWorkspaceDocument) throws -> Data {
        let canonical = document.canonicalized()
        try canonical.validateStructure()
        guard canonical.revision.documentDigest == (try digest(for: canonical)) else {
            throw WorkspaceDomainValidationError.digestMismatch
        }
        let data = try encoder().encode(canonical)
        guard data.count <= maximumDocumentBytes else {
            throw WorkspaceDomainValidationError.invalidField("workspace document size")
        }
        return data
    }

    public static func decode(_ data: Data) throws -> PortableWorkspaceDocument {
        guard data.count <= maximumDocumentBytes else {
            throw WorkspaceDomainValidationError.invalidField("workspace document size")
        }
        let decoded = try decoder().decode(PortableWorkspaceDocument.self, from: data).canonicalized()
        try decoded.validateStructure()
        guard decoded.revision.documentDigest == (try digest(for: decoded)) else {
            throw WorkspaceDomainValidationError.digestMismatch
        }
        guard try encoder().encode(decoded) == data else {
            throw WorkspaceDomainValidationError.nonCanonicalOrUnsupportedContent
        }
        return decoded
    }

    public static func encodeDeviceState(_ state: DeviceWorkspaceState) throws -> Data {
        let canonical = state.canonicalized()
        try canonical.validateStructure()
        let data = try encoder().encode(canonical)
        guard data.count <= maximumDocumentBytes else {
            throw WorkspaceDomainValidationError.invalidField("device workspace state size")
        }
        return data
    }

    public static func decodeDeviceState(
        _ data: Data, against portable: PortableWorkspaceDocument? = nil
    ) throws -> DeviceWorkspaceState {
        guard data.count <= maximumDocumentBytes else {
            throw WorkspaceDomainValidationError.invalidField("device workspace state size")
        }
        let decoded = try decoder().decode(DeviceWorkspaceState.self, from: data).canonicalized()
        try decoded.validateStructure(against: portable)
        guard try encoder().encode(decoded) == data else {
            throw WorkspaceDomainValidationError.nonCanonicalOrUnsupportedContent
        }
        return decoded
    }

    public static func digest(for document: PortableWorkspaceDocument) throws -> DocumentDigest {
        let canonical = document.canonicalized()
        let payload = DigestDocument(document: canonical)
        let bytes = try encoder().encode(payload)
        let value = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return DocumentDigest(value: value)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(canonicalTimestamp(date))
        }
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = timestampFormatter().date(from: text), canonicalTimestamp(date) == text else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Expected canonical UTC RFC 3339 milliseconds."))
            }
            return date
        }
        return decoder
    }

    private static func canonicalTimestamp(_ date: Date) -> String {
        timestampFormatter().string(from: WorkspaceDomainValidation.canonicalDate(date))
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}

private struct DigestDocument: Encodable {
    var schemaVersion: UInt
    var minimumReaderVersion: UInt
    var minimumWriterVersion: UInt
    var workspaceID: WorkspaceObjectID
    var revision: DigestRevision
    var artifacts: [ArtifactRecord]
    var sources: [PortableSourceDescriptor]
    var subscriptions: [UpstreamSubscription]
    var logicalProjects: [LogicalProjectRecord]
    var assignments: [AssignmentContribution]
    var presets: [PresetRecord]
    var tombstones: [ArtifactTombstone]
    var configurationState: WorkspaceConfigurationState?
    var mcpDefinitions: [PortableMCPDefinitionRecord]?

    init(document: PortableWorkspaceDocument) {
        schemaVersion = document.schemaVersion
        minimumReaderVersion = document.minimumReaderVersion
        minimumWriterVersion = document.minimumWriterVersion
        workspaceID = document.workspaceID
        revision = DigestRevision(revision: document.revision)
        artifacts = document.artifacts
        sources = document.sources
        subscriptions = document.subscriptions
        logicalProjects = document.logicalProjects
        assignments = document.assignments
        presets = document.presets
        tombstones = document.tombstones
        configurationState = document.configurationState
        mcpDefinitions = document.mcpDefinitions
    }
}

private struct DigestRevision: Encodable {
    var id: WorkspaceObjectID
    var parentIDs: [WorkspaceObjectID]
    var writerID: WorkspaceObjectID
    var createdAt: Date

    init(revision: WorkspaceRevision) {
        id = revision.id
        parentIDs = revision.parentIDs
        writerID = revision.writerID
        createdAt = revision.createdAt
    }
}

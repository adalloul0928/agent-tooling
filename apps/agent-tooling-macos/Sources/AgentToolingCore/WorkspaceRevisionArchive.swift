import Foundation

/// A bounded, complete ancestry graph. Every revision is digest-checked,
/// immutable, in the same workspace, and reachable from the advertised head.
/// Missing parents are an error, never permission to guess a merge base.
struct WorkspaceRevisionArchive: Hashable, Sendable {
    static let maximumBytes = 32 << 20
    let document: PortableWorkspaceDocument
    let ancestors: [PortableWorkspaceDocument]
    var documents: [PortableWorkspaceDocument] { ancestors + [document] }

    init(document: PortableWorkspaceDocument, ancestors: [PortableWorkspaceDocument]) throws {
        guard ancestors.count <= WorkspaceRevisionStore.ancestryLimit * 3 else {
            throw WorkspaceRevisionStoreError.archiveLimitExceeded
        }
        var byID: [WorkspaceObjectID: PortableWorkspaceDocument] = [:]
        for value in ancestors + [document] {
            guard value.workspaceID == document.workspaceID else {
                throw WorkspaceRevisionStoreError.wrongWorkspaceOrDevice
            }
            _ = try WorkspaceDocumentCoding.encode(value)
            if let known = byID[value.revision.id], known != value {
                throw WorkspaceRevisionStoreError.corruptState
            }
            byID[value.revision.id] = value
        }
        var reachable = Set<WorkspaceObjectID>()
        var pending = [document.revision.id]
        while let id = pending.popLast() {
            guard reachable.insert(id).inserted else { continue }
            guard reachable.count <= WorkspaceRevisionStore.ancestryLimit else {
                throw WorkspaceRevisionStoreError.archiveLimitExceeded
            }
            guard let value = byID[id] else { throw WorkspaceRevisionStoreError.missingAncestry }
            pending += value.revision.parentIDs
        }
        var counts: [WorkspaceObjectID: Int] = [:]
        var children: [WorkspaceObjectID: [WorkspaceObjectID]] = [:]
        for id in reachable {
            guard let value = byID[id] else { throw WorkspaceRevisionStoreError.missingAncestry }
            counts[id] = value.revision.parentIDs.count
            for parent in value.revision.parentIDs { children[parent, default: []].append(id) }
        }
        var ready = reachable.filter { counts[$0] == 0 }.sorted()
        var ordered: [PortableWorkspaceDocument] = []
        while let id = ready.popLast() {
            guard let value = byID[id] else { throw WorkspaceRevisionStoreError.missingAncestry }
            ordered.append(value)
            for child in (children[id] ?? []).sorted() {
                counts[child, default: 0] -= 1
                if counts[child] == 0 { ready.append(child) }
            }
        }
        guard ordered.count == reachable.count, ordered.last?.revision.id == document.revision.id else {
            throw WorkspaceRevisionStoreError.missingAncestry
        }
        self.document = document
        self.ancestors = Array(ordered.dropLast())
    }

    func encoded() throws -> Data {
        let encoder = AgentToolingCoding.encoder()
        encoder.outputFormatting.insert(.withoutEscapingSlashes)
        var encodedDocuments: [Data] = []
        var byteCount = try encoder.encode(Wire(formatVersion: 1, documents: [])).count
        for document in documents {
            let encoded = try WorkspaceDocumentCoding.encode(document)
            // Data becomes base64 in JSON. Budget the quotes and separator as
            // well, and stop before retaining an unbounded array of payloads.
            byteCount += ((encoded.count + 2) / 3) * 4 + 3
            guard byteCount <= Self.maximumBytes else { throw WorkspaceRevisionStoreError.archiveLimitExceeded }
            encodedDocuments.append(encoded)
        }
        let bytes = try encoder.encode(Wire(formatVersion: 1, documents: encodedDocuments))
        guard bytes.count <= Self.maximumBytes else { throw WorkspaceRevisionStoreError.archiveLimitExceeded }
        return bytes
    }

    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= maximumBytes else { throw WorkspaceRevisionStoreError.archiveLimitExceeded }
        let wire = try AgentToolingCoding.decoder().decode(Wire.self, from: bytes)
        guard wire.documents.count <= WorkspaceRevisionStore.ancestryLimit else {
            throw WorkspaceRevisionStoreError.archiveLimitExceeded
        }
        guard wire.formatVersion == 1, !wire.documents.isEmpty else { throw WorkspaceRevisionStoreError.corruptState }
        let documents = try wire.documents.map { try WorkspaceDocumentCoding.decode($0) }
        guard let document = documents.last else { throw WorkspaceRevisionStoreError.missingAncestry }
        return try Self(document: document, ancestors: Array(documents.dropLast()))
    }

    private struct Wire: Codable {
        let formatVersion: Int
        let documents: [Data]
    }
}

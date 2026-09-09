import CryptoKit
import Foundation

public enum WorkspaceMigrationIdentityError: Error, Equatable, Sendable {
    case duplicateKey
    case duplicateIdentity
    case invalidIdentity
    case generatedIdentityCollision
}

/// Stable identity allocation for migration previews. An absent inventory row
/// does not delete its mapping. Allocation never confers content ownership.
public enum WorkspaceMigrationIdentity {
    public static func mapping(
        keys: Set<LegacyReferenceKey>, workspaceID: WorkspaceObjectID,
        preserving previous: [WorkspaceMigrationIdentityEntry] = []
    ) throws -> [WorkspaceMigrationIdentityEntry] {
        var entries: [LegacyReferenceKey: WorkspaceMigrationIdentityEntry] = [:]
        var owners: [WorkspaceObjectID: LegacyReferenceKey] = [:]
        for entry in previous {
            try validate(entry.legacy)
            guard entries[entry.legacy] == nil else { throw WorkspaceMigrationIdentityError.duplicateKey }
            guard owners[entry.objectID] == nil else { throw WorkspaceMigrationIdentityError.duplicateIdentity }
            entries[entry.legacy] = entry
            owners[entry.objectID] = entry.legacy
        }
        let unseen = keys.subtracting(entries.keys).sorted(by: keyOrder)
        // Reserve catalog UUIDs before allocating hashes, so input ordering
        // cannot determine whether a catalog keeps its original identity.
        for key in unseen where key.domain == .catalogSource {
            try validate(key)
            guard let uuid = UUID(uuidString: key.identifier) else {
                throw WorkspaceMigrationIdentityError.invalidIdentity
            }
            let id = WorkspaceObjectID(uuid)
            if owners[id] == nil {
                entries[key] = .init(legacy: key, objectID: id)
                owners[id] = key
            }
        }
        for key in unseen where entries[key] == nil {
            try validate(key)
            let id = deterministicID(for: key, workspaceID: workspaceID)
            guard owners[id] == nil else { throw WorkspaceMigrationIdentityError.generatedIdentityCollision }
            entries[key] = .init(
                legacy: key, objectID: id)
            owners[id] = key
        }
        return entries.values.sorted { keyOrder($0.legacy, $1.legacy) }
    }

    private static func deterministicID(for key: LegacyReferenceKey, workspaceID: WorkspaceObjectID) -> WorkspaceObjectID {
        var bytes = Data("agent-tooling.migration-identity.v1\n".utf8)
        // Each UTF-8 field is length delimited; an absent owner has its own
        // discriminator and cannot collide with an identifier containing ':'.
        for field in [workspaceID.rawValue.uuidString.lowercased(), key.domain.rawValue, key.identifier] {
            append(field, to: &bytes)
        }
        bytes.append(key.ownerPolicyID == nil ? 0 : 1)
        if let owner = key.ownerPolicyID { append(owner, to: &bytes) }
        var digest = Array(SHA256.hash(data: bytes).prefix(16))
        digest[6] = (digest[6] & 0x0f) | 0x80 // UUID version 8, application-defined SHA-256 scheme.
        digest[8] = (digest[8] & 0x3f) | 0x80
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex.dropFirst(range.lowerBound).prefix(range.count))
        }
        // The input is exactly 16 hash bytes; UUID syntax is constructed above.
        return WorkspaceObjectID(UUID(uuidString: parts.joined(separator: "-"))!)
    }

    private static func append(_ text: String, to bytes: inout Data) {
        // Swift String equality treats canonically equivalent Unicode as the
        // same key. Hash that same identity, rather than its original bytes.
        let content = Data(text.precomposedStringWithCanonicalMapping.utf8)
        var length = UInt64(content.count).bigEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(content)
    }

    private static func validate(_ key: LegacyReferenceKey) throws {
        try WorkspaceDomainValidation.requireText(key.identifier, field: "legacy identifier", maximum: 512)
        if key.domain == .catalogSource, UUID(uuidString: key.identifier) == nil {
            throw WorkspaceMigrationIdentityError.invalidIdentity
        }
        if let owner = key.ownerPolicyID {
            guard key.domain == .configuration else { throw WorkspaceMigrationIdentityError.invalidIdentity }
            try WorkspaceDomainValidation.requireText(owner, field: "legacy policy owner", maximum: 512)
        }
    }

    private static func keyOrder(_ lhs: LegacyReferenceKey, _ rhs: LegacyReferenceKey) -> Bool {
        if lhs.domain != rhs.domain { return lhs.domain.rawValue < rhs.domain.rawValue }
        if lhs.identifier != rhs.identifier { return lhs.identifier < rhs.identifier }
        switch (lhs.ownerPolicyID, rhs.ownerPolicyID) {
        case (nil, .some): return true
        case (.some(let left), .some(let right)): return left < right
        default: return false
        }
    }
}

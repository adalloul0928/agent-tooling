import CryptoKit
import Foundation

/// Why a preset could not be created, renamed, or deleted, in the words a
/// screen shows. A preset is a named set of library items a person can put in
/// place together; every refusal here names the one thing that was wrong so the
/// sheet can point at it rather than disabling a button without saying why.
public enum WorkspacePresetCommandError: LocalizedError, Equatable, Sendable {
    case emptyName
    case nameTooLong(Int)
    case duplicateName(String)
    case noMembers
    case unknownMember
    case identityCollision
    case presetNotFound
    case previouslyRemoved

    /// The longest a preset name may be. Held here so the sheet and the command
    /// enforce exactly one limit.
    public static let maximumNameLength = 120

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "Give this preset a name."
        case .nameTooLong(let maximum):
            "A preset name can be at most \(maximum) characters."
        case .duplicateName(let name):
            "A preset called \(name) is already in your library. Choose another name."
        case .noMembers:
            "Choose at least one item for this preset."
        case .unknownMember:
            "One of the chosen items is no longer in your library, so it cannot go in a preset."
        case .identityCollision:
            "That identity is already used in this workspace."
        case .presetNotFound:
            "That preset is no longer in your library."
        case .previouslyRemoved:
            "A preset with this identity was removed before. Create a new one rather than re-adding it."
        }
    }
}

/// Creates a preset: a named set of items already in the library.
///
/// A preset lives in two places at once — an `ArtifactRecord` of kind `.preset`
/// that the rest of the document can point at, and a `PresetRecord` that holds
/// its name, revision and members — so both are written in one transaction or
/// neither is. Creating a preset assigns nothing and installs nothing: putting
/// its members in place is the separate act of following it and catching up.
///
/// Every rule the document enforces on a preset is checked here first, in the
/// words a person can read: a non-empty, trimmed, bounded, unique name, and at
/// least one member that is a live artifact in the same document.
public struct CreatePresetCommand: Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let presetID: ArtifactID
    public let name: String
    public let memberArtifactIDs: [ArtifactID]

    /// Validates the name shape up front; membership can only be checked
    /// against the document, so that happens when the command is applied.
    public init(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        presetID: ArtifactID = ArtifactID(),
        name: String,
        memberArtifactIDs: [ArtifactID]
    ) throws(WorkspacePresetCommandError) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyName }
        guard trimmed.count <= WorkspacePresetCommandError.maximumNameLength else {
            throw .nameTooLong(WorkspacePresetCommandError.maximumNameLength)
        }
        // Order is preserved as chosen, but a repeat is dropped: a preset's
        // members are a set, and the document rejects a duplicate outright.
        var seen: Set<ArtifactID> = []
        let members = memberArtifactIDs.filter { seen.insert($0).inserted }
        guard !members.isEmpty else { throw .noMembers }

        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.presetID = presetID
        self.name = trimmed
        self.memberArtifactIDs = members
    }

    func inputDigest() -> String {
        var fields = [
            "preset.create.v1",
            expectedRevisionID.rawValue.uuidString.lowercased(),
            idempotencyKey.rawValue.uuidString.lowercased(),
            presetID.rawValue.uuidString.lowercased(),
            name,
        ]
        fields += memberArtifactIDs.map { $0.rawValue.uuidString.lowercased() }
        let framed = fields.map {
            let value = $0.precomposedStringWithCanonicalMapping
            return String(value.utf8.count) + ":" + value
        }.joined(separator: "|")
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func apply(to document: inout PortableWorkspaceDocument) throws -> [ArtifactID] {
        guard !document.artifacts.contains(where: { $0.identity.id == presetID }),
            !document.presets.contains(where: { $0.id == presetID })
        else { throw WorkspacePresetCommandError.identityCollision }
        guard !document.tombstones.contains(where: { $0.artifactID == presetID }) else {
            throw WorkspacePresetCommandError.previouslyRemoved
        }
        // Two presets with one name is a name a person cannot tell apart in the
        // list, so it is refused here rather than saved and puzzled over later.
        guard
            !document.presets.contains(where: {
                $0.name.compare(name, options: .caseInsensitive) == .orderedSame
            })
        else { throw WorkspacePresetCommandError.duplicateName(name) }
        let live = Set(document.artifacts.map(\.identity.id))
        guard memberArtifactIDs.allSatisfy(live.contains) else {
            throw WorkspacePresetCommandError.unknownMember
        }

        document.artifacts.append(
            .init(
                identity: .init(id: presetID, kind: .preset, displayName: name),
                authority: .centralPersonal))
        document.presets.append(
            .init(id: presetID, name: name, revision: 1, memberArtifactIDs: memberArtifactIDs))
        return [presetID]
    }
}

/// Renames a preset in place, keeping its identity, revision and members.
public struct RenamePresetCommand: Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let presetID: ArtifactID
    public let name: String

    public init(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        presetID: ArtifactID,
        name: String
    ) throws(WorkspacePresetCommandError) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyName }
        guard trimmed.count <= WorkspacePresetCommandError.maximumNameLength else {
            throw .nameTooLong(WorkspacePresetCommandError.maximumNameLength)
        }
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.presetID = presetID
        self.name = trimmed
    }

    func inputDigest() -> String {
        let framed = [
            "preset.rename.v1",
            expectedRevisionID.rawValue.uuidString.lowercased(),
            idempotencyKey.rawValue.uuidString.lowercased(),
            presetID.rawValue.uuidString.lowercased(),
            name,
        ].map {
            let value = $0.precomposedStringWithCanonicalMapping
            return String(value.utf8.count) + ":" + value
        }.joined(separator: "|")
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func apply(to document: inout PortableWorkspaceDocument) throws -> [ArtifactID] {
        guard let presetIndex = document.presets.firstIndex(where: { $0.id == presetID }),
            let artifactIndex = document.artifacts.firstIndex(where: { $0.identity.id == presetID })
        else { throw WorkspacePresetCommandError.presetNotFound }
        guard
            !document.presets.contains(where: {
                $0.id != presetID && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
            })
        else { throw WorkspacePresetCommandError.duplicateName(name) }
        // The name lives on both records, so both are moved together to keep
        // the list label and the artifact's display name in step.
        document.presets[presetIndex].name = name
        document.artifacts[artifactIndex].identity.displayName = name
        return [presetID]
    }
}

/// Deletes a preset: the `PresetRecord`, its `ArtifactRecord`, and any
/// assignment that exists only because it was in this preset.
///
/// A preset's members are left exactly where they are — deleting the shelf is
/// not the same as removing what was on it. Only the preset's own contributions
/// are let go of, matched by the assignment reason that names this preset, so a
/// member a person also asked for another way keeps that other assignment. A
/// tombstone records the removal so the identity cannot silently return.
public struct DeletePresetCommand: Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let presetID: ArtifactID

    public init(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        presetID: ArtifactID
    ) {
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.presetID = presetID
    }

    func inputDigest() -> String {
        let framed = [
            "preset.delete.v1",
            expectedRevisionID.rawValue.uuidString.lowercased(),
            idempotencyKey.rawValue.uuidString.lowercased(),
            presetID.rawValue.uuidString.lowercased(),
        ].joined(separator: "|")
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func apply(to document: inout PortableWorkspaceDocument) throws -> [ArtifactID] {
        guard let artifactIndex = document.artifacts.firstIndex(where: { $0.identity.id == presetID }),
            document.presets.contains(where: { $0.id == presetID })
        else { throw WorkspacePresetCommandError.presetNotFound }
        document.presets.removeAll { $0.id == presetID }
        document.artifacts.remove(at: artifactIndex)
        // An assignment made because this preset asked for it would otherwise
        // point at a preset that no longer exists, which the document refuses;
        // a member's own manual assignment is a different reason and stays.
        document.assignments.removeAll { assignment in
            if case .preset(let id) = assignment.reason { return id == presetID }
            return false
        }
        document.tombstones.append(
            .init(artifactID: presetID, deletedInRevisionID: document.revision.id))
        return [presetID]
    }
}

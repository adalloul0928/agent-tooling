import CryptoKit
import Foundation

public enum WorkspaceAttachedAuthoringError: Error, Equatable, Sendable {
    case invalidDirectory
    case notAStandaloneSkill
    case identityCollision
    case alreadyAttached
    case sourceIdentityConflict
    case detachedItemMissing
    case notAttached
}

/// Registers a folder you already author in as the editable source for one
/// skill.
///
/// The folder stays exactly where it is and stays the only editable copy: no
/// bytes are taken into the central library, no content digest is recorded, and
/// nothing is written back into the folder. That is the whole point of an
/// attached root — it must never become a second master competing with the
/// repository you already publish from.
///
/// The path is device-local. Another Mac sees the same logical source and must
/// bind it to its own checkout.
public struct AttachedAuthoringIntakeCommand: Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let artifactID: ArtifactID
    public let sourceID: WorkspaceObjectID
    public let displayName: String
    public let declaredName: String
    public let aliases: [ExternalAlias]
    /// This Mac's path to the authored folder.
    public let directoryPath: String

    public init(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        artifactID: ArtifactID = ArtifactID(),
        sourceID: WorkspaceObjectID = WorkspaceObjectID(),
        displayName: String,
        prepared: PreparedStandaloneSkill,
        directory: URL,
        aliases: [ExternalAlias] = []
    ) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.contains("\0"),
              directory.standardizedFileURL.path == directory.path, directory.path.count <= 4_096 else {
            throw WorkspaceAttachedAuthoringError.invalidDirectory
        }
        guard prepared.review.upstream == nil else {
            // A folder that already tracks a publisher is an upstream
            // subscription, not an authoring root of your own.
            throw WorkspaceAttachedAuthoringError.notAStandaloneSkill
        }
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.artifactID = artifactID
        self.sourceID = sourceID
        self.displayName = displayName
        declaredName = prepared.frontmatter.name
        self.aliases = aliases
        directoryPath = directory.path
    }

    func inputDigest() -> String {
        var fields = ["attached-authoring.intake.v1",
                      expectedRevisionID.rawValue.uuidString.lowercased(),
                      idempotencyKey.rawValue.uuidString.lowercased(),
                      artifactID.rawValue.uuidString.lowercased(),
                      sourceID.rawValue.uuidString.lowercased(),
                      displayName, declaredName, directoryPath]
        fields += aliases.flatMap { [$0.namespace, $0.value] }
        let framed = fields.map {
            let value = $0.precomposedStringWithCanonicalMapping
            return String(value.utf8.count) + ":" + value
        }.joined(separator: "|")
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func apply(to document: inout PortableWorkspaceDocument) throws -> [ArtifactID] {
        guard !document.artifacts.contains(where: { $0.identity.id == artifactID }),
              !document.tombstones.contains(where: { $0.artifactID == artifactID }),
              artifactID.rawValue != sourceID.rawValue,
              !document.sources.contains(where: { $0.id == sourceID }),
              !document.subscriptions.contains(where: { $0.id == sourceID }) else {
            throw WorkspaceAttachedAuthoringError.identityCollision
        }
        document.sources.append(.init(id: sourceID, role: .attachedAuthoring, packageRelativePaths: ["."]))
        // No content digest: the folder is the content, and this workspace does
        // not hold a copy that could drift from it.
        document.artifacts.append(.init(
            identity: .init(id: artifactID, kind: .skill, displayName: displayName, aliases: aliases),
            authority: .attachedAuthoring(sourceRootID: sourceID),
            declaredName: declaredName))
        return [artifactID]
    }

    func bind(_ device: inout DeviceWorkspaceState) throws {
        guard !device.sourceLocations.contains(where: { $0.sourceRootID == sourceID }) else {
            throw WorkspaceAttachedAuthoringError.alreadyAttached
        }
        // One folder is one source here; attaching it twice would create two
        // editable masters for the same files.
        guard !device.sourceLocations.contains(where: { $0.checkoutPath == directoryPath }) else {
            throw WorkspaceAttachedAuthoringError.sourceIdentityConflict
        }
        device.sourceLocations.append(.init(sourceRootID: sourceID, checkoutPath: directoryPath))
    }
}

/// Stops managing an attached item. The folder and its contents are untouched:
/// detaching removes a registration, never files someone authored.
public struct AttachedAuthoringDetachCommand: Sendable {
    public let expectedRevisionID: WorkspaceObjectID
    public let idempotencyKey: WorkspaceObjectID
    public let artifactID: ArtifactID

    public init(
        expectedRevisionID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID(),
        artifactID: ArtifactID
    ) {
        self.expectedRevisionID = expectedRevisionID
        self.idempotencyKey = idempotencyKey
        self.artifactID = artifactID
    }

    func inputDigest() -> String {
        let framed = ["attached-authoring.detach.v1",
                      expectedRevisionID.rawValue.uuidString.lowercased(),
                      idempotencyKey.rawValue.uuidString.lowercased(),
                      artifactID.rawValue.uuidString.lowercased()].joined(separator: "|")
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func apply(to document: inout PortableWorkspaceDocument) throws -> (affected: [ArtifactID], sourceID: WorkspaceObjectID) {
        guard let index = document.artifacts.firstIndex(where: { $0.identity.id == artifactID }) else {
            throw WorkspaceAttachedAuthoringError.detachedItemMissing
        }
        guard case .attachedAuthoring(let sourceID) = document.artifacts[index].authority else {
            throw WorkspaceAttachedAuthoringError.notAttached
        }
        document.artifacts.remove(at: index)
        document.assignments.removeAll { $0.artifactID == artifactID }
        document.presets = document.presets.map {
            var preset = $0
            preset.memberArtifactIDs.removeAll { $0 == artifactID }
            return preset
        }
        // The source existed only to describe this item's folder.
        if !document.artifacts.contains(where: { $0.authority == .attachedAuthoring(sourceRootID: sourceID) }) {
            document.sources.removeAll { $0.id == sourceID }
        }
        document.tombstones.append(.init(artifactID: artifactID,
                                         aliases: document.artifacts.isEmpty ? [] : [],
                                         deletedInRevisionID: document.revision.id))
        return ([artifactID], sourceID)
    }
}

import CryptoKit
import Foundation

/// A point in this workspace's own history that can be returned to.
public struct WorkspaceRestorePoint: Hashable, Sendable {
    public let revisionID: WorkspaceObjectID
    public let createdAt: Date
    public let itemCount: Int
    public let assignmentCount: Int
    /// True for the revision the workspace is on right now.
    public let isCurrent: Bool
}

/// What returning to a restore point would change.
public struct WorkspaceRestorePreview: Sendable {
    public let restoredItems: [String]
    public let removedItems: [String]
    public let changedItems: [String]
    /// Named, not silently dropped: these were in that version and have been
    /// deleted since, so a restore leaves them deleted. Saying so is the point
    /// — otherwise someone restores to get one of these back and cannot tell
    /// why it did not return.
    public let deletedSinceItems: [String]
    public let assignmentDifference: Int
    /// True when restoring would change nothing. Items deleted since do not
    /// count: a restore will not bring them back either way.
    public var isEmpty: Bool {
        restoredItems.isEmpty && removedItems.isEmpty && changedItems.isEmpty && assignmentDifference == 0
    }
}

/// Returning a workspace to something it held before.
///
/// A restore is a new revision built from historical content, with the current
/// head as its parent. It never rewinds history, never resurrects what was
/// deliberately deleted since — tombstones are carried forward — and never
/// touches another device's copy until the result is shared like any other
/// revision.
public enum WorkspaceRestorePoints {
    /// Candidates to return to, walking back through this workspace's own
    /// history from where it is now.
    ///
    /// The order is ancestry, not the clock: nearest to the current state
    /// first. Revisions carry the writing Mac's wall clock, and this codebase
    /// never lets two Macs' clocks decide which state is later.
    public static func available(
        in store: WorkspaceRevisionStore,
        limit: Int = 20
    ) throws -> [WorkspaceRestorePoint] {
        guard let current = try store.snapshot() else { return [] }
        var points: [WorkspaceRestorePoint] = []
        var seen = Set<WorkspaceObjectID>()
        var queue = [current.document.revision.id]
        while let id = queue.first, points.count < max(1, limit) {
            queue.removeFirst()
            guard seen.insert(id).inserted, let document = try store.revision(id) else { continue }
            points.append(.init(
                revisionID: id, createdAt: document.revision.createdAt,
                itemCount: document.artifacts.filter { $0.identity.parentPackageID == nil }.count,
                assignmentCount: document.assignments.count,
                isCurrent: id == current.document.revision.id))
            queue += document.revision.parentIDs
        }
        return points
    }

    /// What would change, in the person's terms, without changing anything.
    public static func preview(
        restoring revisionID: WorkspaceObjectID,
        in store: WorkspaceRevisionStore
    ) throws -> WorkspaceRestorePreview? {
        guard let current = try store.snapshot(), let past = try store.revision(revisionID) else { return nil }
        let now = Dictionary(current.document.artifacts.map { ($0.identity.id, $0) },
                             uniquingKeysWith: { first, _ in first })
        let then = Dictionary(past.artifacts.map { ($0.identity.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        // Anything deleted since is left deleted; a restore is not a way to
        // bring back something that was deliberately removed.
        let deleted = Set(current.document.tombstones.map(\.artifactID))
        var restored: [String] = []
        var removed: [String] = []
        var changed: [String] = []
        var deletedSince: [String] = []
        for (id, artifact) in then.sorted(by: { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }) {
            guard !deleted.contains(id) else {
                deletedSince.append(artifact.identity.displayName)
                continue
            }
            guard let existing = now[id] else { restored.append(artifact.identity.displayName); continue }
            if existing != artifact { changed.append(artifact.identity.displayName) }
        }
        for (id, artifact) in now.sorted(by: { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString })
        where then[id] == nil {
            removed.append(artifact.identity.displayName)
        }
        return .init(restoredItems: restored, removedItems: removed, changedItems: changed,
                     deletedSinceItems: deletedSince,
                     assignmentDifference: past.assignments.count - current.document.assignments.count)
    }

    /// Commits the historical content as a new revision on top of the current
    /// head. Tombstones from the current state are carried forward.
    ///
    /// Carrying them forward is what keeps a restore from quietly undoing a
    /// deletion another Mac made and shared: a tombstone is how that deletion
    /// travelled here, and returning to an older state is not a decision to
    /// reverse it. `preview` names those items so the choice is visible.
    ///
    /// `expectedRevisionID` is the head the person's preview was computed
    /// against, and it is theirs to state rather than something this reads back
    /// from the store: a repeat of the same request has to describe the same
    /// request, or a retry after a lost answer would be treated as a new one
    /// and restore twice.
    @discardableResult
    public static func restore(
        _ revisionID: WorkspaceObjectID,
        in store: WorkspaceRevisionStore,
        expectedRevisionID: WorkspaceObjectID,
        writerID: WorkspaceObjectID,
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID()
    ) throws -> WorkspaceCommandReceipt {
        guard let current = try store.snapshot(), let past = try store.revision(revisionID) else {
            throw WorkspaceRevisionStoreError.missingArtifact
        }
        let deleted = Set(current.document.tombstones.map(\.artifactID))
        let digest = inputDigest(revisionID, expectedRevisionID, idempotencyKey)
        return try store.commitMetadata(
            expectedRevisionID: expectedRevisionID,
            idempotencyKey: idempotencyKey,
            inputDigest: digest,
            writerID: writerID
        ) { document in
            document.artifacts = past.artifacts.filter { !deleted.contains($0.identity.id) }
            document.sources = past.sources
            document.subscriptions = past.subscriptions
            document.logicalProjects = past.logicalProjects
            document.presets = past.presets
            document.assignments = past.assignments.filter { !deleted.contains($0.artifactID) }
            if document.schemaVersion >= 3 { document.mcpDefinitions = past.mcpDefinitions ?? [] }
            if document.schemaVersion >= 2, let state = past.configurationState {
                document.configurationState = state
            }
            // Deletions since this point stay deleted.
            return document.artifacts.map(\.identity.id).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        }
    }

    static func inputDigest(
        _ restored: WorkspaceObjectID, _ head: WorkspaceObjectID, _ idempotencyKey: WorkspaceObjectID
    ) -> String {
        let payload = Data(["workspace-restore.v1", restored.rawValue.uuidString.lowercased(),
                            head.rawValue.uuidString.lowercased(),
                            idempotencyKey.rawValue.uuidString.lowercased()]
            .joined(separator: "\u{0}").utf8)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

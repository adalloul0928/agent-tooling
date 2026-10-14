import CryptoKit
import Foundation

public enum WorkspaceSyncOutcome: Sendable {
    /// Nothing to do: the remote already holds this device's revision.
    case upToDate(head: String)
    /// The remote had nothing yet, so this device's revision was published.
    case published(GitWorkspacePublishReceipt)
    /// A remote revision was merged and the result published.
    case merged(receipt: WorkspaceCommandReceipt, published: GitWorkspacePublishReceipt)
    /// A remote revision was accepted locally; nothing needed publishing.
    case adopted(WorkspaceCommandReceipt)
    /// The merge needs a person's decision. Nothing was committed or published.
    case needsResolution([WorkspaceMergeConflict])
    /// The remote moved while this pass ran. Sync again; nothing was forced.
    case remoteMovedDuringSync
}

/// One pass of the sync lifecycle: read the remote, merge against the common
/// ancestor, commit the result locally, then publish it.
///
/// Local intent is never replaced by a remote revision, and nothing is
/// published until the merged revision is durably committed here. A merge that
/// still carries conflicts stops the pass: no revision is committed, nothing is
/// pushed, and the person decides. The remote is never force-pushed.
///
/// Arriving shared intent is not evidence that any native client file changed.
/// Deployment stays a separate reviewed step.
public actor WorkspaceSyncCoordinator {
    /// What one pass moved besides the document.
    public struct ContentReport: Sendable, Equatable {
        /// Trees this Mac copied into its own content store from the remote.
        public var imported: [ContentDigest] = []
        /// Trees this Mac added to the remote.
        public var published: [ContentDigest] = []
        /// Trees the document names that neither side could supply.
        public var missing: [ContentDigest] = []
        public init() {}
    }

    private let store: WorkspaceRevisionStore
    private let transport: any WorkspaceRevisionTransport
    private let writerID: WorkspaceObjectID
    private let contentStore: CentralPackageContentStore?
    private let status: (@Sendable () async -> PublishedDeviceStatus?)?
    /// What the most recent pass did with content. Read after a pass.
    public private(set) var lastContentReport = ContentReport()
    /// Every other Mac's published summary, as of the most recent read.
    public private(set) var deviceStatuses: [PublishedDeviceStatus] = []

    public init(store: WorkspaceRevisionStore, transport: any WorkspaceRevisionTransport,
                writerID: WorkspaceObjectID, contentStore: CentralPackageContentStore? = nil,
                status: (@Sendable () async -> PublishedDeviceStatus?)? = nil) {
        self.store = store
        self.transport = transport
        self.writerID = writerID
        self.contentStore = contentStore
        self.status = status
    }

    // MARK: Content

    /// Digests the document names for content this library authored, which is
    /// the content that travels. Followed skills are re-fetched from their
    /// repository on each Mac; native plugins are installed by their app.
    static func travellingDigests(in document: PortableWorkspaceDocument) -> Set<ContentDigest> {
        Set(document.artifacts.compactMap { artifact in
            guard case .centralPersonal = artifact.authority else { return nil }
            return artifact.contentDigest
        })
    }

    /// Copies into this Mac's content store every travelling tree the document
    /// names that the store lacks and the remote has. Verified on the way in.
    private func importContent(for document: PortableWorkspaceDocument, remote: GitWorkspaceRemoteState) async {
        guard let contentStore, transport.carriesContent else { return }
        for digest in Self.travellingDigests(in: document).sorted(by: { $0.value < $1.value }) {
            if (try? await contentStore.read(digest)) != nil { continue }
            guard remote.contentDigests.contains(digest) else {
                lastContentReport.missing.append(digest)
                continue
            }
            guard let tree = try? await transport.content(for: digest), tree.digest == digest else {
                lastContentReport.missing.append(digest)
                continue
            }
            if (try? await contentStore.store(tree)) != nil { lastContentReport.imported.append(digest) }
        }
    }

    /// The travelling trees the document names that this Mac holds and the
    /// remote does not yet: what goes up with the next publish.
    private func contentToPublish(for document: PortableWorkspaceDocument, remote: GitWorkspaceRemoteState) async -> [CapturedPackageTree] {
        guard let contentStore, transport.carriesContent else { return [] }
        var trees: [CapturedPackageTree] = []
        for digest in Self.travellingDigests(in: document).sorted(by: { $0.value < $1.value })
        where !remote.contentDigests.contains(digest) {
            if let tree = try? await contentStore.read(digest) {
                trees.append(tree)
                lastContentReport.published.append(digest)
            }
        }
        return trees
    }

    private func publish(
        _ document: PortableWorkspaceDocument, remote: GitWorkspaceRemoteState
    ) async throws -> GitWorkspacePublishReceipt {
        let content = await contentToPublish(for: document, remote: remote)
        let status = await status?()
        return try await transport.publish(
            document: document, content: content, status: status, expectedRemoteHead: remote.head)
    }

    private func beginPass(_ remote: GitWorkspaceRemoteState) {
        lastContentReport = ContentReport()
        deviceStatuses = remote.deviceStatuses
    }

    /// Applies a person's conflict decisions against freshly read state, then
    /// commits and publishes like an ordinary pass. The decisions are checked
    /// against the conflicts this moment actually has: if the remote moved
    /// since they were made, the pass reports what still needs deciding rather
    /// than applying an answer to a different question.
    public func resolve(
        _ resolutions: [WorkspaceConflictResolution],
        idempotencyKey: WorkspaceObjectID = WorkspaceObjectID()
    ) async throws -> WorkspaceSyncOutcome {
        guard let local = try store.snapshot() else {
            throw WorkspaceRevisionStoreError.notInitialized
        }
        let remote = try await transport.remoteState()
        guard let remoteDocument = remote.document, let remoteHead = remote.head else {
            return try await sync(idempotencyKey: idempotencyKey)
        }
        beginPass(remote)
        if remoteDocument.revision.id == local.document.revision.id { return .upToDate(head: remoteHead) }
        try store.importRemoteRevision(remoteDocument)
        let ancestor = try store.commonAncestor(withRemote: remoteDocument)
        let conflicts = WorkspaceMergeEngine.merge(base: ancestor, local: local.document,
                                                   remote: remoteDocument, writerID: writerID).conflicts
        let resolved = WorkspaceConflictResolver.resolve(
            base: ancestor, local: local.document, remote: remoteDocument,
            conflicts: conflicts, resolutions: resolutions, writerID: writerID)
        guard resolved.isResolved, let document = resolved.document else {
            return .needsResolution(resolved.remaining)
        }
        let receipt = try store.commitMerge(
            document: document,
            expectedLocalHead: local.document.revision.id,
            remoteRevisionID: remoteDocument.revision.id,
            idempotencyKey: idempotencyKey,
            inputDigest: try Self.inputDigest(remoteHead, local.document.revision.id))
        guard let committed = try store.revision(receipt.committedRevisionID) else {
            throw WorkspaceRevisionStoreError.corruptState
        }
        await importContent(for: committed, remote: remote)
        do {
            let published = try await publish(committed, remote: remote)
            return .merged(receipt: receipt, published: published)
        } catch GitWorkspaceTransportError.remoteAdvanced {
            return .remoteMovedDuringSync
        }
    }

    public func sync(idempotencyKey: WorkspaceObjectID = WorkspaceObjectID()) async throws -> WorkspaceSyncOutcome {
        guard let local = try store.snapshot() else {
            throw WorkspaceRevisionStoreError.notInitialized
        }
        let remote = try await transport.remoteState()
        beginPass(remote)

        guard let remoteDocument = remote.document, let remoteHead = remote.head else {
            let receipt = try await publish(local.document, remote: remote)
            return .published(receipt)
        }
        if remoteDocument.revision.id == local.document.revision.id {
            // Same revision both sides; content may still be owed either way,
            // and this Mac's status is refreshed when something is.
            await importContent(for: local.document, remote: remote)
            let owed = await contentToPublish(for: local.document, remote: remote)
            if !owed.isEmpty || status != nil {
                _ = try? await transport.publish(
                    document: local.document, content: owed, status: await status?(), expectedRemoteHead: remoteHead)
            }
            return .upToDate(head: remoteHead)
        }

        // Record the remote revision first so the merged revision's ancestry is
        // resolvable from this store alone afterwards.
        try store.importRemoteRevision(remoteDocument)
        let ancestor = try store.commonAncestor(withRemote: remoteDocument)

        // A remote revision that already descends from ours is adopted whole,
        // keeping its own identity so both devices settle on one head.
        if ancestor?.revision.id == local.document.revision.id {
            let receipt = try store.fastForward(
                to: remoteDocument.revision.id,
                expectedLocalHead: local.document.revision.id,
                idempotencyKey: idempotencyKey,
                inputDigest: try Self.inputDigest(remoteHead, local.document.revision.id))
            await importContent(for: remoteDocument, remote: remote)
            // Adopting changes no document, but this Mac's status and any content
            // it alone holds still go up.
            let owed = await contentToPublish(for: remoteDocument, remote: remote)
            if !owed.isEmpty || status != nil {
                _ = try? await transport.publish(
                    document: remoteDocument, content: owed, status: await status?(), expectedRemoteHead: remoteHead)
            }
            return .adopted(receipt)
        }

        let merge = WorkspaceMergeEngine.merge(base: ancestor, local: local.document,
                                               remote: remoteDocument, writerID: writerID)
        guard merge.isResolved, let document = merge.document else {
            return .needsResolution(merge.conflicts)
        }
        let receipt = try store.commitMerge(
            document: document,
            expectedLocalHead: local.document.revision.id,
            remoteRevisionID: remoteDocument.revision.id,
            idempotencyKey: idempotencyKey,
            inputDigest: try Self.inputDigest(remoteHead, local.document.revision.id))
        guard let committed = try store.revision(receipt.committedRevisionID) else {
            throw WorkspaceRevisionStoreError.corruptState
        }
        await importContent(for: committed, remote: remote)
        do {
            let published = try await publish(committed, remote: remote)
            return .merged(receipt: receipt, published: published)
        } catch GitWorkspaceTransportError.remoteAdvanced {
            // The merged revision is committed here and will publish on the
            // next pass. Nothing was forced onto the remote.
            return .remoteMovedDuringSync
        }
    }
}

private extension WorkspaceSyncCoordinator {
    /// Binds the receipt to the exact pair of revisions this pass combined, so
    /// a replay of the same pass returns its original result and a different
    /// pair cannot reuse the key.
    static func inputDigest(_ remoteHead: String, _ localHead: WorkspaceObjectID) throws -> String {
        let payload = Data(("workspace-sync.v1\u{0}" + remoteHead + "\u{0}"
            + localHead.rawValue.uuidString.lowercased()).utf8)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

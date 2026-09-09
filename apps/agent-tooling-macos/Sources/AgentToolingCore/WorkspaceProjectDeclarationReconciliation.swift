import Foundation

/// What a project's committed declaration asks for, against what this workspace
/// actually holds.
///
/// This is what makes a declaration worth committing: somebody checks the
/// project out on another Mac, and this says which of the things it asks for
/// they already have, which are at a different version than the lock pins, and
/// which they have not got at all.
///
/// It is pure and it changes nothing. Answering "what does this project want,
/// and what do I have" is a different act from getting it, and getting it goes
/// through the ordinary reviewed paths like everything else.
public enum WorkspaceProjectDeclarationReconciliation {
    public enum State: String, Hashable, Sendable, CaseIterable {
        /// Held, and at the exact revision the lock pins.
        case matchesLock
        /// Held, but at a different revision than the lock pins. The project
        /// asked for one set of bytes and this workspace has another.
        case differsFromLock
        /// Held, and the declaration pins nothing to compare against.
        case heldUnpinned
        /// Not in this workspace at all.
        case missing
    }

    public struct Item: Hashable, Sendable {
        public let name: String
        public let kind: ArtifactKind
        public let state: State
        /// Present when this workspace holds it.
        public let artifactID: ArtifactID?
        /// The revision the lock pins, when it pins one.
        public let lockedRevision: String?
        /// The revision this workspace holds, when it has one.
        public let heldRevision: String?
    }

    public struct Result: Sendable {
        public let items: [Item]
        public var missingCount: Int { items.filter { $0.state == .missing }.count }
        public var differingCount: Int { items.filter { $0.state == .differsFromLock }.count }
        /// True when everything the project asks for is here at the pinned
        /// version. Anything unpinned keeps this false: "we cannot tell" is not
        /// the same answer as "yes".
        public var isFullySatisfied: Bool {
            !items.isEmpty && items.allSatisfy { $0.state == .matchesLock }
        }
    }

    public static func reconcile(
        declaration: WorkspaceProjectDeclaration,
        lock: WorkspaceProjectLock?,
        against document: PortableWorkspaceDocument
    ) -> Result {
        let locked = Dictionary(
            (lock?.entries ?? []).map { (Key(name: $0.name, kind: $0.kind), $0) },
            uniquingKeysWith: { first, _ in first })
        let subscriptions = Dictionary(document.subscriptions.map { ($0.artifactID, $0) },
                                       uniquingKeysWith: { first, _ in first })
        // Matched on the name the item goes by and its kind, which is what the
        // declaration records. Workspace identifiers are per-workspace and mean
        // nothing in a file another Mac reads.
        var held: [Key: ArtifactRecord] = [:]
        for artifact in document.artifacts where artifact.identity.parentPackageID == nil {
            let key = Key(name: artifact.declaredName ?? artifact.identity.displayName,
                          kind: artifact.identity.kind)
            if held[key] == nil { held[key] = artifact }
        }

        let items = declaration.entries.map { entry -> Item in
            let key = Key(name: entry.name, kind: entry.kind)
            let pinned = locked[key]?.revision.value
            guard let artifact = held[key] else {
                return .init(name: entry.name, kind: entry.kind, state: .missing,
                             artifactID: nil, lockedRevision: pinned, heldRevision: nil)
            }
            let mine = subscriptions[artifact.identity.id]?.lock.approvedRevision.value
            let state: State
            if let pinned {
                state = mine == pinned ? .matchesLock : .differsFromLock
            } else {
                state = .heldUnpinned
            }
            return .init(name: entry.name, kind: entry.kind, state: state,
                         artifactID: artifact.identity.id, lockedRevision: pinned,
                         heldRevision: mine)
        }
        return .init(items: items)
    }

    private struct Key: Hashable {
        let name: String
        let kind: ArtifactKind
    }
}

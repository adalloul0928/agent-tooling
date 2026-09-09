import Foundation

/// Carries one portable workspace document to and from somewhere shared.
///
/// Two methods, and deliberately no more. A transport observes what is there
/// and publishes on top of exactly what it observed; it never merges, never
/// decides a conflict, and never overwrites a head it did not expect. Those
/// belong to `WorkspaceSyncCoordinator` and to the person, and keeping them out
/// of here is what lets a second transport exist without a second set of merge
/// rules to get subtly wrong.
///
/// `head` is opaque to callers: a Git commit for one transport, a content
/// digest for another. It is only ever compared for equality and passed back.
public protocol WorkspaceRevisionTransport: Actor {
    /// What is there now. A `nil` head means nothing has been published yet —
    /// which is not the same as an empty workspace.
    func remoteState() async throws -> GitWorkspaceRemoteState

    /// Publishes on top of `expectedRemoteHead`. A transport that finds
    /// something else there must refuse rather than overwrite it, and say what
    /// it found so the caller can merge.
    func publish(
        document: PortableWorkspaceDocument,
        expectedRemoteHead: String?
    ) async throws -> GitWorkspacePublishReceipt
}

extension GitWorkspaceTransport: WorkspaceRevisionTransport {}
